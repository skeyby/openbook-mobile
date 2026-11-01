# OpenBook Mobile

A native SwiftUI client for OpenBook, built for iPhone and iPad with a shared macOS app. Connect to a compatible OpenBook instance, browse your timeline, and interact with people and posts.

The project is in early development and follows an evolving, experimental REST API. The interface is currently in Italian. It uses Swift 6 and Apple frameworks, with no third-party package dependencies.

## Features

- Personal Timeline and World feeds, with infinite scrolling and pull to refresh.
- Profiles, personal posts, shared posts, followers and following; profile lookup by instance UUID.
- Follow/unfollow, pending follow state, and approval or rejection of incoming follow requests.
- Post details, likes and manual boosts, with shared state across screens.
- Text post creation with public, unlisted or followers-only visibility; basic editing and deletion of your own posts.
- Native Markdown rendering, clickable links, content warnings and custom emoji in posts and profiles.
- Full-screen images and profile photos, with zoom and dismissal gestures on iOS; a modal viewer on macOS.
- Relative post timestamps for the first 24 hours, then local date and time.
- Instance-name branding, system appearance, Dynamic Type and accessibility support.

Authentication uses the system browser with OAuth Authorization Code and PKCE. The app does not collect your password; access and refresh tokens are stored in the device Keychain.

## Requirements

- iOS 17 or later, or macOS 14 or later.
- For development: a Mac with full Xcode, Swift 6 support and the relevant platform SDKs. Command Line Tools alone do not include the iOS Simulator.
- An account on an OpenBook instance that exposes the compatible REST API and supports public OAuth client registration.

## Run the app

1. Clone this repository and open `OpenBook.xcodeproj` in Xcode.
2. Select the **OpenBook** scheme and an iPhone/iPad simulator, or **My Mac**.
3. Run with **⌘R**. A simulator normally does not require a paid Apple Developer membership.
4. Enter the instance origin, such as `https://social.example.org`, without an API path.
5. Complete login and authorization in the system browser.

For a physical device or distribution, configure your own Team, bundle identifier and signing settings in the OpenBook target. The checked-in project includes the maintainer's signing configuration; it does not include signing credentials or provisioning profiles. See [Identity and distribution](#identity-and-distribution) before changing the app identity.

Instances should use HTTPS with a trusted certificate. HTTP is accepted only for loopback development addresses. On a physical phone, `localhost` refers to the phone itself; the instance must be reachable from the device. The app does not disable TLS verification or add a global ATS exception.

Disconnecting removes the local session. It does not revoke the token remotely. A definitive token-refresh rejection clears the saved session and asks you to sign in again; temporary failures remain retryable. The current screen and draft stay in memory until you explicitly disconnect.

## Current limitations

This is an early client, not a complete implementation of every OpenBook feature:

- Comments are a placeholder; profile-name search and profile editing are not implemented.
- The composer supports text and visibility, without media uploads, replies, polls or quotes. Editing has the same basic scope; unsupported post types may be rejected by the server.
- Remote profiles and relationship lists contain what the authenticated instance knows and may be incomplete.
- Biographies remain plain text rather than rendered Markdown/HTML. Custom emoji are static; unknown or unavailable emoji retain their shortcode. Author references in lists do not include an emoji map.
- Markdown images appear as linked alternative text. Code and link labels retain literal emoji shortcodes. Tables have no dedicated table layout.
- Drafts remain in memory and are not restored after the app exits. An uncertain publication requires checking the timeline before explicitly retrying.

See [API coverage](docs/API_COVERAGE.md) for supported operations and [architecture](docs/ARCHITECTURE.md) for behavioral details. These detailed documents are currently in Italian.

## Development

### API contract

The upstream OpenAPI document is the source of truth. By default, the contract checker expects a sibling OpenBook checkout:

```text
workspace/
├── openbook/docs/api/openapi.json
└── openbook-mobile/
```

From this repository's root:

```sh
python3 Scripts/check_api.py
swift test
```

An upstream checkout is only needed for checking the current API contract; the tests use bundled fixtures and make no requests to a live instance. To use a specification in another location:

```sh
python3 Scripts/check_api.py --spec /path/to/openapi.json
```

The checker compares the document's content hash and operations with the reviewed baseline in `docs/api-baseline.json`. When upstream changes, review the affected contract, adapt code and tests, then record the reviewed version:

```sh
python3 Scripts/check_api.py --spec /path/to/openapi.json --record
```

This refreshes the baseline and official example fixtures. Review the resulting diff; recording a new baseline is not a substitute for implementing a contract change.

### Build checks

Compile the iOS app without distribution signing:

```sh
xcodebuild -project OpenBook.xcodeproj -scheme OpenBook \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Compile the macOS app:

```sh
xcodebuild -project OpenBook.xcodeproj -scheme OpenBook \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Unsigned builds check compilation only. Use normal Xcode execution with local simulator signing to test the app, including Keychain access. `swift build --product OpenBookDesktop` also checks the shared views, but that helper executable does not replace the Xcode app bundle for browser authentication or sandbox testing.

The [validation guide](docs/VALIDATION.md) describes automated checks and manual smoke tests. Automated tests run through SwiftPM; the Xcode scheme currently has no separate test target.

### Repository layout

| Path | Purpose |
| --- | --- |
| `App/` | SwiftUI screens, session orchestration, browser authentication and Keychain storage |
| `Sources/OpenBookCore/` | Models, HTTP client, OAuth primitives and UI-independent state |
| `Tests/OpenBookCoreTests/` | Contract, transport and state tests with bundled fixtures |
| `Scripts/` | API contract checking and app-icon generation |
| `OpenBook.xcodeproj` | Shared iOS/macOS application and core framework |
| `docs/` | Architecture, API coverage and validation guidance |
| `AGENTS.md` | Repository conventions for coding agents |

## Identity and distribution

Forks should use their own app identity and signing configuration. Keep the app bundle identifier, OAuth callback scheme and redirect URI in `Sources/OpenBookCore/OAuth.swift`, URL types in `App/Info.plist`, and Keychain service in `App/KeychainStore.swift` aligned. Changing the Keychain namespace requires signing in again.

For TestFlight, archive the iOS app in Xcode and distribute through App Store Connect using your own Apple Developer account and matching provisioning profile. Increment the build number for each upload. Provide reviewers with a reachable instance and a dedicated demo account when login is required. Keep certificates, private keys, provisioning profiles and account credentials out of Git.

The placeholder app icon is generated with Apple frameworks. To regenerate it on macOS:

```sh
swift Scripts/generate_app_icon.swift
```

## Contributing

Keep changes focused, check the current API contract for integrations, and include relevant tests. Preserve shared feed/navigation components and the security boundaries described in [AGENTS.md](AGENTS.md). Report automated checks separately from simulator, device and live-server testing.
