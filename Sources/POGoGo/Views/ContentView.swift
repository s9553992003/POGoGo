import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var appState: AppState

    // 右鍵選單
    @State private var showAutoWalkMenu: Bool = false
    @State private var pendingDestination: CLLocationCoordinate2D? = nil

    // 搜尋結果跳轉目標（給 MapView 重新定位用）
    @State private var mapFocusCoord: CLLocationCoordinate2D? = nil

    // 使用者引導
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showOnboarding: Bool = false

    init() {
        let dm = DeviceManager()
        _deviceManager = StateObject(wrappedValue: dm)
        _appState = StateObject(wrappedValue: AppState(deviceManager: dm))
    }

    var body: some View {
        HSplitView {
            // 左：地圖
            mapLayer

            // 右：控制面板
            ControlPanelView(
                deviceManager: deviceManager,
                appState: appState,
                onSearchResult: { coord in
                    mapFocusCoord = coord
                }
            )
        }
        .onAppear {
            deviceManager.startMonitoring()
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showOnboarding = true
        }
        .onDisappear {
            deviceManager.stopMonitoring()
        }
        // 內建工具未就緒警告（正常情況不應出現）
        .overlay(alignment: .top) {
            if !deviceManager.isBundledToolAvailable {
                installWarningBanner
            }
        }
        // 右鍵自動走路確認
        .confirmationDialog(
            "自動走路到此位置？",
            isPresented: $showAutoWalkMenu,
            titleVisibility: .visible
        ) {
            Button("自動走路") {
                if let dest = pendingDestination {
                    appState.startAutoWalk(to: dest)
                }
            }
            Button("傳送過去") {
                if let dest = pendingDestination {
                    appState.teleport(to: dest)
                }
            }
            Button("取消", role: .cancel) {}
        }
        // 使用者引導
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
            }
        }
    }

    // MARK: - 地圖層

    private var mapLayer: some View {
        ZStack(alignment: .topLeading) {
            MapView(
                appState: appState,
                onTap: { coord in
                    // 左鍵：瞬間傳送
                    appState.teleport(to: coord)
                },
                onRightClick: { coord in
                    // 右鍵：顯示選單
                    pendingDestination = coord
                    showAutoWalkMenu = true
                }
            )
            .ignoresSafeArea()

            // 左上角狀態 badge
            statusBadge
                .padding(12)
        }
    }

    // MARK: - 狀態 Badge

    private var statusBadge: some View {
        HStack(spacing: 8) {
            if appState.isAutoWalking {
                Label("自動走路中", systemImage: "figure.walk")
                    .foregroundColor(.white)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.blue))
            }

            if appState.cooldownEnabled && appState.isCoolingDown {
                Label("冷卻 \(appState.formattedCooldown)", systemImage: "timer")
                    .foregroundColor(.white)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.orange))
            }
        }
    }

    // MARK: - 內建工具警告 Banner

    private var installWarningBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("內建工具未就緒，iOS 17+ 無法注入位置。請重新安裝 POGoGo。")
                .font(.system(size: 12))
            Spacer()
            Button("查看說明") {
                showOnboarding = true
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
