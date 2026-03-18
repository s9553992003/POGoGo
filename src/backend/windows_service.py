"""
Windows Service for POGoGo tunneld.
Install:   pogogo.exe --install-service
Uninstall: pogogo.exe --uninstall-service
Start:     pogogo.exe --start-service
"""
import sys
import os
import subprocess
import logging
from pathlib import Path

SERVICE_NAME = "POGoGoTunneld"
SERVICE_DISPLAY = "POGoGo Tunnel Daemon"
SERVICE_DESC = "Maintains iOS 17+ DVT tunnel for POGoGo GPS spoofing"


def get_exe_path() -> str:
    """Return path to POGoGo.exe."""
    if getattr(sys, "frozen", False):
        return sys.executable
    # Dev mode: use python + script
    return f'"{sys.executable}" "{os.path.abspath(__file__)}"'


def install_service():
    """Install tunneld as Windows Service using sc.exe (requires admin)."""
    exe = get_exe_path()
    cmd_args = f'"{exe}" --tunneld'

    # Use sc.exe to create service
    cmds = [
        ["sc", "create", SERVICE_NAME,
         "binPath=", cmd_args,
         "start=", "auto",
         "DisplayName=", SERVICE_DISPLAY],
        ["sc", "description", SERVICE_NAME, SERVICE_DESC],
        ["sc", "start", SERVICE_NAME],
    ]

    for cmd in cmds:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode not in (0, 1056):  # 1056 = already started
            logging.error(f"sc.exe error: {result.stderr}")
            return False, result.stderr

    return True, "Service installed and started"


def uninstall_service():
    """Remove the Windows Service."""
    cmds = [
        ["sc", "stop", SERVICE_NAME],
        ["sc", "delete", SERVICE_NAME],
    ]
    for cmd in cmds:
        subprocess.run(cmd, capture_output=True)
    return True, "Service removed"


def start_service():
    result = subprocess.run(["sc", "start", SERVICE_NAME], capture_output=True, text=True)
    return result.returncode == 0 or result.returncode == 1056, result.stdout + result.stderr


def stop_service():
    result = subprocess.run(["sc", "stop", SERVICE_NAME], capture_output=True, text=True)
    return result.returncode == 0, result.stdout + result.stderr


def restart_service():
    stop_service()
    import time; time.sleep(2)
    return start_service()


def is_service_installed() -> bool:
    result = subprocess.run(
        ["sc", "query", SERVICE_NAME],
        capture_output=True, text=True
    )
    return result.returncode == 0


def get_service_state() -> str:
    """Returns: running, stopped, starting, unknown"""
    result = subprocess.run(
        ["sc", "query", SERVICE_NAME],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return "unknown"
    out = result.stdout.upper()
    if "RUNNING" in out:
        return "running"
    elif "START_PENDING" in out:
        return "starting"
    elif "STOPPED" in out:
        return "stopped"
    return "unknown"


def read_tunneld_log(lines: int = 100) -> str:
    """Return last N lines of tunneld log."""
    from .pogogo_tools import TUNNELD_LOG
    try:
        if TUNNELD_LOG.exists():
            with open(TUNNELD_LOG, encoding="utf-8", errors="replace") as f:
                all_lines = f.readlines()
            return "".join(all_lines[-lines:])
    except Exception as e:
        return f"Error reading log: {e}"
    return "(log empty)"


def is_tunneld_port_open() -> bool:
    """Check if tunneld is listening on port 49151."""
    import socket
    try:
        with socket.create_connection(("127.0.0.1", 49151), timeout=1):
            return True
    except Exception:
        return False


def run_as_admin(cmd: list[str]) -> tuple[bool, str]:
    """Launch a command elevated via ShellExecuteEx (UAC)."""
    import ctypes
    if ctypes.windll.shell32.IsUserAnAdmin():
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.returncode == 0, result.stdout + result.stderr
    else:
        # Re-launch with elevation
        import ctypes.wintypes
        params = " ".join(f'"{a}"' for a in cmd[1:])
        ret = ctypes.windll.shell32.ShellExecuteW(
            None, "runas", cmd[0], params, None, 1
        )
        return int(ret) > 32, ""
