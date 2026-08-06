import Foundation
import Combine

/// Minimal protocol surface for AppEnvironment so tests can inject doubles
/// without constructing the full 20-dependency graph. Production code
/// continues to use the concrete `AppEnvironment`; tests conform a lightweight
/// `TestEnvironment` to this protocol.
@MainActor
protocol AppEnvironmentProtocol: ObservableObject {
    var settings: AppSettings { get }
    var permissions: PermissionsManager { get }
    var history: HistoryManager { get }
    var hud: HUDManager { get }
    var main: MainManager { get }
    var transcription: TranscriptionManager { get }
    var postProcessing: PostProcessingManager { get }
    var secureStorage: SecureAppStorage { get }
    var apiKeysScrollTarget: String? { get set }
    var sidebarNavigationTarget: SidebarItem? { get set }
    func installStatusBarIfNeeded()
    func presentMainWindow()
}

// Concrete conformance — no extra implementation needed.
extension AppEnvironment: AppEnvironmentProtocol {}

// MARK: - Test helper (kept minimal to avoid MainActor init issues)

/// Lightweight test double. Create via `await MainActor.run { TestEnvironment(...) }`
/// so MainActor-isolated inits (AppSettings, HistoryManager, etc) are valid.
@MainActor
final class TestEnvironment: ObservableObject, AppEnvironmentProtocol {
    let settings: AppSettings
    let permissions: PermissionsManager
    let history: HistoryManager
    let hud: HUDManager
    let transcription: TranscriptionManager
    let postProcessing: PostProcessingManager
    let secureStorage: SecureAppStorage
    let main: MainManager
    @Published var apiKeysScrollTarget: String?
    @Published var sidebarNavigationTarget: SidebarItem?

    init(
        settings: AppSettings,
        permissions: PermissionsManager,
        history: HistoryManager,
        hud: HUDManager,
        transcription: TranscriptionManager,
        postProcessing: PostProcessingManager,
        secureStorage: SecureAppStorage,
        main: MainManager
    ) {
        self.settings = settings
        self.permissions = permissions
        self.history = history
        self.hud = hud
        self.transcription = transcription
        self.postProcessing = postProcessing
        self.secureStorage = secureStorage
        self.main = main
    }

    func installStatusBarIfNeeded() {}
    func presentMainWindow() {}
}
