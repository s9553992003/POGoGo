"""
OnboardingDialog: 4-step first-time tutorial.
"""
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QDialog, QHBoxLayout, QLabel, QPushButton,
    QStackedWidget, QVBoxLayout, QWidget,
)

STEPS = [
    {
        "title": "Welcome to POGoGo",
        "icon": "🎮",
        "body": (
            "<b>GPS Spoofing for Pokémon GO on Windows</b><br><br>"
            "• <b>Map</b> — Click to teleport instantly<br>"
            "• <b>Joystick</b> — Walk with analog control<br>"
            "• <b>Auto-Walk</b> — Set a destination and go<br>"
            "• <b>Cooldown Timer</b> — Avoid ban detection<br>"
            "• <b>Speed Modes</b> — Walk / Jog / Bike / Car"
        ),
    },
    {
        "title": "Device Setup",
        "icon": "📱",
        "body": (
            "<ol style='margin:0;padding-left:18px;'>"
            "<li style='margin-bottom:6px;'>Enable <b>Developer Mode</b> on iPhone<br>"
            "<small>Settings → Privacy → Developer Mode → Enable</small></li>"
            "<li style='margin-bottom:6px;'>Connect iPhone via <b>USB cable</b><br>"
            "<small>Trust the computer if prompted</small></li>"
            "<li style='margin-bottom:6px;'>Click <b>Refresh</b> in the device panel<br>"
            "<small>Your iPhone should appear in the dropdown</small></li>"
            "<li style='margin-bottom:6px;'>Click <b>Install Tunnel Service</b><br>"
            "<small>Requires admin rights (UAC prompt will appear)</small></li>"
            "</ol>"
        ),
    },
    {
        "title": "How to Use",
        "icon": "🗺️",
        "body": (
            "<table style='border-spacing:4px;'>"
            "<tr><td>🖱️ Left click map</td><td>→ Teleport instantly</td></tr>"
            "<tr><td>🖱️ Right click map</td><td>→ Auto-Walk / Teleport menu</td></tr>"
            "<tr><td>🕹️ Joystick drag</td><td>→ Move continuously</td></tr>"
            "<tr><td>⌨️ Arrow keys / WASD</td><td>→ Keyboard movement</td></tr>"
            "<tr><td>🔍 Search bar</td><td>→ Find any location</td></tr>"
            "<tr><td>⏱️ Cooldown timer</td><td>→ Wait before re-spoofing</td></tr>"
            "</table>"
        ),
    },
    {
        "title": "You're Ready!",
        "icon": "✅",
        "body": (
            "<b>Quick Tips</b><br><br>"
            "• Always wait for the <b>Cooldown Timer</b> after large jumps<br>"
            "• Use <b>Walk mode</b> (1.4 m/s) for most gameplay<br>"
            "• The tunnel auto-reconnects on device replug<br>"
            "• Logs available via the 'View Log' button<br><br>"
            "<small style='color:#888;'>POGoGo uses the iOS DVT tunnel for<br>"
            "reliable GPS injection on iOS 17+</small>"
        ),
    },
]


class OnboardingDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("POGoGo Setup")
        self.setFixedSize(540, 460)
        self.setModal(True)
        self.setStyleSheet("""
            QDialog { background: #1e1e2e; color: #ddd; }
            QLabel { color: #ddd; }
            QPushButton {
                background: #4a9eff; color: white; border-radius: 8px;
                padding: 8px 20px; font-size: 13px; border: none;
            }
            QPushButton:hover { background: #5aaeee; }
            QPushButton#skip {
                background: transparent; color: #888;
            }
            QPushButton#skip:hover { color: #bbb; }
        """)
        self._step = 0
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 28, 32, 24)
        layout.setSpacing(0)

        # Step indicators
        self._step_row = QHBoxLayout()
        self._step_row.setSpacing(6)
        self._step_dots = []
        for i in range(len(STEPS)):
            dot = QLabel("●")
            dot.setAlignment(Qt.AlignmentFlag.AlignCenter)
            dot.setFont(QFont("Arial", 10))
            self._step_dots.append(dot)
            self._step_row.addWidget(dot)
        self._step_row.addStretch()
        layout.addLayout(self._step_row)
        layout.addSpacing(20)

        # Stacked pages
        self._stack = QStackedWidget()
        for s in STEPS:
            page = self._make_page(s["icon"], s["title"], s["body"])
            self._stack.addWidget(page)
        layout.addWidget(self._stack, 1)
        layout.addSpacing(24)

        # Buttons
        btn_row = QHBoxLayout()
        self._skip_btn = QPushButton("Skip")
        self._skip_btn.setObjectName("skip")
        self._skip_btn.clicked.connect(self.accept)
        self._back_btn = QPushButton("← Back")
        self._next_btn = QPushButton("Next →")
        self._back_btn.clicked.connect(self._prev)
        self._next_btn.clicked.connect(self._next)
        btn_row.addWidget(self._skip_btn)
        btn_row.addStretch()
        btn_row.addWidget(self._back_btn)
        btn_row.addSpacing(8)
        btn_row.addWidget(self._next_btn)
        layout.addLayout(btn_row)

        self._update_ui()

    def _make_page(self, icon: str, title: str, body: str) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(12)

        icon_lbl = QLabel(icon)
        icon_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        icon_lbl.setFont(QFont("Segoe UI Emoji", 40))
        lay.addWidget(icon_lbl)

        title_lbl = QLabel(title)
        title_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        f = QFont("Segoe UI", 18, QFont.Weight.Bold)
        title_lbl.setFont(f)
        lay.addWidget(title_lbl)

        body_lbl = QLabel(body)
        body_lbl.setTextFormat(Qt.TextFormat.RichText)
        body_lbl.setWordWrap(True)
        body_lbl.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        body_lbl.setStyleSheet("font-size: 13px; color: #ccc; line-height: 1.6;")
        lay.addWidget(body_lbl, 1)
        return w

    def _update_ui(self):
        self._stack.setCurrentIndex(self._step)
        is_last = self._step == len(STEPS) - 1
        self._next_btn.setText("Get Started" if is_last else "Next →")
        self._back_btn.setVisible(self._step > 0)
        for i, dot in enumerate(self._step_dots):
            dot.setStyleSheet(
                "color: #4a9eff; font-size: 14px;" if i == self._step
                else "color: #444; font-size: 10px;"
            )

    def _next(self):
        if self._step == len(STEPS) - 1:
            self.accept()
        else:
            self._step += 1
            self._update_ui()

    def _prev(self):
        if self._step > 0:
            self._step -= 1
            self._update_ui()
