import XCTest
@testable import PairDesk

final class RemoteControlTests: XCTestCase {
    func testOnlyGrantedIdentityWithCurrentEpochAndIncreasingSequenceIsAccepted() {
        var gate = RemoteControlGate()
        let now: TimeInterval = 1_000
        gate.grant(identity: "viewer-a", epoch: "epoch-1", now: now)

        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-b", now: now))
        XCTAssertFalse(gate.accept(message(epoch: "old-epoch", seq: 1), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a", now: now))
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 2), sender: "viewer-a", now: now))
    }

    func testHeartbeatRenewsLeaseButCannotExtendBeyondTwoSeconds() {
        var gate = RemoteControlGate()
        let now: TimeInterval = 1_000
        gate.grant(identity: "viewer-a", epoch: "epoch-1", now: now)
        var heartbeat = message(epoch: "epoch-1", seq: 1, kind: .heartbeat)
        heartbeat.leaseMilliseconds = 60_000

        XCTAssertTrue(gate.accept(heartbeat, sender: "viewer-a", now: now + 1))
        XCTAssertEqual(gate.expiresAtUptime, 1_003)
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 2), sender: "viewer-a", now: now + 3))
    }

    func testRevokeMakesQueuedMessagesInert() {
        var gate = RemoteControlGate()
        gate.grant(identity: "viewer-a", epoch: "epoch-1")
        gate.revoke()
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a"))
        XCTAssertNil(gate.driverIdentity)
    }

    func testArbiterGrantsOneDriverAndQueuesTheNextInArrivalOrder() {
        var arbiter = RemoteControlArbiter()
        arbiter.enable()

        XCTAssertEqual(arbiter.request(identity: "viewer-a"), .grant)
        XCTAssertEqual(arbiter.request(identity: "viewer-b"), .queued)
        XCTAssertEqual(arbiter.request(identity: "viewer-a"), .ignored)
        XCTAssertEqual(arbiter.driverIdentity, "viewer-a")

        XCTAssertEqual(arbiter.release(identity: "viewer-a"), "viewer-b")
        XCTAssertEqual(arbiter.driverIdentity, "viewer-b")
        XCTAssertNil(arbiter.release(identity: "viewer-b"))
        XCTAssertNil(arbiter.driverIdentity)
    }

    func testPausingAutomaticControlDropsDriverAndWaitingRequests() {
        var arbiter = RemoteControlArbiter()
        arbiter.enable()
        XCTAssertEqual(arbiter.request(identity: "viewer-a"), .grant)
        XCTAssertEqual(arbiter.request(identity: "viewer-b"), .queued)

        arbiter.disable()

        XCTAssertFalse(arbiter.isEnabled)
        XCTAssertNil(arbiter.driverIdentity)
        XCTAssertTrue(arbiter.waiting.isEmpty)
        XCTAssertEqual(arbiter.request(identity: "viewer-c"), .ignored)
    }

    func testIdleLeaseDoesNotExpireWhileAKeyOrButtonIsHeld() {
        XCTAssertFalse(RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: 1, heldButtonCount: 0))
        XCTAssertFalse(RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: 0, heldButtonCount: 1))
        XCTAssertTrue(RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: 0, heldButtonCount: 0))
    }

    func testNormalizedPointerUsesSelectedDisplayOrigin() {
        let displayBounds = CGRect(x: -1_440, y: 120, width: 1_440, height: 900)
        XCTAssertEqual(RemoteInputInjector.point(x: 0.5, y: 0.25, in: displayBounds), CGPoint(x: -720, y: 345))
        XCTAssertEqual(RemoteInputInjector.point(x: 1, y: 1, in: displayBounds), CGPoint(x: 0, y: 1_020))
    }

    func testNormalizedPointerRejectsInvalidCoordinatesAndEmptyDisplays() {
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertNil(RemoteInputInjector.point(x: .nan, y: 0.5, in: bounds))
        XCTAssertNil(RemoteInputInjector.point(x: 1.01, y: 0.5, in: bounds))
        XCTAssertNil(RemoteInputInjector.point(x: 0.5, y: 0.5, in: .zero))
    }

    func testAvailabilityMessageRoundTripsAndUnknownKindsAreIgnored() throws {
        let sent = RemoteControlMessage(epoch: "", sequence: 7, kind: .availability, available: false,
                                        reason: RemoteControlUnavailableReason.accessibility.rawValue)
        let received = try JSONDecoder().decode(RemoteControlMessage.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(received, sent)
        XCTAssertEqual(received.reason.flatMap(RemoteControlUnavailableReason.init(rawValue:)), .accessibility)
        // Older builds drop kinds they don't know instead of failing the call.
        let future = Data(#"{"version":1,"epoch":"","sequence":1,"kind":"something-newer"}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(RemoteControlMessage.self, from: future))
    }

    func testAvailabilityReportsTheFirstBlockingCondition() {
        let window = RemoteControlAvailability.evaluate(sharingWindow: true, accessibilityTrusted: true, automaticControlEnabled: true)
        XCTAssertFalse(window.available); XCTAssertEqual(window.reason, .windowShare)
        let untrusted = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: false, automaticControlEnabled: true)
        XCTAssertFalse(untrusted.available); XCTAssertEqual(untrusted.reason, .accessibility)
        let paused = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true, automaticControlEnabled: false)
        XCTAssertFalse(paused.available); XCTAssertEqual(paused.reason, .paused)
        let ready = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true, automaticControlEnabled: true)
        XCTAssertTrue(ready.available); XCTAssertNil(ready.reason)
    }

    private func message(epoch: String, seq: UInt64, kind: RemoteControlMessage.Kind = .pointer) -> RemoteControlMessage {
        RemoteControlMessage(epoch: epoch, sequence: seq, kind: kind, x: 0.5, y: 0.5)
    }
}
