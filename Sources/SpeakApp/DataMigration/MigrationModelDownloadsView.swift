import SwiftUI

struct MigrationModelDownloadsView: View {
    @ObservedObject var controller: MigrationController
    @ObservedObject private var models = LocalModelManager.shared
    @ObservedObject private var fluidAudio = FluidAudioModelManager.shared
    @ObservedObject private var llms = LocalPostProcessingModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var downloading: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model downloads").font(.title2)
            Text("Model files were not included in the export. Download the ones you need on this Mac.")
                .foregroundStyle(.secondary)
            List(controller.modelReferences, id: \.id) { reference in
                HStack {
                    VStack(alignment: .leading) {
                        Text(reference.name)
                        Text(reference.source).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installed(reference) {
                        Text("Downloaded").foregroundStyle(.secondary)
                    } else if downloading.contains(reference.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(reference.family == "streaming" ? "Open model settings" : "Download") {
                            downloading.insert(reference.id)
                            Task {
                                await controller.downloadModel(reference)
                                downloading.remove(reference.id)
                            }
                        }
                    }
                }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 580, height: 400)
    }
    private func installed(_ reference: MigrationModelReference) -> Bool {
        switch reference.family {
        case "whisper": return models.isInstalled(reference.id)
        case "fluidAudio": return fluidAudio.installState.isInstalled
        #if !APP_STORE
            case "llm": return llms.isInstalled(reference.id)
        #endif
        default: return false
        }
    }
}
