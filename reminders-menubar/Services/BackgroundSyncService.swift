import Foundation
import AppKit
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

@MainActor
final class BackgroundSyncService: ObservableObject {
    static let shared = BackgroundSyncService()
    private init() {}

    private var scheduler: NSBackgroundActivityScheduler?

    func applyPreference() {
        if UserPreferences.shared.enableBackgroundSync {
            SyncLogService.shared.logEvent(tag: "bg-sync", level: "INFO", message: "Enabling background sync")
            start()
        } else {
            SyncLogService.shared.logEvent(tag: "bg-sync", level: "INFO", message: "Disabling background sync")
            stop()
        }
    }

    func start() {
        stop()
        let id = AppConstants.mainBundleId + ".firebase.sync"
        let scheduler = NSBackgroundActivityScheduler(identifier: id)
        let minutes = max(15, UserPreferences.shared.backgroundSyncIntervalMinutes)
        scheduler.interval = TimeInterval(minutes * 60)
        scheduler.tolerance = min(scheduler.interval / 2.0, 3600)
        scheduler.repeats = true
        SyncLogService.shared.logEvent(
            tag: "bg-sync",
            level: "INFO",
            message: "Scheduled background sync every \(minutes) min (tol=\(Int(scheduler.tolerance))s)"
        )
        scheduler.schedule { completion in
            Task {
                // Preflight
                if FirebaseManager.shared.firestore != nil, await RemindersService.shared.hasFullRemindersAccess() {
                    let now = Date()
                    let lastFull = await MainActor.run { UserPreferences.shared.lastFullSyncDate }
                    let sixHours: TimeInterval = 6 * 60 * 60
                    let doFull = (lastFull == nil) || (now.timeIntervalSince(lastFull!) >= sixHours)
                    let mode: FirebaseSyncService.SyncMode = doFull ? .full : .delta
                    _ = await FirebaseSyncService.shared.syncNow(mode: mode, targetCalendar: nil)
                }
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        SyncLogService.shared.logEvent(tag: "bg-sync", level: "INFO", message: "Background sync stopped")
    }
}

@MainActor
final class ManualSyncService: ObservableObject {
    static let shared = ManualSyncService()
    private init() {}

    @Published private(set) var isSyncing = false

    func trigger(reason: String, showToast: Bool = true) {
        guard let delegate = AppDelegate.shared else {
            SyncLogService.shared.logEvent(tag: "sync", level: "WARN", message: "Manual sync aborted (\(reason)): AppDelegate not ready")
            return
        }

        guard !isSyncing else {
            if showToast { SyncFeedbackService.shared.show(message: "Bob sync already running") }
            SyncLogService.shared.logEvent(tag: "sync", level: "INFO", message: "Manual sync ignored (\(reason)) because a sync is in progress")
            return
        }

        #if canImport(FirebaseAuth)
        if FirebaseManager.shared.firestore == nil || Auth.auth().currentUser == nil {
            SyncLogService.shared.logEvent(tag: "sync", level: "WARN", message: "Manual sync aborted (\(reason)): not authenticated or Firebase not configured")
            if showToast { SyncFeedbackService.shared.show(message: "Sign in with Bob before syncing") }
            return
        }
        #endif

        isSyncing = true
        let calendar = delegate.remindersData.calendarForSaving

        Task { [weak self] in
            SyncLogService.shared.logEvent(tag: "sync", level: "INFO", message: "Manual sync started (\(reason))")
            let result = await FirebaseSyncService.shared.syncNow(mode: .full, targetCalendar: calendar)
            await delegate.remindersData.update()

            if !result.errors.isEmpty {
                let joined = result.errors.joined(separator: " | ")
                SyncLogService.shared.logEvent(tag: "sync", level: "ERROR", message: "Manual sync finished with \(result.errors.count) errors (\(reason)): \(joined)")
            } else {
                SyncLogService.shared.logEvent(tag: "sync", level: "INFO", message: "Manual sync finished successfully (\(reason)) created=\(result.created) updated=\(result.updated)")
            }

            if showToast {
                let toast = "Sync: +\(result.created) ↺\(result.updated) ⚠︎\(result.errors.count)"
                await MainActor.run { SyncFeedbackService.shared.show(message: toast) }
            }

            await MainActor.run { self?.isSyncing = false }
        }
    }
}
