import Foundation

/// The one History playback request, Play or Read aloud, that a desktop host
/// may still act on.
///
/// Starting playback can suspend, for example while the record's audio file
/// is resolved, and Read aloud reports its outcome only after its speech
/// ends. A request acts only while its ticket is current: a newer request
/// supersedes it, and anything that ends playback (Stop, another row,
/// recording, import, a hidden or deleted row, closing) ends it. An ended
/// request neither starts audio nor reports an outcome, so it can never
/// undo a Stop or overwrite the status of whatever ended it.
public struct DesktopPlaybackRequests: Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private var latest: UInt64 = 0

    public init() {}

    /// Supersedes every earlier request.
    public mutating func begin() -> Ticket {
        latest &+= 1
        return Ticket(value: latest)
    }

    /// Ends every request issued so far.
    public mutating func end() { latest &+= 1 }

    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.value == latest }
}
