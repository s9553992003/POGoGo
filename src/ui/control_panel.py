"""
ControlPanelWidget: Right-side control panel.
"""
import threading
import urllib.parse
import urllib.request
import json as _json

from PyQt6.QtCore import Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QPainter
from PyQt6.QtWidgets import (
    QComboBox, QDialog, QDialogButtonBox, QGroupBox, QHBoxLayout,
    QLabel, QLineEdit, QMessageBox, QPushButton, QScrollArea,
    QSizePolicy, QSlider, QTextEdit, QVBoxLayout, QWidget,
)

from app_state import AppState, SpeedMode
from device_manager import DeviceManager
from ui.joystick_widget import JoystickWidget


def nominatim_search(query: str, callback):
    def run():
        try:
            q = urllib.parse.quote(query)
            url = (f"https://nominatim.openstreetmap.org/search"
                   f"?q={q}&format=json&limit=5&addressdetails=0")
            req = urllib.request.Request(url, headers={"User-Agent": "POGoGo/1.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = _json.loads(resp.read().decode())
            results = [{"name": r["display_name"],
                        "lat": float(r["lat"]), "lon": float(r["lon"])} for r in data]
            callback(results)
        except Exception:
            callback([])
    threading.Thread(target=run, daemon=True).start()


DARK = """
QWidget { background: #1a1a2e; color: #ddd; }
QGroupBox {
    color: #aaa; font-size: 11px; font-weight: bold;
    border: 1px solid #333; border-radius: 6px;
    margin-top: 8px; padding-top: 6px;
}
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
QLineEdit {
    background: #2a2a3e; border: 1px solid #444; border-radius: 5px;
    color: #ddd; padding: 4px 8px; font-size: 12px;
}
QLineEdit:focus { border-color: #4a9eff; }
QPushButton {
    background: #2e2e44; color: #ccc; border: 1px solid #444;
    border-radius: 5px; padding: 4px 10px; font-size: 12px;
}
QPushButton:hover { background: #3a3a58; border-color: #4a9eff; }
QPushButton:pressed { background: #222238; }
QPushButton:disabled { color: #555; }
QComboBox {
    background: #2a2a3e; border: 1px solid #444; border-radius: 5px;
    color: #ccc; padding: 3px 6px;
}
QComboBox::drop-down { border: none; }
QComboBox QAbstractItemView { background: #2a2a3e; color: #ccc; border: 1px solid #444; }
QSlider::groove:horizontal { background: #333; height: 4px; border-radius: 2px; }
QSlider::handle:horizontal {
    background: #4a9eff; width: 14px; height: 14px;
    border-radius: 7px; margin: -5px 0;
}
QSlider::sub-page:horizontal { background: #4a9eff; border-radius: 2px; }
QScrollArea { border: none; }
"""


def _btn(text, color=None, tooltip=None):
    b = QPushButton(text)
    if color:
        b.setStyleSheet(f"QPushButton{{background:{color};color:white;border:none;}}"
                        f"QPushButton:hover{{background:{color}cc;}}")
    if tooltip:
        b.setToolTip(tooltip)
    return b


class _Dot(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedSize(12, 12)
        self._c = QColor("#555")

    def set_color(self, c):
        self._c = QColor(c); self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setBrush(self._c); p.setPen(Qt.PenStyle.NoPen)
        p.drawEllipse(0, 0, 12, 12); p.end()


class ControlPanelWidget(QWidget):
    teleport_to   = pyqtSignal(float, float)
    auto_walk_to  = pyqtSignal(float, float)
    reset_gps     = pyqtSignal()
    stop_walk     = pyqtSignal()
    map_center_to = pyqtSignal(float, float)

    def __init__(self, app_state: AppState, dm: DeviceManager, parent=None):
        super().__init__(parent)
        self.app_state = app_state
        self.dm = dm
        self.setStyleSheet(DARK)
        self.setFixedWidth(300)
        self._build()
        self._wire()

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build(self):
        scroll = QScrollArea(self)
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(8)

        lay.addWidget(self._g_device())
        lay.addWidget(self._g_tunnel())
        lay.addWidget(self._g_search())
        lay.addWidget(self._g_coord())
        lay.addWidget(self._g_speed())
        lay.addWidget(self._g_joystick())
        lay.addWidget(self._g_cooldown())
        lay.addWidget(self._g_autowalk())
        lay.addWidget(self._g_actions())
        lay.addStretch()

        scroll.setWidget(inner)
        ml = QVBoxLayout(self)
        ml.setContentsMargins(0, 0, 0, 0)
        ml.addWidget(scroll)

    # ── Groups ────────────────────────────────────────────────────────────────

    def _g_device(self):
        g = QGroupBox("Device")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        r = QHBoxLayout()
        self._dev_dot = _Dot()
        self._dev_lbl = QLabel("No device connected")
        self._dev_lbl.setStyleSheet("font-size:12px;")
        r.addWidget(self._dev_dot); r.addWidget(self._dev_lbl, 1)
        lay.addLayout(r)

        r2 = QHBoxLayout()
        self._dev_combo = QComboBox()
        self._dev_combo.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._refresh_btn = _btn("Refresh"); self._refresh_btn.setFixedWidth(64)
        r2.addWidget(self._dev_combo, 1); r2.addWidget(self._refresh_btn)
        lay.addLayout(r2)
        return g

    def _g_tunnel(self):
        g = QGroupBox("iOS 17+ Tunnel  (auto-managed)")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        r = QHBoxLayout()
        self._tun_dot = _Dot()
        self._tun_lbl = QLabel("Starting...")
        self._tun_lbl.setStyleSheet("font-size:12px;")
        r.addWidget(self._tun_dot); r.addWidget(self._tun_lbl, 1)
        lay.addLayout(r)

        r2 = QHBoxLayout()
        self._restart_btn = _btn("Restart Tunnel")
        self._restart_btn.clicked.connect(self.dm.restart_tunneld)
        self._log_btn = _btn("View Log")
        self._log_btn.clicked.connect(self._on_view_log)
        r2.addWidget(self._restart_btn); r2.addWidget(self._log_btn)
        lay.addLayout(r2)
        return g

    def _g_search(self):
        g = QGroupBox("Location Search")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        r = QHBoxLayout()
        self._search_edit = QLineEdit()
        self._search_edit.setPlaceholderText("Search location...")
        self._search_edit.returnPressed.connect(self._on_search)
        self._search_btn = _btn("Go"); self._search_btn.setFixedWidth(40)
        self._search_btn.clicked.connect(self._on_search)
        r.addWidget(self._search_edit, 1); r.addWidget(self._search_btn)
        lay.addLayout(r)

        self._res_box = QWidget()
        self._res_lay = QVBoxLayout(self._res_box)
        self._res_lay.setContentsMargins(0, 0, 0, 0); self._res_lay.setSpacing(2)
        lay.addWidget(self._res_box)
        return g

    def _g_coord(self):
        g = QGroupBox("Current Location")
        lay = QVBoxLayout(g); lay.setSpacing(4)

        r = QHBoxLayout()
        self._coord_lbl = QLabel("25.047837°N  121.531737°E")
        self._coord_lbl.setStyleSheet("font-size:11px;color:#aaa;font-family:Consolas;")
        self._copy_btn = _btn("Copy"); self._copy_btn.setFixedWidth(48)
        self._copy_btn.clicked.connect(self._on_copy)
        r.addWidget(self._coord_lbl, 1); r.addWidget(self._copy_btn)
        lay.addLayout(r)
        return g

    def _g_speed(self):
        g = QGroupBox("Speed")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        mr = QHBoxLayout(); mr.setSpacing(4)
        self._mode_btns: dict[SpeedMode, QPushButton] = {}
        for m in SpeedMode:
            b = QPushButton(m.label); b.setFixedHeight(28); b.setCheckable(True)
            b.clicked.connect(lambda _, mode=m: self._set_mode(mode))
            self._mode_btns[m] = b; mr.addWidget(b)
        lay.addLayout(mr)

        sr = QHBoxLayout()
        self._mul_lbl = QLabel("1.0x"); self._mul_lbl.setFixedWidth(36)
        self._mul_slider = QSlider(Qt.Orientation.Horizontal)
        self._mul_slider.setRange(5, 20); self._mul_slider.setValue(10)
        self._mul_slider.valueChanged.connect(self._on_mul)
        sr.addWidget(QLabel("0.5x")); sr.addWidget(self._mul_slider, 1)
        sr.addWidget(QLabel("2.0x")); sr.addWidget(self._mul_lbl)
        lay.addLayout(sr)

        self._set_mode(SpeedMode.WALK)
        return g

    def _g_joystick(self):
        g = QGroupBox("Joystick  (Arrow Keys / WASD)")
        lay = QVBoxLayout(g)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._joystick = JoystickWidget()
        self._joystick.vector_changed.connect(self._on_joystick)
        lay.addWidget(self._joystick, 0, Qt.AlignmentFlag.AlignCenter)
        return g

    def _g_cooldown(self):
        g = QGroupBox("Cooldown Timer")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        r = QHBoxLayout()
        self._cd_btn = QPushButton("Cooldown ON  ✓")
        self._cd_btn.setCheckable(True); self._cd_btn.setChecked(True)
        self._cd_btn.setStyleSheet(
            "QPushButton:checked{background:#1a4a1a;border-color:#2e7d32;color:#66bb6a;}"
        )
        self._cd_btn.clicked.connect(self._on_cd_toggle)
        self._skip_btn = _btn("Skip"); self._skip_btn.setFixedWidth(48)
        self._skip_btn.clicked.connect(self.app_state.skip_cooldown)
        r.addWidget(self._cd_btn, 1); r.addWidget(self._skip_btn)
        lay.addLayout(r)

        self._cd_lbl = QLabel("No cooldown")
        self._cd_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._cd_lbl.setStyleSheet("color:#888;font-size:12px;")
        lay.addWidget(self._cd_lbl)
        return g

    def _g_autowalk(self):
        g = QGroupBox("Auto-Walk Destination")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        self._aw_edit = QLineEdit()
        self._aw_edit.setPlaceholderText("lat, lon  (e.g. 25.047, 121.531)")
        lay.addWidget(self._aw_edit)

        r = QHBoxLayout()
        self._aw_dist = QLabel("")
        self._aw_dist.setStyleSheet("font-size:11px;color:#888;")
        self._aw_go = _btn("Go", "#1565c0"); self._aw_go.setFixedWidth(50)
        self._aw_go.clicked.connect(self._on_aw_go)
        r.addWidget(self._aw_dist, 1); r.addWidget(self._aw_go)
        lay.addLayout(r)

        self._aw_edit.textChanged.connect(self._on_aw_text)
        return g

    def _g_actions(self):
        g = QGroupBox("Actions")
        lay = QVBoxLayout(g); lay.setSpacing(6)

        r = QHBoxLayout()
        self._stop_btn = _btn("Stop Walk", "#b71c1c")
        self._reset_btn = _btn("Reset GPS", "#4a4a00")
        self._stop_btn.clicked.connect(self._on_stop)
        self._reset_btn.clicked.connect(self._on_reset)
        r.addWidget(self._stop_btn); r.addWidget(self._reset_btn)
        lay.addLayout(r)
        return g

    # ── Wiring ────────────────────────────────────────────────────────────────

    def _wire(self):
        self.app_state.coordinate_changed.connect(self._on_coord)
        self.app_state.cooldown_tick.connect(self._on_cd_tick)
        self.app_state.auto_walk_changed.connect(lambda w: self._stop_btn.setEnabled(w))

        self.dm.devices_updated.connect(self._on_devices)
        self.dm.connection_changed.connect(self._on_connected)
        self.dm.tunneld_status.connect(self._on_tunnel_status)

        self._dev_combo.currentIndexChanged.connect(self._on_combo)
        self._refresh_btn.clicked.connect(self.dm.detect_devices)

    # ── Handlers ─────────────────────────────────────────────────────────────

    def _on_coord(self, lat, lon):
        self._coord_lbl.setText(f"{lat:.6f}°N  {lon:.6f}°E")
        self.dm.set_location(lat, lon)

    def _on_devices(self, devices):
        cur = self._dev_combo.currentData()
        self._dev_combo.blockSignals(True)
        self._dev_combo.clear()
        for d in devices:
            self._dev_combo.addItem(d.get("name", "iPhone"), d["hwUDID"])
        if cur:
            idx = self._dev_combo.findData(cur)
            if idx >= 0: self._dev_combo.setCurrentIndex(idx)
        self._dev_combo.blockSignals(False)

    def _on_combo(self, idx):
        udid = self._dev_combo.currentData()
        if udid: self.dm.select_device(udid)

    def _on_connected(self, ok):
        if ok:
            self._dev_dot.set_color("#4caf50")
            self._dev_lbl.setText(f"{self.dm.device_name(self.dm.selected_udid)} connected")
        else:
            self._dev_dot.set_color("#ef5350")
            self._dev_lbl.setText("No device connected")

    def _on_tunnel_status(self, s):
        colors = {"running": "#4caf50", "starting": "#ffa726",
                  "stopped": "#ef5350", "unknown": "#555"}
        labels = {"running": "Running  ✓", "starting": "Starting...",
                  "stopped": "Stopped  (auto-restart)", "unknown": "Unknown"}
        self._tun_dot.set_color(colors.get(s, "#555"))
        self._tun_lbl.setText(labels.get(s, s))

    def _on_view_log(self):
        log = self.dm.get_tunneld_log()
        dlg = QDialog(self)
        dlg.setWindowTitle("Tunnel Log")
        dlg.resize(620, 420)
        dlg.setStyleSheet("QDialog{background:#1e1e2e;}"
                          "QTextEdit{background:#111;color:#0f0;"
                          "font-family:Consolas;font-size:11px;}")
        lay = QVBoxLayout(dlg)
        te = QTextEdit(); te.setReadOnly(True); te.setPlainText(log)
        te.moveCursor(te.textCursor().MoveOperation.End)
        lay.addWidget(te)
        bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        bb.rejected.connect(dlg.reject)
        lay.addWidget(bb)
        dlg.exec()

    def _on_search(self):
        q = self._search_edit.text().strip()
        if not q: return
        self._search_btn.setText("..."); self._search_btn.setEnabled(False)
        nominatim_search(q, lambda r: QTimer.singleShot(0, lambda: self._show_results(r)))

    def _show_results(self, results):
        self._search_btn.setText("Go"); self._search_btn.setEnabled(True)
        while self._res_lay.count():
            item = self._res_lay.takeAt(0)
            if item.widget(): item.widget().deleteLater()
        for r in results[:5]:
            name = r["name"].split(",")[0][:40]
            b = QPushButton(name); b.setToolTip(r["name"])
            b.setStyleSheet("QPushButton{text-align:left;padding:4px 8px;font-size:11px;}")
            lat, lon = r["lat"], r["lon"]
            b.clicked.connect(lambda _, la=lat, lo=lon: self.map_center_to.emit(la, lo))
            self._res_lay.addWidget(b)

    def _on_copy(self):
        from PyQt6.QtWidgets import QApplication
        QApplication.clipboard().setText(f"{self.app_state.lat:.6f},{self.app_state.lon:.6f}")

    def _set_mode(self, mode):
        self.app_state.speed_mode = mode
        for m, b in self._mode_btns.items():
            b.setChecked(m == mode)
            b.setStyleSheet(
                "QPushButton{background:#1565c0;color:white;border:1px solid #1976d2;border-radius:5px;}"
                if m == mode else ""
            )

    def _on_mul(self, val):
        mul = val / 10.0
        self.app_state.speed_multiplier = mul
        self._mul_lbl.setText(f"{mul:.1f}x")

    def _on_joystick(self, dx, dy):
        self.app_state.joystick_vector = (dx, dy)
        if abs(dx) > 0.01 or abs(dy) > 0.01:
            self.app_state.start_joystick()
        else:
            self.app_state.stop_joystick()

    def _on_cd_toggle(self, checked):
        self.app_state.cooldown_enabled = checked
        self._cd_btn.setText("Cooldown ON  ✓" if checked else "Cooldown OFF")

    def _on_cd_tick(self, secs):
        if secs <= 0:
            self._cd_lbl.setText("Ready")
            self._cd_lbl.setStyleSheet("color:#4caf50;font-size:12px;")
        else:
            m, s = divmod(secs, 60)
            self._cd_lbl.setText(f"Wait: {m:02d}:{s:02d}")
            self._cd_lbl.setStyleSheet("color:#ffa726;font-size:12px;")

    def _on_aw_text(self, text):
        try:
            lat, lon = (float(x) for x in text.strip().split(","))
            d = AppState.distance_meters(self.app_state.lat, self.app_state.lon, lat, lon)
            self._aw_dist.setText(f"{d/1000:.2f} km" if d >= 1000 else f"{d:.0f} m")
        except Exception:
            self._aw_dist.setText("")

    def _on_aw_go(self):
        try:
            lat, lon = (float(x) for x in self._aw_edit.text().strip().split(","))
            self.auto_walk_to.emit(lat, lon)
        except Exception:
            QMessageBox.warning(self, "Invalid", "Enter: lat, lon  (e.g. 25.047, 121.531)")

    def _on_stop(self):  self.stop_walk.emit()
    def _on_reset(self): self.reset_gps.emit()
