import Foundation
import CoreLocation
import CoreGraphics
import Combine

// MARK: - CLLocationManager 代理（獨立 NSObject 子類，避免 AppState 繼承 NSObject）
private class RealGPSDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocationCoordinate2D) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        manager.stopUpdatingLocation()
        let cb = onLocation
        onLocation = nil
        DispatchQueue.main.async { cb?(loc.coordinate) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorized {
            manager.startUpdatingLocation()
        }
    }
}

// 移動速度模式
enum SpeedMode: String, CaseIterable {
    case walk = "步行"
    case jog = "慢跑"
    case bike = "腳踏車"
    case car = "汽車"

    // 單位：m/s
    var speed: Double {
        switch self {
        case .walk: return 1.4
        case .jog: return 3.0
        case .bike: return 6.0
        case .car: return 14.0
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .jog:
            if #available(macOS 13.0, *) { return "figure.run" }
            return "hare"
        case .bike: return "bicycle"
        case .car: return "car.fill"
        }
    }
}

class AppState: ObservableObject {
    // 當前偽造的位置
    @Published var currentCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(
        latitude: 25.0478,
        longitude: 121.5318  // 預設：台北 101
    )

    // 速度設定
    @Published var speedMode: SpeedMode = .walk
    @Published var speedMultiplier: Double = 1.0  // 0.5x ~ 2.0x

    // 移動狀態
    @Published var isMoving: Bool = false
    @Published var joystickVector: CGPoint = .zero  // -1.0 到 1.0

    // 冷卻計時器
    @Published var cooldownEnabled: Bool = false
    @Published var cooldownSeconds: Int = 0
    @Published var isCoolingDown: Bool = false

    // 自動走路狀態
    @Published var isAutoWalking: Bool = false

    // 每次更新的時間間隔（秒）
    let updateInterval: Double = 0.1

    private var movementTimer: Timer?
    private var cooldownTimer: Timer?
    private var deviceManager: DeviceManager
    private var cancellables = Set<AnyCancellable>()

    private let locationManager = CLLocationManager()
    private let gpsDelegate = RealGPSDelegate()

    init(deviceManager: DeviceManager) {
        self.deviceManager = deviceManager

        // 取得 Mac 真實位置作為初始地圖中心
        locationManager.delegate = gpsDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        gpsDelegate.onLocation = { [weak self] coord in
            self?.currentCoordinate = coord
        }
        locationManager.requestWhenInUseAuthorization()
        // 若已授權則直接啟動，否則 delegate 的 didChangeAuthorization 會觸發
        let status = locationManager.authorizationStatus
        if status == .authorizedAlways || status == .authorized {
            locationManager.startUpdatingLocation()
        }

        // tunneld 就緒時（狀態轉換），自動將裝置 GPS 對準地圖當前位置
        deviceManager.$tunneldStatus
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self = self, status.isRunning else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, self.deviceManager.tunneldStatus.isRunning else { return }
                    self.deviceManager.forceSetLocation(
                        latitude: self.currentCoordinate.latitude,
                        longitude: self.currentCoordinate.longitude
                    )
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 瞬間傳送

    func teleport(to coordinate: CLLocationCoordinate2D) {
        let distance = distanceInMeters(from: currentCoordinate, to: coordinate)
        currentCoordinate = coordinate
        deviceManager.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if cooldownEnabled {
            startCooldown(for: distance)
        }
    }

    // MARK: - 冷卻計時器（1km ≈ 1 分鐘，最長 2 小時）

    private func startCooldown(for distanceMeters: Double) {
        cooldownTimer?.invalidate()
        let km = distanceMeters / 1000.0
        // 簡化計算：1km = 1分鐘，最長 120 分鐘
        let minutes = min(km, 120.0)
        cooldownSeconds = Int(minutes * 60)

        guard cooldownSeconds > 0 else { return }
        isCoolingDown = true

        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.cooldownSeconds > 0 {
                self.cooldownSeconds -= 1
            } else {
                self.isCoolingDown = false
                timer.invalidate()
            }
        }
    }

    func skipCooldown() {
        cooldownTimer?.invalidate()
        cooldownSeconds = 0
        isCoolingDown = false
    }

    // MARK: - 搖桿移動

    func startJoystickMovement() {
        stopMovement()
        isMoving = true
        // 強制注入當前地圖座標（不受速率限制），確保裝置 GPS 從地圖位置出發
        deviceManager.forceSetLocation(latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude)
        movementTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.applyJoystickMovement()
        }
    }

    func stopMovement() {
        movementTimer?.invalidate()
        movementTimer = nil
        isMoving = false
        joystickVector = .zero
    }

    private func applyJoystickMovement() {
        guard joystickVector.x != 0 || joystickVector.y != 0 else { return }

        let speed = speedMode.speed * speedMultiplier
        let distancePerTick = speed * updateInterval  // 公尺

        // 將搖桿向量轉成移動方向
        let dx = Double(joystickVector.x)  // 東西方向
        let dy = Double(joystickVector.y)  // 南北方向（注意：螢幕 Y 向下 = 南）

        let newCoord = moveCoordinate(
            from: currentCoordinate,
            distanceMeters: distancePerTick,
            bearingDx: dx,
            bearingDy: dy
        )

        currentCoordinate = newCoord
        deviceManager.setLocation(latitude: newCoord.latitude, longitude: newCoord.longitude)
    }

    // MARK: - 自動走路（直線）

    func startAutoWalk(to destination: CLLocationCoordinate2D) {
        stopAutoWalk()
        isAutoWalking = true
        // 強制注入當前地圖座標，確保裝置 GPS 從地圖位置出發
        deviceManager.forceSetLocation(latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude)

        movementTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let remaining = self.distanceInMeters(from: self.currentCoordinate, to: destination)
            if remaining < 1.0 {
                self.currentCoordinate = destination
                self.deviceManager.setLocation(latitude: destination.latitude, longitude: destination.longitude)
                self.stopAutoWalk()
                return
            }
            let speed = self.speedMode.speed * self.speedMultiplier
            let step = min(speed * self.updateInterval, remaining)
            let bearing = self.bearingAngle(from: self.currentCoordinate, to: destination)
            let dx = sin(bearing)
            let dy = cos(bearing)
            let next = self.moveCoordinate(
                from: self.currentCoordinate,
                distanceMeters: step,
                bearingDx: dx,
                bearingDy: dy
            )
            self.currentCoordinate = next
            self.deviceManager.setLocation(latitude: next.latitude, longitude: next.longitude)
        }
    }

    func stopAutoWalk() {
        movementTimer?.invalidate()
        movementTimer = nil
        isAutoWalking = false
    }

    // MARK: - 位置重置

    func resetLocation() {
        stopMovement()
        stopAutoWalk()
        deviceManager.resetLocation()
        // 重置後，將地圖更新到 Mac 真實位置
        fetchRealLocation()
    }

    private func fetchRealLocation() {
        gpsDelegate.onLocation = { [weak self] coord in
            self?.currentCoordinate = coord
        }
        locationManager.startUpdatingLocation()
    }

    // MARK: - 座標數學工具

    private func moveCoordinate(
        from coord: CLLocationCoordinate2D,
        distanceMeters: Double,
        bearingDx: Double,
        bearingDy: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0  // 公尺
        let lat = coord.latitude * .pi / 180

        // 平面近似計算（短距離足夠準確）
        let deltaLat = (distanceMeters * bearingDy) / earthRadius
        let deltaLon = (distanceMeters * bearingDx) / (earthRadius * cos(lat))

        return CLLocationCoordinate2D(
            latitude: coord.latitude + deltaLat * 180 / .pi,
            longitude: coord.longitude + deltaLon * 180 / .pi
        )
    }

    private func distanceInMeters(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let loc1 = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let loc2 = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return loc1.distance(from: loc2)
    }

    private func bearingAngle(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x)
    }

    // MARK: - 格式化顯示

    var formattedCoordinate: String {
        String(format: "%.6f, %.6f", currentCoordinate.latitude, currentCoordinate.longitude)
    }

    func distanceToFormatted(_ destination: CLLocationCoordinate2D) -> String {
        let meters = distanceInMeters(from: currentCoordinate, to: destination)
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
        }
    }

    var formattedCooldown: String {
        let m = cooldownSeconds / 60
        let s = cooldownSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
