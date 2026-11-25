#if canImport(CoreLocation)
import CoreLocation

extension LocationFix {
    /// Bridges a `CLLocation`. Returns nil for an invalid fix (CoreLocation reports a negative
    /// `horizontalAccuracy` when the coordinate is unusable).
    public init?(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  accuracyMeters: location.horizontalAccuracy,
                  timestamp: Instant(millis: Saturating.int64(location.timestamp.timeIntervalSince1970 * 1_000)))
    }
}

/// Thin adapter from `CLLocationUpdate.liveUpdates` to `LocationFix`. It only bridges; every decision
/// about *whether to publish* is made by `PublishGate`.
///
/// Honest scope: this adapter compiles in CI but is not exercised by the tests or by the demo (the
/// Simulator demo drives a scripted route). Requesting authorization, background modes and the
/// significant-change fallback are the app's job and are not implemented here.
@available(iOS 17.0, macOS 14.0, *)
public enum LiveUpdatesSource {
    public static func configuration(for motion: MotionState) -> CLLocationUpdate.LiveConfiguration {
        switch motion {
        case .driving: return .automotiveNavigation
        case .walking, .cycling: return .fitness
        case .stationary, .unknown: return .default
        }
    }

    /// Takes the (Sendable) motion state rather than a `LiveConfiguration`, which is not Sendable and so
    /// cannot cross into the iterating task.
    public static func fixes(for motion: MotionState = .unknown) -> AsyncStream<LocationFix> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(configuration(for: motion)) {
                        if let location = update.location, let fix = LocationFix(location) { continuation.yield(fix) }
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
