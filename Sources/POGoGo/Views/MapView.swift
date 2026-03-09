import SwiftUI
import MapKit

// MARK: - macOS 12 相容：MKMapView 子類別

/// macOS 12 的 SwiftUI validateDimension 無法處理 MKMapView.intrinsicContentSize 回傳的
/// noIntrinsicMetric（-1），導致 EXC_BAD_INSTRUCTION。覆寫為 .zero 讓 SwiftUI
/// 以「無偏好大小」展開填滿父容器，行為與原本相同。
private final class _MKMapViewCompat: MKMapView {
    override var intrinsicContentSize: NSSize { .zero }
}

// MARK: - macOS 12 相容：NSTextField 子類別

/// NSTextField.intrinsicContentSize.width 同樣回傳 noIntrinsicMetric（-1），
/// 在 macOS 12 SwiftUI validateDimension 中造成相同崩潰。
/// 將 width 覆寫為 0 讓 SwiftUI 以「無最小寬度偏好」展開，行為不變。
final class _NSTextFieldCompat: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 0, height: super.intrinsicContentSize.height)
    }
}

/// 包裝 _NSTextFieldCompat，取代 SwiftUI TextField，修正 macOS 12 validateDimension crash。
/// isRounded: 對應 .roundedBorder 樣式；nsFont 指定 NSFont（nil 則用系統預設字體）。
struct _CompatibleTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isRounded: Bool = false
    var nsFont: NSFont? = nil
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> _NSTextFieldCompat {
        let field = _NSTextFieldCompat()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.font = nsFont ?? .systemFont(ofSize: NSFont.systemFontSize)
        if isRounded {
            field.bezelStyle = .roundedBezel
            field.isBezeled = true
            field.isBordered = false
        } else {
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
        }
        return field
    }

    func updateNSView(_ nsView: _NSTextFieldCompat, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: _CompatibleTextField
        init(parent: _CompatibleTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - MapKit NSViewRepresentable 包裝

struct MapView: NSViewRepresentable {
    @ObservedObject var appState: AppState
    var onTap: (CLLocationCoordinate2D) -> Void
    var onRightClick: (CLLocationCoordinate2D) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let mapView = _MKMapViewCompat()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true

        // 點擊手勢：傳送
        let tapGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        mapView.addGestureRecognizer(tapGesture)

        // 右鍵：自動走路目標
        let rightClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClick.buttonMask = 0x2  // 右鍵
        mapView.addGestureRecognizer(rightClick)

        // 初始視角
        let region = MKCoordinateRegion(
            center: appState.currentCoordinate,
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        )
        mapView.setRegion(region, animated: false)

        // 加入初始標記
        context.coordinator.updatePin(on: mapView, at: appState.currentCoordinate)

        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let coord = appState.currentCoordinate
        // 座標沒變就完全跳過 MapKit 操作，避免冷卻/搖桿 state 變更 spam KVO → crash
        guard context.coordinator.hasCoordinateChanged(coord) else { return }
        context.coordinator.updatePin(on: mapView, at: coord)
        context.coordinator.centerIfNeeded(mapView: mapView, coordinate: coord)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onRightClick: onRightClick)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        var onTap: (CLLocationCoordinate2D) -> Void
        var onRightClick: (CLLocationCoordinate2D) -> Void
        private var currentPin: MKPointAnnotation?
        private var lastCenteredCoordinate: CLLocationCoordinate2D?
        private var lastPinnedCoordinate: CLLocationCoordinate2D?   // 避免重複 KVO
        private var isProgrammaticCenter = false  // 區分程式觸發 vs 使用者手動 pan
        private var userHasPanned = false          // 使用者手動移動後停止自動置中

        init(
            onTap: @escaping (CLLocationCoordinate2D) -> Void,
            onRightClick: @escaping (CLLocationCoordinate2D) -> Void
        ) {
            self.onTap = onTap
            self.onRightClick = onRightClick
        }

        @objc func handleTap(_ gesture: NSClickGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            userHasPanned = false  // 點擊傳送 = 重新啟用自動置中
            // 延遲到 gesture 處理完成後才更新 state，避免 MKMapView re-entrancy crash
            DispatchQueue.main.async { self.onTap(coord) }
        }

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            DispatchQueue.main.async { self.onRightClick(coord) }
        }

        /// 座標是否有實質變動（~0.01m 精度），並更新追蹤值
        func hasCoordinateChanged(_ coordinate: CLLocationCoordinate2D) -> Bool {
            if let last = lastPinnedCoordinate,
               abs(last.latitude - coordinate.latitude) < 1e-7,
               abs(last.longitude - coordinate.longitude) < 1e-7 {
                return false
            }
            lastPinnedCoordinate = coordinate
            return true
        }

        func centerIfNeeded(mapView: MKMapView, coordinate: CLLocationCoordinate2D) {
            guard !userHasPanned else { return }
            if let last = lastCenteredCoordinate,
               abs(last.latitude - coordinate.latitude) < 1e-7,
               abs(last.longitude - coordinate.longitude) < 1e-7 {
                return
            }
            isProgrammaticCenter = true
            lastCenteredCoordinate = coordinate
            mapView.setCenter(coordinate, animated: false)
            DispatchQueue.main.async { self.isProgrammaticCenter = false }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if !isProgrammaticCenter {
                userHasPanned = true
            }
        }

        func updatePin(on mapView: MKMapView, at coordinate: CLLocationCoordinate2D) {
            if let existing = currentPin {
                // 直接更新座標，避免 remove/add 造成閃爍
                existing.coordinate = coordinate
            } else {
                let pin = MKPointAnnotation()
                pin.coordinate = coordinate
                pin.title = "偽造位置"
                mapView.addAnnotation(pin)
                currentPin = pin
            }
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "SpoofPin"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
            } else {
                view?.annotation = annotation
            }
            view?.markerTintColor = .systemRed
            view?.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
            return view
        }
    }
}

// MARK: - macOS 12 相容：NSSlider 子類別

/// NSSlider.intrinsicContentSize.width 回傳 noIntrinsicMetric（-1），
/// 在 macOS 12 SwiftUI validateDimension 中造成 EXC_BAD_INSTRUCTION。
/// 覆寫 width 為 0，讓 SwiftUI 以「無最小寬度偏好」展開填滿父容器。
final class _NSSliderCompat: NSSlider {
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: max(0, s.width), height: max(0, s.height))
    }
}

/// 包裝 _NSSliderCompat，取代 SwiftUI Slider，修正 macOS 12 validateDimension crash。
/// range: 滑桿範圍；step: 步進值（0 = 連續）。
struct _CompatibleSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0

    func makeNSView(context: Context) -> _NSSliderCompat {
        let slider = _NSSliderCompat()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderChanged(_:))
        return slider
    }

    func updateNSView(_ nsView: _NSSliderCompat, context: Context) {
        if abs(nsView.doubleValue - value) > 1e-9 {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject {
        var parent: _CompatibleSlider
        init(parent: _CompatibleSlider) { self.parent = parent }

        @objc func sliderChanged(_ sender: NSSlider) {
            let v = sender.doubleValue
            let step = parent.step
            if step > 0 {
                let stepped = (v / step).rounded() * step
                parent.value = min(max(stepped, parent.range.lowerBound), parent.range.upperBound)
            } else {
                parent.value = v
            }
        }
    }
}

// MARK: - macOS 12 相容：NSProgressIndicator 子類別

/// NSProgressIndicator (bar style) intrinsicContentSize.width 回傳 noIntrinsicMetric（-1），
/// 在 macOS 12 SwiftUI validateDimension 中造成 EXC_BAD_INSTRUCTION。
/// 覆寫 clamp 到 ≥0，確保不回傳負值。
final class _NSProgressIndicatorCompat: NSProgressIndicator {
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: max(0, s.width), height: max(0, s.height))
    }
}

/// 包裝 _NSProgressIndicatorCompat，取代 SwiftUI ProgressView，修正 macOS 12 validateDimension crash。
/// style: .spinning = 旋轉（預設）；.bar = 線形進度條
/// controlSize: 控制大小（避免使用 .scaleEffect —— macOS 12 對 NSViewRepresentable 套用
/// scaleEffect 會產生私有 wrapper NSView，其 intrinsicContentSize 回傳 -1 仍會觸發 crash）
struct _CompatibleProgressView: NSViewRepresentable {
    var style: NSProgressIndicator.Style = .spinning
    var controlSize: NSControl.ControlSize = .regular

    func makeNSView(context: Context) -> _NSProgressIndicatorCompat {
        let v = _NSProgressIndicatorCompat()
        v.style = style
        v.controlSize = controlSize
        v.isIndeterminate = true
        v.startAnimation(nil)
        return v
    }

    func updateNSView(_ nsView: _NSProgressIndicatorCompat, context: Context) {
        nsView.startAnimation(nil)
    }
}

// MARK: - macOS 12 相容：NSSwitch 子類別

/// NSSwitch.intrinsicContentSize 在 macOS 12 SwiftUI validateDimension 中可能造成
/// EXC_BAD_INSTRUCTION。覆寫 clamp 到 ≥0，確保不回傳負值。
final class _NSSwitchCompat: NSSwitch {
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: max(0, s.width), height: max(0, s.height))
    }
}

/// 包裝 _NSSwitchCompat，取代 SwiftUI Toggle，修正 macOS 12 validateDimension crash。
struct _CompatibleToggle: NSViewRepresentable {
    @Binding var isOn: Bool
    var controlSize: NSControl.ControlSize = .mini

    func makeNSView(context: Context) -> _NSSwitchCompat {
        let sw = _NSSwitchCompat()
        sw.controlSize = controlSize
        sw.state = isOn ? .on : .off
        sw.target = context.coordinator
        sw.action = #selector(Coordinator.toggled(_:))
        return sw
    }

    func updateNSView(_ nsView: _NSSwitchCompat, context: Context) {
        context.coordinator.parent = self
        if nsView.state != (isOn ? .on : .off) {
            nsView.state = isOn ? .on : .off
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject {
        var parent: _CompatibleToggle
        init(parent: _CompatibleToggle) { self.parent = parent }

        @objc func toggled(_ sender: NSSwitch) {
            parent.isOn = sender.state == .on
        }
    }
}

// MARK: - 搜尋位置（透過 MKLocalSearch）

struct LocationSearchBar: View {
    @Binding var searchText: String
    var onSearch: ([MKMapItem]) -> Void

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            _CompatibleTextField(text: $searchText, placeholder: "搜尋地點...", onSubmit: performSearch)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        MKLocalSearch(request: request).start { response, _ in
            if let items = response?.mapItems {
                DispatchQueue.main.async { onSearch(items) }
            }
        }
    }
}
