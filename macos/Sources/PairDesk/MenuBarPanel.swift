import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var addingPerson = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.user == nil {
                Text(store.busy ? "Restoring your session…" : "Sign in to call your team.").foregroundStyle(Theme.textMuted)
                Button("Sign in") { show("main") }.buttonStyle(PrimaryButtonStyle()).disabled(store.busy)
            } else {
                statusRow
                if let incoming = store.incomingCall { incomingCall(incoming) }
                if store.activeRoom != nil { inCall } else { roster }
                if let message = store.callMessage { Text(message).font(.caption).foregroundStyle(Theme.textMuted) }
                if let error = store.error ?? rtc.error {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Dismiss") { store.error = nil }.buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
            }
        }
        .padding(16).frame(width: Theme.panelWidth)
        .background(Theme.surface)
        .tint(Theme.accent)
        .onAppear { if store.user != nil { Task { await store.refresh() } } }
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }

    // MARK: Header and status

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            Text("PairDesk").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let user = store.user { PersonAvatar(name: user.name, id: user.id, size: 26).help(user.name) }
            Menu {
                Button("Permissions…") { show("permissions") }
                if store.user != nil { Button("Account settings…") { show("account") } }
                Toggle("Start at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                Toggle("Start calls muted", isOn: $store.startCallsMuted)
                if loginItem.needsApproval { Button("Approve automatic startup…") { loginItem.openSettings() } }
                Divider()
                Button("Quit PairDesk") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Theme.textMuted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Settings").accessibilityLabel("Settings")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(teamConnected ? Theme.online : Theme.attention).frame(width: 6, height: 6)
            Text(store.directoryStatus).font(.caption).foregroundStyle(Theme.textMuted)
            Spacer()
            if store.activeRoom == nil {
                Text("\(teammates.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textMuted)
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(Theme.textMuted)
                }.buttonStyle(.plain).help("Refresh contacts").accessibilityLabel("Refresh contacts")
            }
        }
    }

    private var teamConnected: Bool { store.directoryStatus == "Team connected" }

    private func incomingCall(_ incoming: CallInvitation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PersonAvatar(name: incoming.caller.name, id: incoming.caller.id, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(incoming.caller.name).font(.system(size: 13, weight: .semibold))
                    Text("Incoming call…").font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Decline") { Task { await store.declineCall(incoming) } }.buttonStyle(DangerButtonStyle())
                Button("Accept") { Task { await store.acceptCall(incoming) } }.buttonStyle(PrimaryButtonStyle())
            }.disabled(store.busy)
            Divider()
        }
    }

    // MARK: In a call

    private var inCall: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(rtc.isSharing || rtc.screenTrack != nil ? "Screen share" : "Audio call").font(.system(size: 13, weight: .semibold))
                if let started = store.callStartedAt {
                    Text("·").foregroundStyle(Theme.textMuted)
                    Text(started, style: .timer).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if rtc.isReconnecting {
                    Label(rtc.isSharing ? "Reconnecting · control paused" : "Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(Theme.attention).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rtc.participants.filter { !$0.isLocal }) { person in
                    HStack(spacing: 10) {
                        PersonAvatar(name: person.name, id: person.identity, size: 28)
                        Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer()
                        if person.isSpeaking { Image(systemName: "waveform").font(.caption).foregroundStyle(Theme.online) }
                    }
                }
                ForEach(store.outgoingCalls) { invitation in
                    HStack(spacing: 10) {
                        PersonAvatar(name: invitation.target.name, id: invitation.target.id, size: 28).opacity(0.6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(invitation.target.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("Calling…").font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button("Cancel") { Task { await store.cancelCall(invitation) } }.buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
            }
            HStack(spacing: 8) {
                CallTile(title: rtc.isMicrophoneEnabled ? "Mute me" : "Unmute me",
                         systemImage: rtc.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                         highlight: rtc.isMicrophoneEnabled ? nil : Theme.attention,
                         level: rtc.isMicrophoneEnabled ? rtc.localMicrophoneLevel : nil,
                         action: { Task { do { try await store.setMicrophoneEnabled(!rtc.isMicrophoneEnabled) } catch { store.error = error.localizedDescription } } }) {
                    audioDeviceMenu
                }
                CallTile(title: rtc.isSharing ? "Stop sharing" : "Share screen",
                         systemImage: rtc.isSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                         highlight: rtc.isSharing ? Theme.accent : nil,
                         action: { if rtc.isSharing { Task { await store.stopSharing() } } else { show("share") } }) {
                    if rtc.isSharing {
                        Button("Change source…") { Task { await store.changeScreenSource() } }.disabled(store.busy)
                    } else if rtc.screenTrack != nil {
                        Button("Show shared screen") { show("screen") }
                    } else {
                        Text("Choose a display or window when you share")
                    }
                }
            }
            if !permissions.microphone && !rtc.isMicrophoneEnabled {
                Button("Microphone access needed to talk…") { show("permissions") }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            }
            if rtc.isSharing { sharingStatus }
            Divider()
            HStack {
                if store.canAddPerson {
                    Button { addingPerson.toggle() } label: { Label(addingPerson ? "Done" : "Add person", systemImage: addingPerson ? "checkmark" : "person.badge.plus") }
                        .buttonStyle(QuietButtonStyle())
                } else {
                    Text("Call is full · four people").font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("End call") { Task { await store.leave() } }.buttonStyle(DangerButtonStyle())
            }
            if addingPerson && store.canAddPerson {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("Add to this call")
                    if store.availablePeople.isEmpty {
                        Text("No one else is available right now").font(.caption).foregroundStyle(Theme.textMuted).padding(.horizontal, 8)
                    }
                    ForEach(store.availablePeople) { person in contactRow(person) }
                }
            }
        }
    }

    @ViewBuilder
    private var audioDeviceMenu: some View {
        Section("Microphone") {
            if rtc.savedAudioInputUnavailable { Text("Saved microphone unavailable; using system default") }
            if rtc.audioInputDevices.isEmpty { Text("No microphones found") }
            ForEach(rtc.audioInputDevices) { device in
                Button { rtc.selectAudioInput(device.deviceId) } label: {
                    if rtc.selectedAudioInputID == device.deviceId { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        }
        Section("Speaker") {
            if rtc.savedAudioOutputUnavailable { Text("Saved speaker unavailable; using system default") }
            if rtc.audioOutputDevices.isEmpty { Text("System default") }
            ForEach(rtc.audioOutputDevices) { device in
                Button { rtc.selectAudioOutput(device.deviceId) } label: {
                    if rtc.selectedAudioOutputID == device.deviceId { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        }
    }

    private var sharingStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let controller = rtc.activeControllerIdentity {
                Label("\(rtc.participantName(for: controller)) is controlling your Mac", systemImage: "cursorarrow.motionlines")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            } else if rtc.remoteControlAvailable && rtc.automaticControlEnabled {
                Label("Teammates can control when they click or type", systemImage: "cursorarrow").font(.caption).foregroundStyle(Theme.textMuted)
            }
            if rtc.remoteControlAvailable {
                Button(rtc.automaticControlEnabled ? "Stop control" : "Allow control again") {
                    if rtc.automaticControlEnabled { rtc.pauseRemoteControl() } else { rtc.resumeRemoteControl() }
                }.buttonStyle(QuietButtonStyle(compact: true)).disabled(rtc.isReconnecting)
            } else if rtc.isSharingWindow {
                Text("Window sharing is view-only").font(.caption).foregroundStyle(Theme.textMuted)
            } else if !permissions.accessibility {
                Button("Set up remote control…") { show("permissions") }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            } else {
                Text("Remote control unavailable for this share").font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: Roster

    private var roster: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search people…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

            if filteredTeammates.isEmpty {
                VStack(spacing: 7) {
                    Text(teamConnected ? (searchText.isEmpty ? "No teammates yet" : "No matching teammates") : "Loading teammates…")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                    if teamConnected { Button("Refresh") { Task { await store.refresh() } }.buttonStyle(QuietButtonStyle(compact: true)) }
                }.frame(maxWidth: .infinity).frame(minHeight: 76)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !onlineTeammates.isEmpty { contactSection("Online", people: onlineTeammates) }
                        if !offlineTeammates.isEmpty { contactSection("Offline", people: offlineTeammates) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                // Take the list's real height, scrolling only past the cap. The
                // menu bar window settles on the panel's minimum height, so an
                // estimate clipped short rosters.
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var teammates: [TeamUser] {
        store.users.filter { $0.id != store.user?.id }.sorted {
            if ($0.online == true) != ($1.online == true) { return $0.online == true }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    private var filteredTeammates: [TeamUser] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return teammates }
        return teammates.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query) }
    }
    private var onlineTeammates: [TeamUser] { filteredTeammates.filter { $0.online == true } }
    private var offlineTeammates: [TeamUser] { filteredTeammates.filter { $0.online != true } }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted).padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func contactSection(_ title: String, people: [TeamUser]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(title)
            ForEach(people) { person in contactRow(person) }
        }
    }

    private func contactRow(_ person: TeamUser) -> some View {
        let online = person.online == true
        return HStack(spacing: 10) {
            PersonAvatar(name: person.name, id: person.id, size: 32, presence: presence(person)).opacity(online ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.system(size: 13, weight: .medium)).foregroundStyle(online ? Color.primary : Theme.textMuted).lineLimit(1)
                Text(status(person)).font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 4)
            if canCall(person) {
                Button { Task { await store.call(person) } } label: {
                    Label(store.activeRoom == nil ? "Call" : "Add", systemImage: "phone.fill")
                }.buttonStyle(QuietButtonStyle(compact: true))
            }
        }
        .frame(height: 44).padding(.horizontal, 8).contentShape(Rectangle())
    }

    private func presence(_ person: TeamUser) -> Presence {
        person.online != true ? .offline : (person.busy == true ? .busy : .online)
    }
    private func status(_ person: TeamUser) -> String {
        if rtc.participants.contains(where: { $0.identity == person.id }) { return "In this call" }
        return person.online != true ? "Offline" : (person.busy == true ? "In a call" : "Online")
    }
    private func canCall(_ person: TeamUser) -> Bool {
        !store.busy && person.online == true && person.busy != true &&
        !rtc.participants.contains(where: { $0.identity == person.id }) &&
        !store.outgoingCalls.contains(where: { $0.target.id == person.id }) &&
        (store.activeRoom == nil || store.canAddPerson)
    }
    private func show(_ id: String) {
        if id == "permissions" {
            DispatchQueue.main.async { PermissionWindowController.shared.show() }
        } else { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
    }
}

struct IncomingCallView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        let caller = store.incomingCall?.caller
        VStack(spacing: 18) {
            PersonAvatar(name: caller?.name ?? "?", id: caller?.id ?? "", size: 72, circular: true, ring: true).padding(.top, 6)
            VStack(spacing: 4) {
                Text("Incoming call…").font(.caption).foregroundStyle(Theme.textMuted)
                Text(caller?.name ?? "Your teammate").font(.system(size: 18, weight: .semibold))
                if let email = caller?.email { Text(email).font(.caption).foregroundStyle(Theme.textMuted) }
            }
            HStack(spacing: 12) {
                Button { if let call = store.incomingCall { Task { await store.declineCall(call) } } } label: {
                    Label("Decline", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                }.buttonStyle(DangerButtonStyle(filled: true))
                Button { if let call = store.incomingCall { Task { await store.acceptCall(call) } } } label: {
                    Label("Accept", systemImage: "phone.fill").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle())
            }.disabled(store.busy || store.incomingCall == nil)
        }
        .padding(24).frame(width: 300)
        .background(Theme.surface)
        .background(FloatingPanelPlacement())
        .onChange(of: store.incomingCall?.id) { _, id in if id == nil { dismissWindow(id: "incoming") } }
    }
}

/// Shows the incoming-call window like a notification: top right, above other
/// apps' windows and on every Space. An accessory app's new window otherwise
/// opens behind the frontmost app, where a ringing call is easy to miss. It
/// does not activate the app, so typing elsewhere cannot answer the call.
private struct FloatingPanelPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingPanelView { FloatingPanelView() }
    func updateNSView(_ nsView: FloatingPanelView, context: Context) {}
}
@MainActor
private final class FloatingPanelView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        // Wait one turn so SwiftUI has sized the window before it is placed.
        DispatchQueue.main.async {
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - window.frame.width - 16, y: visible.maxY - 16))
            }
            window.orderFrontRegardless()
        }
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Image(systemName: store.incomingCall != nil ? "phone.arrow.down.left" : (store.activeRoom != nil ? "phone.fill" : "rectangle.on.rectangle"))
            .onChange(of: store.incomingCall?.id) { _, id in
                if id != nil { openWindow(id: "incoming") }
                else { dismissWindow(id: "incoming") }
            }
            .onChange(of: rtc.activeSharerIdentity) { _, identity in
                if identity != nil, !rtc.isSharing, rtc.screenTrack != nil { openWindow(id: "screen"); NSApp.activate(ignoringOtherApps: true) }
            }
            .onChange(of: store.activeRoom?.id) { _, id in
                if id == nil { dismissWindow(id: "screen"); dismissWindow(id: "share") }
            }
    }
}
