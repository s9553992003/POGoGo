# POGoGo Windows - Build Guide

## Prerequisites (Windows machine required)

1. **Python 3.10+** — https://python.org (check "Add to PATH" during install)
2. **Inno Setup 6** — https://jrsoftware.org/isinfo.php (for creating installer)
3. **Git** (optional)

## Quick Build

```cmd
cd POGoGo-Win
build.bat
```

This will:
1. Install all Python dependencies
2. Build `dist\POGoGo\POGoGo.exe` with PyInstaller
3. Create `output\POGoGo-Setup.exe` with Inno Setup

## Manual Build Steps

### Step 1: Install dependencies
```cmd
pip install -r requirements.txt
pip install pyinstaller
```

### Step 2: Build exe
```cmd
pyinstaller pogogo.spec --noconfirm
```

### Step 3: Build installer
```cmd
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
```

## Project Structure

```
POGoGo-Win/
├── src/
│   ├── main.py                  # Entry point (GUI + backend dispatch)
│   ├── app_state.py             # Location/movement logic
│   ├── device_manager.py        # Device detection + worker management
│   ├── map.html                 # Leaflet.js interactive map
│   ├── backend/
│   │   ├── pogogo_tools.py      # GPS injection backend (pymobiledevice3)
│   │   └── windows_service.py  # Windows Service management
│   └── ui/
│       ├── main_window.py       # QMainWindow
│       ├── map_widget.py        # QWebEngineView + Leaflet
│       ├── control_panel.py     # Right-side controls
│       ├── joystick_widget.py   # Virtual joystick
│       └── onboarding_dialog.py # First-run tutorial
├── resources/
│   └── icon.ico                 # Application icon
├── pogogo.spec                  # PyInstaller spec
├── installer.iss                # Inno Setup script
├── requirements.txt
└── build.bat                    # One-click build
```

## Features (mirrors macOS version)

| Feature | Description |
|---------|-------------|
| GPS Teleport | Left-click map |
| Auto-Walk | Right-click → "Auto Walk Here" |
| Joystick | Drag or arrow keys / WASD |
| Speed Modes | Walk (1.4) / Jog (3.0) / Bike (6.0) / Car (14.0) m/s |
| Speed Multiplier | 0.5x – 2.0x |
| Cooldown Timer | Anti-ban distance-based cooldown |
| Location Search | OpenStreetMap/Nominatim geocoding |
| Device Detection | Auto-detects USB iPhones |
| Tunnel Service | Windows Service (replaces macOS LaunchDaemon) |
| Onboarding | 4-step tutorial |
| GPS Reset | Restore real GPS |

## Runtime Requirements (end users)

- Windows 10 1809+ (64-bit)
- iTunes installed (for iPhone USB driver)
- iPhone with Developer Mode enabled
- iOS 17+ (for DVT tunnel)

## App Data Paths

| Path | Description |
|------|-------------|
| `%APPDATA%\POGoGo\cache\device_names.json` | Device name cache |
| `%TEMP%\pogogo\pogogo-tunneld.log` | Tunnel daemon log |
| `%TEMP%\pogogo\pogogo-worker.log` | GPS worker log |
| `%TEMP%\pogogo\pogogo_coords.txt` | Current GPS coordinate (IPC) |

## Windows Service

The tunnel daemon runs as a Windows Service (`POGoGoTunneld`):
- **Auto-start**: Enabled at install
- **Manual control**: Use "Install/Restart" buttons in app
- **Log**: View via "View Log" button or `%TEMP%\pogogo\pogogo-tunneld.log`

## Icon

Place a `resources/icon.ico` (256x256 recommended) before building.
Generate from PNG: https://convertico.com
