import Foundation
import SpeakCore

extension DesktopHostController {
    package func cancelVoiceProviderCredentialWork(_ context: VoiceAccountCredentialContext?) {
        guard let context else { return }
        let destination = VoiceOutputCredentialDestination.explicitProvider(context)
        if voiceCredentialReadWorkerDestination == destination { voiceCredentialReadTask?.cancel() }
        if voiceCredentialReadDestination == destination {
            voiceCredentialReadID = nil
            voiceCredentialReadDestination = nil
        }
        if voiceCredentialWriteDestination == destination { voiceCredentialTask?.cancel() }
    }

    /// Unsupported hosts retain transfer values; only hosts with the sole desktop Voice model reconcile work.
    package func reconcileSonioxRegionChange(_ previousValue: Platform.VoiceOutputSettings?) {
        guard let current = settings.voiceOutput as? DesktopVoiceOutputSettings else { return }
        let previous = previousValue as? DesktopVoiceOutputSettings ?? .init()
        guard SonioxTTSRegion.recognized(from: previous.sonioxRegion)
            != SonioxTTSRegion.recognized(from: current.sonioxRegion) else { return }
        voiceCredentialEpoch = UUID()
        voiceDiscovery.inventories[.soniox] = nil
        if let ticket = voiceDiscovery.sonioxOutputTicket, playbackRequests.isCurrent(ticket) {
            stopReadAloud()
            voiceDiscovery.sonioxOutputTicket = nil
        }
        if let context = voiceDiscovery.context, context.provider == .soniox {
            cancelVoiceProviderCredentialWork(context)
            voiceDiscovery.task?.cancel()
            voiceDiscovery.retiredEpochs.insert(context.epoch)
            voiceDiscovery.context = nil
            voiceDiscovery.listing = nil
            voiceDiscovery.listingContext = nil
            voiceDiscovery.offeredIDs = []
            voiceProviderIssuedSlot = nil
        }
    }
}
