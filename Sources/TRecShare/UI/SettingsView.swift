import AppKit
import SwiftUI

@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var tab: SettingsView.Tab = .general
}

struct SettingsView: View {
    enum Tab: String, Hashable { case general, recording, uploads, shortcuts }

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }.tag(Tab.recording)
            UploadSettings().tabItem { Label("Uploads", systemImage: "icloud.and.arrow.up") }.tag(Tab.uploads)
            ShortcutsAbout().tabItem { Label("Shortcuts & About", systemImage: "keyboard") }.tag(Tab.shortcuts)
        }
        .padding(.top, 8)
        .frame(minWidth: 560, minHeight: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var launchAtLogin = AppSettings.shared.launchAtLogin

    var body: some View {
        Form {
            Section("Recordings folder") {
                HStack {
                    Image(systemName: "folder")
                    Text(settings.recordingsFolder.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                    if settings.saveFolderPath != nil {
                        Button("Reset") { settings.saveFolderPath = nil; RecordingLibrary.shared.refresh() }
                    }
                }
                Button("Open in Finder") { NSWorkspace.shared.open(settings.recordingsFolder) }
            }
            Section("After recording") {
                Toggle("Open the review window", isOn: $settings.openReviewAfterRecording)
                Toggle("Upload automatically and copy the link", isOn: $settings.autoUpload)
                    .disabled(settings.uploadDestination == .none)
                Toggle("Open the link in the browser after upload", isOn: $settings.openLinkAfterUpload)
                    .disabled(settings.uploadDestination == .none)
            }
            Section("App") {
                Toggle("Open TRecShare when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        settings.launchAtLogin = on
                        launchAtLogin = settings.launchAtLogin
                    }
                Button("Show the welcome & permissions guide") { WindowRouter.shared.showWelcome() }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.directoryURL = settings.recordingsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "TRecShare can't write to that folder"
            alert.informativeText = "Choose a folder you have write access to."
            alert.runModal()
            return
        }
        settings.saveFolderPath = url.path
        RecordingLibrary.shared.refresh()
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Video") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(RecordingQuality.allCases) { Text("\($0.rawValue)  (\($0.sizeHint))").tag($0) }
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    Text("30 fps (smaller files)").tag(30)
                    Text("60 fps (smoother motion)").tag(60)
                }
                Text("Native records every pixel of your display (sharpest text). Recordings use HEVC; upload copies use H.264 so they play everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cursor") {
                Toggle("Show the mouse pointer", isOn: $settings.showCursor)
                Toggle("Highlight clicks", isOn: $settings.highlightClicks)
            }
            Section("Camera") {
                Picker("Shape", selection: $settings.cameraShape) {
                    ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $settings.cameraSize) {
                    ForEach(CameraSize.allCases) { Text($0.title).tag($0) }
                }
                Text("Drag the camera anywhere. Right-click it to change shape or size. It appears in screen and area recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Toggle("Even out voice volume in uploaded and smaller copies", isOn: $settings.levelVoice)
                Text("Quiet voices are raised to a standard level and loud peaks are limited. Your original recording always keeps its own audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Start") {
                Toggle("3-second countdown", isOn: $settings.countdownEnabled)
                Text("Counts 3, 2, 1 before recording starts, and outlines the screen that will be recorded. Click the number to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A short list of official documentation links shown under an upload destination's settings.
private struct HelpLinks: View {
    let links: [(title: String, url: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(links, id: \.url) { link in
                if let url = URL(string: link.url) {
                    Link(destination: url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .help(link.url)
                }
            }
        }
        .tint(Theme.accent)
        .padding(.top, 2)
    }
}

// MARK: - Uploads

private struct UploadSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var signingIn = false

    var body: some View {
        Form {
            Section {
                Picker("Upload to", selection: $settings.uploadDestination) {
                    ForEach(UploadDestination.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                if settings.uploadDestination != .none {
                    Picker("Upload size", selection: $settings.uploadQuality) {
                        ForEach(UploadQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Upload automatically after each recording", isOn: $settings.autoUpload)
                    if settings.uploadDestination != .drive {
                        Toggle("Create a share page (player + download button)", isOn: $settings.createSharePage)
                    }
                }
            } footer: {
                Text("Your original recording always stays on this Mac. The link is copied to the clipboard when the upload finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch settings.uploadDestination {
            case .none: EmptyView()
            case .spaces: spacesSection
            case .drive: driveSection
            case .server: serverSection
            }

            if settings.uploadDestination != .none {
                Section {
                    HStack {
                        Button(testing ? "Testing…" : "Test Connection", action: test)
                            .disabled(testing || settings.missingSetup(for: settings.uploadDestination) != nil)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let missing = settings.missingSetup(for: settings.uploadDestination) {
                        Label(missing, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.uploadDestination) { _, _ in testResult = nil }
    }

    // DigitalOcean Spaces / S3

    private var spacesSection: some View {
        Section {
            TextField("Endpoint", text: $settings.spacesEndpoint, prompt: Text("nyc3.digitaloceanspaces.com"))
            TextField("Region", text: $settings.spacesRegion, prompt: Text("nyc3"))
            TextField("Bucket (Space name)", text: $settings.spacesBucket, prompt: Text("my-videos"))
            TextField("Access key", text: $settings.spacesAccessKey)
            SecretField(title: "Secret key", key: .spacesSecret)
            TextField("Folder in bucket", text: $settings.spacesPrefix, prompt: Text("recordings"))
            Picker("Who can watch", selection: $settings.spacesLinkAccess) {
                ForEach(LinkAccess.allCases) { Text($0.title).tag($0) }
            }
            TextField("CDN / custom domain (optional)", text: $settings.spacesPublicBaseURL, prompt: Text("https://my-videos.nyc3.cdn.digitaloceanspaces.com"))
            Toggle("Path-style URLs (needed by some S3-compatible services)", isOn: $settings.spacesPathStyle)
        } header: {
            Text("DigitalOcean Spaces (or any S3-compatible storage)")
        } footer: {
            Text("Create a key in DigitalOcean → API → Spaces Keys. The secret is stored in your Keychain. Each upload gets an unguessable link.")
                .font(.caption).foregroundStyle(.secondary)
            HelpLinks(links: [
                ("DigitalOcean Spaces documentation", "https://docs.digitalocean.com/products/spaces/"),
                ("How to create Spaces access keys", "https://docs.digitalocean.com/products/spaces/how-to/manage-access/")
            ])
        }
    }

    // Google Drive

    private var driveSection: some View {
        Section {
            TextField("OAuth client ID", text: $settings.driveClientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
            SecretField(title: "OAuth client secret", key: .driveClientSecret)
            HStack {
                if Keychain.has(.driveRefreshToken) {
                    Label("Signed in as \(settings.driveAccount.isEmpty ? "your Google account" : settings.driveAccount)",
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out") {
                        GoogleAuth.signOut()
                        settings.driveAccount = ""
                        settings.driveFolderID = ""
                        settings.objectWillChange.send()
                    }
                } else {
                    Button(signingIn ? "Waiting for the browser…" : "Sign in with Google", action: signIn)
                        .disabled(signingIn || settings.driveClientID.trimmed.isEmpty)
                    Spacer()
                }
            }
            Toggle("Anyone with the link can watch", isOn: $settings.driveAnyoneWithLink)
        } header: {
            Text("Google Drive")
        } footer: {
            Text("In Google Cloud Console: enable the Google Drive API, then create an OAuth client of type \"Desktop app\" and paste its ID and secret here. TRecShare only gets access to the files it uploads (folder \"TRecShare › Recordings\" in your Drive, created automatically).\n\nIf Google says \"access_denied\": add your account under Audience → Test users. To stay signed in, fill in Branding (app name, home page, privacy policy link), then press Publish app. When Google warns the app is unverified, choose Advanced → Go to TRecShare.")
                .font(.caption).foregroundStyle(.secondary)
            HelpLinks(links: [
                ("Enable the Google Drive API", "https://console.cloud.google.com/apis/library/drive.googleapis.com"),
                ("OAuth for desktop apps (Google docs)", "https://developers.google.com/identity/protocols/oauth2/native-app"),
                ("Google Drive API overview", "https://developers.google.com/workspace/drive/api/guides/about-sdk")
            ])
        }
    }

    // Own server

    private var serverSection: some View {
        Section {
            Picker("Method", selection: $settings.serverMethod) {
                ForEach(ServerMethod.allCases) { Text($0.title).tag($0) }
            }
            switch settings.serverMethod {
            case .sftp:
                TextField("Host", text: $settings.serverHost, prompt: Text("videos.example.com"))
                TextField("Port", value: $settings.serverPort, format: .number.grouping(.never))
                TextField("SSH user", text: $settings.serverUser, prompt: Text("deploy"))
                TextField("Folder on the server", text: $settings.serverRemotePath, prompt: Text("/var/www/videos"))
                HStack {
                    TextField("SSH private key (optional)", text: $settings.serverKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                    Button("Choose…", action: chooseKey)
                }
            case .http:
                TextField("Upload URL", text: $settings.serverUploadURL, prompt: Text("https://videos.example.com/upload/"))
                SecretField(title: "Access token (sent as Bearer)", key: .serverToken)
            }
            TextField("Public URL of that folder", text: $settings.serverPublicBaseURL, prompt: Text("https://videos.example.com"))
        } header: {
            Text("My own server (VPS)")
        } footer: {
            Text(settings.serverMethod == .sftp
                 ? "Uses your SSH key or ssh-agent (no passwords are stored). The folder must be served by your web server at the public URL."
                 : "Files are sent with HTTP PUT (e.g. nginx WebDAV). The token is stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.serverMethod == .sftp {
                HelpLinks(links: [
                    ("Add an SSH key to a server (DigitalOcean guide)", "https://docs.digitalocean.com/products/droplets/how-to/add-ssh-keys/"),
                    ("ssh-agent manual (OpenBSD)", "https://man.openbsd.org/ssh-agent")
                ])
            } else {
                HelpLinks(links: [
                    ("nginx WebDAV module (HTTP PUT uploads)", "https://nginx.org/en/docs/http/ngx_http_dav_module.html")
                ])
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            settings.serverKeyPath = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
    }

    private func signIn() {
        signingIn = true
        testResult = nil
        Task {
            do {
                let email = try await GoogleAuth.signIn(clientID: settings.driveClientID.trimmed,
                                                        clientSecret: Keychain.get(.driveClientSecret))
                settings.driveAccount = email
                settings.driveFolderID = ""
                testResult = (true, "Signed in as \(email).")
            } catch is CancellationError {
            } catch {
                testResult = (false, error.localizedDescription)
            }
            signingIn = false
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let uploader: Uploader
                switch settings.uploadDestination {
                case .spaces: uploader = try SpacesUploader.fromSettings()
                case .drive: uploader = try DriveUploader.fromSettings()
                case .server: uploader = try ServerUploader.fromSettings()
                case .none: testing = false; return
                }
                testResult = (true, try await uploader.testConnection())
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}

// MARK: - Shortcuts & About

private struct ShortcutsAbout: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Keyboard shortcuts (work in any app)") {
                Toggle("Enable shortcuts", isOn: $settings.hotkeysEnabled)
                LabeledContent("Start / finish recording", value: HotKeys.toggleRecording.display)
                LabeledContent("Pause / resume", value: HotKeys.togglePause.display)
                LabeledContent("Cancel / delete recording", value: HotKeys.cancelRecording.display)
                LabeledContent("Take a screenshot", value: HotKeys.screenshot.display)
            }
            Section("About") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("Recordings", value: settings.recordingsFolder.path)
                Text("TRecShare records your screen, camera and voice and keeps the files on your Mac. Uploads only go to the storage you set up here. No analytics, no tracking.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("TRecShare is not affiliated with, endorsed by, or sponsored by Apple Inc. It is built with Apple's ScreenCaptureKit framework.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Logs in Console") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Entry for a secret stored in the Keychain. A saved secret is never read back into the window:
/// the field only shows that one is saved, and offers Replace and Remove.
private struct SecretField: View {
    let title: String
    let key: Keychain.Key
    @EnvironmentObject private var settings: AppSettings
    @State private var saved = false
    @State private var editing = false
    @State private var value = ""

    var body: some View {
        HStack {
            if saved && !editing {
                LabeledContent(title) {
                    Label("Saved in Keychain", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
                Button("Replace…") { value = ""; editing = true }
                Button("Remove", role: .destructive) {
                    Keychain.delete(key)
                    refresh()
                }
            } else {
                SecureField(title, text: $value)
                    .onSubmit(save)
                Button("Save", action: save).disabled(value.trimmed.isEmpty)
                if editing { Button("Cancel") { editing = false; value = "" } }
            }
        }
        .onAppear(perform: refresh)
    }

    private func save() {
        let v = value.trimmed
        guard !v.isEmpty else { return }
        Keychain.set(v, for: key)
        value = ""
        editing = false
        refresh()
    }

    private func refresh() {
        saved = Keychain.has(key)
        settings.objectWillChange.send()   // re-evaluate "what's missing" messages
    }
}
