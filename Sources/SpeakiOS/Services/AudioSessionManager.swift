#if os(iOS)
import AVFoundation
import Foundation

/// Manages iOS audio session configuration for recording and transcription.
@MainActor
public final class AudioSessionManager: ObservableObject {
    @Published private(set) public var isConfigured = false
    @Published private(set) public var currentRoute: String = "Unknown"
    @Published private(set) public var lastError: Error?
    
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    
    public var onInterruption: ((Bool) -> Void)?
    public var onRouteChange: (() -> Void)?
    
    public init() {
        setupNotificationObservers()
    }
    
    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Configure audio session for recording with speech recognition.
    public func configureForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        
        do {
            // Category: playAndRecord allows simultaneous input/output
            // Mode: measurement for high-quality audio capture
            // Options: allowBluetooth for headsets, defaultToSpeaker for better UX
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            
            // Activate the session
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            isConfigured = true
            updateCurrentRoute()
            
            print("[AudioSessionManager] Configured for recording: \(session.currentRoute.inputs.first?.portName ?? "unknown")")
        } catch {
            lastError = error
            isConfigured = false
            throw error
        }
    }
    
    /// Deactivate audio session when done recording.
    public func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isConfigured = false
            print("[AudioSessionManager] Deactivated")
        } catch {
            print("[AudioSessionManager] Failed to deactivate: \(error.localizedDescription)")
        }
    }
    
    /// Check if microphone permission is granted.
    public func hasMicrophonePermission() -> Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }
    
    /// Request microphone permission.
    public func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // MARK: - Private
    
    private func setupNotificationObservers() {
        // Interruption observer (phone calls, Siri, etc.)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        
        // Route change observer (headphones plugged/unplugged, Bluetooth changes)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }
    
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        
        switch type {
        case .began:
            print("[AudioSessionManager] Interruption began")
            onInterruption?(true)
            
        case .ended:
            print("[AudioSessionManager] Interruption ended")
            // Check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[AudioSessionManager] Should resume after interruption")
                }
            }
            onInterruption?(false)
            
        @unknown default:
            break
        }
    }
    
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        
        print("[AudioSessionManager] Route changed: \(reason)")
        updateCurrentRoute()
        onRouteChange?()
    }
    
    private func updateCurrentRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let input = route.inputs.first {
            currentRoute = input.portName
        } else {
            currentRoute = "No input"
        }
    }
}
#endif
