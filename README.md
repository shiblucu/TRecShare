# TRecShare

A screen recorder for macOS, written in Swift. Record your screen, a window or an area together with your
camera and voice, then share a link from **your own** storage: Google Drive, DigitalOcean Spaces
(or any S3-compatible service), or your own server.

Everything stays on your Mac unless you set up an upload. No account, no analytics, no tracking.

<!-- SCREENSHOTS: save images in docs/images/ and uncomment, for example:
<p align="center">
  <img src="docs/images/recorder.png" alt="TRecShare recorder panel in the menu bar" width="420">
  <img src="docs/images/review.png" alt="Review window with trim and upload" width="420">
</p>
-->

> **Status: 1.0, early release.** Recording, review, trimming and local saving are tested on real
> recordings. The upload destinations (Google Drive, DigitalOcean Spaces / S3, your own server) are **beta**:
> the upload code is covered by automated tests and local mock servers, but has not yet been run against
> every real service. If an upload fails, the recording is never lost, so please
> [open an issue](https://github.com/shiblucu/TRecShare/issues) with the error message shown.

## Contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Install (step by step)](#install-step-by-step)
4. [First recording](#first-recording)
5. [Using TRecShare](#using-trecshare)
6. [Settings reference](#settings-reference)
7. [Set up uploads](#set-up-uploads)
8. [Quality and file sizes](#quality-and-file-sizes)
9. [Where things are stored](#where-things-are-stored)
10. [Troubleshooting](#troubleshooting)
11. [Update and uninstall](#update-and-uninstall)
12. [Privacy and security](#privacy-and-security)
13. [Accessibility](#accessibility)
14. [Known limitations](#known-limitations)
15. [Development](#development)
16. [Publishing a release](#publishing-a-release)
17. [Legal and license](#legal-and-license)

---

## Features

**Recording**
- Menu-bar app. No Dock icon until you open a window.
- Record a whole **screen**, a single **window**, or a dragged **area**, on any display.
- Draggable **camera** in portrait (rounded corners) or circle shape. Included in screen and area recordings.
- Microphone (pick the input, with a live level meter) and system audio, mixed into one track.
- Quality up to **native Retina / 4K**, 30 or 60 fps, hardware HEVC encoding.
- 3-second countdown, cursor and click highlighting.
- Floating **control bar**: timer, pause/resume, restart, delete, finish, mute the mic, hide the camera.
  It is never captured in the video.
- **Screenshots** of a screen, window or area.
- Global keyboard shortcuts.
- Safe: saves on quit or logout, stops before the disk fills, saves what was captured if a display is
  unplugged, and keeps every recorded part if joining paused parts ever fails.

**After recording**
- **Review window**: play, **trim** (lossless), rename, save a smaller copy, move to the Trash.
- **Upload and copy link** automatically, with progress in the menu bar and a notification. Pick the
  destination and who can watch for each upload in the Review window.
- **Share page** with a player, a download button and a copy-link button (Spaces and your own server).
- Upload sizes: Original, 1440p, **1080p (default)** or 720p. Upload copies are H.264 + AAC with "fast start",
  so they play in every browser and start streaming at once. Your original is never changed.
- **Voice levelling** (on by default): quiet voices are raised to a standard level in upload and smaller
  copies. The original recording keeps its own audio.
- **Library window**: every recording with thumbnail, duration, size and upload status. Filter by Shared,
  On this Mac only or Upload failed; search; copy link, upload or retry in one click.

---

## Requirements

| | |
|---|---|
| **Mac** | Apple silicon or Intel. A normal build runs on the Mac that built it. |
| **macOS** | **15 (Sequoia) or later**. Recording uses an API that first shipped in macOS 15. |
| **Build tools** | Apple's free **Command Line Tools** or **Xcode 16+** (Swift 5.10 or newer) |
| **Apple Developer account** | **Not needed** to build and run on your own Mac |
| **Disk space** | About 1 GB free before recording starts; recordings use roughly 5–45 MB per minute |

To check your macOS version: Apple menu → **About This Mac**.

---

## Install (step by step)

TRecShare is built from source on your own Mac. It takes a few minutes and needs no Apple Developer account.

### 1. Install the build tools

Open **Terminal** (Applications → Utilities → Terminal) and run:

```bash
xcode-select --install
```

A window opens; click **Install** and wait until it finishes. If you already have Xcode or the Command Line
Tools, this command says so and you can continue. Check that Swift works:

```bash
swift --version
```

You should see a version number (5.10 or newer). If you only installed Xcode, open it once and accept the license.

### 2. Get the code

Either clone with git (recommended, makes updating easy):

```bash
git clone https://github.com/shiblucu/TRecShare.git
cd TRecShare
```

or on GitHub click **Code → Download ZIP**, unzip it, and `cd` into the folder.

### 3. Build the app

```bash
./scripts/build-app.sh
```

This compiles TRecShare, creates `build/TRecShare.app`, and signs it for your Mac. It takes one to three minutes
the first time. When it ends you should see `✓ Built build/TRecShare.app`.

- If you get **"permission denied"**: run `chmod +x scripts/build-app.sh` and try again.
- If you get an error about `xcrun` or a missing developer directory: repeat step 1.
- **An app that must run on both Apple silicon and Intel Macs** (for example to copy it to another Mac): build with
  `UNIVERSAL=1 ./scripts/build-app.sh`. A normal build only runs on the kind of Mac that built it.

### 4. Move it to Applications and open it

```bash
cp -R build/TRecShare.app /Applications/
open /Applications/TRecShare.app
```

Because you built it yourself, macOS does not show a "downloaded from the internet" warning.
(Only if you copied an already-built app from someone else, remove the quarantine flag first:
`xattr -dr com.apple.quarantine /Applications/TRecShare.app`.)

A video icon appears in the menu bar and the **Welcome** window opens.

### 5. Allow the permissions

The Welcome window lists what TRecShare needs. Click **Allow** next to each:

| Permission | Why | Required? |
|---|---|---|
| **Screen Recording** | To record your screen | **Yes** |
| **Microphone** | To record your voice | Only if you record voice |
| **Camera** | To show yourself on screen | Optional |
| **Notifications** | To tell you when a recording or link is ready | Optional |

Screen Recording opens **System Settings → Privacy & Security → Screen & System Audio Recording**.
Switch **TRecShare** on there (if it is not in the list, click **+** and choose it from Applications).

> **Important:** after you allow Screen Recording, macOS usually asks you to **quit and reopen** the app.
> Click the power icon in TRecShare's panel (or right-click the menu-bar icon → Quit), then open it again.

You can reopen the guide any time: **Settings → General → Show the welcome & permissions guide**.

### 6. (Optional) Start at login

**Settings → General → Open TRecShare when I log in.** Keep the app in `/Applications` for this to work reliably.

---

## First recording

1. Click the **video icon** in the menu bar. The TRecShare panel opens under it.
2. Choose **Screen**, **Window** or **Area**. For Screen, pick the display (the one you clicked from is pre-selected).
3. Turn the **camera** and **microphone** on or off (the meter under the microphone shows it hears you).
   Choose **System audio** if you want sound from apps.
4. Press **Start recording** (or **⌥⇧R**). After the 3-second countdown, recording starts.
5. Use the **floating control bar** to pause, restart, delete, mute, hide the camera or finish.
6. Press **Finish** (or **⌥⇧R** again). The **Review** window opens with your video.

The video is saved in `~/Movies/TRecShare`. If uploads are set up, it uploads and the link is copied to your clipboard.

---

## Using TRecShare

### The menu-bar icon
- **Click** it to open the panel. It closes when you click elsewhere, press **Esc**, switch apps, or open a window.
- **Right-click** it for a quick menu: start/finish, pause, mute, hide the camera, delete, take a screenshot,
  Library, Settings, Quit.
- While recording it shows a **timer**; while uploading it shows the **upload percentage**.

### Recording modes
| Mode | What it records |
|---|---|
| **Screen** | A whole display. The camera appears in the video. |
| **Window** | One app window, without its drop shadow. The camera is not included. |
| **Area** | A rectangle you drag out on a display. Press **Return** to use the whole display, **Esc** to cancel. |

### Control bar
A small floating bar near the bottom of the screen:
- **Pause / resume** (⌥⇧P): paused time is cut from the video.
- **Restart**: delete this take and start again with the same source (asks for confirmation).
- **Delete**: throw the recording away (asks for confirmation). The **⌥⇧C** shortcut deletes at once, without asking.
- **Mute microphone**: the video is silent until you unmute. Each switch starts a new part, like pause and
  resume, so there can be a split-second gap.
- **Hide camera**: takes the camera bubble out of the video until you show it again.
- **Finish** (⌥⇧R): stop and save.

The same controls are in the menu-bar panel and the right-click menu while you record.

### Camera
Turn it on in the panel. **Drag** it where you want it. **Right-click** it to change its **shape**
(portrait with rounded corners, or circle) and **size**. It is part of the recording only while you record.
While recording, its right-click menu offers **Hide Camera** (the same as the control bar's button).

### Keyboard shortcuts (work in any app)
| Shortcut | Action |
|---|---|
| **⌥⇧R** | Start / finish recording (also cancels the countdown) |
| **⌥⇧P** | Pause / resume |
| **⌥⇧C** | Cancel the countdown, or delete the current recording |
| **⌥⇧S** | Take a screenshot |

Turn them off in **Settings → Shortcuts & About** if they clash with another app.

### Screenshots
Press **⌥⇧S**, click **Take screenshot** in the panel, or use the right-click menu. It captures what the current
mode selects (screen, window or area), saves a **PNG** to `Screenshots/` inside your recordings folder, and copies the
image to the clipboard so you can paste it straight into a message.

### Review window
Opens after each recording (turn off in Settings). It lets you:
- **Play** the video with the standard macOS controls.
- **Trim**: drag the yellow handles, then confirm. A new trimmed file is saved; the original is kept. No quality is lost.
- **Rename**: edit the title and press Return.
- **Upload and copy link**: choose where to upload and who can watch (Spaces: permanent or 7-day link;
  Google Drive: anyone with the link or only people you share it with), or pick another upload size from the
  arrow next to the button. The "who can watch" choice also becomes your default in Settings.
- **Save Smaller Copy**: 1440p, 1080p or 720p next to the original.
- **Show in Finder** or **Move to Trash**.

### Library
Menu-bar icon → **Library** (also **⌘L** while a TRecShare window is open). The sidebar filters recordings:
**All**, **Shared**, **On this Mac only** and **Upload failed**, each with a count. Each card shows a thumbnail,
length, size, a status (Shared, On this Mac, Uploading, Upload failed) and a one-click action (Copy link,
Upload, Retry or Cancel). Retry always goes to the destination that failed. Click a card to open it.
Right-click for: open, play in QuickTime, copy link, open link, upload / upload again, show in Finder,
move to Trash. "Upload failed" is not remembered after you quit TRecShare.

---

## Settings reference

Open with the **gear** in the panel, the right-click menu, or **⌘,** while a TRecShare window is open.

### General
| Setting | What it does |
|---|---|
| Recordings folder | Where recordings are saved (default `~/Movies/TRecShare`). **Change…**, **Reset**, **Open in Finder**. |
| Open the review window | Show the Review window after each recording. |
| Upload automatically and copy the link | Upload right after recording (needs an upload destination). |
| Open the link in the browser after upload | Open the share link when the upload finishes. |
| Open TRecShare when I log in | Launch at login. |

### Recording
| Setting | What it does |
|---|---|
| Quality | Recording resolution, from 720p up to **Native** (default). See [Quality](#quality-and-file-sizes). |
| Frame rate | 30 fps (smaller files) or 60 fps (smoother motion). |
| Show the mouse pointer / Highlight clicks | Cursor options in the video. |
| Camera → Shape, Size | Portrait or circle; small, medium or large. |
| Even out voice volume | Levels the voice in upload and smaller copies. Never changes the original. |
| 3-second countdown | Count down before recording starts. |

### Uploads
| Setting | What it does |
|---|---|
| Upload to | Don't upload, DigitalOcean Spaces / S3, Google Drive, or My own server. |
| Upload size | Original, 1440p, 1080p (default) or 720p. |
| Upload automatically after each recording | On by default once a destination is ready. |
| Create a share page | A web page with a player and download button (Spaces and your server). |
| **Test Connection** | Checks your details with a tiny test request. Use it before your first upload. |

Destination details are explained in [Set up uploads](#set-up-uploads).

### Shortcuts & About
Turn global shortcuts on or off, see the list, the version and the recordings folder, and open Console for logs.

---

## Set up uploads

Open **Settings → Uploads**, choose a destination, fill in the details and press **Test Connection**.
Secrets (keys, tokens) are stored in your macOS Keychain and are **never shown again** after saving: the field
shows "Saved in Keychain" with **Replace** and **Remove** buttons.

When an upload finishes, the link is copied to your clipboard and a notification appears.

### DigitalOcean Spaces (or S3, Cloudflare R2, Backblaze B2, MinIO)

1. In DigitalOcean, **Create → Spaces Object Storage**. Pick a region and a name (this is your **bucket**).
2. Go to **API → Spaces Keys → Generate New Key**. Copy the **Access key** and the **Secret** (shown only once).
3. In TRecShare, **Settings → Uploads → Upload to → DigitalOcean Spaces / S3** and enter:
   - **Endpoint**: `<region>.digitaloceanspaces.com`, for example `nyc3.digitaloceanspaces.com`
   - **Region**: for example `nyc3`
   - **Bucket**: the Space name
   - **Access key** and **Secret key**
   - **Folder in bucket**: for example `recordings`
4. Choose **Who can watch**:
   - **Anyone with the link (permanent):** a public link with an unguessable random path.
   - **Private, link expires after 7 days:** files stay private; the link is a signed URL.
5. Optional: **CDN / custom domain** (for example the Space's CDN endpoint) for nicer, faster links.
   Turn on **Path-style URLs** only for services that need it (MinIO, some R2 setups).
6. Press **Test Connection**. You should see "Connected to <bucket>. Uploads will work."

Each upload goes into its own folder with a random name, for example
`recordings/2026-11/my-demo-Ab3dE5.../` containing the video, a poster image and `index.html` (the share page).

### Google Drive

Google requires every app to use an OAuth client. You create your own (free, about 5 minutes):

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and **create a project**.
2. **APIs & Services → Library → Google Drive API → Enable.**
3. **APIs & Services → OAuth consent screen**: choose **External**, fill in the app name and your email.
   While the app is in **Testing**, add your own Google account under **Test users**.
   Then, to avoid being signed out every 7 days, press **Publish app** (status *In production*). TRecShare only asks
   for the narrow `drive.file` scope, which should not need Google's verification review. Check Google's current
   rules if the console says otherwise.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID → Application type: Desktop app.**
   Copy the **Client ID** and **Client secret**.
5. In TRecShare: **Upload to → Google Drive**, paste the client ID and secret, then press **Sign in with Google**.
   Your browser opens; allow access and return to the app. It shows "Signed in as <email>".
6. Optional: turn **Anyone with the link can watch** off if you want to share files from Drive yourself.

Videos go into a **TRecShare** folder in your Drive. TRecShare can only see files it created itself.
Google Drive links open Google's own player (no share page).

### Your own server (VPS)

You need a server with a web server (nginx, Caddy…) that serves a folder over **HTTPS**.
Choose one method:

#### Option A: SFTP (recommended)
Uses your SSH key or `ssh-agent`. No password is stored.

1. On the server, create a folder for videos and make sure your SSH user can write to it:
   ```bash
   sudo mkdir -p /var/www/videos && sudo chown "$USER" /var/www/videos
   ```
2. Make sure you can log in with a key: `ssh you@videos.example.com` should work without a password.
3. Serve the folder over HTTPS, for example with nginx (and `certbot --nginx` for a certificate):
   ```nginx
   server {
       server_name videos.example.com;
       root /var/www/videos;
       autoindex off;                 # don't list recordings
       location ~* \.mp4$ { add_header Accept-Ranges bytes; }
   }
   ```
4. In TRecShare: **Upload to → My own server (VPS) → SFTP** and enter the **Host**, **Port** (22),
   **SSH user**, **Folder on the server** (`/var/www/videos`), optionally the **SSH private key**
   (**Choose…**), and the **Public URL of that folder** (`https://videos.example.com`).
5. Press **Test Connection**.

The first connection trusts the server's host key and remembers it in `~/.ssh/known_hosts`. If the key later changes,
the upload stops with a warning.

#### Option B: HTTPS PUT / WebDAV
TRecShare sends files with `PUT` (and `MKCOL` for the folder), with an optional `Authorization: Bearer <token>`.
Example nginx endpoint (needs nginx's WebDAV module, for example the `nginx-extras` package on Debian/Ubuntu):

```nginx
location /upload/ {
    alias /var/www/videos/;
    dav_methods PUT DELETE MKCOL;
    create_full_put_path on;
    client_max_body_size 4G;
    if ($http_authorization != "Bearer CHANGE-ME-LONG-RANDOM-TOKEN") { return 401; }
}
```

Use a long random token (for example `openssl rand -hex 32`). In TRecShare enter the **Upload URL**
(`https://videos.example.com/upload/`), the **Access token** and the **Public URL**.

> Uploads require **HTTPS**. Plain `http://` is only accepted for `localhost` while testing.

---

## Quality and file sizes

### Recording quality
| Setting | Resolution | Approximate size |
|---|---|---|
| 720p · Small | up to 1280×720 | ~5 MB per minute |
| 1080p · Balanced | up to 1920×1080 | ~10 MB per minute |
| 1440p · Detailed | up to 2560×1440 | ~18 MB per minute |
| 4K · Best | up to 3840×2160 | ~30 MB per minute |
| **Native · Sharpest** (default) | your display's real pixels | ~25–45 MB per minute |

Sizes are estimates. A still screen records far smaller than scrolling or video. The recorder only stores frames
when the picture changes, so a still page can drop to 1 frame per second; this is normal and plays smoothly.

### Upload copies
Uploads use a separate copy, so your sharp original stays on your Mac:

| Upload size | Video bitrate | Good for |
|---|---|---|
| Original | as recorded | Largest. Highest quality. |
| 1440p | 9 Mbps | Fine detail such as code or small UI text |
| **1080p** (default) | 6 Mbps | Best balance of sharpness and smooth streaming |
| 720p | 3 Mbps | Slow connections (text looks soft) |

Upload copies are H.264 with AAC audio and "fast start", which plays in every browser and device.

---

## Where things are stored

| What | Where |
|---|---|
| Recordings | `~/Movies/TRecShare` (changeable in Settings) |
| Screenshots | `<recordings folder>/Screenshots` |
| Smaller and trimmed copies | Next to the original recording |
| Upload links and history | `~/Library/Application Support/TRecShare/uploads.json` |
| Settings | `~/Library/Preferences/com.tawfiq.trecshare.plist` |
| Keys and tokens | macOS Keychain, service `com.tawfiq.trecshare.secrets` |
| Logs | macOS unified log, subsystem `com.tawfiq.trecshare` |
| Temporary files | Removed after each recording or upload |

Recordings and screenshots are readable only by your user account.

---

## Troubleshooting

**macOS keeps asking for Screen Recording permission, or the app can't record even though it is switched on**
Reset the permission and grant it again:
```bash
tccutil reset ScreenCapture com.tawfiq.trecshare
```
Reopen TRecShare, allow Screen Recording when asked, then **quit and reopen** the app once.
Local builds use a stable signature, so the permission normally survives rebuilds.

**The build script says "permission denied"**
`chmod +x scripts/build-app.sh`

**The build fails with a developer-directory or `xcrun` error**
Install the tools: `xcode-select --install`. If Xcode is installed but not selected:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

**I don't see the menu-bar icon**
On Macs with a notch the menu bar can run out of space, and macOS hides icons that don't fit. Quit other
menu-bar apps or use a tool that manages menu-bar items. Make sure the app is running (Activity Monitor → TRecShare).

**The camera doesn't show**
Check System Settings → Privacy & Security → Camera. Close other apps using the camera (video-call apps).
The camera is not included in **Window** recordings.

**My voice is quiet or missing**
Choose the right microphone in the panel and raise the input volume in System Settings → Sound → Input.
Voice levelling only affects upload and smaller copies. For system audio, turn **System audio** on.

**The video looks blurry**
Set **Settings → Recording → Quality** to **Native**. When sharing, use **1080p** or **1440p** for uploads; 720p is soft.

**Upload test or upload fails**

| Message | What to do |
|---|---|
| "The access key is not recognised" | Re-enter the Spaces access key. |
| "The secret key doesn't match the access key" | Use **Replace…** and paste the secret again. |
| "The bucket wasn't found" | Check the bucket (Space) name and that the endpoint matches its region. |
| "Access denied" | The key needs write permission for that bucket. |
| "The Google Drive API is turned off…" | Enable the Drive API in your Google Cloud project. |
| "Your Google sign-in has expired" | Sign in again. Publish the consent screen to avoid weekly expiry. |
| "The server didn't accept your SSH key" | Check the key path, or add the key to `ssh-agent`. |
| "The server's SSH host key changed" | Check `~/.ssh/known_hosts`; this can mean the server was reinstalled, or something worse. |
| "Couldn't reach host:port" | Check the host name, port and firewall. |
| "The server refused the upload (401)" | The token is wrong. |
| "(405)" / "(404)" | The upload URL is wrong, or WebDAV/PUT isn't enabled. |
| "(413)" | Raise the server's upload size limit (`client_max_body_size`). |

**The share link doesn't play**
For Spaces, the file must be public (**Anyone with the link**) or the signed link must not have expired (7 days).
For your own server, check that the public URL points at the same folder you upload into, over HTTPS.

**Look at the logs**
```bash
log show --last 10m --info --predicate 'subsystem == "com.tawfiq.trecshare"'
```
Dynamic values such as file names are redacted by default.

---

## Update and uninstall

### Update
```bash
cd TRecShare
git pull
./scripts/build-app.sh
cp -R build/TRecShare.app /Applications/       # quit TRecShare first
```
Your settings, recordings and permissions are kept.

**Coming from ScrCapKit (the app's earlier name)?** The first launch of TRecShare copies your
settings and moves `~/Movies/ScrCapKit` to `~/Movies/TRecShare`. Because the app identity changed,
macOS asks for Screen Recording (and camera/microphone) permission again, and upload secrets
(access keys, tokens, Google sign-in) must be entered once more in **Settings → Uploads**. You can then
delete the old `ScrCapKit.app` and clear its data with the uninstall steps below, using `scrcapkit` in
place of `trecshare`.

### Uninstall
1. Quit TRecShare and delete `/Applications/TRecShare.app`.
2. (Optional) remove its data:
   ```bash
   defaults delete com.tawfiq.trecshare
   rm -rf ~/Library/Application\ Support/TRecShare
   tccutil reset All com.tawfiq.trecshare
   for k in spaces.secretKey drive.clientSecret drive.refreshToken server.httpToken; do
     security delete-generic-password -s com.tawfiq.trecshare.secrets -a "$k" 2>/dev/null
   done
   ```
3. Your recordings in `~/Movies/TRecShare` are **not** deleted. Remove them yourself if you want.
4. Uploaded videos stay in your storage until you delete them there.

---

## Privacy and security

- No analytics, no tracking, no third-party SDKs. Network access only to the storage you configure.
- The microphone level meter runs only while the menu-bar panel is open, so macOS shows its microphone
  indicator then. It never records.
- Keys, tokens and client secrets live in the macOS Keychain (this device only) and are never displayed again.
- All uploads use HTTPS. Storage settings (endpoint, bucket, region, folder) are strictly validated before any
  request is signed.
- Google sign-in uses OAuth with PKCE and a one-time listener on `127.0.0.1`; only the `drive.file` scope.
- Share links use cryptographically random paths. Share pages escape all text, load nothing from third parties
  and set a restrictive Content-Security-Policy. Their only script is the small built-in copy-link button,
  allowed by its exact SHA-256 hash, so no other script can run.
- SFTP runs `/usr/bin/sftp` directly (no shell) with validated input, key-based login only and host-key checking.
- Recordings are saved readable only by your user account. The app runs with the hardened runtime and only the
  camera and microphone entitlements.
- Report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

---

## Accessibility

- Every control has a VoiceOver label, and recording steps (countdown, recording, paused, saved, errors) are announced.
- Recording can be controlled entirely from the keyboard with the global shortcuts. The area selector uses
  **Return** (whole screen) and **Esc**. Library cards and buttons are reachable with Tab (turn on
  *System Settings → Keyboard → Keyboard navigation*).
- Respects **Reduce Motion** (no blinking indicator or animated countdown) and uses colours that meet WCAG AA contrast.

---

## Known limitations

- If the app or the Mac crashes in the middle of a recording, that recording is lost: macOS only finalizes the
  video file when recording stops. (Quitting, logging out and unplugging a display are handled and save the recording.)
- Screenshots are saved locally and copied to the clipboard; they aren't uploaded.
- Window recordings don't include the camera.
- Recordings can only be uploaded after they finish; an upload interrupted by quitting the app must be started again.
- Uploads to Google Drive, Spaces / S3 and your own server are beta (see the status note at the top).
- Local builds are not notarized, so they are meant for the Mac they were built on.

---

## Development

### Project layout
```
Package.swift
Sources/TRecShare/
  App/        entry point, menu-bar item and panel, windows, menus, shortcuts, notifications
  Recording/  RecorderModel (state machine), ScreenRecorder (ScreenCaptureKit), camera, area selector,
              countdown, control bar
  Media/      joining paused parts, transcoding, voice levelling, trimming, thumbnails
  Upload/     upload manager, S3/Spaces (SigV4), Google Drive (OAuth + resumable), own server, share page
  Model/      settings, Keychain, library, permissions, helpers
  UI/         menu-bar panel, review, library, settings, welcome
Tests/TRecShareTests/   signing test vectors, naming, escaping, validation, video maths, voice levelling
Support/                Info.plist, entitlements, app icon
scripts/build-app.sh    build, sign (hardened runtime), DMG, notarize
.github/workflows/      CI: build and test on every push and pull request
```

### Build and test
```bash
swift build            # debug build
swift test             # 22 tests
./scripts/build-app.sh --open     # release build as a real .app, then launch it
```
Run the `.app` for anything involving permissions or the menu bar. A plain `swift run` has no bundle, so macOS
stops it when it asks for the microphone. You can open `Package.swift` in Xcode for editing and autocomplete.

### How it fits together
- **ScreenCaptureKit** (Apple) does the capture and writes MP4 files. Pause closes the current file and resume starts
  a new one; the parts are joined losslessly when you finish.
- **RecorderModel** is the single state machine (`idle → preparing → countdown → recording ⇄ paused → finishing`).
- **UploadManager** prepares the upload copy (`Transcoder`, `AudioLeveler`), then hands it to an `Uploader`.
- **Uploaders** are small and independent: `SpacesUploader`, `DriveUploader`, `ServerUploader`.

### Add another upload destination
1. Create a type conforming to `Uploader` (`upload(_:progress:)` and `testConnection()`) in `Upload/`.
2. Add a case to `UploadDestination` and any settings to `AppSettings` (secrets go in `Keychain`, never `UserDefaults`).
3. Add a `switch` branch in `UploadManager.upload` and a section in `SettingsView`.
4. Add tests for anything that parses or validates user input.

### Code guidelines
- No compiler warnings. Keep the test suite green; CI builds and runs it on every push.
- Validate everything a user can type before it goes into a URL, a file path or a command.
- Never log or display secrets. Use the Keychain.
- Every control needs an accessibility label; announce state changes with `Accessibility.announce`.
- Keep user-visible text short and in plain language.

### Using your own copy (fork)
Change the bundle identifier so macOS permissions and the Keychain entries don't clash with the original:
`CFBundleIdentifier` in `Support/Info.plist` and `BUNDLE_ID` in `scripts/build-app.sh`.

---

## Publishing a release

Apps for other people's Macs must be signed with a **Developer ID** certificate and **notarized** by Apple
(needs an Apple Developer Program membership). Without it, other Macs block the app until the user allows it in
*System Settings → Privacy & Security → Open Anyway*.

```bash
xcrun notarytool store-credentials trecshare       # once: Apple ID + app-specific password + team ID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=trecshare UNIVERSAL=1 \
./scripts/build-app.sh --dmg                        # → build/TRecShare-<version>.dmg, notarized and stapled
```

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist` for each release, and attach the
DMG to a **GitHub Release** (DMG files are git-ignored so they can't be committed by accident).

---

## Legal and license

TRecShare is an independent project and is **not affiliated with, endorsed by, or sponsored by Apple Inc.**
It is built with Apple's ScreenCaptureKit framework. Apple and macOS are trademarks of Apple Inc.

MIT License. See [LICENSE](LICENSE).
