# MacVidCatch

MacVidCatch is a native macOS 13+ Internet Download Manager prototype with browser integration. The user-facing app, `.app` bundle, DMG volume, Swift package, and executable target use the name `MacVidCatch`.

## Current Features

- SwiftUI desktop app with a downloads list, status filters, manual URL dialog, settings view, and menu bar controls.
- Native HTTP/HTTPS downloader with metadata probing, queue management, pause/resume, retry, file-size validation, partial-file cleanup, and segmented downloads when the server supports `Accept-Ranges: bytes`.
- Basic global speed limiting and local persistence under Application Support.
- Custom URL scheme integration via `macvidcatch://download?...`.
- Browser-originated video and HLS downloads routed through `yt-dlp`.
- Chrome Manifest V3 and Firefox WebExtensions prototypes with direct media detection, legal-first DRM checks, and a floating download button.
- Local scripts for building the `.app` bundle and DMG installer.
- Diagnostic logs for app-level events and per-download `yt-dlp` output.

## Requirements

- macOS 13 or later.
- Swift Package Manager / Xcode command line tools with Swift 6 support.
- Optional runtime tools for browser video and HLS downloads:

```bash
brew install yt-dlp aria2 ffmpeg
```

MacVidCatch looks for `yt-dlp` in common Homebrew and system locations such as `/opt/homebrew/bin` and `/usr/local/bin`. HLS-to-MP4 output requires `ffmpeg`, which `yt-dlp` uses for the final remux step.

## Build And Run

Run commands from this `app/` directory.

```bash
swift build -c release
./scripts/build_app.sh
open ".build/release/MacVidCatch.app"
```

`./scripts/build_app.sh` builds the Swift package, creates `.build/release/MacVidCatch.app`, copies the `MacVidCatch` executable into the bundle, and writes the bundle `Info.plist` including the `macvidcatch` URL scheme.

## Create A DMG

```bash
./scripts/build_app.sh
./scripts/create_dmg.sh
```

The DMG is written to `.build/release/MacVidCatch.dmg` with the volume name `MacVidCatch`.

Signing and notarization require an Apple Developer ID:

```bash
codesign --deep --force --options runtime --sign "Developer ID Application: YOUR NAME" ".build/release/MacVidCatch.app"
xcrun notarytool submit ".build/release/MacVidCatch.dmg" --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple ".build/release/MacVidCatch.dmg"
```

## Browser Integration

The app registers the custom URL scheme:

```text
macvidcatch://download?url=...
```

The browser extensions send the media URL plus page URL, title, MIME type, and source browser to the app. Browser-originated downloads and `.m3u8` / HLS media use the `yt-dlp` path, while native direct HTTP downloads continue to use the built-in downloader.

To load the Chrome extension prototype:

1. Open `chrome://extensions`.
2. Enable Developer Mode.
3. Choose **Load unpacked**.
4. Select `BrowserExtension/chrome`.
5. When direct media is detected, use the floating button to open the app through the URL scheme.

To load the Firefox extension prototype temporarily:

1. Open `about:debugging#/runtime/this-firefox`.
2. Choose **Load Temporary Add-on…**.
3. Select `BrowserExtension/firefox/manifest.json`.
4. When direct media is detected, use the floating button to open the app through the URL scheme.

## Browser Video Downloads

For video and HLS media sent by a browser extension, MacVidCatch runs `yt-dlp` with the originating page referer, matching browser user agent, matching Chrome or Firefox cookies, and `aria2c` as the parallel downloader. HLS playlists are remuxed to MP4 through `ffmpeg` after download.

Make sure you are already signed in with the same Chrome or Firefox profile when downloading media that requires authorized access. MacVidCatch does not bypass DRM, paywalls, encryption, or access controls.

## Logging And Data

MacVidCatch keeps persisted app data under the existing `VidcatchMac` Application Support folder for compatibility with older builds.

Logs are written to:

```text
~/Library/Application Support/VidcatchMac/Logs/
```

- `app.log` contains global app and download lifecycle events.
- `download-<UUID>.log` contains per-download details and captured `yt-dlp` output.

Use the app's **Logs** button to open the logs directory when diagnosing failed downloads.

## Validation

There is currently no dedicated test suite. Validate code changes with:

```bash
swift build -c release
```

When bundle behavior, URL scheme handling, or packaging changes, also run:

```bash
./scripts/build_app.sh
```

## Compliance And Safety

MacVidCatch is intended only for downloads the user is authorized to access. The app and extension do not implement DRM, paywall, encryption, or access-control bypasses, and should not be extended with functionality intended to evade protections such as Widevine, FairPlay, PlayReady, token theft, or paywall circumvention.

Current safety behavior in this prototype:

- The browser extensions only surface direct media candidates for common direct video URLs and HLS playlists such as `.mp4`, `.mov`, `.webm`, `.m4v`, and `.m3u8`.
- The extensions perform best-effort DRM detection from response headers, including known DRM header names and `keyformat`, `widevine`, `playready`, or `fairplay` markers. If a candidate appears protected, the floating button is not shown and the user sees an explanatory notice.
- The extensions honor their local domain blocklist and allowlist-mode settings before sending a candidate to the app. The app also applies its persisted domain blocklist when enqueuing jobs.
- Browser-originated media and HLS jobs are delegated to `yt-dlp`; native manual HTTP/HTTPS downloads continue to use the built-in downloader unless the URL or MIME type indicates HLS.
- `yt-dlp` is invoked with the originating page referer, browser-specific user agent, `--cookies-from-browser chrome` or `--cookies-from-browser firefox`, `aria2c`, and HLS-friendly output handling. This is for content the user is already authorized to access in their local browser profile, not for bypassing restrictions.
- App command logs redact common sensitive URL query parameters such as `token`, `signature`, `sig`, `policy`, `key`, and `jwt`; however, per-download `yt-dlp` output is captured for diagnostics and may include upstream tool output. Avoid sharing logs publicly without reviewing them first.

The DRM and policy checks are intentionally conservative, best-effort safeguards, not a guarantee that every protected or restricted stream can be identified. Users remain responsible for following the source site's terms and only downloading content they are allowed to save.
