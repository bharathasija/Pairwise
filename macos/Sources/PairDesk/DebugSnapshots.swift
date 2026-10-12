#if DEBUG
import AppKit
import SwiftUI

/// Renders key screens with fixture data to PNG files so UI changes can be
/// reviewed without a server, a call, or clicking through the menu bar.
/// Debug builds only:
///
///     PAIRDESK_SNAPSHOT_DIR=/tmp/pairdesk-shots swift run
///
/// The app exits after rendering and never calls AppRuntime.start(), so it
/// does not read the saved session. Fixture stores point at an invalid server
/// address, so a view's refresh fails locally instead of reaching a server
/// (a 401 there would clear the saved session).
@MainActor
enum UISnapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loginItem = LoginItemManager()
        let me = TeamUser(id: "me", name: "Bharat Hasija", email: "bharat@example.com", online: true, busy: false, admin: true, enabled: true)
        let harshit = TeamUser(id: "harshit", name: "Harshit", email: "harshit@example.com", online: true, busy: false, enabled: true)
        let team = [
            me, harshit,
            TeamUser(id: "alex", name: "Alex Rivera", email: "alex@example.com", online: true, busy: true, enabled: true),
            TeamUser(id: "sam", name: "Sam Lee", email: "sam@example.com", online: false, busy: false, enabled: true)
        ]
        let room = PairRoom(id: "room", name: "Direct call", participantCount: 1, participants: [])
        func store(_ configure: (AppStore) -> Void = { _ in }) -> AppStore {
            let store = AppStore()
            store.serverAddress = "snapshot.invalid"
            configure(store)
            return store
        }
        func invitation(from caller: TeamUser, to target: TeamUser) -> CallInvitation {
            CallInvitation(id: "call-\(caller.id)-\(target.id)", status: "pending", caller: caller, target: target, room: room, expiresAt: "")
        }

        let signedOut = store()
        let idle = store { $0.user = me; $0.users = team; $0.directoryStatus = "Team connected" }
        let ringing = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room; $0.callInvitations = [invitation(from: me, to: harshit)]
        }
        let incoming = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.callInvitations = [invitation(from: harshit, to: me)]
        }

        snapshot("menu-signed-out", to: directory) { MenuBarPanel(store: signedOut, rtc: signedOut.rtc, loginItem: loginItem) }
        snapshot("menu-roster", to: directory, compact: true) { MenuBarPanel(store: idle, rtc: idle.rtc, loginItem: loginItem) }
        let pair = store {
            $0.user = me; $0.directoryStatus = "Team connected"
            $0.users = [me, harshit, TeamUser(id: "saurab", name: "Saurab", email: "saurab@example.com", online: false, busy: false, enabled: true)]
        }
        snapshot("menu-roster-two", to: directory, compact: true) { MenuBarPanel(store: pair, rtc: pair.rtc, loginItem: loginItem) }
        let crowd = store {
            $0.user = me; $0.directoryStatus = "Team connected"
            $0.users = [me] + (1...14).map { TeamUser(id: "t\($0)", name: "Teammate \($0)", email: "t\($0)@example.com", online: $0 <= 6, busy: $0 == 2, enabled: true) }
        }
        snapshot("menu-roster-many", to: directory, compact: true) { MenuBarPanel(store: crowd, rtc: crowd.rtc, loginItem: loginItem) }
        snapshot("menu-ringing", to: directory) { MenuBarPanel(store: ringing, rtc: ringing.rtc, loginItem: loginItem) }
        snapshot("menu-incoming", to: directory) { MenuBarPanel(store: incoming, rtc: incoming.rtc, loginItem: loginItem) }
        snapshot("window-incoming-call", to: directory) { IncomingCallView(store: incoming) }
        snapshot("window-sign-in", to: directory) { RootView(store: signedOut).environmentObject(loginItem) }
        snapshot("window-signed-in", to: directory) { RootView(store: idle).environmentObject(loginItem) }
        snapshot("window-permissions", to: directory) { PermissionsView() }
        snapshot("window-account", to: directory) { AccountView(store: idle).environmentObject(loginItem) }
        snapshot("window-share-picker", to: directory) { ScreenSharePickerView(store: ringing) }
        snapshot("window-shared-screen", to: directory, size: CGSize(width: 1000, height: 620)) {
            SharedScreenWindow(store: ringing, rtc: ringing.rtc, transcripts: ringing.transcripts)
        }
        print("Rendered UI snapshots to \(directory.path)")
    }

    /// `compact` renders at the smallest height the view accepts, which is
    /// what MenuBarExtra's window settles on; ideal-height renders hide
    /// views that collapse there.
    private static func snapshot<V: View>(_ name: String, to directory: URL, size: CGSize? = nil, compact: Bool = false, @ViewBuilder _ content: () -> V) {
        let view = content()
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let ideal = host.fittingSize
        let compactSize = compact ? NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: ideal.width, height: 0)) : ideal
        let frame = NSRect(origin: .zero, size: size ?? compactSize)
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { window.close() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        do { try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png")) }
        catch { print("Could not write \(name).png: \(error.localizedDescription)") }
    }
}
#endif
