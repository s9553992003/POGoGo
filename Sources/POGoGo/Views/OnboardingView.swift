import SwiftUI

struct OnboardingView: View {
    var onDismiss: () -> Void

    @State private var currentStep: Int = 0
    @State private var goingForward: Bool = true

    private let steps: [OnboardingStep] = [
        .welcome,
        .deviceSetup,
        .usage,
        .done
    ]

    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicators
                stepIndicator
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                // Page content
                ZStack {
                    switch currentStep {
                    case 0: WelcomeStepView().transition(slideTransition)
                    case 1: DeviceSetupStepView().transition(slideTransition)
                    case 2: UsageStepView().transition(slideTransition)
                    default: DoneStepView().transition(slideTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Navigation buttons
                navigationButtons
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                    .padding(.horizontal, 40)
            }
        }
        .frame(width: 580, height: 520)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { i in
                if i < currentStep {
                    // Completed
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                } else if i == currentStep {
                    // Current
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: 24, height: 8)
                } else {
                    // Future
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .animation(.spring(response: 0.3), value: currentStep)
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            if currentStep > 0 {
                Button("上一步") {
                    goingForward = false
                    withAnimation(.easeInOut(duration: 0.25)) { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < steps.count - 1 {
                Button("下一步") {
                    goingForward = true
                    withAnimation(.easeInOut(duration: 0.25)) { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            } else {
                Button("開始使用") {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
    }

    private var slideTransition: AnyTransition {
        AnyTransition.asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading),
            removal: .move(edge: goingForward ? .leading : .trailing)
        )
    }
}

// MARK: - Step Enum

private enum OnboardingStep {
    case welcome, deviceSetup, usage, done
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var body: some View {
        OnboardingStepContainer {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.bottom, 16)

            Text("歡迎使用 POGoGo")
                .font(.system(size: 28, weight: .bold))

            Text("透過 USB 連接 iPhone，在地圖上\n點擊任意位置即可模擬 GPS 位置。")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                FeatureTag(icon: "map.fill", label: "地圖傳送")
                FeatureTag(icon: "gamecontroller.fill", label: "搖桿移動")
                FeatureTag(icon: "figure.walk", label: "自動走路")
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Step 2: Device Setup

private struct DeviceSetupStepView: View {
    var body: some View {
        OnboardingStepContainer {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 52))
                .foregroundColor(.blue)
                .padding(.bottom, 12)

            Text("設定 iPhone")
                .font(.system(size: 24, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                SetupRow(
                    number: 1,
                    icon: "hammer.fill",
                    title: "開啟開發者模式",
                    detail: "設定 → 隱私權與安全性 → 開發者模式"
                )
                SetupRow(
                    number: 2,
                    icon: "cable.connector",
                    title: "用 USB 連接 Mac",
                    detail: "連接後點選 iPhone 上的「信任」"
                )
                SetupRow(
                    number: 3,
                    icon: "checkmark.seal.fill",
                    title: "確認 POGoGo 偵測到裝置",
                    detail: "開啟 POGoGo，右側控制面板應顯示裝置名稱（綠色狀態）"
                )
                SetupRow(
                    number: 4,
                    icon: "lock.shield.fill",
                    title: "設定開機自啟動 Tunnel",
                    detail: "首次使用點「設定開機自啟動 Tunnel」，輸入 Mac 密碼完成一次性設定"
                )
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Step 3: Usage

private struct UsageStepView: View {
    var body: some View {
        OnboardingStepContainer {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
                .padding(.bottom, 12)

            Text("基本操作")
                .font(.system(size: 24, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                UsageRow(icon: "cursorarrow.click", color: .blue,
                         action: "左鍵點地圖", effect: "瞬間傳送到該位置")
                UsageRow(icon: "cursorarrow.click.2", color: .orange,
                         action: "右鍵點地圖", effect: "選擇「自動走路」或「傳送」")
                UsageRow(icon: "gamecontroller.fill", color: .purple,
                         action: "拖動搖桿", effect: "連續方向移動，放開停止")
                UsageRow(icon: "magnifyingglass", color: .teal,
                         action: "搜尋地點", effect: "輸入地名快速跳轉")
                UsageRow(icon: "speedometer", color: .red,
                         action: "切換速度模式", effect: "步行／慢跑／腳踏車／汽車")
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Step 4: Done

private struct DoneStepView: View {
    var body: some View {
        OnboardingStepContainer {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.bottom, 16)

            Text("準備完成！")
                .font(.system(size: 28, weight: .bold))

            Text("連接 iPhone，在地圖上點擊任意地點\n即可開始模擬 GPS 位置。")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("隨時可在「說明」選單重新查看引導。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Reusable Components

private struct OnboardingStepContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 16) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

private struct FeatureTag: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.blue)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 80)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

private struct SetupRow: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

private struct UsageRow: View {
    let icon: String
    let color: Color
    let action: String
    let effect: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(action)
                    .font(.system(size: 13, weight: .semibold))
                Text(effect)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}
