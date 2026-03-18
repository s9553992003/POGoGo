"""
MapWidget: Leaflet.js map in QWebEngineView with QWebChannel bridge.
"""
import os
from pathlib import Path

from PyQt6.QtCore import QObject, QUrl, pyqtSignal, pyqtSlot
from PyQt6.QtWebChannel import QWebChannel
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtWebEngineCore import QWebEngineSettings


class MapBridge(QObject):
    """Exposed to JavaScript as 'bridge'."""
    left_click = pyqtSignal(float, float)     # lat, lon → teleport
    right_click_walk = pyqtSignal(float, float)  # lat, lon → auto-walk

    @pyqtSlot(float, float)
    def onMapLeftClick(self, lat: float, lon: float):
        self.left_click.emit(lat, lon)

    @pyqtSlot(float, float)
    def onMapRightClickWalk(self, lat: float, lon: float):
        self.right_click_walk.emit(lat, lon)


class MapWidget(QWebEngineView):
    teleport_requested = pyqtSignal(float, float)
    auto_walk_requested = pyqtSignal(float, float)

    def __init__(self, parent=None):
        super().__init__(parent)
        # Allow local/remote mixed content for CDN tiles
        self.settings().setAttribute(QWebEngineSettings.WebAttribute.LocalContentCanAccessRemoteUrls, True)
        self.settings().setAttribute(QWebEngineSettings.WebAttribute.JavascriptEnabled, True)

        # Setup WebChannel
        self._channel = QWebChannel(self)
        self._bridge = MapBridge(self)
        self._channel.registerObject("bridge", self._bridge)
        self.page().setWebChannel(self._channel)

        # Connect bridge signals
        self._bridge.left_click.connect(self.teleport_requested)
        self._bridge.right_click_walk.connect(self.auto_walk_requested)

        # Load HTML — handle both dev (src/) and frozen (dist/) layouts
        import sys
        if getattr(sys, "frozen", False):
            base = Path(sys.executable).parent
        else:
            base = Path(__file__).parent.parent
        html_path = base / "map.html"
        self.load(QUrl.fromLocalFile(str(html_path)))

    def update_marker(self, lat: float, lon: float):
        self.page().runJavaScript(f"updateMarker({lat}, {lon});")

    def center_map(self, lat: float, lon: float):
        self.page().runJavaScript(f"centerMap({lat}, {lon});")

    def pan_to(self, lat: float, lon: float):
        self.page().runJavaScript(f"panToMarker({lat}, {lon});")

    def search_center(self, lat: float, lon: float, name: str):
        safe_name = name.replace("'", "\\'")
        self.page().runJavaScript(f"searchAndCenter({lat}, {lon}, '{safe_name}');")
