import XCTest
import LiveLocation
@testable import LiveLocationUI

/// The demo README quotes these numbers; if the scenario or the policy changes, this fails first.
@MainActor
final class ScenarioModelTests: XCTestCase {
    func testScenarioProducesTheNumbersTheDemoREADMEQuotes() async throws {
        let model = ScenarioModel(manifest: CapabilityManifest(capabilities: [.liveLocationSharing]),
                                  declaration: AgeRatingDeclaration(sharedLocation: true))
        await model.runIfNeeded()
        XCTAssertTrue(model.finished)
        let c = model.counters
        XCTAssertEqual(c.fixesSeen, ScenarioExpectations.fixes)
        XCTAssertEqual(c.uploaded, ScenarioExpectations.uploaded)
        XCTAssertEqual(c.heartbeats, ScenarioExpectations.heartbeats)
        XCTAssertEqual(c.suppressed[.inaccurate], 1)
        XCTAssertEqual(c.suppressed[.outOfOrder], 1)
        XCTAssertGreaterThan(c.suppressed[.budgetExhausted] ?? 0, 0, "the demo budget must visibly run dry")
        XCTAssertTrue(model.flushedAfterOutage)
        XCTAssertTrue(model.refusal.hasPrefix("refused"))

        guard model.viewers.count == 3 else { return XCTFail("expected three viewers") }
        let alice = model.viewers[0], bob = model.viewers[1], carol = model.viewers[2]
        guard case .live = alice.freshness else { return XCTFail("Alice: \(alice.freshness)") }
        guard case .behind = bob.freshness else { return XCTFail("Bob: \(bob.freshness)") }
        XCTAssertEqual(carol.freshness, .ended)
        XCTAssertEqual(alice.received, ScenarioExpectations.uploaded, "Alice decrypted every point")
        XCTAssertNotNil(bob.latitude)
        XCTAssertNotEqual(bob.longitude, alice.longitude, "Bob's pin is an earlier, en-route point")
        XCTAssertNil(carol.latitude, "a revoked viewer has no pin")
        XCTAssertEqual(model.copyBytes, ScenarioExpectations.copyBytes)
        XCTAssertEqual(bob.received, ScenarioExpectations.bobDecrypted)
        XCTAssertEqual(carol.received, ScenarioExpectations.carolDecrypted)
        XCTAssertEqual(model.budgetRemaining, ScenarioExpectations.budgetLeft)
    }
}

/// Single source for the figures quoted in the demo README and release notes.
enum ScenarioExpectations {
    static let fixes = 420
    static let uploaded = 37
    static let heartbeats = 6
    static let copyBytes = 365
    static let bobDecrypted = 5
    static let carolDecrypted = 29
    static let budgetLeft = 1
}
