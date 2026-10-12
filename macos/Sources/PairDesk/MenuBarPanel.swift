import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("PairDesk", systemImage: "rectangle.on.rectangle").font(.headline)
                Spacer()
                if let user = store.user {
                    Text(user.initials).font(.caption.bold()).frame(width: 27, height: 27)
                        .background(Circle().fill(Color.purple.opacity(0.22)))
                        .help(user.name)
                }
                Menu {
                    Button("Permissions…") { show("permissions") }
                    if store.user != nil { Button("Account settings…") { show("account") } }
                    Toggle("Start at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                    Toggle("Start calls muted", isOn: $store.startCallsMuted)
                    if loginItem.needsApproval { Button("Approve automatic startup…") { loginItem.openSettings() } }
                    Divider()
                    Button("Quit PairDesk") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
            }
            if store.user == nil {
                Text(store.busy ? "Restoring your session…" : "Sign in to call your team.").foregroundStyle(.secondary)
                Button("Sign in") { show("main") }.disabled(store.busy)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(store.directoryStatus == "Team connected" ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(store.directoryStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(teammates.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if let incoming = store.incomingCall {
                    Text("\(incoming.caller.name) is calling").bold()
                    HStack {
                        Button("Decline") { Task { await store.declineCall(incoming) } }
                        Button("Accept") { Task { await store.acceptCall(incoming) } }.buttonStyle(.borderedProminent)
                    }.disabled(store.busy)
                    Divider()
                }
                ForEach(store.outgoingCalls) { invitation in
                    HStack { ProgressView().controlSize(.small); Text("Calling \(invitation.target.name)…").font(.caption); Spacer(); Button("Cancel") { Task { await store.cancelCall(invitation) } } }
                }
                if store.activeRoom != nil {
                    // While ringing, nobody else has joined yet; an empty Text
                    // would still reserve a line and leave a gap in the panel.
                    let remoteNames = rtc.participants.filter { !$0.isLocal }.map(\.name)
                    if !remoteNames.isEmpty {
                        Text(remoteNames.joined(separator: ", ")).font(.subheadline.bold()).lineLimit(2)
                    }
                    if rtc.isReconnecting {
                        Label(rtc.isSharing ? "Reconnecting · control paused" : "Reconnecting call…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button { Task { do { try await store.setMicrophoneEnabled(!rtc.isMicrophoneEnabled) } catch { store.error = error.localizedDescription } } } label: { Label(rtc.isMicrophoneEnabled ? "Mute" : "Unmute", systemImage: rtc.isMicrophoneEnabled ? "mic.fill" : "mic.slash") }
                        if rtc.isMicrophoneEnabled {
                            ProgressView(value: rtc.localMicrophoneLevel).frame(width: 42).help("Local microphone level; audio is not recorded by the meter")
                        }
                        Button(rtc.isSharing ? "Stop sharing" : "Share screen") { if rtc.isSharing { Task { await store.stopSharing() } } else { show("share") } }
                        if rtc.isSharing {
                            Button("Change source…") { Task { await store.changeScreenSource() } }.disabled(store.busy)
                        }
                        Menu {
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
                        } label: { Label("Audio", systemImage: "hifispeaker") }
                        .help("Choose microphone and speaker")
                    }
                    if !permissions.microphone && !rtc.isMicrophoneEnabled {
                        Button("Microphone access needed to talk…") { show("permissions") }.font(.caption)
                    }
                    if rtc.isSharing {
                        if let controller = rtc.activeControllerIdentity {
                            Label("\(rtc.participantName(for: controller)) is controlling your Mac", systemImage: "cursorarrow.motionlines")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if rtc.remoteControlAvailable && rtc.automaticControlEnabled {
                            Text("Remote control is ready when a teammate interacts").font(.caption).foregroundStyle(.secondary)
                        }
                        if rtc.remoteControlAvailable {
                            Button(rtc.automaticControlEnabled ? "Stop control" : "Allow control again") { if rtc.automaticControlEnabled { rtc.pauseRemoteControl() } else { rtc.resumeRemoteControl() } }
                                .disabled(rtc.isReconnecting)
                        } else if rtc.isSharingWindow {
                            Text("Window sharing is view-only").font(.caption).foregroundStyle(.secondary)
                        } else if !permissions.accessibility {
                            Button("Set up remote control…") { show("permissions") }.font(.caption)
                        } else {
                            Text("Remote control unavailable for this share").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        if rtc.screenTrack != nil && !rtc.isSharing { Button("Show shared screen") { show("screen") } }
                        Spacer()
                        Button("Hang up") { Task { await store.leave() } }.tint(.red)
                    }
                    Divider()
                    Text(store.canAddPerson ? "ADD PERSON TO THIS CALL" : "CALL FULL · FOUR PEOPLE").font(.caption2).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search contacts…", text: $searchText).textFieldStyle(.plain)
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))

                        if filteredTeammates.isEmpty {
                            VStack(spacing: 7) {
                                Text(store.directoryStatus == "Team connected" ? (searchText.isEmpty ? "No teammates yet" : "No matching teammates") : "Loading teammates…")
                                    .font(.caption).foregroundStyle(.secondary)
                                if store.directoryStatus == "Team connected" {
                                    Button("Refresh contacts") { Task { await store.refresh() } }.font(.caption)
                                }
                            }.frame(maxWidth: .infinity).frame(minHeight: 76)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    if !onlineTeammates.isEmpty {
                                        contactSection("ONLINE", people: onlineTeammates)
                                    }
                                    if !offlineTeammates.isEmpty {
                                        contactSection("OFFLINE", people: offlineTeammates)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Take the list's real height, scrolling only past the
                            // cap. The menu bar window settles on the panel's minimum
                            // height, so an estimate (it was 48 pt per contact,
                            // ignoring section headers) clipped short rosters.
                            .frame(maxHeight: 420)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Text("Roster refreshes automatically").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button { Task { await store.refresh() } } label: {
                                Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh contacts")
                            }.buttonStyle(.plain).help("Refresh contacts")
                        }
                    }
                }
                if let message = store.callMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = store.error ?? rtc.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Dismiss message") { store.error = nil }
                }
            }
        }.padding(18).frame(width: 360).tint(.purple).onAppear {
            if store.user != nil { Task { await store.refresh() } }
        }.task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
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
    @ViewBuilder
    private func contactSection(_ title: String, people: [TeamUser]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
            ForEach(people) { person in
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        Text(person.initials).font(.caption2.bold()).foregroundStyle(person.online == true ? Color.purple : Color.secondary)
                            .frame(width: 30, height: 30).background(Circle().fill(Color.primary.opacity(0.07)))
                        Circle().fill(person.online == true ? (person.busy == true ? Color.orange : Color.green) : Color.gray)
                            .frame(width: 8, height: 8).overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5)).offset(x: 2, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.system(size: 13, weight: .medium)).foregroundStyle(person.online == true ? .primary : .secondary).lineLimit(1)
                        Text(status(person)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if canCall(person) {
                        Button(store.activeRoom == nil ? "Call" : "Add") { Task { await store.call(person) } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    } else if person.online == true && person.busy == true {
                        Text("Busy").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
        }
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
        VStack(spacing: 20) {
            Image(systemName: "phone.arrow.down.left").font(.system(size: 32))
            Text("\(store.incomingCall?.caller.name ?? "Your teammate") is calling").font(.title3.bold())
            HStack(spacing: 20) {
                Button("Decline") { if let call = store.incomingCall { Task { await store.declineCall(call) } } }
                Button("Accept call") { if let call = store.incomingCall { Task { await store.acceptCall(call) } } }.buttonStyle(.borderedProminent)
            }.disabled(store.busy || store.incomingCall == nil)
        }.padding(30).frame(width: 360)
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
