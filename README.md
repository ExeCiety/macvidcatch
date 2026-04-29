# MacVidCatch

Prototype aplikasi Internet Download Manager native untuk macOS 13+.

## Fitur saat ini

- SwiftUI desktop app dengan daftar download, filter status, dialog URL manual, settings, dan menu bar controller.
- Download engine HTTP/HTTPS dengan HEAD metadata probe, queue, pause/resume, retry, validasi ukuran file, partial file, dan segment download untuk server `Accept-Ranges: bytes`.
- Global speed limiter dasar dan persistence lokal di Application Support.
- Custom URL scheme `vidcatchmac://download?url=...` untuk integrasi browser.
- Chrome Manifest V3 extension prototype dengan deteksi direct media/non-DRM dan floating button.
- Script build `.app` dan `.dmg` lokal.

## Build

```bash
./scripts/build_app.sh
open ".build/release/MacVidCatch.app"
```

## Download video dari browser

Untuk media video/HLS yang dikirim dari Chrome extension, aplikasi memakai `yt-dlp` dengan cookies Chrome, referer halaman asal, user-agent browser, dan `aria2c` sebagai downloader paralel.

Install dependency lokal:

```bash
brew install yt-dlp aria2
```

Catatan: aplikasi tidak membypass DRM, paywall, enkripsi, atau pembatasan akses. Jika video membutuhkan izin/cookies, pastikan sudah login di Chrome yang sama.

## Buat DMG

```bash
./scripts/build_app.sh
./scripts/create_dmg.sh
```

Signing dan notarization membutuhkan Apple Developer ID:

```bash
codesign --deep --force --options runtime --sign "Developer ID Application: YOUR NAME" ".build/release/MacVidCatch.app"
xcrun notarytool submit ".build/release/MacVidCatch.dmg" --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple ".build/release/MacVidCatch.dmg"
```

## Chrome extension

1. Buka `chrome://extensions`.
2. Aktifkan Developer Mode.
3. Load unpacked folder `BrowserExtension/chrome`.
4. Saat media langsung terdeteksi, floating button membuka URL scheme app.

## Catatan compliance

Aplikasi tidak membypass DRM, paywall, enkripsi, atau pembatasan akses. Extension menolak kandidat yang terindikasi DRM dan menampilkan pesan legal-first sesuai PRD.
