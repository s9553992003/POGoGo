"""
DeviceManager: device detection, tunneld subprocess, GPS worker subprocess.
No Windows Service required — tunneld runs as a child process of the app.
"""
import json
import sys
import time
from pathlib import Path

from PyQt6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, pyqtSignal

from backend.pogogo_tools import COORDS_FILE, STOP_FILE, TMP_DIR, TUNNELD_LOG


def _exe() -> str:
    """POGoGo.exe in frozen mode, python interpreter in dev mode."""
    return sys.executable


def _args(cmd: list[str]) -> list[str]:
    """Prepend main.py in dev mode."""
    if getattr(sys, "frozen", False):
        return cmd
    return [str(Path(__file__).parent / "main.py")] + cmd


def _proc_env() -> QProcessEnvironment:
    env = QProcessEnvironment.systemEnvironment()
    env.insert("PYTHONUNBUFFERED", "1")
    return env


def _is_port_open(port: int = 49151) -> bool:
    import socket
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except Exception:
        return False


class DeviceManager(QObject):
    devices_updated      = pyqtSignal(list)   # [{"hwUDID":..., "name":...}]
    connection_changed   = pyqtSignal(bool)   # device connected
    tunneld_status       = pyqtSignal(str)    # starting / running / stopped
    worker_running       = pyqtSignal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.devices: list[dict] = []
        self.selected_udid: str = ""
        self._tunneld_status = "stopped"

        self._tunneld_proc: QProcess | None = None
        self._worker_proc:  QProcess | None = None
        self._detect_proc:  QProcess | None = None

        self._worker_restart_count = 0
        self._last_set_time = 0.0

        # Health-check tunneld every 3 s
        self._health_timer = QTimer(self)
        self._health_timer.setInterval(3000)
        self._health_timer.timeout.connect(self._check_tunneld_health)
        self._health_timer.start()

        # Device polling every 5 s
        self._device_timer = QTimer(self)
        self._device_timer.setInterval(5000)
        self._device_timer.timeout.connect(self.detect_devices)
        self._device_timer.start()

        # Boot sequence
        QTimer.singleShot(300,  self._start_tunneld)
        QTimer.singleShot(1000, self.detect_devices)

    # ── Tunneld subprocess ────────────────────────────────────────────────────

    def _start_tunneld(self):
        if self._tunneld_proc and self._tunneld_proc.state() != QProcess.ProcessState.NotRunning:
            return
        self._set_tunneld_status("starting")
        p = QProcess(self)
        p.setProcessEnvironment(_proc_env())
        p.finished.connect(self._on_tunneld_finished)
        p.start(_exe(), _args(["tunneld"]))
        self._tunneld_proc = p

    def _on_tunneld_finished(self, code, status):
        self._set_tunneld_status("stopped")
        self._tunneld_proc = None
        # Auto-restart after 5 s
        QTimer.singleShot(5000, self._start_tunneld)

    def _check_tunneld_health(self):
        if _is_port_open():
            if self._tunneld_status != "running":
                self._set_tunneld_status("running")
        else:
            if self._tunneld_status == "running":
                self._set_tunneld_status("stopped")

    def _set_tunneld_status(self, s: str):
        if s != self._tunneld_status:
            self._tunneld_status = s
            self.tunneld_status.emit(s)

    def restart_tunneld(self):
        if self._tunneld_proc:
            self._tunneld_proc.kill()
            self._tunneld_proc.waitForFinished(2000)
            self._tunneld_proc = None
        QTimer.singleShot(500, self._start_tunneld)

    def get_tunneld_log(self, lines: int = 200) -> str:
        try:
            if TUNNELD_LOG.exists():
                all_lines = TUNNELD_LOG.read_text(encoding="utf-8", errors="replace").splitlines()
                return "\n".join(all_lines[-lines:])
        except Exception as e:
            return f"Error: {e}"
        return "(log empty)"

    # ── Device detection ──────────────────────────────────────────────────────

    def detect_devices(self):
        if self._detect_proc and self._detect_proc.state() != QProcess.ProcessState.NotRunning:
            return
        p = QProcess(self)
        p.setProcessEnvironment(_proc_env())
        p.readyReadStandardOutput.connect(lambda: self._on_detect_data(p))
        p.finished.connect(lambda: self._on_detect_done())
        p.start(_exe(), _args(["detect"]))
        self._detect_proc = p

    def _on_detect_data(self, p: QProcess):
        raw = bytes(p.readAllStandardOutput()).decode("utf-8", errors="replace")
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("["):
                try:
                    devs = json.loads(line)
                    self.devices = devs
                    self.devices_updated.emit(devs)
                    if devs and not self.selected_udid:
                        self.select_device(devs[0]["hwUDID"])
                    connected = any(d["hwUDID"] == self.selected_udid for d in devs)
                    self.connection_changed.emit(connected)
                    return
                except Exception:
                    pass

    def _on_detect_done(self):
        self._detect_proc = None
        if not self.devices:
            self.connection_changed.emit(False)

    def select_device(self, udid: str):
        self.selected_udid = udid

    def device_name(self, udid: str) -> str:
        for d in self.devices:
            if d["hwUDID"] == udid:
                return d.get("name", "iPhone")
        return udid[:8] if udid else ""

    # ── GPS Worker subprocess ─────────────────────────────────────────────────

    def set_location(self, lat: float, lon: float):
        now = time.time()
        if now - self._last_set_time < 0.3:
            return
        self._last_set_time = now
        self._write_coords(lat, lon)
        self._ensure_worker()

    def force_set_location(self, lat: float, lon: float):
        self._last_set_time = 0
        self.set_location(lat, lon)

    def reset_location(self):
        self._stop_worker()
        if not self.selected_udid:
            return
        p = QProcess(self)
        p.setProcessEnvironment(_proc_env())
        p.start(_exe(), _args(["clear", self.selected_udid]))
        p.waitForFinished(10000)

    def _write_coords(self, lat: float, lon: float):
        try:
            TMP_DIR.mkdir(parents=True, exist_ok=True)
            COORDS_FILE.write_text(f"{lat},{lon}", encoding="utf-8")
        except Exception as e:
            print(f"write_coords: {e}")

    def _ensure_worker(self):
        if self._worker_proc and self._worker_proc.state() == QProcess.ProcessState.Running:
            return
        if not self.selected_udid or not _is_port_open():
            return
        self._start_worker()

    def _start_worker(self):
        if not self.selected_udid:
            return
        STOP_FILE.unlink(missing_ok=True)
        p = QProcess(self)
        p.setProcessEnvironment(_proc_env())
        p.finished.connect(self._on_worker_finished)
        p.start(_exe(), _args(["worker", self.selected_udid]))
        self._worker_proc = p
        self.worker_running.emit(True)

    def _stop_worker(self):
        if self._worker_proc:
            try: STOP_FILE.touch()
            except Exception: pass
            self._worker_proc.terminate()
            self._worker_proc.waitForFinished(3000)
            self._worker_proc = None
        self.worker_running.emit(False)
        for f in (COORDS_FILE, STOP_FILE):
            f.unlink(missing_ok=True)

    def _on_worker_finished(self, code, status):
        self._worker_proc = None
        self.worker_running.emit(False)
        delays = [3000, 6000, 9000, 15000, 30000]
        if self._worker_restart_count < len(delays):
            delay = delays[self._worker_restart_count]
            self._worker_restart_count += 1
            QTimer.singleShot(delay, self._start_worker)
        else:
            self._worker_restart_count = 0

    def cleanup(self):
        self._stop_worker()
        if self._tunneld_proc:
            self._tunneld_proc.terminate()
            self._tunneld_proc.waitForFinished(3000)
