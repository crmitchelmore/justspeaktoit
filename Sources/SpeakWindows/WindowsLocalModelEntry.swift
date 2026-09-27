import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

/// One row of the Local models dialog: a speech model for whisper.cpp or a
/// language model for llama.cpp, from the catalogue or a Hugging Face import.
enum WindowsLocalModelEntry: Sendable, Equatable {
    case speech(WhisperCppModel)
    case language(LlamaCppModel)

    var identifier: String {
        switch self {
        case .speech(let model): return model.catalogueID
        case .language(let model): return model.identifier
        }
    }

    var displayName: String {
        switch self {
        case .speech(let model): return model.displayName
        case .language(let model): return model.displayName
        }
    }

    var artifact: LocalModelFileArtifact {
        switch self {
        case .speech(let model): return model.artifact
        case .language(let model): return model.artifact
        }
    }

    var item: LocalModelInstaller.Item {
        LocalModelInstaller.Item(identifier: identifier, displayName: displayName, artifact: artifact)
    }

    var isImport: Bool { DesktopLocalModelImports.registered.model(for: identifier) != nil }
}

/// An action from the native Local models dialog, on the UI thread.
func localModelEvent(_ action: Int32, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    // Import fields are readable only during this callback, so copy them now.
    var fields = ("", "")
    if action == Int32(JSTI_LOCAL_MODEL_IMPORT.rawValue) {
        var repositoryBuffer = [CChar](repeating: 0, count: 256)
        var fileBuffer = [CChar](repeating: 0, count: 1_024)
        let read = jsti_local_models_import_fields(
            &repositoryBuffer, repositoryBuffer.count, &fileBuffer, fileBuffer.count
        )
        guard read == 0 else { return }
        fields = (String(cString: repositoryBuffer), String(cString: fileBuffer))
    }
    let (repository, file) = fields
    holder.enqueueSettings {
        await holder.controller.localModelAction(action, index: Int(index), repository: repository, file: file)
    }
}

struct WindowsLocalModelRow {
    let name: String
    let detail: String
    let about: String
    let state: Int32
}

/// Borrowed NUL-terminated copies of `strings`, valid only inside `body`.
func withCStrings<Result>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> Result) -> Result {
    let owned = strings.map { string -> UnsafeMutablePointer<CChar> in
        let chars = Array(string.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
        pointer.initialize(from: chars, count: chars.count)
        return pointer
    }
    defer { owned.forEach { $0.deallocate() } }
    return body(owned.map { UnsafePointer($0) })
}
