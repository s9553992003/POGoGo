"""
POGoGo Windows backend - GPS injection via pymobiledevice3
Commands: detect, tunneld, worker <udid>, clear <udid>
"""
import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path

# Windows paths
APPDATA = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
DATA_DIR = APPDATA / "POGoGo"
CACHE_DIR = DATA_DIR / "cache"
TMP_DIR = Path(os.environ.get("TEMP", Path.home() / "AppData" / "Local" / "Temp")) / "pogogo"
COORDS_FILE = TMP_DIR / "pogogo_coords.txt"
STOP_FILE   = TMP_DIR / "pogogo_stop.txt"
TUNNELD_LOG = TMP_DIR / "pogogo-tunneld.log"
WORKER_LOG  = TMP_DIR / "pogogo-worker.log"
DEVICE_CACHE = CACHE_DIR / "device_names.json"

for _d in [DATA_DIR, CACHE_DIR, TMP_DIR]:
    _d.mkdir(parents=True, exist_ok=True)


def load_device_cache() -> dict:
    try:
        if DEVICE_CACHE.exists():
            return json.loads(DEVICE_CACHE.read_text(encoding="utf-8"))
    except Exception:
        pass
    return {}


def save_device_cache(cache: dict):
    try:
        DEVICE_CACHE.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


async def cmd_detect():
    """List connected USB iPhones as JSON."""
    from pymobiledevice3.usbmux import list_devices as usbmux_list_devices
    from pymobiledevice3.lockdown import create_using_usbmux

    cache = load_device_cache()
    result = []

    try:
        devices = await usbmux_list_devices()
    except Exception:
        print(json.dumps([]), flush=True)
        return

    for dev in devices:
        if dev.connection_type != "USB":
            continue
        udid = dev.serial
        name = cache.get(udid)
        if not name:
            try:
                async with create_using_usbmux(serial=udid) as lockdown:
                    name = lockdown.display_name or lockdown.product_type or "iPhone"
                cache[udid] = name
                save_device_cache(cache)
            except Exception:
                name = cache.get(udid, "iPhone")
        result.append({"hwUDID": udid, "name": name})

    print(json.dumps(result), flush=True)


def cmd_tunneld():
    """Start tunneld service."""
    import logging as _log
    _log.basicConfig(
        level=_log.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[
            _log.FileHandler(str(TUNNELD_LOG), encoding="utf-8"),
            _log.StreamHandler(sys.stdout),
        ],
        force=True,
    )
    logger = _log.getLogger("pogogo.tunneld")

    try:
        from pymobiledevice3.tunneld.server import TunneldRunner, TunneldCore, TunnelTask
        from pymobiledevice3.tunneld.api import TUNNELD_DEFAULT_ADDRESS
        from pymobiledevice3.remote.common import TunnelProtocol
        from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy
        from pymobiledevice3 import usbmux
        from pymobiledevice3.lockdown import create_using_usbmux

        host, port = TUNNELD_DEFAULT_ADDRESS
        original_monitor_usbmux = TunneldCore.monitor_usbmux_task

        async def _try_connect_device(self, mux_device):
            tid = f"usbmux-{mux_device.serial}-{mux_device.connection_type}"
            if self.tunnel_exists_for_udid(mux_device.serial) or tid in self.tunnel_tasks:
                return True
            service = None
            try:
                async with await create_using_usbmux(mux_device.serial) as lockdown:
                    service = await CoreDeviceTunnelProxy.create(lockdown)
                self.tunnel_tasks[tid] = TunnelTask(
                    udid=mux_device.serial,
                    task=asyncio.create_task(
                        self.start_tunnel_task(tid, service, protocol=TunnelProtocol.TCP),
                        name=f"start-tunnel-task-{tid}",
                    ),
                )
                return True
            except Exception as e:
                logger.warning(f"{mux_device.serial}: tunnel failed: {e}")
                if service is not None:
                    try:
                        await service.close()
                    except Exception:
                        pass
                return False

        async def patched_monitor_usbmux(self):
            async def initial_scan_with_retry():
                delays = [0, 3, 5, 10, 15, 20]
                for attempt, delay in enumerate(delays):
                    if delay:
                        await asyncio.sleep(delay)
                    try:
                        mux = await usbmux.create_mux()
                        await mux.get_device_list(timeout=2.0)
                        devs = list(mux.devices)
                        await mux.close()
                    except Exception as e:
                        logger.warning(f"scan attempt {attempt+1} mux error: {e}")
                        continue
                    pending = [
                        d for d in devs
                        if not self.tunnel_exists_for_udid(d.serial)
                        and f"usbmux-{d.serial}-{d.connection_type}" not in self.tunnel_tasks
                    ]
                    if not pending:
                        return
                    for mux_device in pending:
                        await self._try_connect_device(mux_device)

            asyncio.create_task(initial_scan_with_retry(), name="pogogo-initial-scan")
            await original_monitor_usbmux(self)

        TunneldCore._try_connect_device = _try_connect_device
        TunneldCore.monitor_usbmux_task = patched_monitor_usbmux

        logger.info(f"Starting tunneld on {host}:{port}")
        runner = TunneldRunner(host=host, port=port, protocol=TunnelProtocol.TCP)
        runner._run_app()

    except Exception as e:
        logger.error(f"tunneld fatal: {e}", exc_info=True)
        sys.exit(1)


async def cmd_worker(udid: str):
    """GPS injection worker: reads coords file and injects via DVT."""
    import logging as _log
    _log.basicConfig(
        level=_log.INFO,
        format="%(asctime)s %(levelname)s: %(message)s",
        handlers=[
            _log.FileHandler(str(WORKER_LOG), encoding="utf-8"),
            _log.StreamHandler(sys.stdout),
        ],
        force=True,
    )
    logger = _log.getLogger("pogogo.worker")
    logger.info(f"Worker starting for {udid}")

    STOP_FILE.unlink(missing_ok=True)

    tunnel = await _get_tunnel_for_udid(udid, logger)
    if not tunnel:
        logger.error("No tunnel found")
        sys.exit(1)

    host, port = tunnel
    logger.info(f"Connecting RSD {host}:{port}")

    try:
        from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
        from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import DvtSecureSocketProxyService

        async with RemoteServiceDiscoveryService((host, port)) as rsd:
            async with DvtSecureSocketProxyService(lockdown=rsd) as dvt:
                async with LocationSimulation(dvt) as ls:
                    logger.info("LocationSimulation ready")
                    last_coord = None
                    last_set_time = 0.0
                    consecutive_errors = 0

                    while True:
                        if STOP_FILE.exists():
                            logger.info("Stop signal")
                            break

                        coord = _read_coords()
                        now = time.monotonic()

                        if coord and (coord != last_coord or now - last_set_time >= 2.0):
                            try:
                                await ls.set(coord[0], coord[1])
                                last_coord = coord
                                last_set_time = now
                                consecutive_errors = 0
                            except Exception as e:
                                consecutive_errors += 1
                                logger.error(f"ls.set error ({consecutive_errors}): {e}")
                                if consecutive_errors >= 3:
                                    break

                        await asyncio.sleep(0.1)

    except Exception as e:
        logger.error(f"Worker error: {e}", exc_info=True)
        sys.exit(1)


async def cmd_clear(udid: str):
    """Clear GPS spoofing on device."""
    logger = logging.getLogger("pogogo.clear")
    tunnel = await _get_tunnel_for_udid(udid, logger)
    if not tunnel:
        print("ERROR: no tunnel", flush=True)
        sys.exit(1)

    host, port = tunnel
    try:
        from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
        from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import DvtSecureSocketProxyService

        async with RemoteServiceDiscoveryService((host, port)) as rsd:
            async with DvtSecureSocketProxyService(lockdown=rsd) as dvt:
                async with LocationSimulation(dvt) as ls:
                    await ls.clear()
                    print("OK", flush=True)
    except Exception as e:
        print(f"ERROR: {e}", flush=True)
        sys.exit(1)


async def _get_tunnel_for_udid(udid: str, logger) -> tuple | None:
    """Query tunneld HTTP API for tunnel address."""
    import requests as req

    for attempt in range(5):
        if attempt > 0:
            await asyncio.sleep(attempt * 3)
        try:
            resp = req.get("http://127.0.0.1:49151", timeout=3)
            data = resp.json()
            for entry in data:
                eu = entry.get("udid") or entry.get("serial") or ""
                if eu == udid or udid == "":
                    tunnel = entry.get("tunnel") or entry.get("tunnelAddress") or {}
                    if isinstance(tunnel, dict):
                        return tunnel.get("host"), int(tunnel.get("port", 0))
                    elif isinstance(tunnel, str) and ":" in tunnel:
                        h, p = tunnel.rsplit(":", 1)
                        return h, int(p)
        except Exception as e:
            logger.warning(f"tunneld query attempt {attempt+1}: {e}")

    return None


def _read_coords() -> tuple | None:
    try:
        if COORDS_FILE.exists():
            text = COORDS_FILE.read_text(encoding="utf-8").strip()
            lat_s, lon_s = text.split(",")
            return float(lat_s), float(lon_s)
    except Exception:
        pass
    return None


def main():
    if len(sys.argv) < 2:
        print("Usage: POGoGo {detect|tunneld|worker <udid>|clear <udid>}")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "detect":
        asyncio.run(cmd_detect())
    elif cmd == "tunneld":
        cmd_tunneld()
    elif cmd == "worker":
        if len(sys.argv) < 3:
            print("Usage: POGoGo worker <udid>")
            sys.exit(1)
        asyncio.run(cmd_worker(sys.argv[2]))
    elif cmd == "clear":
        if len(sys.argv) < 3:
            print("Usage: POGoGo clear <udid>")
            sys.exit(1)
        asyncio.run(cmd_clear(sys.argv[2]))
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
