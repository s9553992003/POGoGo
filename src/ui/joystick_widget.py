"""
JoystickWidget: Virtual analog joystick with keyboard arrow key support.
"""
import math

from PyQt6.QtCore import Qt, QPointF, pyqtSignal, QTimer
from PyQt6.QtGui import QPainter, QColor, QPen, QBrush, QKeyEvent
from PyQt6.QtWidgets import QWidget


class JoystickWidget(QWidget):
    vector_changed = pyqtSignal(float, float)  # dx, dy (-1..1)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedSize(160, 160)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self._dragging = False
        self._thumb = QPointF(0, 0)  # offset from center
        self._radius = 60.0
        self._thumb_radius = 22.0
        self._keyboard_dirs = set()  # active keys
        self._kb_timer = QTimer(self)
        self._kb_timer.setInterval(50)
        self._kb_timer.timeout.connect(self._kb_tick)

    def center(self) -> QPointF:
        return QPointF(self.width() / 2, self.height() / 2)

    def _clamp_to_circle(self, offset: QPointF) -> QPointF:
        dist = math.sqrt(offset.x()**2 + offset.y()**2)
        if dist > self._radius:
            scale = self._radius / dist
            return QPointF(offset.x() * scale, offset.y() * scale)
        return offset

    def _emit_vector(self):
        r = self._radius
        if r == 0:
            return
        dx = self._thumb.x() / r
        dy = -self._thumb.y() / r  # Qt Y is inverted; up = positive
        self.vector_changed.emit(dx, dy)

    # ── Mouse Events ──────────────────────────────────────────────────────────

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            offset = QPointF(event.pos()) - self.center()
            if math.sqrt(offset.x()**2 + offset.y()**2) <= self._radius + 10:
                self._dragging = True
                self._thumb = self._clamp_to_circle(offset)
                self._emit_vector()
                self.update()

    def mouseMoveEvent(self, event):
        if self._dragging:
            offset = QPointF(event.pos()) - self.center()
            self._thumb = self._clamp_to_circle(offset)
            self._emit_vector()
            self.update()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton and self._dragging:
            self._dragging = False
            self._thumb = QPointF(0, 0)
            self.vector_changed.emit(0.0, 0.0)
            self.update()

    # ── Keyboard Events ───────────────────────────────────────────────────────

    def keyPressEvent(self, event: QKeyEvent):
        key = event.key()
        if key in (Qt.Key.Key_Up, Qt.Key.Key_Down, Qt.Key.Key_Left, Qt.Key.Key_Right,
                   Qt.Key.Key_W, Qt.Key.Key_S, Qt.Key.Key_A, Qt.Key.Key_D):
            self._keyboard_dirs.add(key)
            if not self._kb_timer.isActive():
                self._kb_timer.start()
        else:
            super().keyPressEvent(event)

    def keyReleaseEvent(self, event: QKeyEvent):
        self._keyboard_dirs.discard(event.key())
        if not self._keyboard_dirs:
            self._kb_timer.stop()
            self._thumb = QPointF(0, 0)
            self.vector_changed.emit(0.0, 0.0)
            self.update()

    def _kb_tick(self):
        dx, dy = 0.0, 0.0
        up_keys = {Qt.Key.Key_Up, Qt.Key.Key_W}
        down_keys = {Qt.Key.Key_Down, Qt.Key.Key_S}
        left_keys = {Qt.Key.Key_Left, Qt.Key.Key_A}
        right_keys = {Qt.Key.Key_Right, Qt.Key.Key_D}

        if self._keyboard_dirs & up_keys:    dy =  1.0
        if self._keyboard_dirs & down_keys:  dy = -1.0
        if self._keyboard_dirs & left_keys:  dx = -1.0
        if self._keyboard_dirs & right_keys: dx =  1.0

        # Normalize diagonal
        mag = math.sqrt(dx**2 + dy**2)
        if mag > 0:
            dx /= mag; dy /= mag

        # Update thumb visual
        self._thumb = QPointF(dx * self._radius, -dy * self._radius)
        self.vector_changed.emit(dx, dy)
        self.update()

    # ── Painting ──────────────────────────────────────────────────────────────

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        cx, cy = self.width() / 2, self.height() / 2
        r = self._radius

        # Base circle
        painter.setPen(QPen(QColor("#444"), 2))
        painter.setBrush(QBrush(QColor("#1e1e2e")))
        painter.drawEllipse(QPointF(cx, cy), r, r)

        # Crosshair
        painter.setPen(QPen(QColor("#555"), 1))
        painter.drawLine(int(cx - r + 4), int(cy), int(cx + r - 4), int(cy))
        painter.drawLine(int(cx), int(cy - r + 4), int(cx), int(cy + r - 4))

        # Compass chevrons
        painter.setPen(QPen(QColor("#666"), 1))
        for label, pos in [
            ("N", QPointF(cx, cy - r + 12)),
            ("S", QPointF(cx, cy + r - 12)),
            ("W", QPointF(cx - r + 12, cy)),
            ("E", QPointF(cx + r - 12, cy)),
        ]:
            painter.drawText(pos.toPoint(), label)

        # Thumb
        tx = cx + self._thumb.x()
        ty = cy + self._thumb.y()
        color = QColor("#4a9eff") if self._dragging or self._keyboard_dirs else QColor("#6680aa")
        painter.setPen(QPen(QColor("#aaccff"), 1))
        painter.setBrush(QBrush(color))
        painter.drawEllipse(QPointF(tx, ty), self._thumb_radius, self._thumb_radius)

        # Center dot
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QBrush(QColor("#88aae8")))
        painter.drawEllipse(QPointF(tx, ty), 5, 5)
        painter.end()
