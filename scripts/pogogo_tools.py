#!/usr/bin/env python3
"""POGoGo 內建工具 — 統一 CLI 入口

Usage: pogogo <detect|tunneld|worker <udid>|clear <udid>>

  detect   列出 USB 連接的 iOS 裝置（JSON 輸出）
  tunneld  啟動 pymobiledevice3 remote tunneld（持續執行）
  worker   GPS 位置注入 worker（持續執行）
  clear    清除指定裝置的 GPS 模擬
"""
import sys
import os
import json
import time


def cmd_detect():
    """列出 USB 連接的 iOS 裝置，輸出 JSON 陣列。"""
    import asyncio
    import inspect

    # 裝置名稱快取（跨呼叫持久化，避免每次都重建 lockdown 連線）
    name_cache_path = os.path.expanduser('~/.pogogo/device_names.json')

    def load_name_cache():
        try:
            with open(name_cache_path) as f:
                return json.load(f)
        except Exception:
            return {}

    def save_name_cache(cache):
        try:
            os.makedirs(os.path.dirname(name_cache_path), exist_ok=True)
            with open(name_cache_path, 'w') as f:
                json.dump(cache, f)
        except Exception:
            pass

    async def _fetch_name(serial):
        """透過 lockdown 取得裝置名稱，最多等待 2 秒，逾時返回 serial。"""
        from pymobiledevice3.lockdown import create_using_usbmux

        async def _inner():
            lc_raw = create_using_usbmux(serial=serial)
            lc = (await lc_raw) if inspect.iscoroutine(lc_raw) else lc_raw
            name = (lc.all_values or {}).get('DeviceName', serial)
            close_raw = lc.close()
            if inspect.iscoroutine(close_raw):
                await close_raw
            return name

        try:
            return await asyncio.wait_for(_inner(), timeout=2.0)
        except Exception:
            return serial

    async def _detect():
        from pymobiledevice3.usbmux import list_devices
        raw = list_devices()
        devices = (await raw) if inspect.iscoroutine(raw) else raw
        usb = [d for d in devices if d.connection_type == 'USB']

        name_cache = load_name_cache()
        cache_updated = False
        result = []
        for dev in usb:
            if dev.serial in name_cache:
                name = name_cache[dev.serial]
            else:
                name = await _fetch_name(dev.serial)
                if name != dev.serial:  # 成功取得真實名稱，存入快取
                    name_cache[dev.serial] = name
                    cache_updated = True
            result.append({"hwUDID": dev.serial, "name": name})

        if cache_updated:
            save_name_cache(name_cache)
        return result

    try:
        result = asyncio.run(_detect())
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps([]), file=sys.stderr)
        sys.exit(1)


def cmd_tunneld():
    """啟動 pymobiledevice3 remote tunneld（持續阻塞）。"""
    import asyncio
    import logging
    import traceback
    from pymobiledevice3.tunneld.server import TunneldRunner, TunneldCore, TunnelTask
    from pymobiledevice3.tunneld.api import TUNNELD_DEFAULT_ADDRESS
    from pymobiledevice3.remote.common import TunnelProtocol
    from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux

    # Enable DEBUG-level logging so tunnel errors are visible in the log file
    logging.basicConfig(level=logging.DEBUG)

    host, port = TUNNELD_DEFAULT_ADDRESS

    # monitor_usbmux_task 只監聽新裝置事件，若 daemon 重啟時 iPhone 已連接則不會觸發
    # 在此 patch 加入啟動時的初始掃描
    original_monitor_usbmux = TunneldCore.monitor_usbmux_task

    async def _try_connect_device(self, mux_device):
        """嘗試為單一裝置建立 tunnel，回傳是否成功。"""
        tid = f"usbmux-{mux_device.serial}-{mux_device.connection_type}"
        if self.tunnel_exists_for_udid(mux_device.serial) or tid in self.tunnel_tasks:
            return True
        service = None
        try:
            async with await create_using_usbmux(mux_device.serial) as lockdown:
                service = await CoreDeviceTunnelProxy.create(lockdown)
            print(f'[pogogo] {mux_device.serial}: tunnel proxy created', flush=True)
            self.tunnel_tasks[tid] = TunnelTask(
                udid=mux_device.serial,
                task=asyncio.create_task(
                    self.start_tunnel_task(tid, service, protocol=TunnelProtocol.TCP),
                    name=f"start-tunnel-task-{tid}",
                ),
            )
            return True
        except Exception as e:
            print(f'[pogogo] {mux_device.serial}: FAILED: {type(e).__name__}: {e}', flush=True)
            if service is not None:
                try:
                    await service.close()
                except Exception:
                    pass
            return False

    async def patched_monitor_usbmux(self):
        # 啟動時以 retry 掃描已連接的 USB 裝置（最多嘗試 6 次，間隔遞增）
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
                    print(f'[pogogo] scan attempt {attempt+1} mux error: {e}', flush=True)
                    continue

                pending = [
                    d for d in devs
                    if not self.tunnel_exists_for_udid(d.serial)
                    and f"usbmux-{d.serial}-{d.connection_type}" not in self.tunnel_tasks
                ]
                if not pending:
                    print(f'[pogogo] all devices have tunnels after attempt {attempt+1}', flush=True)
                    return

                print(f'[pogogo] scan attempt {attempt+1}: {len(pending)} device(s) need tunnel', flush=True)
                for mux_device in pending:
                    await self._try_connect_device(mux_device)

            print('[pogogo] initial scan exhausted all retries', flush=True)

        asyncio.create_task(initial_scan_with_retry(), name="pogogo-initial-scan")
        print('[pogogo] initial scan task started, continuing to original monitor_usbmux_task', flush=True)
        # 繼續正常的 listen 監控
        await original_monitor_usbmux(self)

    TunneldCore._try_connect_device = _try_connect_device
    TunneldCore.monitor_usbmux_task = patched_monitor_usbmux

    runner = TunneldRunner(host=host, port=port, protocol=TunnelProtocol.TCP)
    runner._run_app()


def cmd_worker(udid):
    """GPS 位置注入 worker：從檔案讀取座標，透過 DVT 持續推送。"""
    import asyncio
    COORDS = '/tmp/pogogo_coords.txt'
    STOP   = '/tmp/pogogo_stop.txt'
    LOG    = '/tmp/pogogo-worker.log'

    def log(msg):
        try:
            with open(LOG, 'a') as f:
                f.write(str(msg) + '\n')
        except Exception:
            pass

    if os.path.exists(STOP):
        os.remove(STOP)

    def read_coords():
        try:
            with open(COORDS) as f:
                parts = f.read().strip().split(',')
            return round(float(parts[0]), 7), round(float(parts[1]), 7)
        except Exception:
            return None

    REFRESH_INTERVAL = 2.0  # 靜止時每 2 秒刷新，防止 iOS 回退真實 GPS

    async def _run():
        import requests
        from pymobiledevice3.tunneld.api import get_tunneld_devices
        from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import DvtSecureSocketProxyService
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

        try:
            tunneld_udids = list(requests.get('http://127.0.0.1:49151', timeout=2).json().keys())
        except Exception:
            tunneld_udids = []

        if tunneld_udids and udid not in tunneld_udids:
            log('device not in tunneld: ' + udid)
            log('tunneld has: ' + ', '.join(tunneld_udids))
            sys.exit(2)

        rsds = await get_tunneld_devices()
        target = next((r for r in rsds if r.udid == udid), None)
        if not target:
            log('device not in tunneld (rsd): ' + udid)
            if rsds:
                log('available rsds: ' + ', '.join(r.udid for r in rsds))
            sys.exit(2)

        log('connecting to ' + udid)
        async with DvtSecureSocketProxyService(target) as dvt:
            log('DVT connected')
            ls = LocationSimulation(dvt)
            log('LocationSimulation ready')
            last = None
            last_set_time = 0.0
            while not os.path.exists(STOP):
                c = read_coords()
                now = time.time()
                if c and (c != last or now - last_set_time >= REFRESH_INTERVAL):
                    try:
                        await ls.set(c[0], c[1])
                        changed = c != last
                        last = c
                        last_set_time = now
                        log(('set ' if changed else 'refresh ') + str(c))
                    except Exception as e:
                        log('set error: ' + str(e))
                        return
                await asyncio.sleep(0.1)

    try:
        asyncio.run(_run())
    except Exception as e:
        log('fatal: ' + str(e))
        sys.exit(1)

    log('worker done')


def cmd_clear(udid):
    """清除指定裝置的 GPS 模擬。"""
    import asyncio

    async def _clear():
        from pymobiledevice3.tunneld.api import get_tunneld_devices
        from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import DvtSecureSocketProxyService
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

        rsds = await get_tunneld_devices()
        target = next((r for r in rsds if r.udid == udid), None)
        if not target:
            print(f'device {udid} not found in tunneld', file=sys.stderr)
            sys.exit(2)

        async with DvtSecureSocketProxyService(target) as dvt:
            ls = LocationSimulation(dvt)
            await ls.clear()

    try:
        asyncio.run(_clear())
    except Exception as e:
        print(f'clear error: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == 'detect':
        cmd_detect()
    elif cmd == 'tunneld':
        cmd_tunneld()
    elif cmd == 'worker':
        if len(sys.argv) < 3:
            print('Usage: pogogo worker <udid>', file=sys.stderr)
            sys.exit(1)
        cmd_worker(sys.argv[2])
    elif cmd == 'clear':
        if len(sys.argv) < 3:
            print('Usage: pogogo clear <udid>', file=sys.stderr)
            sys.exit(1)
        cmd_clear(sys.argv[2])
    else:
        print(f'Unknown command: {cmd}', file=sys.stderr)
        sys.exit(1)
