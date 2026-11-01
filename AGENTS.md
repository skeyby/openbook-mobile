# Agent guidelines

## Scope and structure

- Build a native SwiftUI client for OpenBook. iOS is the primary platform; macOS shares the application and core client. Minimum targets are iOS 17, macOS 14 and Swift 6.
- Keep user-facing copy in Italian unless the task explicitly changes localization. Keep this file and the README in English.
- Put screens and platform integration in `App/`; keep `Sources/OpenBookCore/` independent of SwiftUI. Test core behavior in `Tests/OpenBookCoreTests/` using simulated transport and fixtures.
- Prefer Apple frameworks and existing abstractions. Do not introduce dependencies, generators or broad refactors without a concrete need.
- When adding or removing sources, update the Xcode project references and build phases. SwiftPM discovers sources automatically.

## Read the current contract

- Treat the upstream OpenAPI document as authoritative. Reread it at the start of API work and before completing an integration; do not infer endpoints from the web UI.
- Run `python3 Scripts/check_api.py`. Its default source is a sibling OpenBook checkout; use `--spec /path/to/openapi.json` for another layout. Never hardcode a contributor's absolute path.
- Review affected operations, required/optional fields, errors, security and pagination. Adapt implementation and tests before using `--record` to update the baseline and official fixtures. Never advance the baseline merely to silence a failure.
- Do not change the server repository to accommodate a client implementation.
- Preserve unknown/optional values and distinguish unavailable counts from zero. Descriptive roles and account types do not grant client-side privileges.
- Consult `docs/API_COVERAGE.md` and `docs/ARCHITECTURE.md` for feature-specific semantics; update them when behavior changes rather than turning this file into an endpoint inventory.

## Security and session boundaries

- Use system-browser Authorization Code authentication with PKCE S256 and fresh random state/verifier values. Validate callback and state before exchanging the code. Never collect passwords or embed a client secret.
- Store access and refresh tokens only in Keychain. Public client IDs and instance origins may use preferences. Never log credentials or put them in fixtures, documentation or Git.
- Reuse public client registration per instance. Serialize refreshes and retain the previous refresh token when rotation is omitted. Terminal authentication failures must require reauthentication rather than repeated use of invalid credentials.
- Require HTTPS except loopback HTTP for development. Do not weaken TLS verification or ATS globally.
- Credential-bearing API calls must not follow redirects. Validate the authenticated origin, path and source before sending a Bearer token to a pagination URL. Server-provided links and media URLs are not trusted API destinations.
- Keep authenticated API transport ephemeral, without persistent private-response caching or cookies. Media loads must not receive API credentials; use system cache policies rather than a custom persistent image cache unless explicitly required.
- Reset account-specific state on session changes and reject stale asynchronous results. Disconnect means local removal unless the API explicitly supports remote revocation.

## State, pagination and mutations

- Reuse `PostListView`, `PostFeed` and `PostRow` across home, profiles and details. Keep one scrolling container per feed and use the shared navigation stack; preserve the originating feed and Back navigation.
- Keep source-specific pagination isolated. Preserve cursor strings, timestamp precision and time zones exactly; never derive API cursors from display dates. Follow validated post continuation links and use the documented person cursor rules.
- Infinite scrolling must serialize requests, deduplicate identifiers and stop on empty pages or repeated cursors/links. After errors, require explicit retry; provide a restart when a cursor is invalid.
- Keep original authorship separate from boost context. Determine ownership using the authenticated identity and original author, never the person who shared a post. Keep account types such as `application` visible.
- Serialize changes to the same resource. Use server-confirmed state and counts; never invent optimistic counters or treat 404 as successful mutation.
- Do not automatically replay writes. Handle uncertain outcomes explicitly, preserve drafts, and warn about duplicate publication before another POST. A confirmed creation remains successful even if its representation cannot be decoded.
- Send only documented fields. Preserve unsupported fields when editing, respect empty responses, and require confirmation for destructive actions or discarding drafts. Do not persist draft content automatically.
- Shared mutation state must protect newer writes from older reads. Keep deletion tombstones for the session and preserve feed/boost context when applying detail responses.

## Presentation and accessibility

- Respect content warnings before creating views that load protected text media, attachments or custom emoji.
- Use native Markdown parsing and layout. Preserve line breaks and literal code, validate link schemes, and never add authentication to external links. Markdown images remain explicit linked alt text rather than implicit downloads.
- Use the shared emoji renderer with the map belonging to that text. Preserve attributed styles and readable fallbacks; bound downloads and decoding work. Do not fetch a full profile for every author reference.
- Reuse the image viewer for attachments and profile photos. Preserve zoom/pan bounds, an accessible close action, loading/error states and explicit retry.
- Constrain media to the available row width before clipping; support Dynamic Type, light/dark appearance, Reduce Motion and VoiceOver. Accessible labels must retain meaningful metadata and actions.
- Keep loading, empty, unavailable and error states distinct. Do not present unimplemented or unread data as an empty server result.

## Verification and delivery

- Check the working tree before editing and preserve unrelated changes.
- Run the API checker, `swift test`, and builds for touched platforms when the SDKs are available. Add meaningful regression tests for changed behavior; avoid tests that merely mirror layout or implementation.
- Distinguish passing tests, successful compilation, simulator/device checks and live-server testing. Never claim checks that were not performed. Unsigned compilation does not validate Keychain behavior or distribution signing.
- Keep the README focused on the project, setup and capabilities; keep architecture and coverage documents focused on current behavior. Store personal paths, troubleshooting history and local working notes in ignored `LOCAL.md`. Never store secrets there either.
- Do not install toolchains, change global Xcode selection, alter signing identities/certificates or publish the app without a request. Standard local simulator signing is part of development verification.
- Summarize material findings, changes, checks and remaining limitations. Do not commit or push unless requested.
