import Foundation
import SpeakCore

struct MigrationModelReference: Codable {
    let id: String
    let name: String
    let source: String
    var destination: String
    let family: String
}

@MainActor
extension MigrationStore {
    func addInstalledModelReferences(to snapshot: inout MigrationSnapshot) throws {
        var references: [MigrationModelReference] = []
        let destination = support.appendingPathComponent("LocalModels").path
        let local = LocalModelManager.shared
        for model in local.availableModels where local.isInstalled(model.id) {
            references.append(.init(id: model.id, name: model.displayName,
                                    source: model.modelRepo ?? "argmaxinc/whisperkit-coreml",
                                    destination: destination,
                                    family: "whisper"))
        }
        if FluidAudioModelManager.shared.installState.isInstalled {
            references.append(.init(id: FluidAudioParakeetModel.id, name: "FluidAudio Parakeet",
                                    source: "FluidAudio managed catalogue", destination: destination,
                                    family: "fluidAudio"))
        }
        #if !APP_STORE
            let llms = LocalPostProcessingModelManager.shared
            for model in llms.availableModels where llms.isInstalled(model.id) {
                references.append(.init(id: model.id, name: model.displayName,
                                        source: model.repoID, destination: destination, family: "llm"))
            }
        #endif
        for reference in references {
            let record = MigrationRecord(
                id: reference.id,
                kind: "modelReference",
                value: try MigrationCoding.value(reference)
            )
            if let index = snapshot.records[.models]?.firstIndex(where: { $0.identity == record.identity }) {
                snapshot.records[.models]?[index] = record
            } else {
                snapshot.records[.models, default: []].append(record)
            }
        }
    }
}

@MainActor
extension MigrationController {
    func references(in snapshot: MigrationSnapshot) -> [MigrationModelReference] {
        var references: [String: MigrationModelReference] = [:]
        let destination = store.support.appendingPathComponent("LocalModels").path
        for record in snapshot.records[.models] ?? [] {
            if let reference = try? MigrationCoding.decode(MigrationModelReference.self, record.value) {
                references[reference.id] = reference
            } else if record.kind == "whisperModel",
                      let model = try? MigrationCoding.decode(ImportedModelRecord.self, record.value) {
                references[model.id] = .init(
                    id: model.id,
                    name: model.displayName,
                    source: model.modelRepo ?? "",
                    destination: destination,
                    family: "whisper"
                )
            }
            #if !APP_STORE
                if record.kind == "llmModel",
                   let model = try? MigrationCoding.decode(LocalPostProcessingModel.self, record.value) {
                    references[model.id] = .init(id: model.id, name: model.displayName, source: model.repoID,
                                                 destination: destination, family: "llm")
                } else if record.kind == "streamingModel",
                          let model = try? MigrationCoding.decode(
                              LocalStreamingModelSource.self,
                              record.value
                          ) {
                    references[model.id] = .init(id: model.id, name: model.displayName, source: model.repoID,
                                                 destination: destination, family: "streaming")
                }
            #endif
        }
        return references.values.sorted { $0.name < $1.name }
    }
    func downloadModel(_ reference: MigrationModelReference) async {
        switch reference.family {
        case "whisper":
            if let model = LocalModelManager.shared
                .model(for: reference.id) {
                await LocalModelManager.shared.install(model)
            }
        case "fluidAudio": await FluidAudioModelManager.shared.install()
        #if !APP_STORE
            case "llm":
                if let model = LocalPostProcessingModelManager.shared.model(for: reference.id) {
                    await LocalPostProcessingModelManager.shared.installModel(model)
                }
        #endif
        default: environment.sidebarNavigationTarget = .settings(.transcription)
        }
    }
}

@MainActor
extension MigrationController {
    var unresolvedModelDestinations: [MigrationRecord] {
        guard modes[.models] != .skip else {
            return []
        }
        return incoming?.records[.models]?.filter { record in
            guard record.kind == "modelReference",
                  let reference = try? MigrationCoding.decode(MigrationModelReference.self, record.value)
            else {
                return false
            }
            return !FileManager.default.fileExists(atPath: reference.destination)
        } ?? []
    }
    func resolveModelDestinations() {
        let destination = store.support.appendingPathComponent("LocalModels")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for record in unresolvedModelDestinations {
                var reference = try MigrationCoding.decode(MigrationModelReference.self, record.value)
                reference.destination = destination.path
                if let index = incoming?.records[.models]?
                    .firstIndex(where: { $0.identity == record.identity }) {
                    incoming?.records[.models]?[index].value = try MigrationCoding.value(reference)
                }
            }
        } catch { status = "Could not use this Mac’s model folder: \(error.localizedDescription)" }
    }
}
