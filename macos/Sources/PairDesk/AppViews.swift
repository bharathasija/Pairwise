import SwiftUI
import AppKit
import LiveKit

struct RootView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Group {
            if store.user == nil { LoginView(store: store) }
            else { WorkspaceView(store: store, rtc: store.rtc, transcripts: store.transcripts) }
        }
        .tint(Theme.accent)
        .background(Theme.surface)
        .alert("PairDesk", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct LoginView: View {
    @ObservedObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var serverExpanded = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Logo(size: 44).padding(.top, 12) // clear of the hidden title bar's window buttons
            Text("Sign in to PairDesk").font(.system(size: 22, weight: .semibold))
            Text("Use the account your team created.").foregroundStyle(Theme.textMuted).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 8) {
                Text("EMAIL").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                TextField("you@team.com", text: $email).textFieldStyle(.roundedBorder).focused($focused)
            }.padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                Text("PASSWORD").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                SecureField("Your password", text: $password).textFieldStyle(.roundedBorder)
            }
            Button {
                let submitted = password
                password = ""
                Task { await store.login(email: email, password: submitted) }
            } label: {
                HStack { Spacer(); if store.busy { ProgressView().controlSize(.small) } else { Text("Sign in").fontWeight(.semibold); Image(systemName: "arrow.right") }; Spacer() }
                    .padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).disabled(store.busy || email.isEmpty || password.isEmpty)
                .keyboardShortcut(.defaultAction)
            DisclosureGroup("Server address", isExpanded: $serverExpanded) {
                TextField("https://pair.yourteam.com", text: $store.serverAddress).textFieldStyle(.roundedBorder).padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(Theme.textMuted).disabled(store.busy)
            Text("Need an account or password reset? Ask your team administrator.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }.padding(32).frame(width: 380)
            .onAppear { focused = true }
    }
}

struct SharedScreenWindow: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var transcripts: WhisperTranscriber
    @State private var showTranscript = false
    @State private var permissions = false
    @State private var sourcePicker = false
    private var shareStatus: String? {
        guard let sharer = rtc.activeSharerIdentity else { return nil }
        switch rtc.controlState {
        case .granted:
            return "You have control of \(rtc.participantName(for: sharer))'s Mac"
        case .requesting:
            return "Connecting remote control…"
        case .hostPermissionRequired:
            return "Ask \(rtc.participantName(for: sharer)) to enable Accessibility, then try again"
        case .viewer:
            let host = rtc.participantName(for: sharer)
            if rtc.remoteControlAvailable { return "Viewing \(host) · move or click to request control" }
            if let reason = rtc.remoteControlUnavailableReason { return "Viewing \(host) · \(reason.viewerDescription(host: host))" }
            return "Viewing \(host) · view only"
        case .host:
            return "You are sharing your display"
        case .unavailable:
            return "Shared screen · view only"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(rtc.participants.filter { !$0.isLocal }.map(\.name).joined(separator: ", ")).font(.headline).lineLimit(1)
                if rtc.isReconnecting {
                    Label(rtc.isSharing ? "Reconnecting · control paused" : "Reconnecting call…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                if let shareStatus {
                    Label(shareStatus, systemImage: rtc.controlState.isGranted ? "cursorarrow.motionlines" : "display")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if rtc.screenTrack != nil && !rtc.isSharing {
                    Label(rtc.screenNetworkQuality.label, systemImage: "waveform.path")
                        .font(.caption).foregroundStyle(networkQualityColor).lineLimit(1)
                        .help("Estimated shared-screen network round-trip time. This does not measure image readability or local CPU load.")
                }
                Spacer()
                Button { Task { do { try await store.setMicrophoneEnabled(!rtc.isMicrophoneEnabled) } catch { store.error = error.localizedDescription } } } label: { Image(systemName: rtc.isMicrophoneEnabled ? "mic.fill" : "mic.slash") }
                Button(rtc.isSharing ? "Stop sharing" : "Share screen") { if rtc.isSharing { Task { await store.stopSharing() } } else { sourcePicker = true } }
                if rtc.isSharing { Button("Change source…") { Task { await store.changeScreenSource() } }.disabled(store.busy) }
                Button { showTranscript.toggle() } label: { Image(systemName: "text.bubble") }.help("Local transcript")
                Button("Full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                Button("Hang up") { Task { await store.leave() } }.tint(.red)
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 9)
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let track = rtc.screenTrack, !rtc.isSharing {
                        InteractiveScreenView(track: track, rtc: rtc)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                if let dimensions = track.dimensions {
                                    GeometryReader { geometry in
                                        let contentSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                                        ForEach(rtc.remotePointers) { pointer in
                                            if let point = ScreenCoordinateMapper.displayedPoint(
                                                normalized: CGPoint(x: pointer.x, y: pointer.y),
                                                container: CGRect(origin: .zero, size: geometry.size),
                                                contentSize: contentSize
                                            ) {
                                                RemotePointerBadge(name: rtc.participantName(for: pointer.id), color: cursorColor(for: pointer.id))
                                                    .position(x: min(max(point.x + 54, 54), geometry.size.width - 54),
                                                              y: min(max(point.y + 14, 14), geometry.size.height - 14))
                                                    .transition(.opacity)
                                            }
                                        }
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: rtc.isSharing ? "display.and.arrow.up" : "phone").font(.system(size: 44))
                            Text(rtc.isSharing ? (rtc.isSharingWindow ? "Your window is shared" : "Your display is shared") : (store.activeRoom == nil ? "Call ended" : "Voice call connected"))
                            Text(rtc.isSharing ? (rtc.isSharingWindow ? "Window sharing is view-only. Use the menu bar to stop sharing." : "Your teammates can control your shared display. Use the menu bar to stop control.") : "Call controls and your team are in the PairDesk menu bar.").font(.caption).foregroundStyle(.secondary)
                        }.padding(30)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showTranscript { TranscriptPanel(transcriber: transcripts, rtc: rtc).frame(width: 275) }
            }
            if let error = rtc.error { HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button("Permissions") { permissions = true } }.padding(8) }
        }.background(Theme.surface).tint(Theme.accent)
        .task {
            while !Task.isCancelled {
                rtc.refreshScreenNetworkQuality()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .sheet(isPresented: $permissions) { PermissionsView() }
        .sheet(isPresented: $sourcePicker) { ScreenSharePickerView(store: store) }
        .alert("PairDesk", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }

    private func cursorColor(for identity: String) -> Color { Theme.personColor(for: identity) }

    private var networkQualityColor: Color {
        switch rtc.screenNetworkQuality {
        case .measuring: .secondary
        case .good: .green
        case .fair: .orange
        case .highLatency: .red
        }
    }
}

private struct RemotePointerBadge: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(.white)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.9), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
    }
}

struct ScreenSharePickerView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var screenPermission = PermissionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var permissions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share your screen").font(.title2.bold())
            Text("Choose a display in the macOS picker. PairDesk receives access only to that display for this sharing session; Screen Recording permission is not required.").font(.callout).foregroundStyle(.secondary)
            Label("Remote mouse and keyboard control needs Accessibility access on the Mac being shared. Screen sharing still works without it.", systemImage: "cursorarrow.motionlines")
                .font(.caption).foregroundStyle(.secondary)
            if !screenPermission.accessibility {
                Button("Set up remote control") { screenPermission.requestAccessibility() }
            }
            Spacer()
            HStack { Button("Permissions") { permissions = true }; Spacer(); Button("Cancel") { dismiss() }; Button("Choose display…") { beginSharing() }.buttonStyle(.borderedProminent).disabled(store.busy) }
        }.padding(26).frame(width: 560)
        .task { screenPermission.refresh() }
        .sheet(isPresented: $permissions) { PermissionsView() }
    }

    private func beginSharing() {
        dismiss()
        Task { await store.shareScreen() }
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var transcripts: WhisperTranscriber
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 46))
            Text("PairDesk lives in your menu bar").font(.title2.bold())
            Text("Click its icon at the top right of your screen to call a teammate, share a display, or manage a call.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            // Their own windows, as in the menu bar: these are taller than this
            // compact window, so sheets would hang off its bottom edge.
            HStack { Button("Permissions") { PermissionWindowController.shared.show() }; Button("Account settings") { openWindow(id: "account") } }
        }.padding(40).frame(width: 520)
    }
}

private struct TranscriptPanel: View {
    @ObservedObject var transcriber: WhisperTranscriber
    @ObservedObject var rtc: RTCService
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Local transcript").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Theme.accent) }
            Toggle("Transcribe on this Mac", isOn: Binding(get: { transcriber.enabled }, set: {
                transcriber.setEnabled($0)
                rtc.setAudioForwardingConsented(transcriber.enabled)
            })).toggleStyle(.switch).font(.system(size: 11))
            Text(transcriber.status).font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if transcriber.segments.isEmpty { Text("Speech will appear here when transcription is on. Tiny is fast, but may miss technical words.").font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.top, 20) }
                        ForEach(transcriber.segments) { segment in
                            VStack(alignment: .leading, spacing: 5) { HStack { Text(segment.speakerName).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent); Spacer(); Text(segment.createdAt, style: .time).font(.system(size: 9)).foregroundStyle(Theme.textMuted) }; Text(segment.text).font(.system(size: 12)).textSelection(.enabled).lineSpacing(3) }.id(segment.id)
                        }
                    }
                }.onChange(of: transcriber.segments.count) { _, _ in if let id = transcriber.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack { Button("Clear") { transcriber.clear() }.buttonStyle(.plain); Spacer(); Button("Export text") { export() }.buttonStyle(.plain).disabled(transcriber.segments.isEmpty) }.font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text("No upload. Not saved automatically.").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
        }.padding(20)
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pairdesk-transcript.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = transcriber.segments.map { "[\($0.createdAt.formatted(date: .omitted, time: .standard))] \($0.speakerName): \($0.text)" }.joined(separator: "\n\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
}

struct AccountView: View {
    @EnvironmentObject private var loginItem: LoginItemManager
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var addingMember = false
    @State private var managingTeam = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.user?.name ?? "Account").font(.title2.bold())
            Text(store.user?.email ?? "").foregroundStyle(.secondary)
            if store.user?.admin == true {
                Button("Create a team account") { addingMember = true }.buttonStyle(.bordered)
                Button("Manage team accounts…") { managingTeam = true }.buttonStyle(.bordered)
            }
            Divider()
            Toggle("Start PairDesk at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
            if let message = loginItem.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if loginItem.needsApproval { Button("Open Login Items settings") { loginItem.openSettings() } }
            Divider()
            Text("Change password").font(.headline)
            SecureField("Current password", text: $current).textFieldStyle(.roundedBorder)
            SecureField("New password (at least 12 characters)", text: $newPassword).textFieldStyle(.roundedBorder)
            SecureField("Confirm new password", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack { Button("Sign out") { dismiss(); Task { await store.logout() } }.disabled(store.busy || saving); Spacer(); Button("Close") { dismiss() }; Button(saving ? "Saving…" : "Save password") { saving = true; Task { let success = await store.changePassword(current: current, new: newPassword); saving = false; if success { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || current.isEmpty || newPassword.count < 12 || newPassword != confirmation) }
        }.padding(30).frame(width: 430)
            .sheet(isPresented: $addingMember) { CreateMemberView(store: store) }
            .sheet(isPresented: $managingTeam) { ManageTeamView(store: store) }
    }
}

private struct ManageTeamView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var resetMember: TeamUser?
    @State private var newPassword = ""
    @State private var saving = false
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Team accounts").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Disabling an account ends its sessions. Password resets also sign the member out; share the new password privately.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let message { Text(message).font(.caption).foregroundStyle(.green) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.adminUsers) { member in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.name).font(.system(size: 13, weight: .medium))
                                Text(member.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reset password") { resetMember = member; newPassword = ""; message = nil; error = nil }
                                .controlSize(.small)
                            Button(member.enabled == false ? "Enable" : "Disable") {
                                saving = true; error = nil; message = nil
                                Task {
                                    do { try await store.setTeamMemberEnabled(member, enabled: member.enabled == false); message = "Account updated." }
                                    catch { self.error = error.localizedDescription }
                                    saving = false
                                }
                            }.controlSize(.small).disabled(saving || (member.admin == true && member.enabled != false && store.adminUsers.filter { $0.admin == true && $0.enabled != false }.count <= 1))
                        }.padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minHeight: 180, maxHeight: 320)
            if let resetMember {
                Divider()
                Text("Reset password for \(resetMember.name)").font(.headline)
                SecureField("New password (12+ characters)", text: $newPassword).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { self.resetMember = nil; newPassword = "" }
                    Spacer()
                    Button(saving ? "Saving…" : "Set password") {
                        saving = true; error = nil; message = nil
                        Task {
                            do {
                                try await store.resetTeamMemberPassword(resetMember, newPassword: newPassword)
                                self.resetMember = nil; newPassword = ""; message = "Password reset; the member must sign in again."
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(saving || newPassword.count < 12)
                }
            }
        }.padding(24).frame(width: 620).task {
            do { try await store.refreshAdminUsers() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct CreateMemberView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?
    @State private var created = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create a team account").font(.title2.bold())
            Text("Give your teammate their email and initial password directly. They can change the password after signing in.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Full name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Email", text: $email).textFieldStyle(.roundedBorder)
            SecureField("Initial password (12+ characters)", text: $password).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.orange).font(.system(size: 12)) }
            if created { Label("Account created", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            HStack { Spacer(); Button("Close") { dismiss() }; Button(saving ? "Creating…" : "Create account") {
                saving = true
                error = nil
                Task {
                    do { try await store.createMember(name: name, email: email, password: password); password = ""; created = true }
                    catch { self.error = error.localizedDescription }
                    saving = false
                }
            }.buttonStyle(.borderedProminent).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || email.isEmpty || password.count < 12) }
        }.padding(30).frame(width: 430)
    }
}

private struct Logo: View {
    let size: CGFloat
    var body: some View { Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: size * 0.53, weight: .medium)).foregroundStyle(Theme.accent).frame(width: size, height: size).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26)) }
}
