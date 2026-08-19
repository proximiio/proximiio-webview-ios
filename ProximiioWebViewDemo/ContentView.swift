import SwiftUI
import WebKit
import CoreMotion
import Proximiio

// MARK: - Configuration

/// Replace before running (see README).
private enum DemoConfiguration {
    static let proximiioToken = "INSERT_PROXIMIIO_APPLICATION_TOKEN"
    static let mapURL = URL(string: "INSERT_MAP_URL")!
}

// MARK: - WebView

struct WebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var proximiioManager: ProximiioManager

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)

        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear

        webView.load(URLRequest(url: url))

        proximiioManager.webView = webView

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Proximi.io SDK v6 bridge

/// Owns the Proximi.io SDK v6 instance, consumes its position / floor streams and
/// forwards them to the web map as `SET_LOCATION` `postMessage`s. Movement
/// detection (accelerometer) is app-side and unchanged from the 5.x demo.
@MainActor
final class ProximiioManager: NSObject, ObservableObject {
    @Published var currentPosition: PositionUpdate?
    @Published var level = 0 {
        didSet { sendLocationUpdate() }
    }
    @Published var authStatus: String = "Initializing..."
    @Published var isInMovement = false
    @Published var accelAvailable = false

    var webView: WKWebView?

    private var sdk: Proximiio?
    private var streamTasks: [Task<Void, Never>] = []

    private let motionManager = CMMotionManager()
    private var lastAccelerometerData: CMAcceleration?
    private var movementTimer: Timer?
    private let movementThreshold: Double = 0.1

    override init() {
        super.init()
        setupMotionDetection()
        Task { await startProximiio() }
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
        movementTimer?.invalidate()
        streamTasks.forEach { $0.cancel() }
        if let sdk {
            Task { await sdk.stop() }
        }
    }

    // MARK: SDK lifecycle (configure → permissions → authenticate → start → streams)

    func startProximiio() async {
        do {
            let configuration = ProximiioConfiguration(token: DemoConfiguration.proximiioToken)
            let sdk = try Proximiio(configuration: configuration)
            self.sdk = sdk

            authStatus = "Requesting permissions..."
            _ = await sdk.requestPermissions(always: false)
            // Motion & Fitness is what the pedestrian dead-reckoning (PDR)
            // subsystem needs; without it PDR stays silently inert.
            _ = await sdk.requestMotionPermission()

            authStatus = "Authenticating..."
            try await sdk.authenticate()
            try await sdk.start()

            // 5.x `ProximiioPDRProcessor` → 6.0 built-in PDR subsystem.
            await sdk.enablePdr()

            authStatus = "Positioning"

            streamTasks.append(Task { [weak self, sdk] in
                for await update in await sdk.positions() {
                    guard !Task.isCancelled else { return }
                    self?.handle(position: update)
                }
            })

            streamTasks.append(Task { [weak self, sdk] in
                for await change in await sdk.floorChanges() {
                    guard !Task.isCancelled else { return }
                    self?.handle(floorChange: change)
                }
            })
        } catch {
            authStatus = "Proximi.io error: \(error.localizedDescription)"
            print("Proximi.io SDK failed to start: \(error)")
        }
    }

    // MARK: Stream handlers (5.x `ProximiioDelegate` equivalents)

    /// 5.x `proximiioPositionUpdated(_:)`
    private func handle(position update: PositionUpdate) {
        currentPosition = update
        if let floorLevel = update.floor?.level {
            let newLevel = Int(floorLevel.rounded())
            if newLevel != level {
                level = newLevel   // `didSet` sends the update
                return
            }
        }
        sendLocationUpdate()
    }

    /// 5.x `proximiioFloorChanged(_:)`
    private func handle(floorChange event: FloorChangeEvent) {
        guard let floorLevel = event.floor?.level else { return }
        let newLevel = Int(floorLevel.rounded())
        if newLevel != level {
            level = newLevel
        }
    }

    // MARK: - Motion Detection Setup

    private func setupMotionDetection() {
        accelAvailable = motionManager.isAccelerometerAvailable

        guard accelAvailable else {
            print("Accelerometer not available")
            return
        }

        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: OperationQueue.main) { [weak self] data, _ in
            guard let self, let accelerometerData = data else { return }
            self.processAccelerometerData(accelerometerData.acceleration)
        }
    }

    private func processAccelerometerData(_ acceleration: CMAcceleration) {
        guard let lastData = lastAccelerometerData else {
            lastAccelerometerData = acceleration
            return
        }

        let deltaX = abs(acceleration.x - lastData.x)
        let deltaY = abs(acceleration.y - lastData.y)
        let deltaZ = abs(acceleration.z - lastData.z)

        let totalMovement = sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)

        if totalMovement > movementThreshold {
            if !isInMovement {
                isInMovement = true
                sendLocationUpdate()
            }

            movementTimer?.invalidate()
            movementTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.isInMovement = false
                    self?.sendLocationUpdate()
                }
            }
        }

        lastAccelerometerData = acceleration
    }

    // MARK: - PostMessage (contract with the web map is unchanged)

    private func sendLocationUpdate() {
        guard let webView, let position = currentPosition else { return }

        let payload: [String: Any] = [
            "type": "SET_LOCATION",
            "latitude": position.coordinate.latitude,
            "longitude": position.coordinate.longitude,
            "level": level,
            "accelAvailable": accelAvailable,
            "isInMovement": isInMovement,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8) else { return }

        let javascript = "window.postMessage(\(message), '*');"

        webView.evaluateJavaScript(javascript) { _, error in
            if let error {
                print("Error sending postMessage: \(error)")
            } else {
                print("PostMessage sent successfully: \(message)")
            }
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @StateObject var proximiioManager = ProximiioManager()

    var body: some View {
        GeometryReader { geometry in
            WebView(url: DemoConfiguration.mapURL, proximiioManager: proximiioManager)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .bottom) {
            // Tiny status line until the SDK is positioning (errors stay visible).
            if proximiioManager.authStatus != "Positioning" {
                Text(proximiioManager.authStatus)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
            }
        }
    }
}
