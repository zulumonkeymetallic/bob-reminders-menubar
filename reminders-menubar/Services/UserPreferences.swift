import SwiftUI
import ServiceManagement

private enum PreferencesKeys {
    static let reminderMenuBarIcon = "reminderMenuBarIcon"
    static let calendarIdentifiersFilter = "calendarIdentifiersFilter"
    static let calendarIdentifierForSaving = "calendarIdentifierForSaving"
    static let autoSuggestTodayForNewReminders = "autoSuggestTodayForNewReminders"
    static let removeParsedDateFromTitle = "removeParsedDateFromTitle"
    static let showUncompletedOnly = "showUncompletedOnly"
    static let rmbColorScheme = "rmbColorScheme"
    static let backgroundIsTransparent = "backgroundIsTransparent"
    static let showUpcomingReminders = "showUpcomingReminders"
    static let upcomingRemindersInterval = "upcomingRemindersInterval"
    static let filterUpcomingRemindersByCalendar = "filterUpcomingRemindersByCalendar"
    static let menuBarCounterType = "menuBarCounterType"
    static let filterMenuBarCountByCalendar = "filterMenuBarCountByCalendar"
    static let preferredLanguage = "preferredLanguage"
    // Sync status
    static let lastSyncSummary = "lastSyncSummary"
    static let lastSyncDate = "lastSyncDate"
    static let lastFullSyncDate = "lastFullSyncDate"
    static let lastDeltaSyncDate = "lastDeltaSyncDate"
    // Background sync
    static let enableBackgroundSync = "enableBackgroundSync"
    static let backgroundSyncIntervalMinutes = "backgroundSyncIntervalMinutes"
    // Sync behavior
    static let syncDryRun = "syncDryRun"
    static let showBobMetadataInNotes = "showBobMetadataInNotes"
    static let syncInstanceId = "syncInstanceId"
    // Theme→Calendar mapping (theme name -> calendar identifier)
    static let themeCalendarMap = "themeCalendarMap"
    // Triage classification
    static let enableTriageClassification = "enableTriageClassification"
    static let triageCalendarName = "triageCalendarName"
    static let workCalendarName = "workCalendarName"
    static let llmTriageEndpoint = "llmTriageEndpoint"
    // Auth/session
    static let staySignedIn = "staySignedIn"
}

class UserPreferences: ObservableObject {
    static private(set) var shared = UserPreferences()
    
    private init() {
        // This prevents others from using the default '()' initializer for this class.
    }
    
    private static let defaults = UserDefaults.standard
    
    @Published var remindersMenuBarOpeningEvent = false
    /// Stable per-install identifier used for sync diagnostics/claims.
    var syncInstanceId: String {
        if let existing = UserPreferences.defaults.string(forKey: PreferencesKeys.syncInstanceId),
           !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        UserPreferences.defaults.set(newId, forKey: PreferencesKeys.syncInstanceId)
        return newId
    }
    
    @Published var reminderMenuBarIcon: RmbIcon = {
        guard let menuBarIconString = defaults.string(forKey: PreferencesKeys.reminderMenuBarIcon) else {
            return RmbIcon.defaultIcon
        }
        return RmbIcon(rawValue: menuBarIconString) ?? RmbIcon.defaultIcon
    }() {
        didSet {
            UserPreferences.defaults.set(reminderMenuBarIcon.rawValue, forKey: PreferencesKeys.reminderMenuBarIcon)
        }
    }
    
    var preferredCalendarIdentifiersFilter: [String]? {
        get {
            return UserPreferences.defaults.stringArray(forKey: PreferencesKeys.calendarIdentifiersFilter)
        }
        set {
            UserPreferences.defaults.set(newValue, forKey: PreferencesKeys.calendarIdentifiersFilter)
        }
    }
    
    var preferredCalendarIdentifierForSaving: String? {
        get {
            return UserPreferences.defaults.string(forKey: PreferencesKeys.calendarIdentifierForSaving)
        }
        set {
            UserPreferences.defaults.set(newValue, forKey: PreferencesKeys.calendarIdentifierForSaving)
        }
    }
    
    @Published var autoSuggestToday: Bool = {
        return defaults.bool(forKey: PreferencesKeys.autoSuggestTodayForNewReminders)
    }() {
        didSet {
            UserPreferences.defaults.set(autoSuggestToday, forKey: PreferencesKeys.autoSuggestTodayForNewReminders)
        }
    }
    
    @Published var removeParsedDateFromTitle: Bool = {
        return defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.removeParsedDateFromTitle)
    }() {
        didSet {
            UserPreferences.defaults.set(removeParsedDateFromTitle, forKey: PreferencesKeys.removeParsedDateFromTitle)
        }
    }
    
    @Published var showUncompletedOnly: Bool = {
        return defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.showUncompletedOnly)
    }() {
        didSet {
            UserPreferences.defaults.set(showUncompletedOnly, forKey: PreferencesKeys.showUncompletedOnly)
        }
    }
    
    @Published var upcomingRemindersInterval: ReminderInterval = {
        guard let intervalData = defaults.data(forKey: PreferencesKeys.upcomingRemindersInterval),
              let interval = try? JSONDecoder().decode(ReminderInterval.self, from: intervalData) else {
            return .today
        }
        return interval
    }() {
        didSet {
            let intervalData = try? JSONEncoder().encode(upcomingRemindersInterval)
            UserPreferences.defaults.set(intervalData, forKey: PreferencesKeys.upcomingRemindersInterval)
        }
    }
    
    @Published var filterUpcomingRemindersByCalendar: Bool = {
        return defaults.bool(forKey: PreferencesKeys.filterUpcomingRemindersByCalendar)
    }() {
        didSet {
            UserPreferences.defaults.set(
                filterUpcomingRemindersByCalendar,
                forKey: PreferencesKeys.filterUpcomingRemindersByCalendar
            )
        }
    }
    
    @Published var showUpcomingReminders: Bool = {
        return defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.showUpcomingReminders)
    }() {
        didSet {
            UserPreferences.defaults.set(showUpcomingReminders, forKey: PreferencesKeys.showUpcomingReminders)
        }
    }
    
    var atLeastOneFilterIsSelected: Bool {
        return
            showUpcomingReminders ||
            preferredCalendarIdentifiersFilter == nil ||
            !(preferredCalendarIdentifiersFilter ?? []).isEmpty
    }
    
    var launchAtLoginIsEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                let service = SMAppService.loginItem(identifier: AppConstants.launcherBundleId)
                return service.status == .enabled
            } else {
                // Fallback: reflect the last requested state without using deprecated APIs
                return UserPreferences.defaults.bool(forKey: "launchAtLoginCached")
            }
        }

        set {
            if #available(macOS 13.0, *) {
                let service = SMAppService.loginItem(identifier: AppConstants.launcherBundleId)
                do {
                    if newValue { try service.register() } else { try service.unregister() }
                } catch {
                    // As a fallback, attempt legacy API if available
                    SMLoginItemSetEnabled(AppConstants.launcherBundleId as CFString, newValue)
                }
            } else {
                SMLoginItemSetEnabled(AppConstants.launcherBundleId as CFString, newValue)
            }
            UserPreferences.defaults.set(newValue, forKey: "launchAtLoginCached")
        }
    }
    
    @Published var rmbColorScheme: RmbColorScheme = {
        guard let rmbColorSchemeString = defaults.string(forKey: PreferencesKeys.rmbColorScheme) else {
            return .system
        }
        return RmbColorScheme(rawValue: rmbColorSchemeString) ?? .system
    }() {
        didSet {
            UserPreferences.defaults.set(rmbColorScheme.rawValue, forKey: PreferencesKeys.rmbColorScheme)
        }
    }
    
    @Published var backgroundIsTransparent: Bool = {
        return defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.backgroundIsTransparent)
    }() {
        didSet {
            UserPreferences.defaults.set(backgroundIsTransparent, forKey: PreferencesKeys.backgroundIsTransparent)
        }
    }
    
    @Published var menuBarCounterType: RmbMenuBarCounterType = {
        guard let counterTypeData = defaults.data(forKey: PreferencesKeys.menuBarCounterType),
              let counterType = try? JSONDecoder().decode(RmbMenuBarCounterType.self, from: counterTypeData) else {
            return .today
        }
        return counterType
    }() {
        didSet {
            let counterTypeData = try? JSONEncoder().encode(menuBarCounterType)
            UserPreferences.defaults.set(counterTypeData, forKey: PreferencesKeys.menuBarCounterType)
        }
    }
    
    @Published var filterMenuBarCountByCalendar: Bool = {
        return defaults.bool(forKey: PreferencesKeys.filterMenuBarCountByCalendar)
    }() {
        didSet {
            UserPreferences.defaults.set(
                filterMenuBarCountByCalendar,
                forKey: PreferencesKeys.filterMenuBarCountByCalendar
            )
        }
    }
    
    @Published var preferredLanguage: String? = {
        return defaults.string(forKey: PreferencesKeys.preferredLanguage)
    }() {
        didSet {
            UserPreferences.defaults.set(preferredLanguage, forKey: PreferencesKeys.preferredLanguage)
        }
    }

    // MARK: - Sync Summary
    @Published var lastSyncSummary: String? = {
        return defaults.string(forKey: PreferencesKeys.lastSyncSummary)
    }() {
        didSet {
            UserPreferences.defaults.set(lastSyncSummary, forKey: PreferencesKeys.lastSyncSummary)
        }
    }

    // MARK: - Authentication / Session
    @Published var staySignedIn: Bool = {
        return defaults.bool(forKey: PreferencesKeys.staySignedIn)
    }() {
        didSet {
            UserPreferences.defaults.set(staySignedIn, forKey: PreferencesKeys.staySignedIn)
        }
    }

    @Published var lastSyncDate: Date? = {
        guard defaults.object(forKey: PreferencesKeys.lastSyncDate) != nil else { return nil }
        let timestamp = defaults.double(forKey: PreferencesKeys.lastSyncDate)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }() {
        didSet {
            if let date = lastSyncDate {
                UserPreferences.defaults.set(date.timeIntervalSince1970, forKey: PreferencesKeys.lastSyncDate)
            } else {
                UserPreferences.defaults.removeObject(forKey: PreferencesKeys.lastSyncDate)
            }
        }
    }

    // Timestamp of the last full sync (6-hour cadence)
    @Published var lastFullSyncDate: Date? = {
        guard defaults.object(forKey: PreferencesKeys.lastFullSyncDate) != nil else { return nil }
        let ts = defaults.double(forKey: PreferencesKeys.lastFullSyncDate)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }() {
        didSet {
            if let date = lastFullSyncDate {
                UserPreferences.defaults.set(date.timeIntervalSince1970, forKey: PreferencesKeys.lastFullSyncDate)
            } else {
                UserPreferences.defaults.removeObject(forKey: PreferencesKeys.lastFullSyncDate)
            }
        }
    }

    // Timestamp of the last delta sync (hourly cadence)
    @Published var lastDeltaSyncDate: Date? = {
        guard defaults.object(forKey: PreferencesKeys.lastDeltaSyncDate) != nil else { return nil }
        let ts = defaults.double(forKey: PreferencesKeys.lastDeltaSyncDate)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }() {
        didSet {
            if let date = lastDeltaSyncDate {
                UserPreferences.defaults.set(date.timeIntervalSince1970, forKey: PreferencesKeys.lastDeltaSyncDate)
            } else {
                UserPreferences.defaults.removeObject(forKey: PreferencesKeys.lastDeltaSyncDate)
            }
        }
    }

    // MARK: - Background Sync
    @Published var enableBackgroundSync: Bool = {
        return defaults.bool(forKey: PreferencesKeys.enableBackgroundSync)
    }() {
        didSet { UserPreferences.defaults.set(enableBackgroundSync, forKey: PreferencesKeys.enableBackgroundSync) }
    }

    @Published var backgroundSyncIntervalMinutes: Int = {
        let interval = defaults.integer(forKey: PreferencesKeys.backgroundSyncIntervalMinutes)
        return interval > 0 ? interval : 60
    }() {
        didSet {
            UserPreferences.defaults.set(
                backgroundSyncIntervalMinutes,
                forKey: PreferencesKeys.backgroundSyncIntervalMinutes
            )
        }
    }

    // MARK: - Sync Behavior
    @Published var syncDryRun: Bool = {
        return defaults.bool(forKey: PreferencesKeys.syncDryRun)
    }() {
        didSet { UserPreferences.defaults.set(syncDryRun, forKey: PreferencesKeys.syncDryRun) }
    }

    @Published var showBobMetadataInNotes: Bool = {
        if defaults.object(forKey: PreferencesKeys.showBobMetadataInNotes) == nil {
            return true
        }
        return defaults.bool(forKey: PreferencesKeys.showBobMetadataInNotes)
    }() {
        didSet {
            UserPreferences.defaults.set(showBobMetadataInNotes, forKey: PreferencesKeys.showBobMetadataInNotes)
        }
    }

    // MARK: - Theme→Calendar mapping
    @Published var themeCalendarMap: [String: String] = {
        return defaults.dictionary(forKey: PreferencesKeys.themeCalendarMap) as? [String: String] ?? [:]
    }() {
        didSet { UserPreferences.defaults.set(themeCalendarMap, forKey: PreferencesKeys.themeCalendarMap) }
    }

    // MARK: - Triage Classification
    @Published var enableTriageClassification: Bool = {
        return defaults.bool(forKey: PreferencesKeys.enableTriageClassification)
    }() {
        didSet {
            UserPreferences.defaults.set(
                enableTriageClassification,
                forKey: PreferencesKeys.enableTriageClassification
            )
        }
    }

    // Optional: list names. If empty, classification is skipped.
    @Published var triageCalendarName: String? = {
        return defaults.string(forKey: PreferencesKeys.triageCalendarName)
    }() {
        didSet { UserPreferences.defaults.set(triageCalendarName, forKey: PreferencesKeys.triageCalendarName) }
    }

    @Published var workCalendarName: String? = {
        return defaults.string(forKey: PreferencesKeys.workCalendarName)
    }() {
        didSet { UserPreferences.defaults.set(workCalendarName, forKey: PreferencesKeys.workCalendarName) }
    }

    // Optional: external HTTP endpoint for LLM classification.
    // Expected to accept JSON and return { persona: "work"|"personal", confidence: Number }
    @Published var llmTriageEndpoint: String? = {
        return defaults.string(forKey: PreferencesKeys.llmTriageEndpoint)
    }() {
        didSet { UserPreferences.defaults.set(llmTriageEndpoint, forKey: PreferencesKeys.llmTriageEndpoint) }
    }
}
