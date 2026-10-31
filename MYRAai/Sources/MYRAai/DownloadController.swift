import Foundation
import UIKit
import WebKit
import os

/// AGF-3621 — saves what the SPA downloads: a WKDownload (blob:/data: link click, or an owned-host attachment
/// response) is written to a per-save temp directory and then offered in the system share sheet (Save to Files,
/// AirDrop, Mail, …). All decisions come from the pure `DownloadPolicy`; this class only does the I/O and the UI.
///
/// Main thread only (WKDownloadDelegate callbacks arrive there). Owned STRONGLY by the web view's Coordinator —
/// `WKDownload.delegate` is weak.
final class DownloadController: NSObject, WKDownloadDelegate {

    private let log = Logger(subsystem: "eu.myra.myraai", category: "download")

    // Lifetime: from an accepted decideDestination until that download's finish/fail callback. Maps the download
    // to its per-save directory. Keys are held WEAKLY and compared by identity, so an entry can never outlive its
    // download or be matched by a later download that reuses the heap address; the terminal callbacks still remove
    // the entry eagerly.
    private let active = NSMapTable<WKDownload, NSURL>.weakToStrongObjects()
    // Lifetime: a download is added just BEFORE we cancel it ourselves (completionHandler(nil)); removed by the
    // didFail that cancel may cause. Weak: if WebKit delivers no terminal callback after a nil destination, the
    // entry simply disappears with the download — it can never suppress the alert of a different download.
    // Never inferred from the error code.
    private let cancelledByPolicy = NSHashTable<WKDownload>.weakObjects()

    private static let rootName = "myra-save"
    // Lifetime: the process. Stale directories are swept once per process.
    private static var didSweep = false
    private static let processStart = Date()

    override init() {
        super.init()
        Self.sweepStaleOnce()
    }

    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    /// Removes per-save directories left by a killed process: only those created BEFORE this process started, so
    /// a second Coordinator never deletes a file under an open share sheet.
    private static func sweepStaleOnce() {
        guard !didSweep else { return }
        didSweep = true
        let start = processStart
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in entries {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, created >= start { continue }   // made by this process: leave it
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard DownloadPolicy.isAcceptableSize(expected: response.expectedContentLength) else {
            log.warning("download rejected: size")
            reject(download, completionHandler)
            return
        }
        guard let name = DownloadPolicy.validateFilename(suggestedFilename) else {
            log.warning("download rejected: filename")
            reject(download, completionHandler)
            return
        }
        let dir = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
        } catch {
            log.warning("download rejected: cannot create directory")
            reject(download, completionHandler)
            return
        }
        guard let dest = DownloadPolicy.destination(in: dir, filename: name) else {
            log.warning("download rejected: destination")
            try? FileManager.default.removeItem(at: dir)
            reject(download, completionHandler)
            return
        }
        active.setObject(dir as NSURL, forKey: download)
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        cancelledByPolicy.remove(download)
        guard let dir = takeActive(download) else { return }
        guard let file = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first else {
            log.warning("download finished without a file")
            cleanUp(dir)
            showFailureAlert()
            return
        }
        // The expected length is the sender's claim: re-check what is really on disk.
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        guard DownloadPolicy.isAcceptableSize(expected: size) else {
            log.warning("download rejected: size on disk")
            cleanUp(dir)
            showFailureAlert()
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.cleanUp(dir)   // saved, shared or cancelled: the temp copy is no longer needed
        }
        UIApplication.shared.presentSheet(sheet, onFailure: { [weak self] in
            self?.log.warning("download: nothing to present the share sheet from")
            self?.cleanUp(dir)
        })
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let ownCancel = cancelledByPolicy.contains(download)
        cancelledByPolicy.remove(download)
        if let dir = takeActive(download) { cleanUp(dir) }
        if ownCancel { return }   // the rejection already told the user
        log.warning("download failed")
        showFailureAlert()
    }

    // MARK: - Helpers

    /// Cancels the download (completionHandler(nil)) and tells the user; its didFail must not alert again.
    private func reject(_ download: WKDownload, _ completionHandler: (URL?) -> Void) {
        cancelledByPolicy.add(download)
        completionHandler(nil)
        showFailureAlert()
    }

    /// Removes and returns the per-save directory of `download`, if it has one.
    private func takeActive(_ download: WKDownload) -> URL? {
        guard let dir = active.object(forKey: download) else { return nil }
        active.removeObject(forKey: download)
        return dir as URL
    }

    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Shown for a download the app page asked for but we did not (or could not) save. Also used by the
    /// navigation delegate for an app-page download with a scheme we refuse.
    func showFailureAlert() {
        guard let top = UIApplication.shared.topViewController() else {
            log.warning("download: nothing to present the failure alert from")
            return
        }
        let alert = UIAlertController(title: String(localized: "Could not save the file"), message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        top.present(alert, animated: true)
    }
}
