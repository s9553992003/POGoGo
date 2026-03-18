"""
POGoGo Windows - Entry point.
GUI mode:      python main.py  (or POGoGo.exe)
Backend modes: POGoGo.exe detect|tunneld|worker <udid>|clear <udid>
               POGoGo.exe --install-service
               POGoGo.exe --uninstall-service
               POGoGo.exe --start-service
"""
import sys
import os

# Add src/ to path so imports work in both dev and frozen modes
if not getattr(sys, "frozen", False):
    sys.path.insert(0, os.path.dirname(__file__))


def main():
    args = sys.argv[1:]

    # ── Backend / service commands ────────────────────────────────────────────
    if args and args[0] in ("detect", "tunneld", "worker", "clear"):
        from backend.pogogo_tools import main as backend_main
        backend_main()
        return

    if args and args[0] == "--tunneld":
        # Called by Windows Service
        import asyncio
        from backend.pogogo_tools import cmd_tunneld
        asyncio.run(cmd_tunneld())
        return

    if args and args[0] == "--install-service":
        from backend.windows_service import install_service
        ok, msg = install_service()
        print(msg)
        sys.exit(0 if ok else 1)

    if args and args[0] == "--uninstall-service":
        from backend.windows_service import uninstall_service
        ok, msg = uninstall_service()
        print(msg)
        sys.exit(0 if ok else 1)

    if args and args[0] == "--start-service":
        from backend.windows_service import start_service
        ok, msg = start_service()
        print(msg)
        sys.exit(0 if ok else 1)

    # ── GUI mode ──────────────────────────────────────────────────────────────
    # QtWebEngineWidgets MUST be imported before QApplication is created
    import PyQt6.QtWebEngineWidgets  # noqa: F401

    from PyQt6.QtWidgets import QApplication
    from PyQt6.QtCore import Qt
    from PyQt6.QtGui import QIcon

    app = QApplication(sys.argv)
    app.setApplicationName("POGoGo")
    app.setOrganizationName("POGoGo")
    app.setStyle("Fusion")

    # Dark palette
    from PyQt6.QtGui import QPalette, QColor
    palette = QPalette()
    palette.setColor(QPalette.ColorRole.Window, QColor("#1a1a2e"))
    palette.setColor(QPalette.ColorRole.WindowText, QColor("#ddd"))
    palette.setColor(QPalette.ColorRole.Base, QColor("#2a2a3e"))
    palette.setColor(QPalette.ColorRole.AlternateBase, QColor("#1e1e2e"))
    palette.setColor(QPalette.ColorRole.ToolTipBase, QColor("#2a2a3e"))
    palette.setColor(QPalette.ColorRole.ToolTipText, QColor("#ddd"))
    palette.setColor(QPalette.ColorRole.Text, QColor("#ddd"))
    palette.setColor(QPalette.ColorRole.Button, QColor("#2e2e44"))
    palette.setColor(QPalette.ColorRole.ButtonText, QColor("#ccc"))
    palette.setColor(QPalette.ColorRole.Highlight, QColor("#4a9eff"))
    palette.setColor(QPalette.ColorRole.HighlightedText, QColor("white"))
    app.setPalette(palette)

    # Set icon if available
    icon_path = os.path.join(os.path.dirname(__file__), "..", "resources", "icon.ico")
    if os.path.exists(icon_path):
        app.setWindowIcon(QIcon(icon_path))

    from ui.main_window import MainWindow
    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
