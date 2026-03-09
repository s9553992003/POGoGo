import SwiftUI
import AppKit

// MARK: - 虛擬搖桿

struct JoystickView: View {
    @ObservedObject var appState: AppState

    private let baseRadius: CGFloat = 60
    private let thumbRadius: CGFloat = 24

    @State private var thumbOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            // 底盤
            Circle()
                .fill(Color.white.opacity(0.12))
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 2))
                .frame(width: baseRadius * 2, height: baseRadius * 2)

            // 方向指示線
            DirectionLines(radius: baseRadius)

            // 搖桿拇指
            Circle()
                .fill(isDragging ? Color.blue : Color.white.opacity(0.8))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                .offset(thumbOffset)
        }
        .frame(width: baseRadius * 2, height: baseRadius * 2)
        // NSView overlay 負責捕捉原生滑鼠事件（SwiftUI DragGesture 在 macOS 不可靠）
        .overlay(
            JoystickMouseCapture(
                baseRadius: baseRadius,
                thumbRadius: thumbRadius,
                onDrag: { offset, vector in
                    isDragging = true
                    thumbOffset = offset
                    appState.joystickVector = vector
                    if !appState.isMoving { appState.startJoystickMovement() }
                },
                onEnd: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        thumbOffset = .zero
                    }
                    isDragging = false
                    appState.joystickVector = .zero
                    appState.stopMovement()
                }
            )
        )
    }
}

// MARK: - NSViewRepresentable 滑鼠捕捉

private struct JoystickMouseCapture: NSViewRepresentable {
    let baseRadius: CGFloat
    let thumbRadius: CGFloat
    var onDrag: (CGSize, CGPoint) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> JoystickMouseView {
        JoystickMouseView(baseRadius: baseRadius, thumbRadius: thumbRadius)
    }

    func updateNSView(_ nsView: JoystickMouseView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private class JoystickMouseView: NSView {
    let baseRadius: CGFloat
    let thumbRadius: CGFloat
    var onDrag: ((CGSize, CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    init(baseRadius: CGFloat, thumbRadius: CGFloat) {
        self.baseRadius = baseRadius
        self.thumbRadius = thumbRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// macOS 12 相容：NSView 預設 intrinsicContentSize 回傳 (-1,-1)，
    /// 導致 SwiftUI validateDimension crash。覆寫為 .zero 讓 SwiftUI 以父容器大小展開。
    override var intrinsicContentSize: NSSize { .zero }

    // 允許不需要先點擊視窗就能接收事件
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        handle(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handle(event)
    }

    override func mouseUp(with event: NSEvent) {
        DispatchQueue.main.async { self.onEnd?() }
    }

    private func handle(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        let dx = point.x - center.x
        // NSView Y 軸向上；SwiftUI offset Y 軸向下，所以翻轉
        let dySwiftUI = -(point.y - center.y)

        let distance = sqrt(dx * dx + dySwiftUI * dySwiftUI)
        let maxDist = baseRadius - thumbRadius

        let cx: CGFloat
        let cy: CGFloat
        if distance <= maxDist {
            cx = dx
            cy = dySwiftUI
        } else {
            let scale = maxDist / distance
            cx = dx * scale
            cy = dySwiftUI * scale
        }

        let norm = maxDist > 0 ? maxDist : 1
        let offset = CGSize(width: cx, height: cy)
        // vector Y：往上拖 = 北 = +1，所以再翻轉一次
        let vector = CGPoint(x: cx / norm, y: -cy / norm)

        DispatchQueue.main.async { self.onDrag?(offset, vector) }
    }
}

// MARK: - 方向指示線

private struct DirectionLines: View {
    let radius: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: radius * 2 * 0.6)
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: radius * 2 * 0.6, height: 1)

            ForEach([0, 90, 180, 270], id: \.self) { angle in
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .offset(y: -(radius * 0.65))
                    .rotationEffect(.degrees(Double(angle)))
            }
        }
    }
}

// MARK: - 鍵盤方向鍵支援

struct KeyboardMovementOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Color.clear
            .onAppear { KeyboardMonitor.shared.start(appState: appState) }
            .onDisappear { KeyboardMonitor.shared.stop() }
    }
}

private class KeyboardMonitor {
    static let shared = KeyboardMonitor()

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    private let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    func start(appState: AppState) {
        stop()

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.arrowKeyCodes.contains(event.keyCode) else { return event }
            let vector = self.vectorFor(keyCode: event.keyCode)
            DispatchQueue.main.async {
                appState.joystickVector = vector
                if !appState.isMoving { appState.startJoystickMovement() }
            }
            return nil
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self, self.arrowKeyCodes.contains(event.keyCode) else { return event }
            DispatchQueue.main.async {
                appState.joystickVector = CGPoint(x: 0, y: 0)
                appState.stopMovement()
            }
            return nil
        }
    }

    func stop() {
        if let m = keyDownMonitor { NSEvent.removeMonitor(m); keyDownMonitor = nil }
        if let m = keyUpMonitor  { NSEvent.removeMonitor(m); keyUpMonitor = nil }
    }

    private func vectorFor(keyCode: UInt16) -> CGPoint {
        switch keyCode {
        case 126: return CGPoint(x: 0,  y: 1)   // ↑ 北
        case 125: return CGPoint(x: 0,  y: -1)  // ↓ 南
        case 123: return CGPoint(x: -1, y: 0)   // ← 西
        case 124: return CGPoint(x: 1,  y: 0)   // → 東
        default:  return CGPoint(x: 0,  y: 0)
        }
    }
}
