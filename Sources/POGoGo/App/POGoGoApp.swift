import SwiftUI
import ObjectiveC

@main
struct POGoGoApp: App {
    init() {
        _patchNSTextFieldIntrinsicSizeIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { setDefaultWindowSize() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("使用說明...") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            }
        }
    }

    private func setDefaultWindowSize() {
        guard let window = NSApp.windows.first else { return }
        // 只在初始啟動時設定大小（視窗已有尺寸時不覆蓋）
        if window.frame.width < 800 {
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.center()
        }
    }
}

extension Notification.Name {
    static let showOnboarding = Notification.Name("showOnboarding")
}

// MARK: - macOS 12 NSView intrinsicContentSize 全域修正

/// macOS 12 SwiftUI 3.5.2 的 validateDimension 無法處理 NSView.intrinsicContentSize
/// 回傳的 noIntrinsicMetric（-1），導致 EXC_BAD_INSTRUCTION。
/// 對以下已知會回傳 -1 的類別直接替換實作，將負值截斷為 0：
///   NSTextField、NSSlider、NSProgressIndicator、NSView（兜底）
private func _patchNSTextFieldIntrinsicSizeIfNeeded() {
    if #available(macOS 13, *) { return }
    let sel = #selector(getter: NSView.intrinsicContentSize)
    for cls in [NSView.self, NSTextField.self, NSSlider.self,
                NSProgressIndicator.self] as [AnyClass] {
        guard let method = class_getInstanceMethod(cls, sel) else { continue }
        typealias SizeIMP = @convention(c) (NSView, Selector) -> NSSize
        let orig = unsafeBitCast(method_getImplementation(method), to: SizeIMP.self)
        let block: @convention(block) (NSView) -> NSSize = { v in
            let s = orig(v, sel)
            return NSSize(width: max(0, s.width), height: max(0, s.height))
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
