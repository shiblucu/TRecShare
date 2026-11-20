# ScrCapKit

A screen recorder for macOS 15+, written in Swift.
Record your screen, a window or an area with your camera and voice, then share a link from **your own** storage:
Google Drive, DigitalOcean Spaces (or any S3-compatible service), or your own server.

## Features

**Recording**
- Menu-bar app (no Dock icon until you open a window)
- Record a whole **screen**, a single **window**, or a dragged **area**, on any display
- Draggable **camera** in portrait (rounded corners) or circle shape; right-click it for shape and size (right-click it for size), included in screen and area recordings
- Microphone (choose the input) and system audio, mixed into one track
- Quality up to **native Retina/4K**, 30 or 60 fps, HEVC hardware encoding
- 3-second countdown, cursor and click highlighting
- Floating **control bar**: timer, pause/resume, restart, delete, finish (never captured in the video)
- **Screenshots** of a screen, window or area (**⌥⇧S**): saved as PNG in `Screenshots/` next to your recordings and copied to the clipboard
- Window recordings are cropped without the window's drop shadow
- Global shortcuts: **⌥⇧R** start/finish · **⌥⇧P** pause/resume · **⌥⇧C** cancel/delete · **⌥⇧S** screenshot
- Safe: keeps recording files valid if something goes wrong, saves on quit/logout, stops before the disk fills,
  keeps the display awake, recovers what was captured if a display is unplugged

**After recording**
- **Review window**: play, **trim** (QuickTime-style, lossless), rename, save a smaller copy, move to Trash
- **Upload & copy link** automatically, with progress in the menu bar and a notification
- **Share page**: a clean web page with the player and a download button (Spaces and own server)
- Upload size: Original, 1440p, 1080p (default) or 720p. Upload copies are H.264 + AAC with "fast start",
  so they stream smoothly in every browser. Your original always stays on your Mac.
- **Library window**: every recording with thumbnail, duration, size and link status; search, copy link, re-upload

## Build and run

Needs macOS 15 and Xcode 16 or its Command Line Tools.

```bash
cd ScrCapKit
./scripts/build-app.sh --open      # builds "build/ScrCapKit.app" and launches it
swift test                          # runs the test suite
```

On first launch a welcome window walks you through the permissions
(Screen Recording, Microphone, Camera, Notifications). After allowing Screen Recording,
macOS may ask you to quit and reopen ScrCapKit.

Local builds are signed "ad-hoc" with a stable identity, so macOS keeps the Screen Recording
permission across rebuilds. If it keeps asking anyway: remove ScrCapKit from
System Settings → Privacy & Security → Screen & System Audio Recording, add it again, then reopen the app.

## Set up uploads

Open **Settings → Uploads**, pick a destination, fill in the details, and click **Test Connection**.
Secrets (keys, tokens) are stored in your macOS Keychain, never in plain files.

### DigitalOcean Spaces (or S3, R2, Backblaze B2, MinIO)
1. In DigitalOcean create a Space, then **API → Spaces Keys → Generate New Key**.
2. Enter the endpoint (e.g. `nyc3.digitaloceanspaces.com`), region (`nyc3`), Space name, access key and secret.
3. Choose who can watch:
   - **Anyone with the link**: permanent public link with an unguessable random path.
   - **Private, expires after 7 days**: files stay private; the link is a signed URL.
4. Optional: your CDN or custom domain for nicer links (e.g. `https://my-space.nyc3.cdn.digitaloceanspaces.com`).
   For services that need it (MinIO, some R2 setups) turn on **Path-style URLs**.

### Google Drive
1. In [Google Cloud Console](https://console.cloud.google.com/) create a project and **enable the Google Drive API**.
2. Set up the **OAuth consent screen** (External; add yourself as a test user, or publish it).
3. **Credentials → Create credentials → OAuth client ID → Desktop app**.
4. Paste the client ID and secret into ScrCapKit and click **Sign in with Google**.

ScrCapKit asks only for the `drive.file` scope, so it can see only the files it uploads
(into a "ScrCapKit" folder). Videos are shared as "anyone with the link can view" unless you turn that off.

### Your own server (VPS)
**SFTP** (recommended): uses your SSH key or ssh-agent; no password is stored.
Enter the host, port, user, the folder to upload into (e.g. `/var/www/videos`) and the public URL
that serves that folder (e.g. `https://videos.example.com`). Each recording goes into its own folder
with an unguessable name: `video`, `poster.jpg` and `index.html` (the share page).

Minimal nginx site for that folder:
```nginx
server {
    server_name videos.example.com;
    root /var/www/videos;
    autoindex off;                       # don't list recordings
    location ~* \.mp4$ { add_header Accept-Ranges bytes; }
    # TLS: use certbot --nginx
}
```

**HTTPS PUT / WebDAV**: files are sent with `PUT` to the upload URL with an optional
`Authorization: Bearer <token>`. Example nginx WebDAV upload endpoint:
```nginx
location /upload/ {
    alias /var/www/videos/;
    dav_methods PUT DELETE MKCOL;
    create_full_put_path on;
    client_max_body_size 4G;
    if ($http_authorization != "Bearer CHANGE-ME-LONG-RANDOM-TOKEN") { return 401; }
}
```

## Publish (share the app with others)

Apps for other Macs must be signed with a **Developer ID** certificate and **notarized** by Apple
(requires an Apple Developer Program membership). Then:

```bash
xcrun notarytool store-credentials scrcapkit       # once: Apple ID + app-specific password + team ID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=scrcapkit UNIVERSAL=1 \
./scripts/build-app.sh --dmg                        # → build/ScrCapKit-<version>.dmg, notarized and stapled
```

Without a Developer ID the DMG still builds, but other Macs will block the app until it's allowed in
System Settings → Privacy & Security. Bump `CFBundleShortVersionString` / `CFBundleVersion` in
`Support/Info.plist` for each release.

## Privacy & security
- No analytics, no tracking, no third-party SDKs. Network access only to the storage you configure.
- Secrets in the Keychain (this Mac only, available after first unlock). Uploads are HTTPS only.
- Google sign-in uses OAuth with PKCE and a one-time listener on `127.0.0.1`; only the `drive.file` scope.
- Share links use cryptographically random paths; share pages escape all text and load no scripts.
- SFTP runs `/usr/bin/sftp` directly (no shell) with validated input and `BatchMode`; host keys are checked.
- Recordings are saved readable only by your user account. The app runs with the hardened runtime and
  only the camera and microphone entitlements.
- Logs: Console.app, subsystem `com.tawfiq.scrcapkit` (file names and errors are redacted by default).

## Project layout
```
Package.swift
Sources/ScrCapKit/
  App/        entry point, menu-bar item, windows, menus, shortcuts, notifications
  Recording/  RecorderModel (state machine), ScreenRecorder (ScreenCaptureKit), camera bubble,
              area selector, countdown, control bar
  Media/      segment joining, transcoding, trimming, thumbnails
  Upload/     upload manager, S3/Spaces (SigV4), Google Drive (OAuth + resumable), own server, share page
  Model/      settings, Keychain, library, permissions, helpers
  UI/         menu-bar panel, review, library, settings, welcome
Tests/ScrCapKitTests/  signing test vectors, naming, escaping, video math
Support/      Info.plist, entitlements, app icon
scripts/build-app.sh   build "ScrCapKit.app", sign (hardened runtime), DMG, notarize
```

## Legal
ScrCapKit is an independent project and is **not affiliated with, endorsed by, or sponsored by Apple Inc.**
It is built with Apple's ScreenCaptureKit framework. Apple and macOS are trademarks of Apple Inc.

## License
MIT. See [LICENSE](LICENSE).
