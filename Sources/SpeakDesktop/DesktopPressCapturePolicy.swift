import Foundation

package enum DesktopPressCaptureCapability: Equatable, Sendable {
    case qualified
    case unavailable(String)
}

package enum DesktopPressCapturePermission: Equatable, Sendable {
    case granted
    case unavailable(String)
}

package enum DesktopPressCaptureOwner: Equatable, Sendable {
    case idle, manual, handsFree, comparison, startup, shutdown
}

package enum DesktopPressCaptureRefusal: Equatable, Sendable {
    case disabled
    case capabilityUnavailable(String)
    case permissionUnavailable(String)
    case occupied(DesktopPressCaptureOwner)
}

/// Capability and permission are supplied evidence, not inferred from a saved preference.
package struct DesktopPressCaptureAdmission: Equatable, Sendable {
    package let enabled: Bool
    package let capability: DesktopPressCaptureCapability
    package let permission: DesktopPressCapturePermission
    package let owner: DesktopPressCaptureOwner

    package init(
        enabled: Bool, capability: DesktopPressCaptureCapability,
        permission: DesktopPressCapturePermission, owner: DesktopPressCaptureOwner
    ) {
        self.enabled = enabled
        self.capability = capability
        self.permission = permission
        self.owner = owner
    }

    package var refusal: DesktopPressCaptureRefusal? {
        guard enabled else { return .disabled }
        if case .unavailable(let reason) = capability { return .capabilityUnavailable(reason) }
        if case .unavailable(let reason) = permission { return .permissionUnavailable(reason) }
        guard owner == .idle else { return .occupied(owner) }
        return nil
    }
}

package struct DesktopPressCaptureIdentity: Equatable, Sendable {
    package let deviceID: String
    package let routeID: String
    package let profileID: String
    package let sampleRate: Int
    package let frameMilliseconds: Int

    package init(deviceID: String, routeID: String, profileID: String, sampleRate: Int, frameMilliseconds: Int) {
        self.deviceID = deviceID
        self.routeID = routeID
        self.profileID = profileID
        self.sampleRate = sampleRate
        self.frameMilliseconds = frameMilliseconds
    }

    func validate() throws {
        guard !routeID.isEmpty, sampleRate > 0, frameMilliseconds > 0 else {
            throw DesktopPressCaptureError.invalidConfiguration
        }
    }
}

package struct DesktopPressCaptureBufferLimits: Sendable {
    let preRollBytes: Int
    let reservedBytes: Int

    package init(preRollFrames: Int, reservedFrames: Int) throws {
        guard preRollFrames > 0, reservedFrames >= preRollFrames, reservedFrames <= Int.max / 2 else {
            throw DesktopPressCaptureError.invalidConfiguration
        }
        self.preRollBytes = preRollFrames * 2
        self.reservedBytes = reservedFrames * 2
    }
}

package struct DesktopPressCaptureToken: Equatable, Sendable {
    let id = UUID()
}

package enum DesktopPressCapturePhase: Equatable, Sendable {
    case idle, pending, open, reserved, adopted, closing
}

package enum DesktopPressCaptureError: Error, Equatable, Sendable {
    case invalidConfiguration
    case refused(DesktopPressCaptureRefusal)
    case occupied
    case closed
    case staleLease
    case identityChanged
    case notReady
    case invalidPhase
    case invalidPCM
    case startupOverflow
    case captureFailed(String)
    case openFailed(String)
    case cleanupFailed(String)
}

/// An adapter owns its native handles; neither a handle nor a borrowed PCM pointer crosses actors.
/// Open failure may leave partial resources: close must acknowledge their cleanup, including late opens.
/// A future native adapter must use its own IO executor, never the UI/host actor or an audio callback.
package protocol DesktopPressCaptureWorker: Actor {
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity,
        receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws
    func close(id: UUID) async throws
}
