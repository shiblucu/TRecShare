import AppKit

/// Confirmation dialogs for deleting a recording's uploaded copy, and for moving a recording to the Trash
/// (with the option to remove its online copy too).
@MainActor
enum OnlineCopyPrompts {
    private static var uploads: UploadManager { .shared }

    /// What happens to the online copy, in plain words (it depends on where it was uploaded).
    private static func effect(for url: URL) -> String {
        switch uploads.onlineDestination(for: url) {
        case .drive: return "It is moved to your Google Drive trash, where you can restore it for 30 days."
        case .spaces: return "It is removed from your storage and can't be restored."
        case .server: return "It is removed from your server and can't be restored."
        default: return "It is removed from your cloud storage."
        }
    }

    private static func destinationName(for url: URL) -> String {
        uploads.onlineDestination(for: url)?.shortTitle ?? "the cloud"
    }

    /// "Delete Online Copy…": asks, then deletes the uploaded copy. The recording on this Mac stays.
    static func confirmAndDeleteOnlineCopy(_ url: URL) async {
        guard uploads.hasOnlineCopy(url), !uploads.isDeletingOnline(url) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the online copy of “\(url.deletingPathExtension().lastPathComponent)”?"
        alert.informativeText = "The uploaded video and its share page are deleted from \(destinationName(for: url)), so the link stops working. "
            + effect(for: url) + " The recording on this Mac is not touched."
        alert.addButton(withTitle: "Delete Online Copy")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await deleteShowingErrors(url)
    }

    /// Asks before moving a recording to the Trash. When it has an online copy, offers to delete that too.
    /// Returns true when the recording should now be moved to the Trash.
    static func confirmTrash(_ url: URL) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(url.deletingPathExtension().lastPathComponent)” to the Trash?"
        let hasOnline = uploads.hasOnlineCopy(url)
        alert.informativeText = hasOnline
            ? "You can restore it from the Trash. Its uploaded copy stays online, and its link keeps working, unless you tick the box below."
            : "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        var checkbox: NSButton?
        if hasOnline {
            let box = NSButton(checkboxWithTitle: "Also delete the online copy from \(destinationName(for: url))", target: nil, action: nil)
            box.sizeToFit()
            alert.accessoryView = box
            checkbox = box
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard checkbox?.state == .on else { return true }
        // Delete online first; if that fails, keep the recording so nothing is lost and the user can retry.
        return await deleteShowingErrors(url)
    }

    // MARK: - Several recordings at once

    /// Asks what to do before uploading a selection, when some recordings already have an uploaded copy.
    /// Returns the recordings to upload (empty = nothing to do or cancelled).
    static func confirmUploadMany(_ urls: [URL], to destination: UploadDestination, quality: UploadQuality) -> [URL] {
        let candidates = urls.filter { !uploads.isUploading($0) }
        guard !candidates.isEmpty else { return [] }
        let already = candidates.filter { uploads.hasOnlineCopy($0) }
        let fresh = candidates.filter { !uploads.hasOnlineCopy($0) }
        guard !already.isEmpty else { return candidates }

        let alert = NSAlert()
        alert.messageText = already.count == 1 ? "1 recording already has an uploaded copy" : "\(already.count) recordings already have an uploaded copy"
        alert.informativeText = "Uploading them again makes a new copy at \(destination.shortTitle) and replaces the saved link. "
            + "The earlier copy stays in your storage; use Delete Online Copies first to remove it."
        alert.addButton(withTitle: fresh.isEmpty ? "Upload Again" : "Upload All (\(candidates.count))")
        if !fresh.isEmpty { alert.addButton(withTitle: "Skip Already Uploaded (upload \(fresh.count))") }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return candidates }
        if !fresh.isEmpty, response == .alertSecondButtonReturn { return fresh }
        return []
    }

    private static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Deletes the online copies of `urls`, one after another. Returns the ones that worked and the ones that failed.
    private static func deleteOnlineCopies(_ urls: [URL]) async -> (done: [URL], failed: [(url: URL, reason: String)]) {
        var done: [URL] = []
        var failed: [(url: URL, reason: String)] = []
        for url in urls {
            do {
                try await uploads.deleteOnlineCopy(of: url)
                done.append(url)
            } catch {
                failed.append((url, error.localizedDescription))
            }
        }
        return (done, failed)
    }

    private static func showFailures(_ failed: [(url: URL, reason: String)], intro: String) {
        guard !failed.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = intro
        let lines = failed.prefix(6).map { "• \(name($0.url)): \($0.reason)" }
        alert.informativeText = lines.joined(separator: "\n") + (failed.count > 6 ? "\n…and \(failed.count - 6) more." : "")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// "Delete Online Copies…" for a selection. Recordings without an online copy (or still uploading) are skipped.
    static func confirmAndDeleteOnlineCopies(of urls: [URL]) async {
        let targets = urls.filter { uploads.hasOnlineCopy($0) && !uploads.isUploading($0) && !uploads.isDeletingOnline($0) }
        guard !targets.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to delete online"
            alert.informativeText = "None of the selected recordings has an uploaded copy."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1 ? "Delete 1 online copy?" : "Delete \(targets.count) online copies?"
        alert.informativeText = "The uploaded videos and their share pages are deleted from your cloud storage, so their links stop working. "
            + "Spaces and server copies can't be restored; Google Drive copies go to your Drive trash. The recordings on this Mac are not touched."
        alert.addButton(withTitle: targets.count == 1 ? "Delete Online Copy" : "Delete Online Copies")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = await deleteOnlineCopies(targets)
        showFailures(result.failed, intro: "\(result.failed.count) online \(result.failed.count == 1 ? "copy" : "copies") couldn't be deleted")
    }

    /// Asks before moving several recordings to the Trash, with the option to delete their online copies too.
    /// Returns the recordings that should now be moved to the Trash (those whose online delete failed are kept).
    static func confirmTrash(_ urls: [URL]) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        let online = urls.filter { uploads.hasOnlineCopy($0) && !uploads.isUploading($0) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1 ? "Move 1 recording to the Trash?" : "Move \(urls.count) recordings to the Trash?"
        alert.informativeText = online.isEmpty
            ? "You can restore them from the Trash."
            : "You can restore them from the Trash. \(online.count) \(online.count == 1 ? "has an uploaded copy that stays" : "have uploaded copies that stay") online, and the links keep working, unless you tick the box below."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        var checkbox: NSButton?
        if !online.isEmpty {
            let box = NSButton(checkboxWithTitle: online.count == 1 ? "Also delete its online copy" : "Also delete the \(online.count) online copies",
                               target: nil, action: nil)
            box.sizeToFit()
            alert.accessoryView = box
            checkbox = box
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        guard checkbox?.state == .on else { return urls }
        let result = await deleteOnlineCopies(online)
        let failedURLs = Set(result.failed.map(\.url))
        showFailures(result.failed, intro: "\(result.failed.count) online \(result.failed.count == 1 ? "copy" : "copies") couldn't be deleted, so \(result.failed.count == 1 ? "that recording was" : "those recordings were") not moved to the Trash")
        return urls.filter { !failedURLs.contains($0) }
    }

    @discardableResult
    private static func deleteShowingErrors(_ url: URL) async -> Bool {
        do {
            try await uploads.deleteOnlineCopy(of: url)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't delete the online copy"
            alert.informativeText = error.localizedDescription + "\n\nYour recording was not moved to the Trash."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
    }
}
