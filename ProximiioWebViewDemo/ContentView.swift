import SwiftUI
import WebKit
import Proximiio
import CoreMotion

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
        
        let request = URLRequest(url: url)
        webView.load(request)
        
        proximiioManager.webView = webView
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

class ProximiioManager: NSObject, ObservableObject, ProximiioDelegate {
    @Published var currentPosition: ProximiioLocation?
    @Published var level = 0 {
        didSet {
            sendLocationUpdate()
        }
    }
    @Published var authStatus: String = "Initializing..."
    @Published var isInMovement = false
    @Published var accelAvailable = false
    
    var instance: Proximiio?
    var webView: WKWebView?
    
    private let motionManager = CMMotionManager()
    private var lastAccelerometerData: CMAcceleration?
    private var movementTimer: Timer?
    private let movementThreshold: Double = 0.1
    
    override init() {
        super.init()
        setupProximiio()
        setupMotionDetection()
    }
    
    deinit {
        motionManager.stopAccelerometerUpdates()
        movementTimer?.invalidate()
    }
    
    func proximiioFloorChanged(_ floor: ProximiioFloor!) {
        DispatchQueue.main.async {
            self.level = floor.level.intValue
        }
    }
    
    func setupProximiio() {
        self.instance = Proximiio.sharedInstance()
        
        guard let instance = self.instance else {
            print("Proximiio instance not available")
            return
        }
        
        instance.delegate = self
        instance.requestPermissions(true)
        
        let token = "INSERT_PROXIMIIO_APPLICATION_TOKEN"
        
        instance.setBufferSize(kProximiioBufferExtraLarge)
        instance.auth(withToken: token) { state in
            instance.enable()
            instance.startUpdating()
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
        motionManager.startAccelerometerUpdates(to: OperationQueue.main) { [weak self] data, error in
            guard let self = self, let accelerometerData = data else { return }
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
                DispatchQueue.main.async {
                    self.isInMovement = true
                    self.sendLocationUpdate()
                }
            }
            
            movementTimer?.invalidate()
            movementTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isInMovement = false
                    self?.sendLocationUpdate()
                }
            }
        }
        
        lastAccelerometerData = acceleration
    }
    
    // MARK: - ProximiioDelegate
    func proximiioPositionUpdated(_ location: ProximiioLocation!) {
        DispatchQueue.main.async {
            self.currentPosition = location
            self.sendLocationUpdate()
        }
    }
    
    // MARK: - PostMessage
    private func sendLocationUpdate() {
        guard let webView = webView,
              let position = currentPosition else { return }
        
        let latitude = position.coordinate.latitude
        let longitude = position.coordinate.longitude
        
        let message = """
        {
            "type": "SET_LOCATION",
            "latitude": \(latitude),
            "longitude": \(longitude),
            "level": \(level),
            "accelAvailable": \(accelAvailable ? "true" : "false"),
            "isInMovement": \(isInMovement ? "true" : "false")
        }
        """
        
        let javascript = "window.postMessage(\(message), '*');"
        
        webView.evaluateJavaScript(javascript) { result, error in
            if let error = error {
                print("Error sending postMessage: \(error)")
            } else {
                print("PostMessage sent successfully: \(message)")
            }
        }
    }
}

struct ContentView: View {
    @StateObject var proximiioManager = ProximiioManager()
    
    var body: some View {
        GeometryReader { geometry in
            WebView(url: URL(string: "INSERT_MAP_URL")!, proximiioManager: proximiioManager)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .ignoresSafeArea(.all, edges: .all)
    }
}
