import Foundation

/// What a viewer's UI should say about a pin. The relay's presence and the viewer's own connectivity
/// are separate inputs: "the sharer went quiet" and "*I* am offline" must never render the same way.
public enum Freshness: Hashable, Sendable {
    case waiting                     // share started, nothing received yet
    case live(age: Millis)           // within 1.5 heartbeats
    case delayed(age: Millis)        // late, but presence TTL not yet exceeded
    case stale(age: Millis)          // past the presence TTL: show "last seen", not a live dot
    case offline(lastKnownAge: Millis?)  // the viewer has no network; the pin is whatever we last had
    case ended                       // expired, stopped or revoked: remove the pin

    public var label: String {
        switch self {
        case .waiting: return "Waiting for first update"
        case .live: return "Live"
        case .delayed(let a): return "Delayed · \(Int(a.seconds))s"
        case .stale(let a): return "Last seen \(Freshness.human(a)) ago"
        case .offline(let a): return a.map { "You're offline · last known \(Freshness.human($0)) ago" } ?? "You're offline"
        case .ended: return "Sharing ended"
        }
    }

    static func human(_ d: Millis) -> String {
        let s = d.value / 1_000
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        return "\(s / 3_600)h"
    }

    /// - Parameters:
    ///   - lastSentAt: `sentAt` of the newest decrypted copy (heartbeats refresh it; position may be older).
    ///   - heartbeat: the sharer's heartbeat interval (presence TTL / 2 under `PublishPolicy`).
    public static func classify(lastSentAt: Instant?, now: Instant, heartbeat: Millis, presenceTTL: Millis,
                                isViewerOffline: Bool, hasEnded: Bool) -> Freshness {
        if hasEnded { return .ended }
        let age = lastSentAt.map { now.elapsed(since: $0) }
        if isViewerOffline { return .offline(lastKnownAge: age) }
        guard let age else { return .waiting }
        let liveWindow = Millis(Saturating.add(heartbeat.value, heartbeat.value / 2))
        if age <= liveWindow { return .live(age: age) }
        if age <= presenceTTL { return .delayed(age: age) }
        return .stale(age: age)
    }
}
