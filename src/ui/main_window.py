"""
MainWindow: primary application window.
Layout: map (left, flexible) | control panel (right, fixed 300px)
"""
from PyQt6.QtCore import Qt, QSettings, QTimer, pyqtSignal
from PyQt6.QtGui import QCloseEvent, QKeyEvent
from PyQt6.QtWidgets import QHBoxLayout, QMainWindow, QMessageBox, QSplitter, QWidget

from app_state import AppState
from device_manager import DeviceManager
from ui.control_panel import ControlPanelWidget
from ui.map_widget import MapWidget
from ui.onboarding_dialog import OnboardingDialog


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("POGoGo")
        self.setMinimumSize(900, 600)

        self._app_state = AppState(self)
        self._dm = DeviceManager(self)

        self._setup_ui()
        self._connect_signals()
        self._restore_geometry()

        # Show onboarding if first run
        QTimer.singleShot(500, self._maybe_show_onboarding)

    def _setup_ui(self):
        central = QWidget()
        self.setCentralWidget(central)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.setHandleWidth(1)
        splitter.setStyleSheet("QSplitter::handle { background: #333; }")

        self._map = MapWidget()
        splitter.addWidget(self._map)

        self._panel = ControlPanelWidget(self._app_state, self._dm)
        splitter.addWidget(self._panel)

        splitter.setSizes([700, 300])
        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 0)

        lay = QHBoxLayout(central)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        lay.addWidget(splitter)

        # Keyboard events for arrow keys (fallback if joystick not focused)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def _connect_signals(self):
        # Map → AppState
        self._map.teleport_requested.connect(self._on_teleport)
        self._map.auto_walk_requested.connect(self._on_auto_walk)

        # AppState → Map
        self._app_state.coordinate_changed.connect(self._map.update_marker)
        self._app_state.coordinate_changed.connect(
            lambda lat, lon: self._map.center_map(lat, lon)
        )

        # Panel signals
        self._panel.teleport_to.connect(self._on_teleport)
        self._panel.auto_walk_to.connect(self._on_auto_walk)
        self._panel.reset_gps.connect(self._on_reset_gps)
        self._panel.stop_walk.connect(self._app_state.stop_auto_walk)
        self._panel.map_center_to.connect(self._map.pan_to)

        # Initial marker position
        self._map.page().loadFinished.connect(self._on_map_loaded)

    def _on_map_loaded(self, ok: bool):
        if ok:
            self._map.update_marker(self._app_state.lat, self._app_state.lon)

    def _on_teleport(self, lat: float, lon: float):
        self._app_state.stop_auto_walk()
        self._app_state.teleport(lat, lon)

    def _on_auto_walk(self, lat: float, lon: float):
        self._app_state.start_auto_walk(lat, lon)

    def _on_reset_gps(self):
        self._app_state.stop_auto_walk()
        self._dm.reset_location()
        self._app_state.skip_cooldown()

    def _maybe_show_onboarding(self):
        settings = QSettings("POGoGo", "POGoGo")
        if not settings.value("hasCompletedOnboarding", False, type=bool):
            dlg = OnboardingDialog(self)
            dlg.exec()
            settings.setValue("hasCompletedOnboarding", True)

    def _restore_geometry(self):
        settings = QSettings("POGoGo", "POGoGo")
        geom = settings.value("windowGeometry")
        if geom:
            self.restoreGeometry(geom)
        else:
            self.resize(1100, 720)
            self._center_on_screen()

    def _center_on_screen(self):
        screen = self.screen()
        if screen:
            rect = screen.availableGeometry()
            x = (rect.width() - self.width()) // 2
            y = (rect.height() - self.height()) // 2
            self.move(x, y)

    def closeEvent(self, event: QCloseEvent):
        settings = QSettings("POGoGo", "POGoGo")
        settings.setValue("windowGeometry", self.saveGeometry())
        self._dm.cleanup()
        super().closeEvent(event)
