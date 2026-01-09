#if os(iOS)
import SwiftUI

@main
struct SpeakiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
#else
// Stub for non-iOS builds - this target is iOS-only
@main
struct SpeakiOSStub {
    static func main() {
        print("SpeakiOS is only available on iOS")
    }
}
#endif
