# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.
Report them privately through GitHub: **Security → Report a vulnerability** on this repository
(private vulnerability reporting). Include steps to reproduce and the version you used.
You'll get an answer as soon as possible, and a fix will be released before details are made public.

## How ScrCapKit protects your data

- Recordings stay on your Mac unless you set up uploads; files are readable only by your user account.
- Access keys, tokens and client secrets are stored in the macOS Keychain (this device only) and are
  never shown again in the app after saving.
- All uploads use HTTPS. Storage settings are strictly validated before any request is signed.
- Google sign-in uses OAuth 2.0 with PKCE and a one-time listener bound to `127.0.0.1`, and asks only
  for the `drive.file` scope (files the app created).
- Share links use cryptographically random paths. Share pages escape all text, load no scripts and set
  a restrictive Content-Security-Policy.
- SFTP runs `/usr/bin/sftp` directly (no shell) in batch mode with validated input, key-based auth only,
  and host-key checking.
- The app is built with the hardened runtime and only the camera and microphone entitlements.
  No analytics or third-party SDKs.
