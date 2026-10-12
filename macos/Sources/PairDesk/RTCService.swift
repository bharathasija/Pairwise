import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
@preconcurrency import LiveKit

struct CallParticipant: Identifiable, Equatable {
    let identity: String
    let name: String
    let isLocal: Bool
    var isSpeaking: Bool = false
    var id: String { identity }
}

private enum LocalControlIntent {
    case pointer(Double, Double)
    case key(UInt16, Bool, UInt64)
    case button(Int, Bool, Double, Double)
    case scroll(Double, Double)
}

/// Owns one LiveKit room, local media and the consented remote-control lease.
@MainActor
final class RTCService: NSObject, ObservableObject, RoomDelegate {
    @Published private(set) var connected = false
    @Published private(set) var isMicrophoneEnabled = false
    @Published private(set) var isSharing = false
    @Published private(set) var participants: [CallParticipant] = []
    @Published private(set) var screenTrack: VideoTrack?
    @Published private(set) var status = "Disconnected"
    @Published private(set) var error: String?
    @Published private(set) var controlState: RemoteControlState = .unavailable
    @Published private(set) var pendingControlRequests: [CallParticipant] = []
    @Published private(set) var activeSharerIdentity: String?
    @Published private(set) var remoteControlAvailable = false
    /// Viewer side: why the sharer will not accept input, when it won't.
    @Published private(set) var remoteControlUnavailableReason: RemoteControlUnavailableReason?
    @Published private(set) var automaticControlEnabled = false
    @Published private(set) var remotePointers: [RemotePointer] = []
    @Published private(set) var localIdentity: String?
    @Published private(set) var audioInputDevices: [AudioDevice] = []
    @Published private(set) var audioOutputDevices: [AudioDevice] = []
    @Published private(set) var selectedAudioInputID = ""
    @Published private(set) var selectedAudioOutputID = ""
    @Published private(set) var savedAudioInputUnavailable = false
    @Published private(set) var savedAudioOutputUnavailable = false
    @Published private(set) var localMicrophoneLevel = 0.0
    @Published private(set) var screenNetworkQuality: ScreenNetworkQuality = .measuring
    @Published private(set) var isReconnecting = false

    /// Called for captured local microphone and subscribed remote audio tracks.
    /// Buffers are copied to normalized Float samples before delivery. It remains
    /// silent unless a consumer installs this callback (for example, after consent).
    var onAudioBuffer: ((String, String, [Float], Double) -> Void)?
    private var audioForwardingConsented = false

    private var room: Room?
    private var localAudioRenderer: PCMForwarder?
    private var lastMicrophoneMeterUpdate: TimeInterval = 0
    private var remoteAudioRenderers: [String: (identity: String, track: RemoteAudioTrack, renderer: PCMForwarder)] = [:]
    private var shareTrack: LocalVideoTrack?
    private var isStartingShare = false
    private var accessibilityMonitorTask: Task<Void, Never>?
    private var remoteControlManuallyPaused = false
    private var resumeControlAfterReconnect = false
    private var shareBounds: CGRect?
    private var shareIsWindow = false
    private var controlGate = RemoteControlGate()
    private var controlArbiter = RemoteControlArbiter()
    private var localControllerEpoch: String?
    private var localSequence: UInt64 = 0
    private var queuedLocalIntents: [LocalControlIntent] = []
    private var localHeldKeys = Set<UInt16>()
    private var localHeldButtons = Set<Int>()
    private var controllerIdleTask: Task<Void, Never>?
    private var requestTimeoutTask: Task<Void, Never>?
    /// Availability can arrive before the screen track is subscribed.
    private var controlAvailabilityBySender: [String: (available: Bool, reason: RemoteControlUnavailableReason?)] = [:]
    private var leaseTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var lastPointerSentAt: TimeInterval = 0
    private var lastControlRequestAt: TimeInterval = -.infinity
    private var inputMonitor: Any?
    private var localInputMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var controlSendTail: Task<Void, Never>?
    private var queuedControlSends = 0
    private var controlTransportFailed = false
    private let maxQueuedControlSends = 256

    var activeControllerIdentity: String? { isSharing ? controlArbiter.driverIdentity : nil }
    var isSharingWindow: Bool { isSharing && shareIsWindow }

    func participantName(for identity: String) -> String {
        participants.first(where: { $0.identity == identity })?.name ?? identity
    }

    override init() {
        super.init()
        AudioManager.shared.onDeviceUpdate = { [weak self] manager in
            Task { @MainActor [weak self] in self?.refreshAudioDevices(using: manager) }
        }
        refreshAudioDevices()
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != RemoteInputInjector.eventMarker else { return }
            Task { @MainActor [weak self] in self?.handleLocalInput(event) }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != RemoteInputInjector.eventMarker else { return event }
            Task { @MainActor [weak self] in self?.handleLocalInput(event) }
            return event
        }
        let appCenter = NotificationCenter.default
        notificationTokens.append(appCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSharing else { return }
                self.releaseHeldInputs()
            }
        })
        notificationTokens.append(appCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSharing else { return }
                self.emergencyStop()
                await self.stopScreenShare()
            }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emergencyStop() }
        })
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emergencyStop() }
        })
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        notificationTokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func connect(url: String, token: String, identity: String, name: String) async throws {
        guard room == nil else { throw LiveKitError(.invalidState, message: "Already connected") }
        error = nil
        status = "Connecting…"
        controlTransportFailed = false
        let newRoom = Room(delegate: self)
        room = newRoom
        do {
            try await newRoom.connect(url: url, token: token)
            guard newRoom.participantCount <= 4 else {
                await newRoom.disconnect()
                throw LiveKitError(.invalidState, message: "This room is limited to four participants.")
            }
            localIdentity = newRoom.localParticipant.identity?.stringValue ?? identity
            connected = true
            refreshAudioDevices()
            status = "Connected as \(name)"
            refreshParticipants()
            refreshSharer()
            controlState = .viewer
            // No media is enabled on connect. In particular, there is no camera path.
        } catch {
            self.error = error.localizedDescription
            status = "Connection failed"
            room = nil
            throw error
        }
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        leaseTask?.cancel()
        heartbeatTask = nil
        leaseTask = nil
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        controlAvailabilityBySender.removeAll()
        remoteControlUnavailableReason = nil
        emergencyStop()
        controlTransportFailed = true
        if let room {
            detachAudioRenderers()
            _ = try? await room.localParticipant.setMicrophone(enabled: false)
            await room.disconnect()
        }
        self.room = nil
        room = nil
        isReconnecting = false
        resumeControlAfterReconnect = false
        screenTrack = nil
        shareTrack = nil
        isSharing = false
        isMicrophoneEnabled = false
        connected = false
        participants = []
        activeSharerIdentity = nil
        remotePointers = []
        pendingControlRequests = []
        controlState = .unavailable
        localIdentity = nil
        audioForwardingConsented = false
        shareBounds = nil
        shareIsWindow = false
        remoteControlAvailable = false
        automaticControlEnabled = false
        controlArbiter.disable()
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        status = "Disconnected"
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let room else { throw LiveKitError(.invalidState, message: "Not connected") }
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            isMicrophoneEnabled = enabled
            if enabled { attachLocalAudioRenderer() }
            else { detachLocalAudioRenderer(); localMicrophoneLevel = 0 }
        } catch {
            self.error = "Microphone could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"
            throw error
        }
    }

    func selectAudioInput(_ deviceID: String) {
        guard let device = AudioManager.shared.inputDevices.first(where: { $0.deviceId == deviceID }) else { return }
        AudioManager.shared.inputDevice = device
        selectedAudioInputID = device.deviceId
        UserDefaults.standard.set(device.deviceId, forKey: "audioInputDeviceID")
        savedAudioInputUnavailable = false
        audioInputDevices = AudioManager.shared.inputDevices
    }

    func selectAudioOutput(_ deviceID: String) {
        guard let device = AudioManager.shared.outputDevices.first(where: { $0.deviceId == deviceID }) else { return }
        AudioManager.shared.outputDevice = device
        selectedAudioOutputID = device.deviceId
        UserDefaults.standard.set(device.deviceId, forKey: "audioOutputDeviceID")
        savedAudioOutputUnavailable = false
        audioOutputDevices = AudioManager.shared.outputDevices
    }

    private func refreshAudioDevices(using manager: AudioManager = .shared) {
        let inputs = manager.inputDevices
        let outputs = manager.outputDevices
        if let savedID = UserDefaults.standard.string(forKey: "audioInputDeviceID") {
            if let savedDevice = inputs.first(where: { $0.deviceId == savedID }) {
                if manager.inputDevice.deviceId != savedID { manager.inputDevice = savedDevice }
                savedAudioInputUnavailable = false
            } else {
                savedAudioInputUnavailable = true
            }
        }
        if let savedID = UserDefaults.standard.string(forKey: "audioOutputDeviceID") {
            if let savedDevice = outputs.first(where: { $0.deviceId == savedID }) {
                if manager.outputDevice.deviceId != savedID { manager.outputDevice = savedDevice }
                savedAudioOutputUnavailable = false
            } else {
                savedAudioOutputUnavailable = true
            }
        }
        audioInputDevices = inputs
        audioOutputDevices = outputs
        selectedAudioInputID = manager.inputDevice.deviceId
        selectedAudioOutputID = manager.outputDevice.deviceId
    }

    func refreshScreenNetworkQuality() {
        guard let statistics = screenTrack?.statistics else {
            screenNetworkQuality = .measuring
            return
        }
        let roundTripTime = statistics.iceCandidatePair
            .filter { $0.state == .succeeded && $0.nominated != false }
            .compactMap(\.currentRoundTripTime)
            .min()
        screenNetworkQuality = .from(roundTripTimeSeconds: roundTripTime)
    }

    /// Audio leaves the SDK renderer only after an explicit local transcription opt-in.
    func setAudioForwardingConsented(_ enabled: Bool) {
        audioForwardingConsented = enabled
    }

    func startScreenShare(contentFilter: SCContentFilter) async throws {
        guard !isSharing, !isStartingShare else { throw LiveKitError(.invalidState, message: "Screen sharing is already active or starting.") }
        isStartingShare = true
        defer { isStartingShare = false }
        guard let room, connected else { throw LiveKitError(.invalidState, message: "Not connected") }
        guard room.participantCount <= 4 else { throw LiveKitError(.invalidState, message: "This room is limited to four participants.") }
        refreshSharer()
        guard activeSharerIdentity == nil || activeSharerIdentity == localIdentity else {
            throw LiveKitError(.invalidState, message: "Someone else is already sharing their screen.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !room.localParticipant.permissions.canPublishSources.contains(Track.Source.screenShareVideo.rawValue) {
            guard connected, self.room === room, ProcessInfo.processInfo.systemUptime < deadline else {
                throw LiveKitError(.invalidState, message: "Screen sharing permission was not received. Try sharing again.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        var pendingTrack: LocalVideoTrack?
        do {
            let selectedWindow = contentFilter.style == .window
            let selectedFrame = contentFilter.contentRect
            let canControlDisplay = AXIsProcessTrusted()
            // Older viewers infer view-only from the ".window" suffix; newer
            // ones also receive explicit availability messages.
            let trackName = selectedWindow ? "pairdesk.screen.window" : "pairdesk.screen.display"
            let captureOptions = ScreenShareCaptureOptions(dimensions: .h1440_169,
                                                           fps: 30,
                                                           showCursor: true,
                                                           appAudio: false,
                                                           includeCurrentApplication: true)
            let track = await LocalVideoTrack.createMacOSScreenShareTrack(name: trackName,
                                                                          contentFilter: contentFilter,
                                                                          options: captureOptions)
            pendingTrack = track
            let publishOptions = VideoPublishOptions(name: trackName,
                                                     screenShareEncoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30),
                                                     simulcast: false)
            _ = try await room.localParticipant.publish(videoTrack: track, options: publishOptions)
            shareTrack = track
            shareBounds = selectedWindow ? nil : selectedFrame
            shareIsWindow = selectedWindow
            remoteControlAvailable = !shareIsWindow && canControlDisplay
            remoteControlManuallyPaused = false
            automaticControlEnabled = remoteControlAvailable
            if automaticControlEnabled { controlArbiter.enable() }
            screenTrack = track
            isSharing = true
            activeSharerIdentity = localIdentity
            controlState = .host
            status = selectedWindow
                ? "Sharing window · remote control unavailable"
                : (automaticControlEnabled ? "Sharing display · teammates can control when they interact" : "Sharing display · remote control unavailable")
            sendControl(.init(epoch: UUID().uuidString, sequence: nextSequence(), kind: .releaseAll))
            startAccessibilityMonitor()
            sendControlAvailability()
            pendingTrack = nil
        } catch {
            if let pendingTrack { _ = try? await pendingTrack.capturer.stopCapture() }
            self.error = "Screen sharing failed: \(error.localizedDescription)"
            throw error
        }
    }

    func stopScreenShare() async {
        guard let room, let track = shareTrack else { return }
        accessibilityMonitorTask?.cancel()
        accessibilityMonitorTask = nil
        revokeControl()
        guard let publication = room.localParticipant.localVideoTracks.first(where: { $0.track === track }) else {
            _ = try? await track.capturer.stopCapture()
            shareTrack = nil
            screenTrack = nil
            shareBounds = nil
            remoteControlAvailable = false
            automaticControlEnabled = false
            controlArbiter.disable()
            isSharing = false
            if activeSharerIdentity == localIdentity { activeSharerIdentity = nil }
            controlState = .viewer
            return
        }
        do { try await room.localParticipant.unpublish(publication: publication) }
        catch {
            self.error = "Could not stop screen sharing cleanly: \(error.localizedDescription)"
            _ = try? await track.capturer.stopCapture()
            remoteControlAvailable = false
            return
        }
        shareTrack = nil
        screenTrack = nil
        shareBounds = nil
        remoteControlAvailable = false
        automaticControlEnabled = false
        controlArbiter.disable()
        isSharing = false
        if activeSharerIdentity == localIdentity { activeSharerIdentity = nil }
        controlState = .viewer
        status = "Screen sharing stopped"
    }

    func requestControl() {
        guard canRequestRemoteControl,
              controlState == .viewer || controlState == .hostPermissionRequired,
              ProcessInfo.processInfo.systemUptime - lastControlRequestAt >= 1 else { return }
        lastControlRequestAt = ProcessInfo.processInfo.systemUptime
        controlState = .requesting
        sendControl(.init(epoch: "", sequence: nextSequence(), kind: .request))
        // An older host ignores requests it cannot grant; don't show
        // "Connecting remote control…" forever.
        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, case .requesting = self.controlState else { return }
            self.controlState = .viewer
            self.queuedLocalIntents.removeAll()
        }
    }

    func grantControl(identity: String) {
        guard !controlTransportFailed, controlArbiter.driverIdentity == identity else { return }
        sendGrant(to: identity)
    }

    private func sendGrant(to identity: String) {
        guard isSharing, automaticControlEnabled, !shareIsWindow else { return }
        guard AXIsProcessTrusted() else {
            error = "Enable PairDesk in System Settings → Privacy & Security → Accessibility to continue remote control."
            pauseRemoteControl(userInitiated: false)
            return
        }
        guard room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == identity }) == true else {
            if let next = controlArbiter.release(identity: identity) { sendGrant(to: next) }
            return
        }
        if controlGate.driverIdentity == identity { releaseInjectedInputs() }
        let epoch = UUID().uuidString
        controlGate.grant(identity: identity, epoch: epoch)
        controlState = .granted(identity: identity, expiresAt: .now.addingTimeInterval(2))
        pendingControlRequests.removeAll { $0.identity == identity }
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .grant, leaseMilliseconds: 2_000), to: identity)
        startLeaseWatch()
    }

    /// Pauses automatic control for the rest of this share until explicitly resumed.
    func pauseRemoteControl(userInitiated: Bool = true) {
        guard isSharing else { return }
        if userInitiated { remoteControlManuallyPaused = true }
        let waiting = pendingControlRequests.map(\.identity)
        automaticControlEnabled = false
        controlArbiter.disable()
        revokeActiveLease(notifyDriver: true)
        for identity in waiting {
            sendControl(.init(epoch: "", sequence: nextSequence(), kind: .revoke), to: identity)
        }
        pendingControlRequests.removeAll()
        controlState = .host
        sendControlAvailability()
    }

    func resumeRemoteControl() {
        guard isSharing, remoteControlAvailable, !controlTransportFailed, AXIsProcessTrusted() else { return }
        remoteControlManuallyPaused = false
        automaticControlEnabled = true
        controlArbiter.enable()
        controlState = .host
        sendControlAvailability()
    }

    /// Host: tells one viewer, or everyone, whether input would be accepted now.
    private func sendControlAvailability(to identity: String? = nil) {
        guard isSharing else { return }
        let state = RemoteControlAvailability.evaluate(sharingWindow: shareIsWindow,
                                                       accessibilityTrusted: AXIsProcessTrusted(),
                                                       automaticControlEnabled: automaticControlEnabled)
        sendControl(.init(epoch: "", sequence: nextSequence(), kind: .availability,
                          available: state.available, reason: state.reason?.rawValue), to: identity)
    }

    /// Viewer: prefer what the host said; fall back to the track name for older hosts.
    private func applyRemoteControlAvailability(from sender: String, trackName: String) {
        if let known = controlAvailabilityBySender[sender] {
            applyRemoteControlAvailability(known.available, reason: known.reason)
        } else {
            let isWindow = trackName.hasSuffix(".window")
            applyRemoteControlAvailability(!isWindow, reason: isWindow ? .windowShare : nil)
        }
    }

    private func applyRemoteControlAvailability(_ available: Bool, reason: RemoteControlUnavailableReason?) {
        remoteControlAvailable = available
        remoteControlUnavailableReason = available ? nil : reason
        guard !available else { return }
        requestTimeoutTask?.cancel()
        queuedLocalIntents.removeAll()
        if case .requesting = controlState { controlState = .viewer }
    }

    /// Accessibility consent can change while the share is active in System Settings.
    /// Re-check it on the sharing Mac so a newly granted permission takes effect
    /// without forcing the user to stop and restart screen sharing.
    private func startAccessibilityMonitor() {
        accessibilityMonitorTask?.cancel()
        accessibilityMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSharing, !self.shareIsWindow else { return }
                self.refreshRemoteControlPermission()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func refreshRemoteControlPermission() {
        guard isSharing, !shareIsWindow, !controlTransportFailed else { return }
        let trusted = AXIsProcessTrusted()
        if trusted && !remoteControlAvailable {
            remoteControlAvailable = true
            if !remoteControlManuallyPaused {
                automaticControlEnabled = true
                controlArbiter.enable()
            }
            status = remoteControlManuallyPaused
                ? "Sharing display · remote control is paused"
                : "Sharing display · remote control is ready"
            error = nil
            sendControlAvailability()
        } else if !trusted && remoteControlAvailable {
            remoteControlAvailable = false
            pauseRemoteControl(userInitiated: false)
            status = "Sharing display · enable PairDesk in Accessibility to allow control"
        }
    }

    /// Kept for existing callers; revoking means pausing automatic control.
    func revokeControl() { pauseRemoteControl() }

    private func revokeActiveLease(notifyDriver: Bool) {
        if notifyDriver, let driver = controlGate.driverIdentity, let epoch = controlGate.epoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .revoke), to: driver)
        }
        releaseInjectedInputs()
        controlGate.revoke()
        leaseTask?.cancel()
        leaseTask = nil
    }

    /// Bind this to a local emergency shortcut in the app window (e.g. Escape).
    /// It immediately revokes the lease and releases any held remote keys/buttons.
    func emergencyStop() {
        if isSharing { pauseRemoteControl(); return }
        let wasLocalController = localControllerEpoch != nil
        if let epoch = localControllerEpoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .release))
        }
        localControllerEpoch = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controllerIdleTask?.cancel()
        controllerIdleTask = nil
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        if wasLocalController, connected { controlState = .viewer }
    }

    /// Call when a local owner uses the in-app shared-screen controls.
    func localOwnerInputDetected() {
        guard isSharing, controlGate.driverIdentity != nil,
              !heldKeys.isEmpty || !heldButtons.isEmpty else { return }
        if let driver = controlGate.driverIdentity, let epoch = controlGate.epoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .releaseAll), to: driver)
        }
        releaseInjectedInputs()
    }

    /// Clears held keys/buttons on the host while keeping the lease alive.
    func releaseHeldInputs() {
        if let epoch = localControllerEpoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .releaseAll))
        }
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
    }

    func sendPointer(x: Double, y: Double) {
        guard !controlTransportFailed, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
        guard let epoch = localControllerEpoch else { queueIntent(.pointer(x, y)); return }
        beginActiveInput(epoch: epoch)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerSentAt >= 1.0 / 30 else { return }
        lastPointerSentAt = now
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .pointer, x: x, y: y))
    }

    func sendKey(code: UInt16, down: Bool, modifiers: UInt64 = 0) {
        guard !controlTransportFailed, code < 128 else { return }
        guard canRequestRemoteControl else { return }
        if down { localHeldKeys.insert(code) } else { localHeldKeys.remove(code) }
        guard let epoch = localControllerEpoch else { queueIntent(.key(code, down, modifiers)); return }
        beginActiveInput(epoch: epoch)
        let deviceIndependentFlags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            .intersection(.deviceIndependentFlagsMask).rawValue
        let sanitizedModifiers = UInt64(deviceIndependentFlags) & Self.allowedModifierMask
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .key,
                          code: code, down: down, modifiers: sanitizedModifiers))
    }

    func sendButton(button: Int, down: Bool, x: Double, y: Double) {
        guard !controlTransportFailed, [0, 1, 2].contains(button), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y)
        else { return }
        guard canRequestRemoteControl else { return }
        if down { localHeldButtons.insert(button) } else { localHeldButtons.remove(button) }
        guard let epoch = localControllerEpoch else { queueIntent(.button(button, down, x, y)); return }
        beginActiveInput(epoch: epoch)
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .button, x: x, y: y,
                          code: UInt16(button), down: down))
    }

    func sendScroll(dx: Double, dy: Double) {
        guard !controlTransportFailed, dx.isFinite, dy.isFinite, abs(dx) <= 200, abs(dy) <= 200
        else { return }
        guard let epoch = localControllerEpoch else { queueIntent(.scroll(dx, dy)); return }
        beginActiveInput(epoch: epoch)
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .scroll, deltaX: dx, deltaY: dy))
    }

    // MARK: RoomDelegate

    nonisolated func roomDidConnect(_ room: Room) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.connected = true
            self.setReconnecting(false)
            self.refreshParticipants()
            self.refreshSharer()
        }
    }

    nonisolated func roomIsReconnecting(_ room: Room) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(true)
        }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(true)
        }
    }

    nonisolated func roomDidReconnect(_ room: Room) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(false)
            self.refreshParticipants()
            self.refreshSharer()
        }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(false)
            self.refreshParticipants()
            self.refreshSharer()
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.emergencyStop()
            self.detachAudioRenderers()
            self.connected = false
            self.isReconnecting = false
            self.resumeControlAfterReconnect = false
            self.error = error?.localizedDescription
            self.status = "Disconnected"
            self.isSharing = false
            self.isMicrophoneEnabled = false
            self.shareTrack = nil
            self.shareBounds = nil
            self.shareIsWindow = false
            self.remoteControlAvailable = false
            self.automaticControlEnabled = false
            self.controlArbiter.disable()
            self.screenTrack = nil
            self.activeSharerIdentity = nil
            self.remotePointers = []
            self.pendingControlRequests = []
            self.requestTimeoutTask?.cancel()
            self.requestTimeoutTask = nil
            self.controlAvailabilityBySender.removeAll()
            self.remoteControlUnavailableReason = nil
            self.room = nil
            self.controlState = .unavailable
            self.audioForwardingConsented = false
            self.controlTransportFailed = true
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refreshParticipants()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            let matches = self.remoteAudioRenderers.filter { $0.value.identity == identity }
            for (sid, attachment) in matches {
                attachment.track.remove(audioRenderer: attachment.renderer)
                self.remoteAudioRenderers.removeValue(forKey: sid)
            }
            self.refreshParticipants()
            self.refreshSharer()
            self.remotePointers.removeAll { $0.id == identity }
            self.pendingControlRequests.removeAll { $0.identity == identity }
            if self.controlGateIdentity == identity { self.releaseDriver(sender: identity, notifyDriver: false) }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let identity = participant.identity?.stringValue ?? ""
        let name = participant.name ?? identity
        if let video = publication.track as? VideoTrack, video.source == .screenShareVideo {
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                self.screenTrack = video
                self.activeSharerIdentity = identity
                self.applyRemoteControlAvailability(from: identity, trackName: video.name)
                self.refreshSharer()
                self.requestControl()
            }
        }
        if let audio = publication.track as? RemoteAudioTrack {
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                let renderer = self.makeAudioRenderer(room: room, identity: identity, name: name)
                audio.add(audioRenderer: renderer)
                self.remoteAudioRenderers[publication.sid.stringValue] = (identity, audio, renderer)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if publication.kind == .video {
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                if let video = publication.track as? VideoTrack, self.screenTrack === video {
                    self.screenTrack = nil
                    if self.localControllerEpoch != nil { self.emergencyStop() }
                }
                self.refreshSharer()
            }
        }
        if let audio = publication.track as? RemoteAudioTrack {
            Task { @MainActor [weak self] in
                guard let self, self.room === room,
                      let attachment = self.remoteAudioRenderers.removeValue(forKey: publication.sid.stringValue)
                else { return }
                audio.remove(audioRenderer: attachment.renderer)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.screenTrack = nil
            if self.localControllerEpoch != nil { self.emergencyStop() }
            self.refreshSharer()
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refreshParticipants()
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        guard participant is LocalParticipant, trackPublication.kind == .audio else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.isMicrophoneEnabled = !isMuted
            if isMuted { self.detachLocalAudioRenderer() }
            else { self.attachLocalAudioRenderer() }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == Self.controlTopic, data.count <= 2_048,
              let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data),
              let sender = participant?.identity?.stringValue
        else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.receive(message, sender: sender)
        }
    }

    // MARK: Data protocol

    nonisolated private static let controlTopic = "pairdesk.control.v1"
    private static let allowedModifierMask = CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue

    private var controlGateIdentity: String? { controlGate.driverIdentity }
    var canRequestRemoteControl: Bool {
        connected && remoteControlAvailable && activeSharerIdentity != nil && activeSharerIdentity != localIdentity
    }

    private func receive(_ message: RemoteControlMessage, sender: String) {
        guard let localIdentity else { return }
        if message.kind == .pointer, !isSharing {
            guard let sharer = activeSharerIdentity, sender != localIdentity, sender != sharer,
                  room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == sender }) == true,
                  let x = message.x, let y = message.y,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
            else { return }
            recordRemotePointer(identity: sender, x: x, y: y)
            return
        }
        switch message.kind {
        case .request:
            guard isSharing, sender != localIdentity else { return }
            guard !shareIsWindow, automaticControlEnabled else {
                // Revoke, or hostPermissionRequired, ends an older viewer's wait;
                // availability tells a newer one why, so it stops showing
                // control as available.
                let kind: RemoteControlMessage.Kind = AXIsProcessTrusted() ? .revoke : .hostPermissionRequired
                sendControl(.init(epoch: "", sequence: nextSequence(), kind: kind), to: sender)
                sendControlAvailability(to: sender)
                return
            }
            let name = room?.remoteParticipants.values.first(where: { $0.identity?.stringValue == sender })?.name ?? sender
            if controlArbiter.driverIdentity == sender, controlGate.isActive {
                sendGrant(to: sender)
                return
            }
            if controlArbiter.driverIdentity == sender, !controlGate.isActive {
                releaseDriver(sender: sender, notifyDriver: false)
            }
            switch controlArbiter.request(identity: sender) {
            case .grant: sendGrant(to: sender)
            case .queued:
                if !pendingControlRequests.contains(where: { $0.identity == sender }) {
                    pendingControlRequests.append(CallParticipant(identity: sender, name: name, isLocal: false))
                }
            case .ignored: break
            }
        case .availability:
            guard !isSharing, sender != localIdentity, let available = message.available else { return }
            let reason = message.reason.flatMap(RemoteControlUnavailableReason.init(rawValue:))
            controlAvailabilityBySender[sender] = (available, reason)
            if sender == activeSharerIdentity { applyRemoteControlAvailability(available, reason: reason) }
        case .grant:
            guard sender == activeSharerIdentity, !message.epoch.isEmpty,
                  case .requesting = controlState else { return }
            requestTimeoutTask?.cancel()
            localControllerEpoch = message.epoch
            controlState = .granted(identity: sender, expiresAt: .now.addingTimeInterval(2))
            let queued = queuedLocalIntents
            queuedLocalIntents.removeAll()
            if !queued.isEmpty {
                beginActiveInput(epoch: message.epoch)
                queued.forEach { sendIntent($0) }
            } else { scheduleLocalIdleExpiry(epoch: message.epoch) }
        case .revoke:
            guard sender == activeSharerIdentity else { return }
            requestTimeoutTask?.cancel()
            localControllerEpoch = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            controllerIdleTask?.cancel()
            controllerIdleTask = nil
            queuedLocalIntents.removeAll()
            localHeldKeys.removeAll()
            localHeldButtons.removeAll()
            controlState = .viewer
        case .hostPermissionRequired:
            guard sender == activeSharerIdentity, case .requesting = controlState else { return }
            localControllerEpoch = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            controllerIdleTask?.cancel()
            controllerIdleTask = nil
            queuedLocalIntents.removeAll()
            localHeldKeys.removeAll()
            localHeldButtons.removeAll()
            controlState = .hostPermissionRequired
        case .heartbeat, .pointer, .key, .button, .scroll, .releaseAll, .release:
            guard isSharing,
                  controlGate.accept(message, sender: sender),
                  let expiryUptime = controlGate.expiresAtUptime
            else { return }
            if message.kind == .release {
                releaseDriver(sender: sender, notifyDriver: false)
                return
            }
            let expiry = Date().addingTimeInterval(max(0, expiryUptime - ProcessInfo.processInfo.systemUptime))
            controlState = .granted(identity: sender, expiresAt: expiry)
            if message.kind == .pointer, let x = message.x, let y = message.y,
               x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
                recordRemotePointer(identity: sender, x: x, y: y)
                if !shareIsWindow, let bounds = shareBounds {
                    let activeButton = [0, 1, 2].first(where: heldButtons.contains)
                        .flatMap { CGMouseButton(rawValue: UInt32($0)) }
                    if !RemoteInputInjector.movePointer(x: x, y: y, in: bounds, draggingButton: activeButton) {
                        reportRemoteInputFailure()
                        return
                    }
                }
            } else if message.kind == .key, let code = message.code, let down = message.down {
                guard code < 128, (message.modifiers ?? 0) & ~Self.allowedModifierMask == 0 else { return }
                let flags = CGEventFlags(rawValue: message.modifiers ?? 0)
                if RemoteInputInjector.key(code: code, down: down, modifiers: flags) {
                    if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
                } else { reportRemoteInputFailure(); return }
            } else if message.kind == .button, let code = message.code, code <= 2, let down = message.down,
                      let x = message.x, let y = message.y, x.isFinite, y.isFinite,
                      (0...1).contains(x), (0...1).contains(y), !shareIsWindow,
                      let bounds = shareBounds, let button = CGMouseButton(rawValue: UInt32(code)) {
                guard let point = RemoteInputInjector.point(x: x, y: y, in: bounds) else { return }
                if RemoteInputInjector.button(button, down: down, at: point) {
                    if down { heldButtons.insert(Int(code)) } else { heldButtons.remove(Int(code)) }
                } else { reportRemoteInputFailure(); return }
            } else if message.kind == .scroll,
                      let dx = message.deltaX, let dy = message.deltaY,
                      dx.isFinite, dy.isFinite, abs(dx) <= 200, abs(dy) <= 200,
                      !shareIsWindow {
                if !RemoteInputInjector.scroll(deltaX: dx, deltaY: dy) {
                    reportRemoteInputFailure()
                    return
                }
            }
            else if message.kind == .releaseAll { releaseInjectedInputs() }
            startLeaseWatch()
        }
    }

    private func recordRemotePointer(identity: String, x: Double, y: Double) {
        let timestamp = Date()
        remotePointers.removeAll { $0.id == identity }
        remotePointers.append(RemotePointer(id: identity, x: x, y: y, updatedAt: timestamp))
        let sourceRoom = room
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled,
                  self.room === sourceRoom,
                  self.remotePointers.first(where: { $0.id == identity })?.updatedAt == timestamp
            else { return }
            self.remotePointers.removeAll { $0.id == identity }
        }
    }

    private func reportRemoteInputFailure() {
        error = AXIsProcessTrusted()
            ? "PairDesk couldn't send remote input. Check that Accessibility is enabled for the PairDesk copy in Applications, then restart PairDesk."
            : "Accessibility access is off for PairDesk. Enable it in System Settings to let teammates control this Mac."
        pauseRemoteControl()
    }

    private func sendControl(_ message: RemoteControlMessage, to identity: String? = nil) {
        guard let room, !controlTransportFailed,
              let data = try? JSONEncoder().encode(message)
        else { return }
        guard queuedControlSends < maxQueuedControlSends else {
            failControlTransport("Remote-control message queue is full; the control lease was closed.")
            return
        }
        let destinations = identity.map { [Participant.Identity(from: $0)] } ?? []
        let options = DataPublishOptions(name: "PairDesk control",
                                         destinationIdentities: destinations,
                                         topic: Self.controlTopic,
                                         reliable: true)
        let previous = controlSendTail
        queuedControlSends += 1
        controlSendTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard self.room === room, !self.controlTransportFailed else {
                self.queuedControlSends = max(0, self.queuedControlSends - 1)
                return
            }
            do {
                try await room.localParticipant.publish(data: data, options: options)
                self.queuedControlSends = max(0, self.queuedControlSends - 1)
            } catch {
                self.queuedControlSends = max(0, self.queuedControlSends - 1)
                self.failControlTransport("Control message failed: \(error.localizedDescription)")
            }
        }
    }

    private func failControlTransport(_ message: String) {
        guard !controlTransportFailed else { return }
        controlTransportFailed = true
        error = message
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controllerIdleTask?.cancel()
        controllerIdleTask = nil
        automaticControlEnabled = false
        controlArbiter.disable()
        localControllerEpoch = nil
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        releaseInjectedInputs()
        controlGate.revoke()
        if connected { controlState = isSharing ? .host : .viewer }
    }

    private func nextSequence() -> UInt64 { localSequence &+= 1; return localSequence }

    private func startHeartbeat(epoch: String) {
        heartbeatTask?.cancel()
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .heartbeat, leaseMilliseconds: 2_000))
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, self.localControllerEpoch == epoch else { return }
                self.sendControl(.init(epoch: epoch, sequence: self.nextSequence(), kind: .heartbeat, leaseMilliseconds: 2_000))
            }
        }
        scheduleLocalIdleExpiry(epoch: epoch)
    }

    private func scheduleLocalIdleExpiry(epoch: String) {
        controllerIdleTask?.cancel()
        controllerIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.localControllerEpoch == epoch else { return }
            guard RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: self.localHeldKeys.count,
                                                              heldButtonCount: self.localHeldButtons.count) else {
                self.controllerIdleTask = nil
                self.scheduleLocalIdleExpiry(epoch: epoch)
                return
            }
            self.heartbeatTask?.cancel()
            self.heartbeatTask = nil
            self.localControllerEpoch = nil
            self.controlState = .viewer
            self.queuedLocalIntents.removeAll()
            self.controllerIdleTask = nil
        }
    }

    private func startLeaseWatch() {
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2_100))
            guard !Task.isCancelled, let self, !self.controlGate.isActive else { return }
            if let driver = self.controlGate.driverIdentity {
                self.releaseDriver(sender: driver, notifyDriver: true)
            }
        }
    }

    private func releaseDriver(sender: String, notifyDriver: Bool) {
        if notifyDriver, let epoch = controlGate.epoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .revoke), to: sender)
        }
        releaseInjectedInputs()
        controlGate.revoke()
        leaseTask?.cancel()
        leaseTask = nil
        guard let next = controlArbiter.release(identity: sender) else {
            controlState = .host
            return
        }
        sendGrant(to: next)
    }

    private func queueIntent(_ intent: LocalControlIntent) {
        guard canRequestRemoteControl else { return }
        guard localControllerEpoch == nil else { sendIntent(intent); return }
        if case .pointer(let x, let y) = intent,
           let lastIndex = queuedLocalIntents.indices.last,
           case .pointer(_, _) = queuedLocalIntents[lastIndex] {
            queuedLocalIntents[lastIndex] = .pointer(x, y)
        } else if queuedLocalIntents.count < 16 {
            queuedLocalIntents.append(intent)
        } else {
            queuedLocalIntents.removeAll()
            error = "Input queue cleared while waiting for control. Try the action again."
        }
        requestControl()
    }

    private func beginActiveInput(epoch: String) {
        guard localControllerEpoch == epoch else { return }
        if heartbeatTask == nil { startHeartbeat(epoch: epoch) }
        else { scheduleLocalIdleExpiry(epoch: epoch) }
    }

    private func sendIntent(_ intent: LocalControlIntent) {
        switch intent {
        case .pointer(let x, let y): sendPointer(x: x, y: y)
        case .key(let code, let down, let modifiers): sendKey(code: code, down: down, modifiers: modifiers)
        case .button(let button, let down, let x, let y): sendButton(button: button, down: down, x: x, y: y)
        case .scroll(let dx, let dy): sendScroll(dx: dx, dy: dy)
        }
    }

    private func releaseInjectedInputs() {
        for code in heldKeys { _ = RemoteInputInjector.key(code: code, down: false) }
        for raw in heldButtons {
            guard let button = CGMouseButton(rawValue: UInt32(raw)) else { continue }
            let point = CGEvent(source: nil)?.location ?? .zero
            _ = RemoteInputInjector.button(button, down: false, at: point)
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
    }

    // MARK: State and audio

    private func setReconnecting(_ reconnecting: Bool) {
        guard isReconnecting != reconnecting else { return }
        isReconnecting = reconnecting
        if reconnecting {
            status = "Reconnecting…"
            if isSharing {
                resumeControlAfterReconnect = automaticControlEnabled
                if automaticControlEnabled { pauseRemoteControl() }
                else { releaseInjectedInputs() }
            } else {
                emergencyStop()
            }
            return
        }

        status = connected ? "Connected" : "Disconnected"
        if resumeControlAfterReconnect, isSharing { resumeRemoteControl() }
        resumeControlAfterReconnect = false
    }

    private func refreshParticipants() {
        guard let room else { return }
        let localID = room.localParticipant.identity?.stringValue ?? localIdentity ?? "local"
        let local = CallParticipant(identity: localID, name: room.localParticipant.name ?? localID,
                                    isLocal: true, isSpeaking: room.localParticipant.isSpeaking)
        let remotes = room.remoteParticipants.values.compactMap { participant -> CallParticipant? in
            guard let id = participant.identity?.stringValue else { return nil }
            return CallParticipant(identity: id, name: participant.name ?? id,
                                   isLocal: false, isSpeaking: participant.isSpeaking)
        }.sorted { $0.identity < $1.identity }
        participants = Array(([local] + remotes).prefix(4))
    }

    private func refreshSharer() {
        guard let room else { return }
        if isSharing { activeSharerIdentity = localIdentity; return }
        for participant in room.remoteParticipants.values {
            if let publication = participant.videoTracks.first(where: { $0.source == .screenShareVideo }),
               let sharer = participant.identity?.stringValue {
                activeSharerIdentity = sharer
                applyRemoteControlAvailability(from: sharer, trackName: publication.name)
                controlState = .viewer
                return
            }
        }
        activeSharerIdentity = nil
        remoteControlAvailable = false
        remoteControlUnavailableReason = nil
        if connected { controlState = .viewer }
    }

    private func attachLocalAudioRenderer() {
        guard localAudioRenderer == nil, let room else { return }
        let identity = localIdentity ?? "local"
        let renderer = makeAudioRenderer(room: room, identity: identity, name: room.localParticipant.name ?? identity)
        if let track = room.localParticipant.localAudioTracks.compactMap({ $0.track as? LocalAudioTrack }).first {
            track.add(audioRenderer: renderer)
            localAudioRenderer = renderer
        }
    }

    private func detachLocalAudioRenderer() {
        guard let renderer = localAudioRenderer else { return }
        room?.localParticipant.localAudioTracks.compactMap { $0.track as? LocalAudioTrack }.forEach { $0.remove(audioRenderer: renderer) }
        localAudioRenderer = nil
    }

    private func detachAudioRenderers() {
        detachLocalAudioRenderer()
        for attachment in remoteAudioRenderers.values {
            attachment.track.remove(audioRenderer: attachment.renderer)
        }
        remoteAudioRenderers.removeAll()
    }

    private func makeAudioRenderer(room: Room, identity: String, name: String) -> PCMForwarder {
        PCMForwarder { [weak self] samples, sampleRate in
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                if identity == self.localIdentity {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastMicrophoneMeterUpdate >= 0.1 {
                        self.lastMicrophoneMeterUpdate = now
                        self.localMicrophoneLevel = AudioMeter.level(samples: samples)
                    }
                }
                if self.audioForwardingConsented { self.onAudioBuffer?(identity, name, samples, sampleRate) }
            }
        }
    }

    #if DEBUG
    /// UI snapshot fixtures only: stand in for a connected room.
    func debugSetCall(participants: [CallParticipant], microphoneEnabled: Bool) {
        connected = true
        self.participants = participants
        isMicrophoneEnabled = microphoneEnabled
        localMicrophoneLevel = microphoneEnabled ? 0.45 : 0
    }
    #endif

    private func handleLocalInput(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.contains([.control, .option]) {
            emergencyStop()
            return
        }
        localOwnerInputDetected()
    }

}

private final class PCMForwarder: AudioRenderer, @unchecked Sendable {
    private let onSamples: @Sendable ([Float], Double) -> Void

    init(onSamples: @escaping @Sendable ([Float], Double) -> Void) { self.onSamples = onSamples }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let count = Int(pcmBuffer.frameLength)
        let samples: [Float]
        if let channel = pcmBuffer.floatChannelData?.pointee {
            samples = Array(UnsafeBufferPointer(start: channel, count: count))
        } else if let channel = pcmBuffer.int16ChannelData?.pointee {
            samples = (0..<count).map { Float(channel[$0]) / 32_768 }
        } else if let channel = pcmBuffer.int32ChannelData?.pointee {
            samples = (0..<count).map { Float(channel[$0]) / 2_147_483_648 }
        } else { return }
        let rate = pcmBuffer.format.sampleRate
        onSamples(samples, rate)
    }
}
