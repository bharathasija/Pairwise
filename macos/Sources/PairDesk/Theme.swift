import AppKit
import SwiftUI

/// Design tokens and shared controls. Views use these rather than ad-hoc
/// colors or stock button styles; see .claude/rules/macos-ui.md.
enum Theme {
    static let panelWidth: CGFloat = 400
    static let cornerRadius: CGFloat = 8

    static let accent = Color(red: 0x6A / 255, green: 0x5E / 255, blue: 0xD9 / 255)
    static let surface = dynamic(dark: (0x27, 0x27, 0x2A), light: (0xFA, 0xFA, 0xFA))
    static let surfaceRaised = dynamic(dark: (0x3F, 0x3F, 0x46), light: (0xE4, 0xE4, 0xE7))
    static let textMuted = dynamic(dark: (0xA1, 0xA1, 0xAA), light: (0x71, 0x71, 0x7A))
    static let online = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    static let attention = Color(red: 0xCC / 255, green: 0x7C / 255, blue: 0x2E / 255)
    static let danger = Color(red: 0xCA / 255, green: 0x3A / 255, blue: 0x31 / 255)

    /// One stable color per person, shared by avatars and remote cursors.
    static func personColor(for id: String) -> Color {
        let palette: [Color] = [
            Color(red: 0x4C / 255, green: 0xA8 / 255, blue: 0x6B / 255),
            Color(red: 0x7C / 255, green: 0x6C / 255, blue: 0xE8 / 255),
            Color(red: 0xD9 / 255, green: 0x7A / 255, blue: 0x5B / 255),
            Color(red: 0xD4 / 255, green: 0xB0 / 255, blue: 0x3A / 255),
            Color(red: 0x5A / 255, green: 0x8E / 255, blue: 0xD0 / 255),
            Color(red: 0x3F / 255, green: 0xA9 / 255, blue: 0xA6 / 255)
        ]
        let hash = id.utf8.reduce(UInt64(2_166_136_261)) { ($0 ^ UInt64($1)) &* 16_777_619 }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func initials(for name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    private static func dynamic(dark: (Int, Int, Int), light: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        })
    }
}

enum Presence { case online, busy, offline }

/// Rounded-square avatar in lists; circular with an accent ring for calls.
struct PersonAvatar: View {
    let name: String
    let id: String
    var size: CGFloat = 32
    var presence: Presence?
    var circular = false
    var ring = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(Theme.initials(for: name))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.personColor(for: id), in: RoundedRectangle(cornerRadius: circular ? size / 2 : size * 0.28))
                .overlay {
                    if ring && circular {
                        Circle().stroke(Theme.accent, lineWidth: 2).padding(-4)
                    } else if ring {
                        RoundedRectangle(cornerRadius: size * 0.28 + 4).stroke(Theme.accent, lineWidth: 2).padding(-4)
                    }
                }
            if let presence {
                RoundedRectangle(cornerRadius: 3)
                    .fill(presence == .online ? Theme.online : presence == .busy ? Theme.attention : Theme.textMuted.opacity(0.6))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.surface, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 5 : 7)
            .background(Theme.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Color.primary.opacity(0.08)))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct DangerButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : Theme.danger)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(filled ? Theme.danger.opacity(configuration.isPressed ? 0.8 : 1) : Theme.danger.opacity(configuration.isPressed ? 0.15 : 0),
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.danger.opacity(filled ? 0 : 0.7)))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A large in-call action with a chevron menu for its options, like Tuple's
/// "Mute me" and "Share screen" tiles.
struct CallTile<MenuItems: View>: View {
    let title: String
    let systemImage: String
    var highlight: Color?
    var level: Double?
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: systemImage).font(.system(size: 18, weight: .medium)).frame(height: 20)
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let level {
                        GeometryReader { geometry in
                            Capsule().fill(Color.white.opacity(0.25))
                                .overlay(alignment: .leading) { Capsule().fill(Theme.online).frame(width: geometry.size.width * min(max(level, 0), 1)) }
                        }.frame(width: 40, height: 3)
                    }
                }
                // Fixed height so tiles with and without a level bar line up.
                .frame(maxWidth: .infinity).frame(height: 50).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 30)
            Menu { menu() } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 44).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .foregroundStyle(highlight == nil ? Color.primary : Color.white)
        .background(highlight ?? Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity)
    }
}
