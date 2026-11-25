import Foundation

/// Capabilities the app's code can exercise. The manifest is a checked-in JSON file; the runtime reads it
/// (`SharerSession` refuses to start without `.liveLocationSharing`) and CI reads it (`AgeRatingGate`),
/// so the code path and the App Store Connect answer come from one source and cannot drift silently.
public enum AppCapability: String, Codable, Hashable, Sendable, CaseIterable {
    /// Real-time location shared with another person or group — what Apple's "Shared Location" age-rating
    /// descriptor (App Store Connect, 16 Nov 2026) asks about.
    case liveLocationSharing
    /// Location used only on-device or sent to the developer (maps, weather). Does **not** trigger the
    /// descriptor on its own.
    case locationForAppFeatures
}

public struct CapabilityManifest: Codable, Hashable, Sendable {
    public let capabilities: Set<AppCapability>
    public init(capabilities: Set<AppCapability>) { self.capabilities = capabilities }

    public static func decode(_ data: Data) throws -> CapabilityManifest {
        try JSONDecoder().decode(CapabilityManifest.self, from: data)
    }
}

/// The subset of the App Store Connect age-rating questionnaire this gate checks, as exported to the repo.
public struct AgeRatingDeclaration: Codable, Hashable, Sendable {
    public let sharedLocation: Bool
    public init(sharedLocation: Bool) { self.sharedLocation = sharedLocation }

    public static func decode(_ data: Data) throws -> AgeRatingDeclaration {
        try JSONDecoder().decode(AgeRatingDeclaration.self, from: data)
    }
}

public enum AgeRatingDrift: Hashable, Sendable {
    /// Code can share location with people, but the declaration says it cannot. Blocks the build.
    case undeclaredSharedLocation
    /// Declared, but no capability uses it. Not wrong, but it raises the rating for nothing. Warns.
    case overDeclaredSharedLocation

    public var isBlocking: Bool { self == .undeclaredSharedLocation }

    public var message: String {
        switch self {
        case .undeclaredSharedLocation:
            return "Manifest declares liveLocationSharing but the age-rating declaration answers Shared Location = NO."
        case .overDeclaredSharedLocation:
            return "Age-rating declaration answers Shared Location = YES but no capability shares location with people."
        }
    }
}

public enum AgeRatingGate {
    /// The declaration the manifest implies.
    public static func required(for manifest: CapabilityManifest) -> AgeRatingDeclaration {
        AgeRatingDeclaration(sharedLocation: manifest.capabilities.contains(.liveLocationSharing))
    }

    public static func check(manifest: CapabilityManifest, declaration: AgeRatingDeclaration) -> [AgeRatingDrift] {
        let needed = required(for: manifest).sharedLocation
        switch (needed, declaration.sharedLocation) {
        case (true, false): return [.undeclaredSharedLocation]
        case (false, true): return [.overDeclaredSharedLocation]
        default: return []
        }
    }
}
