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
        "title": "歡迎使用 POGoGo",
        "icon": "🎮",
        "body": (
            "<b>Windows 版 Pokémon GO GPS 模擬工具</b><br><br>"
            "• <b>地圖</b> — 點擊即可立即傳送<br>"
            "• <b>搖桿</b> — 類比控制行走方向<br>"
            "• <b>自動行走</b> — 設定目的地自動前往<br>"
            "• <b>冷卻計時器</b> — 避免被偵測封號<br>"
            "• <b>速度模式</b> — 步行 / 慢跑 / 腳踏車 / 汽車"
        ),
    },
    {
        "title": "裝置設定",
        "icon": "📱",
        "body": (
            "<ol style='margin:0;padding-left:18px;'>"
            "<li style='margin-bottom:6px;'>開啟 iPhone 的<b>開發者模式</b><br>"
            "<small>設定 → 隱私權與安全性 → 開發者模式 → 啟用</small></li>"
            "<li style='margin-bottom:6px;'>用 <b>USB 線</b>連接 iPhone<br>"
            "<small>若出現提示請點選「信任」</small></li>"
            "<li style='margin-bottom:6px;'>點擊裝置面板的<b>重新整理</b><br>"
            "<small>iPhone 應出現在下拉選單中</small></li>"
            "<li style='margin-bottom:6px;'>以<b>系統管理員身份</b>執行 POGoGo<br>"
            "<small>通道服務需要管理員權限</small></li>"
            "</ol>"
        ),
    },
    {
        "title": "使用說明",
        "icon": "🗺️",
        "body": (
            "<table style='border-spacing:4px;'>"
            "<tr><td>🖱️ 地圖左鍵點擊</td><td>→ 立即傳送</td></tr>"
            "<tr><td>🖱️ 地圖右鍵點擊</td><td>→ 自動行走 / 傳送選單</td></tr>"
            "<tr><td>🕹️ 拖曳搖桿</td><td>→ 持續移動</td></tr>"
            "<tr><td>⌨️ 方向鍵 / WASD</td><td>→ 鍵盤移動</td></tr>"
            "<tr><td>🔍 搜尋欄</td><td>→ 搜尋任意地點</td></tr>"
            "<tr><td>⏱️ 冷卻計時器</td><td>→ 傳送後等待冷卻</td></tr>"
            "</table>"
        ),
    },
    {
        "title": "準備就緒！",
        "icon": "✅",
        "body": (
            "<b>使用小技巧</b><br><br>"
            "• 大距離傳送後務必等待<b>冷卻計時器</b>結束<br>"
            "• 一般遊玩建議使用<b>步行模式</b>（1.4 m/s）<br>"
            "• 重新插拔裝置後通道會自動重新連接<br>"
            "• 可透過「查看日誌」按鈕查看通道記錄<br><br>"
            "<small style='color:#888;'>POGoGo 使用 iOS DVT 通道<br>"
            "在 iOS 17+ 上穩定注入 GPS</small>"
        ),
    },
]


class OnboardingDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("POGoGo 設定")
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
        self._skip_btn = QPushButton("跳過")
        self._skip_btn.setObjectName("skip")
        self._skip_btn.clicked.connect(self.accept)
        self._back_btn = QPushButton("← 返回")
        self._next_btn = QPushButton("下一步 →")
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
        self._next_btn.setText("開始使用" if is_last else "下一步 →")
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
