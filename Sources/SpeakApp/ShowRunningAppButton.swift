import AppKit
import SwiftUI

struct ShowRunningAppButton: View {
    @State private var isOpening = false
    @State private var didFail = false
    @State private var isDelayed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(isOpening ? "Opening Finder…" : "Show App") {
                isOpening = true
                didFail = false
                isDelayed = false
                Task {
                    let revealed = await RunningAppIdentity.current.revealInFinder()
                    didFail = !revealed
                    isOpening = false
                }
            }
            .disabled(isOpening)
            if didFail || isDelayed {
                Text("Use Finder → Go → Go to Folder to locate the app by its path.")
                    .font(.caption)
                Button("Copy App Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(RunningAppIdentity.current.bundleURL.path, forType: .string)
                }
            }
        }
        .task(id: isOpening) {
            guard isOpening else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            isDelayed = isOpening
        }
    }
}
