import Foundation
import Combine
import AppKit
import CryptoKit

enum TunneldStatus: Equatable {
    case unknown
    case starting
    case running
    case stopped

    var isRunning: Bool { self == .running }

    var displayText: String {
        switch self {
        case .unknown:  return "偵測中..."
        case .starting: return "啟動中..."
        case .running:  return "執行中 ✅"
        case .stopped:  return "未執行"
        }
    }
}

class DeviceManager: ObservableObject {
    @Published var connectedDevices: [String] = []
    @Published var selectedDeviceUDID: String? = nil
    @Published var deviceName: String = "未連接"
    @Published var deviceNames: [String: String] = [:]
    @Published var isConnected: Bool = false
    // UDID → hardware UDID
    private var hardwareUDIDs: [String: String] = [:]

    /// PyInstaller 持久化解壓目錄（避免每次重開機都重新解壓 Python，加速啟動）
    private var toolTmpDir: String { "\(NSHomeDirectory())/.pogogo/tmp" }

    /// 內建工具（pogogo 二進位）是否已部署就緒
    @Published var isBundledToolAvailable: Bool = false
    @Published var tunneldStatus: TunneldStatus = .unknown
    @Published var installProgress: String = ""
    @Published var isLaunchDaemonInstalled: Bool = false

    private let launchDaemonLabel = "com.pogogo.tunneld"
    private let launchDaemonPlist = "/Library/LaunchDaemons/com.pogogo.tunneld.plist"

    /// 部署路徑（使用者家目錄，daemon 與 worker 皆使用此路徑）
    private var deployedToolPath: String { NSHomeDirectory() + "/.pogogo/bin/pogogo" }

    /// App Bundle 內的原始二進位（依 CPU 架構選擇 arm64 或 x86_64）
    private var bundledToolPath: String? {
        #if arch(arm64)
        return Bundle.main.url(forResource: "pogogo_arm64", withExtension: nil)?.path
        #else
        return Bundle.main.url(forResource: "pogogo_x86_64", withExtension: nil)?.path
        #endif
    }

    private let locationQueue = DispatchQueue(label: "com.pogogo.location", qos: .userInitiated)
    private let detectQueue   = DispatchQueue(label: "com.pogogo.detect",   qos: .utility)
    private var lastLocationSet = Date.distantPast
    private let minLocationInterval: TimeInterval = 0.3

    // 持久化 worker 進程（保持單一 DVT 連線）
    private var workerProcess: Process?
    private let workerLock = NSLock()
    private var workerRestartCount = 0

    // worker 相關檔案路徑
    private let coordsFile = "/tmp/pogogo_coords.txt"
    private let stopFile   = "/tmp/pogogo_stop.txt"

    private var detectionTimer: Timer?
    private var tunneldCheckTimer: Timer?
    private var isDetecting = false

    // MARK: - Debug Log

    private let debugLogPath = "/tmp/pogogo-debug.log"

    private func dlog(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogPath),
               let fh = FileHandle(forWritingAtPath: debugLogPath) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: debugLogPath))
            }
        }
    }

    // MARK: - Init

    init() {
        dlog("=== POGoGo 啟動 ===")
        checkDependencies()
    }

    // MARK: - 工具部署

    /// 檢查並部署內建工具 binary，設定 isBundledToolAvailable。
    func checkDependencies() {
        locationQueue.async { [weak self] in
            guard let self = self else { return }
            let (available, updated) = self.deployBundledBinaryIfNeeded()
            DispatchQueue.main.async {
                self.isBundledToolAvailable = available
                // 若 startMonitoring() 在部署完成前已執行（race condition），補啟動 tunneld 監控
                if self.detectionTimer != nil && self.tunneldCheckTimer == nil {
                    self.checkTunneld()
                    self.tunneldCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                        self?.checkTunneld()
                    }
                }
                self.checkLaunchDaemon()
                // binary 有更新時，重啟 daemon 以載入新版本
                if updated && self.isLaunchDaemonInstalled {
                    self.dlog("checkDependencies: binary updated, restarting daemon")
                    self.restartLaunchDaemon()
                }
            }
        }
    }

    /// 將 Bundle 內的 pogogo binary 複製到 ~/.pogogo/bin/（如有更新則覆蓋）。
    /// 返回 (available, updated)：available=binary 可用，updated=本次有更新。
    private func deployBundledBinaryIfNeeded() -> (available: Bool, updated: Bool) {
        let fm = FileManager.default

        // Ensure persistent PyInstaller tmp dir exists
        try? fm.createDirectory(atPath: toolTmpDir, withIntermediateDirectories: true)

        guard let bundled = bundledToolPath else {
            // 開發環境：Bundle 中無 binary，檢查已部署的版本
            let exists = fm.fileExists(atPath: deployedToolPath)
            dlog("deployBinary: no bundled binary, deployedExists=\(exists)")
            return (exists, false)
        }

        let deployDir = (deployedToolPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: deployDir, withIntermediateDirectories: true)

        // 比對 SHA256（使用 marker 檔案），偵測內容或簽名變更
        let hashFilePath = deployedToolPath + ".sha256"
        let needsCopy: Bool
        if !fm.fileExists(atPath: deployedToolPath) {
            needsCopy = true
            dlog("deployBinary: deployed binary missing, needsCopy=true")
        } else {
            let bundledHash = sha256OfFile(bundled) ?? ""
            let storedHash = (try? String(contentsOfFile: hashFilePath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            needsCopy = (bundledHash != storedHash)
            dlog("deployBinary: bundledHash=\(bundledHash.prefix(8))... storedHash=\(storedHash.prefix(8))... needsCopy=\(needsCopy)")
        }

        if needsCopy {
            // Binary changed — invalidate cached PyInstaller extraction
            try? fm.removeItem(atPath: toolTmpDir)
            try? fm.createDirectory(atPath: toolTmpDir, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: deployedToolPath)
            do {
                try fm.copyItem(atPath: bundled, toPath: deployedToolPath)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deployedToolPath)
                // 保存 bundled binary 的 hash，下次比對用
                let bundledHash = sha256OfFile(bundled) ?? ""
                try? bundledHash.write(toFile: hashFilePath, atomically: true, encoding: .utf8)
                dlog("deployBinary: copied OK → \(deployedToolPath)")
            } catch {
                dlog("deployBinary: copy FAILED \(error)")
                return (false, false)
            }
        }

        // 無論是否剛複製，都清除 quarantine xattr，確保 macOS 不封鎖執行
        removeQuarantine(deployedToolPath)

        return (fm.fileExists(atPath: deployedToolPath), needsCopy)
    }

    // MARK: - 裝置監控

    func startMonitoring() {
        detectDevices()
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.detectDevices()
        }
        checkTunneld()
        tunneldCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkTunneld()
        }
    }

    func stopMonitoring() {
        detectionTimer?.invalidate()
        detectionTimer = nil
        tunneldCheckTimer?.invalidate()
        tunneldCheckTimer = nil
    }

    private func detectDevices() {
        guard !isDetecting else { return }
        isDetecting = true
        detectQueue.async { [weak self] in
            defer { self?.isDetecting = false }
            guard let self = self else { return }
            if self.isBundledToolAvailable {
                self.detectWithBundledTool()
            }
        }
    }

    // MARK: - 裝置偵測（pogogo detect）

    private func detectWithBundledTool() {
        // pogogo detect 輸出 JSON 陣列：[{"hwUDID": "...", "name": "..."}, ...]
        let output = runBinSync(bin: deployedToolPath, args: ["detect"])
        dlog("detect output: \(output.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines))")
        guard let data = output.data(using: .utf8),
              let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            dlog("detect: JSON parse failed, raw=\(output.prefix(100))")
            return
        }

        struct DeviceInfo { let udid: String; let name: String; let hwUDID: String }
        let found = devices.compactMap { d -> DeviceInfo? in
            guard let hw = d["hwUDID"], let name = d["name"] else { return nil }
            return DeviceInfo(udid: hw, name: name, hwUDID: hw)
        }

        let udids = found.map { $0.udid }
        let nameMap = Dictionary(uniqueKeysWithValues: found.map { ($0.udid, $0.name) })
        let hwUDIDMap = Dictionary(uniqueKeysWithValues: found.map { ($0.udid, $0.hwUDID) })

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.connectedDevices = udids
            self.deviceNames = nameMap
            self.hardwareUDIDs = hwUDIDMap
            if let first = udids.first {
                if self.selectedDeviceUDID == nil || !udids.contains(self.selectedDeviceUDID!) {
                    self.selectedDeviceUDID = first
                }
                let wasDisconnected = !self.isConnected
                self.isConnected = true
                let udid = self.selectedDeviceUDID ?? first
                self.deviceName = nameMap[udid] ?? "iPhone"
                // 裝置重新連接後，若有待注入座標且 worker 未執行，自動重啟
                if wasDisconnected {
                    let coordsExist = FileManager.default.fileExists(atPath: self.coordsFile)
                    let stopExists  = FileManager.default.fileExists(atPath: self.stopFile)
                    if coordsExist && !stopExists {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.ensureWorkerRunning()
                        }
                    }
                }
            } else {
                self.isConnected = false
                self.deviceName = "未連接"
                self.selectedDeviceUDID = nil
            }
        }
    }

    func selectDevice(udid: String) {
        guard connectedDevices.contains(udid) else { return }
        selectedDeviceUDID = udid
        deviceName = deviceNames[udid] ?? "iPhone"
        stopWorker()
    }

    // MARK: - Tunnel 管理（iOS 17+ GPS 注入所需）

    func checkTunneld() {
        locationQueue.async { [weak self] in
            guard let self = self else { return }
            let running = self.isTunneldRunning()
            self.dlog("checkTunneld: port49151=\(running) currentStatus=\(self.tunneldStatus)")
            DispatchQueue.main.async {
                if running {
                    self.tunneldStatus = .running
                } else if self.tunneldStatus != .starting {
                    self.tunneldStatus = .stopped
                    self.stopWorker()
                }
            }
        }
    }

    private func isTunneldRunning() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/nc"
        task.arguments = ["-z", "-w", "1", "127.0.0.1", "49151"]
        task.environment = ["HOME": NSHomeDirectory()]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// 查詢 tunneld HTTP API，取得已建立通道的裝置 UDID 列表
    func tunneldDeviceUDIDs() -> Set<String> {
        guard let url = URL(string: "http://127.0.0.1:49151"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return Set(json.keys)
    }

    func startTunneldWithAuth() {
        if isLaunchDaemonInstalled {
            restartLaunchDaemon()
        } else {
            guard isBundledToolAvailable else { return }
            guard tunneldStatus != .starting else { return }
            DispatchQueue.main.async { self.tunneldStatus = .starting }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                self.installLaunchDaemon(progress: { msg in
                    DispatchQueue.main.async { self.installProgress = msg }
                })
                if self.tunneldStatus != .running {
                    DispatchQueue.main.async { self.tunneldStatus = .stopped }
                }
            }
        }
    }

    func checkLaunchDaemon() {
        let plistExists = FileManager.default.fileExists(atPath: launchDaemonPlist)
        guard plistExists else {
            isLaunchDaemonInstalled = false
            return
        }
        // 驗證 plist 是否指向當前 deployed binary，且 PATH 包含 /sbin（避免舊版設定殘留）
        let plistContent = (try? String(contentsOfFile: launchDaemonPlist, encoding: .utf8)) ?? ""
        isLaunchDaemonInstalled = plistContent.contains(deployedToolPath) && plistContent.contains("/sbin")
    }

    /// 安裝 tunneld 為 LaunchDaemon，使用內建的 pogogo binary。
    private func installLaunchDaemon(progress: @escaping (String) -> Void) {
        let toolPath = deployedToolPath
        let userHome = NSHomeDirectory()

        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>com.pogogo.tunneld</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>\(toolPath)</string>
\t\t<string>tunneld</string>
\t</array>
\t<key>EnvironmentVariables</key>
\t<dict>
\t\t<key>HOME</key>
\t\t<string>\(userHome)</string>
\t\t<key>PATH</key>
\t\t<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin</string>
\t\t<key>PYTHONUNBUFFERED</key>
\t\t<string>1</string>
\t</dict>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<true/>
\t<key>StandardOutPath</key>
\t<string>/tmp/pogogo-tunneld.log</string>
\t<key>StandardErrorPath</key>
\t<string>/tmp/pogogo-tunneld.log</string>
</dict>
</plist>
"""
        let tmpPlist = "/tmp/pogogo-tunneld-daemon.plist"
        guard (try? plistContent.write(toFile: tmpPlist, atomically: true, encoding: .utf8)) != nil else {
            progress("無法寫入暫存 plist")
            return
        }

        progress("安裝開機自動服務...")

        // 優先用 launchctl bootstrap（macOS 13+），失敗則 fallback 至 launchctl load（macOS 12）
        let shellCmd = "cp '\(tmpPlist)' '\(launchDaemonPlist)' && "
            + "chown root:wheel '\(launchDaemonPlist)' && "
            + "chmod 644 '\(launchDaemonPlist)' && "
            + "launchctl bootout system/\(launchDaemonLabel) 2>/dev/null ; "
            + "launchctl bootstrap system '\(launchDaemonPlist)' 2>/dev/null || "
            + "launchctl load '\(launchDaemonPlist)'"

        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(shellCmd)\" with administrator privileges")?
            .executeAndReturnError(&error)

        if let err = error {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "安裝失敗"
            DispatchQueue.main.async { self.tunneldStatus = .stopped }
            progress("Tunnel 服務設定失敗：\(msg)")
            return
        }

        // 輪詢最多 60 秒等 tunneld 啟動（PyInstaller 首次解壓需時較長）
        dlog("installLaunchDaemon: NSAppleScript done (error=\(error?.description ?? "nil")), polling...")
        for i in 0..<60 {
            Thread.sleep(forTimeInterval: 1.0)
            let up = isTunneldRunning()
            dlog("installLaunchDaemon: poll[\(i)] port49151=\(up)")
            if up {
                DispatchQueue.main.async {
                    self.isLaunchDaemonInstalled = true
                    self.tunneldStatus = .running
                }
                progress("Tunnel 開機自動服務設定完成 ✓")
                return
            }
        }

        // 逾時：讀 log 供診斷
        let logTail = (try? String(contentsOfFile: "/tmp/pogogo-tunneld.log", encoding: .utf8))?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: " | ") ?? ""
        dlog("installLaunchDaemon: timeout, tunneldLog=\(logTail)")

        let plistExists = FileManager.default.fileExists(atPath: launchDaemonPlist)
        DispatchQueue.main.async { self.isLaunchDaemonInstalled = plistExists }
        if plistExists {
            let hint = logTail.isEmpty ? "Tunnel 服務已安裝，啟動中..." : "安裝完成，但啟動失敗：\(logTail)"
            progress(hint)
        } else {
            progress("安裝失敗，請重試")
        }
    }

    func restartLaunchDaemon() {
        guard tunneldStatus != .starting else { return }
        DispatchQueue.main.async { self.tunneldStatus = .starting }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // kickstart -k 失敗（daemon 未 bootstrap）時，用 bootout+bootstrap 確保重新載入
            let plist = self.launchDaemonPlist
            let label = self.launchDaemonLabel
            let cmd = "launchctl kickstart -k system/\(label) 2>/dev/null"
                + " || (launchctl bootout system/\(label) 2>/dev/null ;"
                + " launchctl bootstrap system '\(plist)')"
            self.dlog("restartLaunchDaemon: running kickstart...")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?
                .executeAndReturnError(&error)
            self.dlog("restartLaunchDaemon: kickstart done (error=\(error?.description ?? "nil")), polling...")
            for i in 0..<60 {
                Thread.sleep(forTimeInterval: 1.0)
                let up = self.isTunneldRunning()
                self.dlog("restartLaunchDaemon: poll[\(i)] port49151=\(up)")
                if up {
                    DispatchQueue.main.async { self.tunneldStatus = .running }
                    return
                }
            }
            // 逾時：讀 log 供診斷
            let logTail = (try? String(contentsOfFile: "/tmp/pogogo-tunneld.log", encoding: .utf8))?
                .components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(3)
                .joined(separator: " | ") ?? ""
            self.dlog("restartLaunchDaemon: timeout, tunneldLog=\(logTail)")
            DispatchQueue.main.async {
                self.tunneldStatus = .stopped
                if !logTail.isEmpty {
                    self.installProgress = "重啟失敗：\(logTail)"
                }
            }
        }
    }

    // MARK: - GPS 注入（持久化 Worker 架構）
    //
    // 架構說明：
    //   每次 setLocation 只寫入座標到 /tmp/pogogo_coords.txt
    //   持久化 worker（pogogo worker <udid>）維持單一 DVT 連線，持續讀檔更新 GPS
    //   完全避免「舊進程死亡 → DVT 斷線 → 新進程尚未連線」導致的 GPS 跳動

    func setLocation(latitude: Double, longitude: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastLocationSet) >= minLocationInterval else { return }
        lastLocationSet = now
        writeCoords(latitude: latitude, longitude: longitude)
        ensureWorkerRunning()
    }

    /// 不受速率限制，立即設置位置（用於起始點錨定）
    func forceSetLocation(latitude: Double, longitude: Double) {
        lastLocationSet = Date()
        workerRestartCount = 0
        writeCoords(latitude: latitude, longitude: longitude)
        ensureWorkerRunning()
    }

    private func writeCoords(latitude: Double, longitude: Double) {
        let content = "\(latitude),\(longitude)"
        try? content.write(toFile: coordsFile, atomically: true, encoding: .utf8)
    }

    private func ensureWorkerRunning() {
        guard isBundledToolAvailable, tunneldStatus.isRunning else { return }
        guard let id = selectedDeviceUDID, let hwUDID = hardwareUDIDs[id] else { return }

        workerLock.lock()
        let alive = workerProcess?.isRunning == true
        workerLock.unlock()

        guard !alive else { return }

        locationQueue.async { [weak self] in
            guard let self = self else { return }
            // 確認裝置已在 tunneld 中（最多重試 5 次，每次等 3s）
            // 裝置剛連接後 tunneld 需要數秒才建立 tunnel，不能只試一次
            for attempt in 0..<5 {
                let available = self.tunneldDeviceUDIDs()
                if available.isEmpty || available.contains(hwUDID) {
                    // available 為空 = API 呼叫失敗，無從判斷，直接嘗試啟動
                    // available 包含本裝置 = 就緒
                    self.startWorker(hwUDID: hwUDID)
                    return
                }
                if attempt < 4 {
                    self.dlog("ensureWorker: not in tunneld (attempt \(attempt+1)/5), waiting 3s...")
                    Thread.sleep(forTimeInterval: 3.0)
                } else {
                    let list = available.joined(separator: ", ")
                    DispatchQueue.main.async {
                        self.installProgress = "裝置未在 tunnel 中（tunneld: \(list.prefix(40))）\n請確認 Developer Mode 已開啟"
                    }
                }
            }
        }
    }

    private func startWorker(hwUDID: String) {
        workerLock.lock()
        if workerProcess?.isRunning == true {
            workerLock.unlock()
            return
        }
        workerLock.unlock()

        try? FileManager.default.removeItem(atPath: stopFile)

        let task = Process()
        task.launchPath = deployedToolPath
        task.arguments = ["worker", hwUDID]
        task.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": toolTmpDir
        ]

        FileManager.default.createFile(atPath: "/tmp/pogogo-worker.log", contents: nil)
        if let logFH = FileHandle(forWritingAtPath: "/tmp/pogogo-worker.log") {
            task.standardOutput = logFH
            task.standardError = logFH
        } else {
            task.standardOutput = Pipe()
            task.standardError = Pipe()
        }

        task.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            let status = p.terminationStatus
            self.dlog("worker terminated: status=\(status)")
            self.workerLock.lock()
            self.workerProcess = nil
            self.workerLock.unlock()
            // 若非用戶主動停止且仍有座標，退避重啟 worker
            let stopExists  = FileManager.default.fileExists(atPath: self.stopFile)
            let coordsExist = FileManager.default.fileExists(atPath: self.coordsFile)
            guard !stopExists, coordsExist else { return }
            self.workerRestartCount += 1
            let maxRestarts = 5
            let delay = min(3.0 * Double(self.workerRestartCount), 20.0)
            // 根據退出碼提示用戶原因
            DispatchQueue.main.async {
                switch status {
                case 2:
                    self.installProgress = "裝置不在 tunnel 中，嘗試重連..."
                case 1:
                    self.installProgress = "GPS 注入發生錯誤，嘗試重啟..."
                default:
                    break
                }
            }
            if self.workerRestartCount <= maxRestarts {
                self.dlog("worker restart \(self.workerRestartCount)/\(maxRestarts) in \(Int(delay))s")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.ensureWorkerRunning()
                }
            } else {
                self.dlog("worker exceeded max restarts (\(maxRestarts)), giving up")
                DispatchQueue.main.async {
                    self.installProgress = "GPS 注入失敗（worker 已重啟 \(maxRestarts) 次）\n請確認裝置連接穩定"
                }
            }
        }

        do {
            try task.run()
            workerLock.lock()
            workerProcess = task
            workerLock.unlock()
        } catch {
            dlog("startWorker: task.run() failed: \(error)")
            DispatchQueue.main.async {
                self.installProgress = "無法啟動 worker: \(error.localizedDescription)"
            }
        }
    }

    func stopWorker() {
        try? "stop".write(toFile: stopFile, atomically: true, encoding: .utf8)
        workerLock.lock()
        let w = workerProcess
        workerProcess = nil
        workerLock.unlock()
        w?.terminate()
        workerRestartCount = 0
    }

    func resetLocation() {
        stopWorker()
        try? FileManager.default.removeItem(atPath: coordsFile)

        locationQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isBundledToolAvailable, self.tunneldStatus.isRunning else { return }
            guard let id = self.selectedDeviceUDID, let hwUDID = self.hardwareUDIDs[id] else { return }
            self.runBinAndWait(bin: self.deployedToolPath, args: ["clear", hwUDID])
        }
    }

    // MARK: - 執行輔助

    private func runBinAndWait(bin: String, args: [String]) {
        let task = Process()
        task.launchPath = bin
        task.arguments = args
        task.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": toolTmpDir
        ]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return }
        task.waitUntilExit()
    }

    private func runBinSync(bin: String, args: [String]) -> String {
        let task = Process()
        task.launchPath = bin
        task.arguments = args
        task.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": toolTmpDir
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            dlog("runBinSync \(args.first ?? "") launch error: \(error)")
            return ""
        }
        let data    = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
            dlog("runBinSync \(args.first ?? "") stderr: \(errStr.prefix(300))")
        }
        dlog("runBinSync \(args.first ?? "") exitCode: \(task.terminationStatus)")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func removeQuarantine(_ path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/xattr"
        task.arguments = ["-d", "com.apple.quarantine", path]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try? task.run(); task.waitUntilExit()
        dlog("removeQuarantine \(path) exit=\(task.terminationStatus)")
    }

    /// 移除 Mach-O 程式碼簽名，讓 PyInstaller 解壓的 Python 不受 Library Validation 封鎖
    private func stripSignature(_ path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["--remove-signature", path]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try? task.run(); task.waitUntilExit()
        dlog("stripSignature \(path) exit=\(task.terminationStatus)")
    }

    /// 計算檔案的 SHA256 hex 字串
    private func sha256OfFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
