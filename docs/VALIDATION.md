# Validation guide

Validation has four separate layers: automated core tests, platform compilation, interactive app checks, and distribution checks. A successful result in one layer does not establish the others.

## Automated checks

Run from the repository root with a Swift 6 toolchain:

```sh
python3 Scripts/check_api.py
swift test
```

The API checker needs the upstream OpenAPI document. Its default location is `../openbook/docs/api/openapi.json`; pass `--spec /path/to/openapi.json` when using another layout. Review contract changes and update implementation/tests before recording a new baseline.

SwiftPM tests use bundled examples and simulated HTTP transport. They cover OAuth primitives and callback validation, controlled terminal-token errors and refresh coordination (concurrent callers, terminal versus temporary failures, storage invalidation and stale-session results), model decoding, request serialization, origin/cursor validation, feed state, reactions, post and comment management, comment pagination/replies/ownership, uncertain publication and email-verification errors, follow relationships and requests, Markdown/custom emoji parsing, image geometry, timestamp presentation, file-backed multipart construction/cleanup, media draft retention, and deferred-publication state/cancellation. They must not use real accounts or mutate a live instance.

These tests do not exercise the full `AppStore` session lifecycle, the actual browser authentication session, OS Keychain behavior, UI gestures or VoiceOver.

## Platform compilation

With full Xcode and the relevant SDKs installed:

```sh
xcodebuild -project OpenBook.xcodeproj -scheme OpenBook \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project OpenBook.xcodeproj -scheme OpenBook \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

These commands check compilation without distribution credentials. For interactive checks, run the application normally in Xcode with local simulator signing or the appropriate device signing. A completely unsigned app may not have working Keychain access. The SwiftPM desktop helper is a compile aid, not a replacement for the application bundle.

## Interactive smoke tests

Use a dedicated test account and record the platform/OS, relevant API revision and observed result. Only perform live mutations when authorized.

- Connect to a reachable instance, complete browser authorization, relaunch to restore the session, and disconnect. Exercise canceled login and expired/revoked sessions.
- Switch Timeline/World, paginate, refresh and retry failures. Verify that switching sources resets pagination and returning from a detail preserves the original feed.
- Open authors, profiles, followers/following and your own posts. Check scrolling, remote-list caveats, profile margins, long names and large Dynamic Type.
- Exercise likes, boosts, follow states and incoming requests. Verify shared state across screens, disabled concurrent actions, authoritative counts and read-only recovery after a confirmed write.
- On iOS, import photos/videos, preview, reorder, describe and remove attachments; test attachment-only posts, missing/zero instance limits, image/video size boundaries, complete multipart limits (including text and descriptions), limits changing before submission, failed limit refresh, interrupted upload and deferred video success/failure/cancellation. Verify background/foreground polling and draft/session cleanup.
- Create/edit/delete dedicated test posts and comments, including nested replies and a deleted/missing parent; check visibility, confirmation, draft retention and uncertain-outcome handling.
- Check an instance without comment endpoints: unavailable message, no creation/reply actions, distinct handling of an inaccessible post, and recovery after server upgrade.
- Check unverified-email creation errors for posts/comments, preserved drafts and retry after email confirmation.
- Verify Markdown links and literal code, custom emoji loading/fallback/wrapping, and relative-date transitions including the 24-hour boundary.
- Confirm content-warning protection before text/media downloads. Open attachments and avatars; check zoom, pan bounds, double tap, swipe/X, rotation and error retry.
- Check light/dark appearance, VoiceOver metadata/actions, Reduce Motion, keyboard navigation and macOS Back/Escape behavior.

## Distribution checks

Distribution requires the maintainer's own Apple account, signing credentials and App Store Connect setup. Keep these outside Git. Validate an archive separately from compilation, increment the build number, and provide review access when authentication is required. Uploads and invitations are explicit release actions, not routine tests.

## Reporting results

Report the commands and outcome for the change being delivered. State unavailable SDKs, failed checks and untested interaction paths explicitly. Keep machine-specific commands, temporary logs, device names and historical test-session notes in ignored `LOCAL.md`, not in this guide.

- Check inline videos in home/profile feeds, post details and comments: poster/loading/error/retry, muted autoplay at half visibility, scroll-off stop, manual pause/seek/audio, fullscreen preserving position, close and background/foreground. Verify content-warning protection, narrow widths, VoiceOver and both platforms with playable and unsupported media.

- Verify the home has no duplicated pinned Timeline/Mondo heading. Check the grey content-warning box with long/missing warning text, Dynamic Type and VoiceOver; reveal/hide must protect text, images, custom emoji and video loading. Profile feed headings remain visible.
