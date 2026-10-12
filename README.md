<p align="center">
  <img src="assets/pairwise-logo.svg" width="280" alt="Pairwise logo">
</p>

# Pairwise

Pairwise is an open-source macOS pairing app for small teams. It combines direct teammate calls, voice, full-display sharing, and optional remote mouse and keyboard control. Calls use LiveKit; the account and presence service is a small Go API. Optional transcripts run locally with Whisper Tiny. There is no camera feature, cloud transcription, public signup, or external account integration.

The current client supports macOS 14 and later. It is an early-stage project; test it with non-sensitive accounts and machines before relying on it.

**Download the complete source:** [ZIP archive of the latest `main` branch](https://github.com/EvAlssment/Pairwise/archive/refs/heads/main.zip) · [browse the repository](https://github.com/EvAlssment/Pairwise)

**Download the [Pairwise 0.3.7 test DMG](https://github.com/EvAlssment/Pairwise/releases/download/pairwise-test-0.3.7/PairDesk-0.3.7-test.dmg)** · [checksum](https://github.com/EvAlssment/Pairwise/releases/download/pairwise-test-0.3.7/PairDesk-0.3.7-test.dmg.sha256). This Apple Silicon development build is ad-hoc signed and not notarized; Gatekeeper rejects it. Do not bypass Gatekeeper to install it. Wait for a signed and notarized release for normal use.

Installable macOS builds will be published under [GitHub Releases](https://github.com/EvAlssment/Pairwise/releases) once the release signing credentials are configured. See [the release guide](docs/releasing.md).

The ZIP contains the tracked source code and documentation. It is not an installable app; follow the build steps below to create a local macOS build. Whisper source and model files are downloaded separately by the preparation script and are not included in the repository.

## Screen sharing and macOS permissions

Pairwise uses Apple's native ScreenCaptureKit content-sharing picker. A person chooses a display in the macOS picker, and the app receives a capture filter for that selected display and session. Pairwise does not enumerate the desktop or ask for the broad Screen Recording permission. The picker still requires the person to choose what to share each time.

Remote mouse and keyboard input is optional. macOS requires the person at the shared Mac to grant Pairwise Accessibility access before input can be injected. Voice uses the microphone only after the person enables it. The app never starts capture, microphone, or transcription just by launching.

## Build and run locally

Prerequisites: macOS 14+, Xcode 16.3 or later with Swift 6.1+, Go, Docker with Compose, and CMake. The checked-in LiveKit client patch is under `vendor/livekit-client-swift`; its upstream base and changes are documented in [UPSTREAM_PATCHES.md](UPSTREAM_PATCHES.md).

```sh
git clone https://github.com/EvAlssment/Pairwise.git
cd Pairwise
sh infra/setup.sh
cd infra
docker compose -p pairwise-dev build api
docker compose -p pairwise-dev stop api
docker compose -p pairwise-dev run --rm --no-deps -it \
  --entrypoint /pairdesk-admin api create-user \
  --admin --name 'Your Name' --email you@example.com
docker compose -p pairwise-dev up -d
cd ../macos
swift run
```

The local service binds to loopback. Set the API address in Pairwise to `http://127.0.0.1:18080`. The first admin command prompts for a password. Admins create the rest of the team's accounts from the app. For a team on multiple networks, deploy the API and LiveKit with HTTPS/WSS and TURN/TLS; see [the self-hosting guide](docs/self-hosting.md).

To build the offline transcription helper and a standalone app bundle:

```sh
cd ..
sh scripts/prepare-whisper.sh
sh scripts/build-app.sh
```

The whisper.cpp source and Tiny model download into ignored `.cache/` and are checked against pinned revisions/checksums. They are not committed. Run `sh scripts/create-signing-identity.sh` once on the Mac that builds PairDesk, and `build-app.sh` signs every build with that same self-signed identity. Without it, builds are ad-hoc signed and macOS treats each one as a new app: the saved sign-in asks for the Mac password (twice) after every install, and permissions may need approval again. Distributing outside your team's Macs still requires a Developer ID signature and Apple notarization. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Tests

```sh
(cd server && go test -race ./... && go vet ./...)
(cd macos && swift test -j 4)
```

To review UI changes without a server or a call, `sh scripts/ui-snapshots.sh` renders the main screens with fixture data to PNG files in `.cache/ui-snapshots/` using a debug build.

The LiveKit integration test needs a running local stack and is exercised separately by `scripts/test-call.sh`. Hardware checks that require two Macs, OS permission prompts, sleep/wake, and cross-network TURN remain manual; unit tests cannot prove those behaviors.

## Project map

- `macos/` — menu-bar app, call UI, LiveKit media, selected-display capture, control input, local transcription, and tests.
- `server/` — Go API for accounts, presence, direct call invitations, room admission, and LiveKit tokens.
- `infra/` — local Compose stack and generic production Compose/Nginx configuration.
- `scripts/` — local build, packaging, speech-runtime preparation, and integration checks.
- `vendor/livekit-client-swift/` — source vendor of LiveKit Swift SDK 2.17.0 with the native-picker filter track overload.

Read [the architecture notes](docs/architecture.md), [feature parity roadmap](docs/feature-parity.md), [release guide](docs/releasing.md), [self-hosting guide](docs/self-hosting.md), and [third-party notices](THIRD_PARTY_NOTICES.md) before operating a public server or redistributing a binary.

## License

Pairwise source code is MIT-licensed; see [LICENSE](LICENSE). Vendored and bundled third-party components keep their upstream licenses and notices. Open-source licensing does not grant rights to Apple's signing identities, service credentials, Whisper model downloads, or a team's user data.
