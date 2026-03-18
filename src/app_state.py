"""
AppState: location/movement state machine (ported from AppState.swift).
"""
import math
import time
from enum import Enum
from PyQt6.QtCore import QObject, QTimer, pyqtSignal


class SpeedMode(Enum):
    WALK = ("Walk", 1.4)
    JOG = ("Jog", 3.0)
    BIKE = ("Bike", 6.0)
    CAR = ("Car", 14.0)

    def __init__(self, label, base_speed):
        self.label = label
        self.base_speed = base_speed  # m/s


class AppState(QObject):
    # Signals
    coordinate_changed = pyqtSignal(float, float)   # lat, lon
    status_changed = pyqtSignal(str)                # status message
    cooldown_tick = pyqtSignal(int)                 # remaining seconds
    auto_walk_changed = pyqtSignal(bool)            # is auto-walking
    speed_changed = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        # Default: Taipei 101
        self.lat = 25.047837
        self.lon = 121.531737
        self.speed_mode = SpeedMode.WALK
        self.speed_multiplier = 1.0  # 0.5x - 2.0x

        # Movement state
        self.joystick_vector = (0.0, 0.0)  # (dx, dy) normalized -1..1
        self.is_auto_walking = False
        self.auto_walk_target = None  # (lat, lon)

        # Cooldown
        self.cooldown_enabled = True
        self.cooldown_seconds = 0

        # Timers
        self._joystick_timer = QTimer()
        self._joystick_timer.setInterval(100)  # 0.1s
        self._joystick_timer.timeout.connect(self._apply_joystick)

        self._auto_walk_timer = QTimer()
        self._auto_walk_timer.setInterval(100)
        self._auto_walk_timer.timeout.connect(self._step_auto_walk)

        self._cooldown_timer = QTimer()
        self._cooldown_timer.setInterval(1000)
        self._cooldown_timer.timeout.connect(self._tick_cooldown)

    @property
    def current_speed(self) -> float:
        return self.speed_mode.base_speed * self.speed_multiplier

    def teleport(self, lat: float, lon: float):
        """Instant jump to location."""
        distance = self.distance_meters(self.lat, self.lon, lat, lon)
        self.lat = lat
        self.lon = lon
        self.coordinate_changed.emit(lat, lon)
        if self.cooldown_enabled and distance > 50:
            secs = min(int(distance / 1000 * 60), 7200)
            self.start_cooldown(secs)

    def start_auto_walk(self, lat: float, lon: float):
        """Start walking toward target at current speed."""
        self.auto_walk_target = (lat, lon)
        self.is_auto_walking = True
        self.auto_walk_changed.emit(True)
        self._auto_walk_timer.start()

    def stop_auto_walk(self):
        self._auto_walk_timer.stop()
        self.is_auto_walking = False
        self.auto_walk_target = None
        self.auto_walk_changed.emit(False)

    def _step_auto_walk(self):
        if not self.auto_walk_target:
            self.stop_auto_walk()
            return
        tlat, tlon = self.auto_walk_target
        dist = self.distance_meters(self.lat, self.lon, tlat, tlon)
        step = self.current_speed * 0.1  # 0.1s interval
        if dist <= step:
            self.lat, self.lon = tlat, tlon
            self.stop_auto_walk()
        else:
            bearing = self.bearing(self.lat, self.lon, tlat, tlon)
            new_lat, new_lon = self.move_coordinate(self.lat, self.lon, bearing, step)
            self.lat, self.lon = new_lat, new_lon
        self.coordinate_changed.emit(self.lat, self.lon)

    def start_joystick(self):
        self._joystick_timer.start()

    def stop_joystick(self):
        self.joystick_vector = (0.0, 0.0)
        self._joystick_timer.stop()

    def _apply_joystick(self):
        dx, dy = self.joystick_vector
        if abs(dx) < 0.01 and abs(dy) < 0.01:
            return
        speed = self.current_speed * 0.1
        dist = speed * math.sqrt(dx**2 + dy**2)
        bearing_deg = math.degrees(math.atan2(dx, dy))  # E=90, N=0
        new_lat, new_lon = self.move_coordinate(self.lat, self.lon, bearing_deg, dist)
        self.lat, self.lon = new_lat, new_lon
        self.coordinate_changed.emit(self.lat, self.lon)

    def start_cooldown(self, seconds: int):
        self.cooldown_seconds = seconds
        self._cooldown_timer.start()
        self.cooldown_tick.emit(seconds)

    def skip_cooldown(self):
        self._cooldown_timer.stop()
        self.cooldown_seconds = 0
        self.cooldown_tick.emit(0)

    def _tick_cooldown(self):
        self.cooldown_seconds -= 1
        self.cooldown_tick.emit(self.cooldown_seconds)
        if self.cooldown_seconds <= 0:
            self._cooldown_timer.stop()

    @staticmethod
    def distance_meters(lat1, lon1, lat2, lon2) -> float:
        """Haversine distance in meters."""
        R = 6371000
        phi1, phi2 = math.radians(lat1), math.radians(lat2)
        dphi = math.radians(lat2 - lat1)
        dlam = math.radians(lon2 - lon1)
        a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlam/2)**2
        return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

    @staticmethod
    def bearing(lat1, lon1, lat2, lon2) -> float:
        """Bearing in degrees (0=North, 90=East)."""
        phi1, phi2 = math.radians(lat1), math.radians(lat2)
        dlam = math.radians(lon2 - lon1)
        x = math.sin(dlam) * math.cos(phi2)
        y = math.cos(phi1)*math.sin(phi2) - math.sin(phi1)*math.cos(phi2)*math.cos(dlam)
        return (math.degrees(math.atan2(x, y)) + 360) % 360

    @staticmethod
    def move_coordinate(lat, lon, bearing_deg, meters) -> tuple:
        """Move from (lat, lon) by `meters` in `bearing_deg` direction."""
        R = 6371000
        d = meters / R
        b = math.radians(bearing_deg)
        phi1 = math.radians(lat)
        lam1 = math.radians(lon)
        phi2 = math.asin(math.sin(phi1)*math.cos(d) + math.cos(phi1)*math.sin(d)*math.cos(b))
        lam2 = lam1 + math.atan2(math.sin(b)*math.sin(d)*math.cos(phi1),
                                   math.cos(d) - math.sin(phi1)*math.sin(phi2))
        return math.degrees(phi2), math.degrees(lam2)
