import AppKit
import Foundation
import Combine
import ApplicationServices
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var user: TeamUser?
    @Published var users: [TeamUser] = []
    @Published var adminUsers: [TeamUser] = []
    @Published var rooms: [PairRoom] = []
    @Published var callInvitations: [CallInvitation] = []
    @Published var callMessage: String?
    @Published var activeRoom: PairRoom?
    @Published var callStartedAt: Date?
    @Published var busy = false
    @Published var error: String?
    @Published var directoryStatus = "Connecting…"
    @Published var serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? (Bundle.main.object(forInfoDictionaryKey: "PairDeskServerURL") as? String) ?? "http://127.0.0.1:18080"
    @Published var startCallsMuted = UserDefaults.standard.bool(forKey: "startCallsMuted") {
        didSet { UserDefaults.standard.set(startCallsMuted, forKey: "startCallsMuted") }
    }
    let rtc = RTCService()
    let transcripts = WhisperTranscriber()
    private var subscriptions = Set<AnyCancellable>()
    private var hadRemoteParticipant = false
    private var restoringSession = false
    private var token: String?
    private var refreshTask: Task<Void, Never>?
    private var callRefreshTask: Task<Void, Never>?
    private var observedCallStatuses: [String: String] = [:]
    private var attentionRequest: Int?
    private var autoVoiceCallID: String?
    private var invitationPollSequence = 0

    var incomingCall: CallInvitation? { callInvitations.first { $0.status == "pending" && $0.target.id == user?.id } }
    var outgoingCalls: [CallInvitation] { callInvitations.filter { $0.status == "pending" && $0.caller.id == user?.id } }
    var canAddPerson: Bool { activeRoom != nil && rtc.participants.count + outgoingCalls.count < 4 }
    var availablePeople: [TeamUser] {
        users.filter { person in
            person.id != user?.id && person.online == true && person.busy != true &&
            !rtc.participants.contains { $0.identity == person.id } &&
            !outgoingCalls.contains { $0.target.id == person.id }
        }
    }
    private var generation = 0
    private var screenClaimRoomID: String?

    var api: APIClient { get throws { try APIClient(server: serverAddress, token: token) } }

    init() {
        rtc.$connected.dropFirst().sink { [weak self] connected in
            guard let self, !connected, self.activeRoom != nil else { return }
            Task { await self.leave() }
        }.store(in: &subscriptions)
        rtc.$participants.sink { [weak self] participants in
            guard let self else { return }
            if participants.contains(where: { !$0.isLocal }) {
                self.hadRemoteParticipant = true
                // Private rooms admit the target only after acceptance, so a
                // remote participant means the call connected. Start talking
                // now instead of waiting for the next invitation poll.
                if self.autoVoiceCallID != nil, self.activeRoom != nil { Task { await self.startAutoVoice() } }
            }
            else if self.hadRemoteParticipant, self.activeRoom != nil {
                Task { await self.leave() }
            }
        }.store(in: &subscriptions)
        rtc.onAudioBuffer = { [weak self] identity, name, samples, rate in
            Task { @MainActor in
                guard let self, self.activeRoom != nil else { return }
                self.transcripts.appendAudio(speakerID: identity, name: name, samples: samples, sampleRate: rate)
            }
        }
    }

    func restore() async {
        guard !restoringSession, user == nil else { return }
        restoringSession = true
        busy = true
        defer { busy = false; restoringSession = false }
        guard let saved = await Task.detached(priority: .userInitiated, operation: { SessionVault.read() }).value else { return }
        serverAddress = saved.server
        token = saved.token
        do {
            let current: MeResponse = try await api.request("v1/me")
            user = current.user
            startRefresh()
        } catch {
            if (error as? APIError)?.status == 401 {
                SessionVault.clear()
                token = nil
            }
            self.error = error.localizedDescription
        }
        busy = false
    }

    func login(email: String, password: String) async {
        guard !busy else { return }
        busy = true
        error = nil
        struct Body: Encodable { let email: String; let password: String }
        do {
            let client = try APIClient(server: serverAddress)
            let response: LoginResponse = try await client.post("v1/login", body: Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
            let saved = SavedSession(token: response.token, server: serverAddress)
            try await Task.detached(priority: .userInitiated) { try SessionVault.save(saved) }.value
            token = response.token
            user = response.user
            UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
            startRefresh()
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func logout() async {
        guard !busy else { return }
        busy = true
        generation += 1
        refreshTask?.cancel()
        callRefreshTask?.cancel()
        await leave()
        try? await api.send("v1/logout", body: EmptyBody())
        SessionVault.clear()
        token = nil
        user = nil
        users = []
        rooms = []
        callInvitations = []
        observedCallStatuses = [:]
        autoVoiceCallID = nil
        if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest); self.attentionRequest = nil }
        busy = false
    }

    private func startRefresh() {
        callRefreshTask?.cancel()
        callRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInvitations()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() async {
        guard user != nil else { return }
        do {
            let client = try api
            if !busy, !rtc.isSharing { try await releaseScreenClaim() }
            try await client.send("v1/heartbeat", body: EmptyBody())
            async let people: UsersResponse = client.request("v1/users")
            async let calls: RoomsResponse = client.request("v1/rooms")
            let (p, c) = try await (people, calls)
            users = p.users
            rooms = c.rooms
            if let room = activeRoom {
                do { try await client.send("v1/rooms/\(room.id)/heartbeat", body: EmptyBody()) }
                catch let ended as APIError where [403, 404, 409].contains(ended.status) {
                    callMessage = "Call ended."
                    await leave()
                    return
                }
                if let updated = rooms.first(where: { $0.id == room.id }) { activeRoom = updated }
            }
            directoryStatus = "Team connected"
        } catch {
            directoryStatus = "Server unreachable — retrying"
            if (error as? APIError)?.status == 401 {
                generation += 1
                refreshTask?.cancel()
                callRefreshTask?.cancel()
                await leave()
                SessionVault.clear()
                token = nil
                user = nil
                self.error = "Your session has expired. Sign in again."
            }
        }
    }

    func refreshInvitations() async {
        guard let currentUser = user else { return }
        invitationPollSequence += 1
        let pollSequence = invitationPollSequence
        do {
            let response: CallsResponse = try await api.request("v1/calls")
            guard user?.id == currentUser.id, pollSequence == invitationPollSequence else { return }
            let oldStatuses = observedCallStatuses
            callInvitations = response.calls
            observedCallStatuses = Dictionary(uniqueKeysWithValues: response.calls.map { ($0.id, $0.status) })
            if let incoming = incomingCall, oldStatuses[incoming.id] == nil {
                NSSound(named: NSSound.Name("Glass"))?.play()
                attentionRequest = NSApp.requestUserAttention(.criticalRequest)
            }
            if incomingCall == nil, let attentionRequest {
                NSApp.cancelUserAttentionRequest(attentionRequest)
                self.attentionRequest = nil
            }
            if let activeRoom, !busy {
                let links = response.calls.filter { $0.room.id == activeRoom.id }
                if !links.isEmpty && links.allSatisfy({ ["cancelled", "declined", "expired"].contains($0.status) }) {
                    callMessage = "Call ended."
                    await leave()
                }
            }
            for invitation in response.calls where invitation.caller.id == currentUser.id {
                guard oldStatuses[invitation.id] == "pending", invitation.status != "pending" else { continue }
                if invitation.status == "accepted", activeRoom?.id == invitation.room.id {
                    callMessage = "\(invitation.target.name) accepted your call."
                    if autoVoiceCallID == invitation.id { await startAutoVoice() }
                } else if ["declined", "expired", "cancelled"].contains(invitation.status) {
                    callMessage = invitation.status == "declined" ? "\(invitation.target.name) declined the call." : "Call to \(invitation.target.name) ended unanswered."
                    if activeRoom?.id == invitation.room.id, rtc.participants.count <= 1, outgoingCalls.isEmpty { await leave() }
                }
            }
        } catch {
            // Directory heartbeat handles authentication/server errors. Polling resumes on the next tick.
        }
    }

    func call(_ person: TeamUser) async {
        guard !busy, user != nil, person.online == true else { return }
        if activeRoom != nil, !canAddPerson { error = "This call is limited to four people."; return }
        busy = true
        defer { busy = false }
        callMessage = nil
        struct Body: Encodable { let userId: String; let roomId: String? }
        do {
            let response: CallResponse = try await api.post("v1/calls", body: Body(userId: person.id, roomId: activeRoom?.id))
            callInvitations.removeAll { $0.id == response.call.id }
            callInvitations.append(response.call)
            observedCallStatuses[response.call.id] = "pending"
            if activeRoom == nil {
                autoVoiceCallID = response.call.id
                await joinInternal(response.call.room)
                if activeRoom == nil { try? await api.send("v1/calls/\(response.call.id)/cancel", body: EmptyBody()) }
            }
            await refreshInvitations()
            if autoVoiceCallID == response.call.id, activeRoom?.id == response.call.room.id,
               callInvitations.contains(where: { $0.room.id == response.call.room.id && $0.status == "accepted" }) {
                await startAutoVoice()
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Enables the microphone once for a call this client started, unless the
    /// person chose to start calls muted.
    private func startAutoVoice() async {
        guard autoVoiceCallID != nil, activeRoom != nil else { return }
        autoVoiceCallID = nil
        guard !startCallsMuted, !rtc.isMicrophoneEnabled else { return }
        do { try await rtc.setMicrophoneEnabled(true) }
        catch { self.error = error.localizedDescription }
    }

    func acceptCall(_ invitation: CallInvitation) async {
        guard !busy, activeRoom == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let response: CallResponse = try await api.post("v1/calls/\(invitation.id)/accept", body: EmptyBody())
            await joinInternal(response.call.room)
            if activeRoom != nil && !startCallsMuted { try await rtc.setMicrophoneEnabled(true) }
        } catch { self.error = error.localizedDescription }
        await refreshInvitations()
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        autoVoiceCallID = nil
        try await rtc.setMicrophoneEnabled(enabled)
    }

    func declineCall(_ invitation: CallInvitation) async {
        guard !busy else { return }
        do { try await api.send("v1/calls/\(invitation.id)/decline", body: EmptyBody()); await refreshInvitations() }
        catch { self.error = error.localizedDescription }
    }

    func cancelCall(_ invitation: CallInvitation) async {
        do {
            try await api.send("v1/calls/\(invitation.id)/cancel", body: EmptyBody())
            await refreshInvitations()
            if rtc.participants.count <= 1, outgoingCalls.isEmpty { await leave() }
        } catch { self.error = error.localizedDescription }
    }

    func createRoom(name: String) async {
        guard !busy else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Enter a room name."; return }
        busy = true
        defer { busy = false }
        struct Body: Encodable { let name: String }
        do {
            let response: RoomResponse = try await api.post("v1/rooms", body: Body(name: clean))
            rooms.append(response.room)
            await joinInternal(response.room)
        } catch { self.error = error.localizedDescription }
    }

    func join(_ room: PairRoom) async {
        guard !busy, activeRoom?.id != room.id else { return }
        busy = true
        defer { busy = false }
        await joinInternal(room)
    }

    private func joinInternal(_ room: PairRoom) async {
        error = nil
        generation += 1
        let attempt = generation
        await leave()
        guard let user else { return }
        do {
            let join: JoinResponse = try await api.post("v1/rooms/\(room.id)/join", body: EmptyBody())
            try await rtc.connect(url: join.url, token: join.token, identity: join.participantIdentity, name: user.name)
            guard generation == attempt else { await rtc.disconnect(); return }
            transcripts.clear()
            activeRoom = join.room
            callStartedAt = Date()
            // Join already refreshed this member's reservation. Update the
            // roster without holding up the microphone behind three more
            // API round trips.
            Task { await self.refresh() }
        } catch {
            await rtc.disconnect()
            try? await api.send("v1/rooms/\(room.id)/leave", body: EmptyBody())
            self.error = error.localizedDescription
        }
    }

    func leave() async {
        transcripts.setEnabled(false)
        transcripts.clear()
        hadRemoteParticipant = false
        let room = activeRoom
        activeRoom = nil
        callStartedAt = nil
        screenClaimRoomID = nil
        await rtc.disconnect()
        if let room { try? await api.send("v1/rooms/\(room.id)/leave", body: EmptyBody()) }
    }

    func shareScreen() async {
        guard !busy, let room = activeRoom else { return }
        busy = true
        defer { busy = false }
        struct Body: Encodable { let enabled: Bool }
        do {
            let filter = try await SystemScreenPicker.shared.chooseDisplay()
            try await api.send("v1/rooms/\(room.id)/share", body: Body(enabled: true))
            screenClaimRoomID = room.id
            try await rtc.startScreenShare(contentFilter: filter)
        } catch {
            try? await releaseScreenClaim()
            if (error as? CocoaError)?.code != .userCancelled { self.error = error.localizedDescription }
        }
    }

    func changeScreenSource() async {
        guard !busy, let room = activeRoom, rtc.isSharing else { return }
        busy = true
        defer { busy = false }
        do {
            // Pick first so canceling leaves the current share untouched.
            let filter = try await SystemScreenPicker.shared.chooseDisplay()
            await rtc.stopScreenShare()
            guard !rtc.isSharing else { throw APIError(status: 0, message: "The current screen share could not be stopped safely.") }
            try await rtc.startScreenShare(contentFilter: filter)
            screenClaimRoomID = room.id
        } catch {
            if (error as? CocoaError)?.code != .userCancelled {
                self.error = "Could not change the shared source: \(error.localizedDescription)"
                if !rtc.isSharing { try? await releaseScreenClaim() }
            }
        }
    }

    func stopSharing() async {
        await rtc.stopScreenShare()
        guard !rtc.isSharing else { return }
        do { try await releaseScreenClaim() }
        catch { self.error = error.localizedDescription }
    }

    private func releaseScreenClaim() async throws {
        guard let roomID = screenClaimRoomID else { return }
        struct Body: Encodable { let enabled: Bool }
        try await api.send("v1/rooms/\(roomID)/share", body: Body(enabled: false))
        if screenClaimRoomID == roomID { screenClaimRoomID = nil }
    }

    func changePassword(current: String, new: String) async -> Bool {
        struct Body: Encodable { let currentPassword: String; let newPassword: String }
        do {
            try await api.send("v1/password", body: Body(currentPassword: current, newPassword: new))
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func createMember(name: String, email: String, password: String) async throws {
        struct Body: Encodable { let name: String; let email: String; let password: String }
        let _: MeResponse = try await api.post("v1/admin/users", body: Body(name: name, email: email, password: password))
        await refresh()
        try await refreshAdminUsers()
    }

    func refreshAdminUsers() async throws {
        let response: UsersResponse = try await api.request("v1/admin/users")
        adminUsers = response.users
    }

    func setTeamMemberEnabled(_ member: TeamUser, enabled: Bool) async throws {
        struct Body: Encodable { let enabled: Bool }
        try await api.send("v1/admin/users/\(member.id)/enabled", body: Body(enabled: enabled))
        try await refreshAdminUsers()
        await refresh()
    }

    func resetTeamMemberPassword(_ member: TeamUser, newPassword: String) async throws {
        struct Body: Encodable { let newPassword: String }
        try await api.send("v1/admin/users/\(member.id)/password", body: Body(newPassword: newPassword))
        try await refreshAdminUsers()
    }
}
