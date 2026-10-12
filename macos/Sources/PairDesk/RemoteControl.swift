import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A remote pointer marker expressed in normalized screen coordinates.
struct RemotePointer: Identifiable, Equatable {
    let id: String
    let x: Double
    let y: Double
    let updatedAt: Date
}

enum RemoteControlState: Equatable {
    case unavailable
    case viewer
    case requesting
    case hostPermissionRequired
    case host
    case granted(identity: String, expiresAt: Date)
}

extension RemoteControlState {
    var isGranted: Bool { if case .granted = self { return true }; return false }
}

/// Wire format for ephemeral control traffic. `identity` is deliberately not
/// encoded: the receiver must use LiveKit's authenticated participant identity.
struct RemoteControlMessage: Codable, Equatable {
    /// Clients ignore messages whose kind they cannot decode, so adding a kind
    /// stays compatible with older builds.
    enum Kind: String, Codable { case request, grant, revoke, hostPermissionRequired, release, heartbeat, pointer, key, button, scroll, releaseAll, availability }
    var version: Int = 1
    var epoch: String
    var sequence: UInt64
    var kind: Kind
    var leaseMilliseconds: UInt32?
    var x: Double?
    var y: Double?
    var code: UInt16?
    var down: Bool?
    var modifiers: UInt64?
    var deltaX: Double?
    var deltaY: Double?
    /// `.availability` only: whether the sharer would accept input now, and why not.
    var available: Bool?
    var reason: String?
}

enum RemoteControlUnavailableReason: String, Codable, Equatable {
    case accessibility
    case paused
    case windowShare

    func viewerDescription(host: String) -> String {
        switch self {
        case .accessibility: "\(host) needs to allow PairDesk in Accessibility before you can control"
        case .paused: "\(host) paused remote control"
        case .windowShare: "window sharing is view only"
        }
    }
}

/// What the sharing Mac tells viewers. Viewers otherwise can only guess from
/// the track name, and would show "control available" for a Mac that cannot
/// accept input.
enum RemoteControlAvailability {
    static func evaluate(sharingWindow: Bool, accessibilityTrusted: Bool, automaticControlEnabled: Bool) -> (available: Bool, reason: RemoteControlUnavailableReason?) {
        if sharingWindow { return (false, .windowShare) }
        if !accessibilityTrusted { return (false, .accessibility) }
        if !automaticControlEnabled { return (false, .paused) }
        return (true, nil)
    }
}

/// First eligible requester owns the current lease; later requesters wait in
/// arrival order. The host enables this only after the user starts sharing.
struct RemoteControlArbiter {
    enum RequestResult: Equatable { case grant, queued, ignored }

    private(set) var isEnabled = false
    private(set) var driverIdentity: String?
    private(set) var waiting: [String] = []

    mutating func enable() { isEnabled = true }

    mutating func disable() {
        isEnabled = false
        driverIdentity = nil
        waiting.removeAll()
    }

    mutating func request(identity: String) -> RequestResult {
        guard isEnabled, !identity.isEmpty, identity != driverIdentity,
              !waiting.contains(identity) else { return .ignored }
        guard driverIdentity == nil else {
            waiting.append(identity)
            return .queued
        }
        driverIdentity = identity
        return .grant
    }

    @discardableResult
    mutating func release(identity: String) -> String? {
        waiting.removeAll { $0 == identity }
        guard driverIdentity == identity else { return nil }
        driverIdentity = waiting.isEmpty ? nil : waiting.removeFirst()
        return driverIdentity
    }
}

enum RemoteControlLeasePolicy {
    static func canExpireIdleLease(heldKeyCount: Int, heldButtonCount: Int) -> Bool {
        heldKeyCount == 0 && heldButtonCount == 0
    }
}

/// Checks the grant, epoch and monotonic sequence before an input event can be
/// posted. A new grant creates a fresh epoch, making old queued messages inert.
struct RemoteControlGate {
    private(set) var driverIdentity: String?
    private(set) var epoch: String?
    private(set) var expiresAtUptime: TimeInterval?
    private(set) var lastSequence: UInt64 = 0

    mutating func grant(identity: String, epoch: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        driverIdentity = identity
        self.epoch = epoch
        expiresAtUptime = now + 2
        lastSequence = 0
    }

    mutating func revoke() {
        driverIdentity = nil
        epoch = nil
        expiresAtUptime = nil
        lastSequence = 0
    }

    mutating func accept(_ message: RemoteControlMessage, sender: String,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard message.version == 1,
              let driverIdentity,
              sender == driverIdentity,
              message.epoch == epoch,
              let currentExpiry = expiresAtUptime, currentExpiry > now,
              message.sequence > lastSequence
        else { return false }
        lastSequence = message.sequence
        if message.kind == .heartbeat {
            let duration = min(Double(message.leaseMilliseconds ?? 2_000), 2_000) / 1_000
            expiresAtUptime = now + max(0.1, duration)
        }
        return true
    }

    var isActive: Bool { expiresAtUptime.map { $0 > ProcessInfo.processInfo.systemUptime } ?? false }
}

enum RemoteInputInjector {
    static let eventMarker: Int64 = 0x504149524445534B

    static func point(x: Double, y: Double, in bounds: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0
        else { return nil }
        return CGPoint(x: bounds.minX + CGFloat(x) * bounds.width,
                       y: bounds.minY + CGFloat(y) * bounds.height)
    }

    /// Posts normalized pointer coordinates within the chosen display bounds.
    /// macOS Accessibility approval is checked for every injection attempt.
    static func movePointer(x: Double, y: Double, in bounds: CGRect, draggingButton: CGMouseButton? = nil) -> Bool {
        guard AXIsProcessTrusted(), let point = point(x: x, y: y, in: bounds) else { return false }
        let mouseType: CGEventType
        switch draggingButton {
        case .some(.left): mouseType = .leftMouseDragged
        case .some(.right): mouseType = .rightMouseDragged
        case .some(.center): mouseType = .otherMouseDragged
        case .none: mouseType = .mouseMoved
        @unknown default: return false
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType,
                                  mouseCursorPosition: point,
                                  mouseButton: draggingButton ?? .left)
        else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    static func key(code: UInt16, down: Bool, modifiers: CGEventFlags = []) -> Bool {
        guard AXIsProcessTrusted(), let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return false }
        event.flags = modifiers
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    static func button(_ button: CGMouseButton, down: Bool, at point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (.center, true): type = .otherMouseDown
        case (.center, false): type = .otherMouseUp
        @unknown default: return false
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    static func scroll(deltaX: Double, deltaY: Double) -> Bool {
        guard AXIsProcessTrusted(), deltaX.isFinite, deltaY.isFinite,
              abs(deltaX) <= 200, abs(deltaY) <= 200,
              let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(deltaY.rounded()),
                                  wheel2: Int32(deltaX.rounded()),
                                  wheel3: 0)
        else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }
}
