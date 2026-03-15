import SwiftUI
import MapKit

// MARK: - 右側控制面板

struct ControlPanelView: View {
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var appState: AppState
    var onSearchResult: (CLLocationCoordinate2D) -> Void

    @State private var searchText: String = ""
    @State private var showSearchResults: Bool = false
    @State private var searchResults: [MKMapItem] = []
    @State private var showAutoWalkConfirm: Bool = false
    @State private var pendingDestination: CLLocationCoordinate2D? = nil

    // 座標輸入自動走路
    @State private var coordInput: String = ""
    @State private var coordInputError: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 裝置狀態
            deviceStatusSection
            Divider()

            // iOS 17+ Tunnel（pymobiledevice3 GPS 注入所需）
            tunnelSection
            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // 位置搜尋
                    searchSection
                    Divider()

                    // 目前座標
                    coordinateSection
                    Divider()

                    // 冷卻計時器
                    cooldownSection
                    Divider()

                    // 座標自動走路
                    coordAutoWalkSection
                    Divider()

                    // 操作按鈕
                    actionButtons
                }
                .padding(16)
            }

            Divider()

            // 速度控制 + 搖桿（ScrollView 外，避免 macOS 拖曳事件被攔截）
            VStack(spacing: 0) {
                speedSection
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                Divider()
                joystickSection
                    .padding(16)
            }
        }
        .frame(width: 240)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 裝置狀態

    private var deviceStatusSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(deviceManager.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                if deviceManager.isConnected && deviceManager.connectedDevices.count > 1 {
                    // 多裝置：顯示下拉選單
                    Menu {
                        ForEach(deviceManager.connectedDevices, id: \.self) { udid in
                            Button(action: { deviceManager.selectDevice(udid: udid) }) {
                                HStack {
                                    Text(deviceManager.deviceNames[udid] ?? udid)
                                    if udid == deviceManager.selectedDeviceUDID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(deviceManager.deviceName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Text(deviceManager.isConnected ? deviceManager.deviceName : "未連接裝置")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                if deviceManager.isConnected, let udid = deviceManager.selectedDeviceUDID {
                    Text(String(udid.prefix(12)) + "...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(action: { deviceManager.startMonitoring() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("重新偵測裝置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            deviceManager.isConnected
            ? Color.green.opacity(0.08)
            : Color.red.opacity(0.08)
        )
    }

    // MARK: - iOS 17+ tunneld 狀態

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tunneldColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("iOS 17+ Tunnel")
                        .font(.system(size: 11, weight: .semibold))
                    Text(tunnelStatusText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if deviceManager.tunneldStatus == .starting {
                    _CompatibleProgressView(style: .spinning, controlSize: .small)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: {
                        deviceManager.checkDependencies()
                        deviceManager.checkTunneld()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("重新偵測")
                }
            }

            if !deviceManager.isBundledToolAvailable {
                // 工具未找到（開發環境或安裝損壞）
                Text("內建工具未找到，請重新安裝 POGoGo")
                    .font(.system(size: 9))
                    .foregroundColor(.red)
            } else if !deviceManager.isLaunchDaemonInstalled {
                // 尚未設定開機服務
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: { deviceManager.startTunneldWithAuth() }) {
                        Label("設定開機自啟動 Tunnel", systemImage: "lock.shield")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                    Text("一次設定，之後開機自動執行（需輸入 Mac 密碼）")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            } else if deviceManager.tunneldStatus == .stopped {
                // Daemon 已安裝但未執行（KeepAlive 自動重試中）
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button(action: { deviceManager.restartLaunchDaemon() }) {
                            Label("強制重啟", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                        Button(action: {
                            let log = (try? String(contentsOfFile: "/tmp/pogogo-tunneld.log", encoding: .utf8)) ?? "（無 log）"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(log, forType: .string)
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("複製 /tmp/pogogo-tunneld.log 到剪貼簿")
                    }
                    Text("服務正在自動重試，或手動強制重啟。複製 Log 可協助診斷。")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tunneldColor.opacity(0.07))
    }

    private var tunnelStatusText: String {
        if !deviceManager.isBundledToolAvailable {
            return "內建工具未找到"
        }
        if !deviceManager.isLaunchDaemonInstalled {
            return "尚未設定開機自動服務"
        }
        // 若有錯誤訊息（重啟或安裝失敗），優先顯示
        if deviceManager.tunneldStatus == .stopped && !deviceManager.installProgress.isEmpty {
            return deviceManager.installProgress
        }
        return deviceManager.tunneldStatus.displayText
    }

    private var tunneldColor: Color {
        if !deviceManager.isBundledToolAvailable { return .red }
        if !deviceManager.isLaunchDaemonInstalled { return .orange }
        switch deviceManager.tunneldStatus {
        case .unknown:  return .secondary
        case .starting: return .blue
        case .running:  return .green
        case .stopped:  return .orange
        }
    }

    // MARK: - 搜尋

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("搜尋地點", systemImage: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            HStack {
                _CompatibleTextField(text: $searchText, placeholder: "輸入地點名稱...", isRounded: true, onSubmit: performSearch)
                Button("搜尋") { performSearch() }
                    .buttonStyle(.bordered)
            }

            if showSearchResults && !searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(searchResults.prefix(5), id: \.self) { item in
                        Button(action: {
                            if let coord = item.placemark.location?.coordinate {
                                onSearchResult(coord)
                                appState.teleport(to: coord)
                            }
                            showSearchResults = false
                            searchText = item.name ?? ""
                        }) {
                            HStack {
                                Image(systemName: "mappin")
                                    .foregroundColor(.red)
                                    .frame(width: 16)
                                Text(item.name ?? "未知地點")
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        .background(Color(NSColor.controlBackgroundColor).cornerRadius(4))
                    }
                }
            }
        }
    }

    // MARK: - 座標顯示

    private var coordinateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("目前偽造位置", systemImage: "location.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                CoordinateRow(label: "緯度", value: String(format: "%.6f°", appState.currentCoordinate.latitude))
                CoordinateRow(label: "經度", value: String(format: "%.6f°", appState.currentCoordinate.longitude))
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // 複製按鈕
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.formattedCoordinate, forType: .string)
            }) {
                Label("複製座標", systemImage: "doc.on.clipboard")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 速度控制

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("移動速度", systemImage: "speedometer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            // 速度模式選擇
            HStack(spacing: 6) {
                ForEach(SpeedMode.allCases, id: \.self) { mode in
                    SpeedModeButton(
                        mode: mode,
                        isSelected: appState.speedMode == mode,
                        action: { appState.speedMode = mode }
                    )
                }
            }

            // 速度倍率
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("速度倍率")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1fx", appState.speedMultiplier))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                _CompatibleSlider(value: $appState.speedMultiplier, range: 0.5...2.0, step: 0.1)
                    .frame(maxWidth: .infinity)
            }

            Text("目前：\(String(format: "%.1f m/s", appState.speedMode.speed * appState.speedMultiplier))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 搖桿

    private var joystickSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("方向搖桿", systemImage: "gamecontroller.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                ZStack {
                    // 深色背景
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.7))
                        .frame(width: 150, height: 150)

                    JoystickView(appState: appState)
                }
                Spacer()
            }

            Text("拖動搖桿移動 · 放開停止")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - 冷卻計時器

    private var cooldownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 標題列 + 開關
            HStack {
                Label("冷卻計時器", systemImage: "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                _CompatibleToggle(isOn: $appState.cooldownEnabled)
                    .onChange(of: appState.cooldownEnabled) { enabled in
                        if !enabled { appState.skipCooldown() }
                    }
            }

            // 計時器內容（僅在開啟時顯示）
            if appState.cooldownEnabled {
                HStack {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                            .frame(width: 48, height: 48)

                        Circle()
                            .trim(from: 0, to: cooldownProgress)
                            .stroke(
                                appState.isCoolingDown ? Color.orange : Color.green,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 48, height: 48)
                            .animation(.linear(duration: 1), value: cooldownProgress)

                        Image(systemName: appState.isCoolingDown ? "clock" : "checkmark")
                            .foregroundColor(appState.isCoolingDown ? .orange : .green)
                            .font(.system(size: 14))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.isCoolingDown ? "冷卻中" : "可傳送")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(appState.isCoolingDown ? .orange : .green)
                        if appState.isCoolingDown {
                            Text(appState.formattedCooldown)
                                .font(.system(size: 20, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(.orange)
                        }
                    }

                    Spacer()

                    if appState.isCoolingDown {
                        Button("跳過") { appState.skipCooldown() }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                    }
                }
                .padding(12)
                .background(
                    (appState.isCoolingDown ? Color.orange : Color.green).opacity(0.08)
                )
                .cornerRadius(10)
            }
        }
    }

    // MARK: - 座標自動走路

    private var coordAutoWalkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("輸入座標自動走路", systemImage: "location.north.line.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                _CompatibleTextField(
                    text: $coordInput,
                    placeholder: "緯度, 經度",
                    isRounded: true,
                    nsFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    onSubmit: startAutoWalkToCoord
                )
                .onChange(of: coordInput) { _ in coordInputError = false }

                Button(action: startAutoWalkToCoord) {
                    Group {
                        if #available(macOS 13.0, *) {
                            Image(systemName: "figure.walk.arrival")
                        } else {
                            Image(systemName: "mappin.and.ellipse")
                        }
                    }
                    .font(.system(size: 14))
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("自動走路到此座標")
            }

            if coordInputError {
                Text("格式錯誤，請輸入「緯度, 經度」")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            } else if let dest = parseCoordInput(), !coordInput.isEmpty {
                let dist = appState.distanceToFormatted(dest)
                Text("距離：\(dist)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func startAutoWalkToCoord() {
        guard let coord = parseCoordInput() else {
            coordInputError = true
            return
        }
        appState.startAutoWalk(to: coord)
    }

    private func parseCoordInput() -> CLLocationCoordinate2D? {
        let parts = coordInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]),
              lat >= -90, lat <= 90,
              lon >= -180, lon <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - 操作按鈕

    private var actionButtons: some View {
        VStack(spacing: 8) {
            // 自動走路狀態
            if appState.isAutoWalking {
                Button(action: { appState.stopAutoWalk() }) {
                    Label("停止自動走路", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            // 重置位置
            Button(action: {
                appState.resetLocation()
            }) {
                Label("重置真實 GPS", systemImage: "location.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("還原裝置使用真實 GPS 位置")

            // 說明
            Text("左鍵點地圖：瞬間傳送\n右鍵點地圖：自動走路")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

        }
    }

    // MARK: - 輔助

    private var cooldownProgress: CGFloat {
        guard appState.isCoolingDown, appState.cooldownSeconds > 0 else { return 0 }
        // 最長冷卻 7200 秒（2小時）
        return CGFloat(7200 - appState.cooldownSeconds) / 7200
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                self.searchResults = response?.mapItems ?? []
                self.showSearchResults = !self.searchResults.isEmpty
            }
        }
    }
}

// MARK: - 速度模式按鈕

private struct SpeedModeButton: View {
    let mode: SpeedMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14))
                Text(mode.rawValue)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color(NSColor.controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 座標列元件

private struct CoordinateRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }
}
