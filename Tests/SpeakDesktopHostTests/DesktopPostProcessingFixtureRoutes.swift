import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

extension DesktopPostProcessing {
    /// Native routes are listed first, but these fixtures store the OpenRouter
    /// key, so they select the first OpenRouter cleanup route explicitly.
    static var firstOpenRouterIndex: Int {
        remoteModels.firstIndex { ModelPickerGrouping.isOpenRouter($0.id, purpose: .postProcessing) } ?? 0
    }

    static var openRouterRemoteModels: [ModelCatalog.Option] {
        remoteModels.filter { ModelPickerGrouping.isOpenRouter($0.id, purpose: .postProcessing) }
    }
}

extension DesktopHostController {
    /// `savePostProcessing(modelIndex:)` for the first OpenRouter route.
    func saveOpenRouterPostProcessing(enabled: Bool, prompt: String, key: String) async {
        await savePostProcessing(
            enabled: enabled, modelIndex: DesktopPostProcessing.firstOpenRouterIndex, prompt: prompt, key: key
        )
    }
}
