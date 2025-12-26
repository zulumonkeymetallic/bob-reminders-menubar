import Foundation

import os.log
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FirebaseFirestore) && canImport(FirebaseAuth)
import FirebaseFirestore
import FirebaseAuth
#endif

class SyncLogService {
    static let shared = SyncLogService()
    
    private init() {}

    enum SyncDirection: String {
        case toReminders
        case toBob
        case diagnostics
    }

    // Remove logs older than this many seconds (3 days)
    private let retentionInterval: TimeInterval = 3 * 24 * 60 * 60
    private let pruneLock = NSLock()
    private var hasPrunedLogsThisLaunch = false

    private func pruneOldLogsIfNeeded(in directory: URL) {
        pruneLock.lock()
        defer { pruneLock.unlock() }
        guard !hasPrunedLogsThisLaunch else { return }
        hasPrunedLogsThisLaunch = true
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logFiles = urls.filter { $0.pathExtension == "log" }
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        for url in logFiles {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let mdate = values?.contentModificationDate ?? values?.creationDate ?? Date.distantPast
            if mdate < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func logFileURL(filename: String = "sync.log") -> URL? {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let logsDir = lib.appendingPathComponent("Logs").appendingPathComponent("RemindersMenuBar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch { return nil }
        pruneOldLogsIfNeeded(in: logsDir)
        return logsDir.appendingPathComponent(filename)
    }

    private func rotateIfNeeded(_ url: URL) {
        // Simple size-based rotation at ~1 MiB
        let limit: UInt64 = 1_048_576
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > limit {
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let stem = url.deletingPathExtension().lastPathComponent
            let rotated = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(timestamp).log")
            _ = try? FileManager.default.moveItem(at: url, to: rotated)
        }
    }

    private func append(lines: [String], filename: String = "sync.log") {
        guard let url = logFileURL(filename: filename) else { return }
        rotateIfNeeded(url)
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    func logSync(
        userId: String?,
        counts: (created: Int, updated: Int),
        linkedStories: Int,
        themed: Int,
        errors: [String]
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        let header = "[\(timestamp)] uid=\(userId ?? "?")"
        let summary = " created=\(counts.created) updated=\(counts.updated)"
        let extras = " linkedStories=\(linkedStories) themed=\(themed) errors=\(errors.count)"
        lines.append(header + summary + extras)
        for errorMessage in errors.prefix(5) {
            lines.append("  err: \(errorMessage)")
        }
        append(lines: lines, filename: "sync.log")
    }

    func logEvent(tag: String, level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let prefix = "[\(timestamp)]"
        let tags = "[\(tag.uppercased())] [\(level)]"
        let line = "\(prefix) \(tags) \(message)"
        append(lines: [line], filename: "sync.log")
        // Mirror important events to the Xcode console for easier live debugging
        if level.uppercased() != "DEBUG" {
            print(line)
        }
    }

    func logAuth(level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let prefix = "[\(timestamp)]"
        let line = "\(prefix) [AUTH] [\(level)] \(message)"
        append(lines: [line], filename: "auth.log")
        if level.uppercased() != "DEBUG" {
            print(line)
        }
    }

    func logError(tag: String, error: Error) {
        let nsError = error as NSError
        var parts: [String] = [nsError.localizedDescription]
        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            parts.append(reason)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(underlying.localizedDescription)
        }
        let message = parts.joined(separator: " | ")
        logEvent(tag: tag, level: "ERROR", message: message)
    }

    // swiftlint:disable:next cyclomatic_complexity
    func logSyncDetail(
        direction: SyncDirection,
        action: String,
        taskId: String?,
        storyId: String?,
        metadata: [String: Any] = [:],
        dryRun: Bool = false
    ) {
        var payload: [String: Any] = [
            "direction": direction.rawValue,
            "action": action
        ]
        if let taskId { payload["taskId"] = taskId }
        if let storyId { payload["storyId"] = storyId }
        if !metadata.isEmpty { payload["metadata"] = metadata }
        if dryRun { payload["dryRun"] = true }

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            append(lines: ["[\(timestamp)] [DETAIL] \(json)"])
        } else {
            logEvent(tag: "sync", level: "ERROR", message: "Unable to encode sync detail: \(payload)")
        }

        // Mirror detail event to Firestore activity stream when available
        #if canImport(FirebaseFirestore) && canImport(FirebaseAuth)
        Task { @MainActor in
            guard let db = FirebaseManager.shared.firestore else { return }
            var activity: [String: Any] = payload
            // Add compatible timestamps and ownership fields for rules
            activity["createdAt"] = FieldValue.serverTimestamp()
            activity["timestamp"] = FieldValue.serverTimestamp()
            activity["source"] = "MacApp"
            if let uid = Auth.auth().currentUser?.uid {
                activity["ownerUid"] = uid
                activity["userId"] = uid // legacy-compatible owner field
            }
            // Flatten simple metadata for convenience filters (e.g., title, status)
            if let meta = payload["metadata"] as? [String: Any] {
                if let title = meta["title"] { activity["title"] = title }
                if let status = meta["status"] { activity["status"] = status }
                if let calendar = meta["calendar"] { activity["calendar"] = calendar }
                if let taskRef = meta["taskRef"] { activity["taskRef"] = taskRef }
                if let storyRef = meta["storyRef"] { activity["storyRef"] = storyRef }
                if let goalRef = meta["goalRef"] { activity["goalRef"] = goalRef }
                if let tags = meta["tags"] { activity["tags"] = tags }
            }
            do {
                // Write to unified collection expected by Bob rules/app
                try await db.collection("activity_stream").addDocument(data: activity)
            } catch {
                // Also emit a local log so failures are visible in logs
                let msg = "Failed to write activity: \(error.localizedDescription)"
                logEvent(tag: "activity", level: "ERROR", message: msg)
            }
        }
        #endif
    }

    #if canImport(AppKit)
    func revealLogInFinder() {
        guard let url = logFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        NSApp.activate(ignoringOtherApps: true)
    }

    func openLogsFolder() {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let logsDir = lib.appendingPathComponent("Logs").appendingPathComponent("RemindersMenuBar", isDirectory: true)
        NSWorkspace.shared.open(logsDir)
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}
