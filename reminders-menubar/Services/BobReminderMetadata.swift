import Foundation
import EventKit

/// Represents the structured metadata embedded inside reminder notes so we can
/// round-trip between BOB entities (tasks & stories) and iOS Reminders.
struct BobReminderMetadata {
    enum EntityType: String {
        case task
        case story

        var bobIdPrefix: String { rawValue + ":" }
    }

    enum ValidationError: Error, CustomStringConvertible {
        case missingKey(String)
        case malformedValue(key: String, value: String)

        var description: String {
            switch self {
            case .missingKey(let key):
                return "Missing metadata line for \(key)"
            case .malformedValue(let key, let value):
                return "Malformed value for \(key): \(value)"
            }
        }
    }

    static let dividerLine = "------"
    static let syncMarker = "[Auto-synced from BOB]"
    static let metadataKeys: [String] = [
        "Task", "Description", "Story", "Story-Name", "Goal", "Theme", "Start", "End", "Sprint", "BOB-ID"
    ]

    let entityType: EntityType
    let entityId: String
    let taskTitle: String?
    let taskDescription: String?
    let storyTitle: String?
    let storyRef: String?
    let goalTitle: String?
    let themeName: String?
    let startDate: Date?
    let endDate: Date?
    let sprintName: String?
    let lastSynced: Date

    init(
        entityType: EntityType,
        entityId: String,
        taskTitle: String?,
        taskDescription: String?,
        storyTitle: String?,
        storyRef: String?,
        goalTitle: String?,
        themeName: String?,
        startDate: Date?,
        endDate: Date?,
        sprintName: String?,
        lastSynced: Date = Date()
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.taskTitle = taskTitle
        self.taskDescription = taskDescription
        self.storyTitle = storyTitle
        self.storyRef = storyRef
        self.goalTitle = goalTitle
        self.themeName = themeName
        self.startDate = startDate
        self.endDate = endDate
        self.sprintName = sprintName
        self.lastSynced = lastSynced
    }

    var isStory: Bool { entityType == .story }

    var bobIdentifier: String { "\(entityType.rawValue):\(entityId)" }

    func apply(into reminder: EKReminder, preferredTitle: String? = nil, sprintTagging: Bool = true) {
        reminder.title = makeReminderTitle(existing: preferredTitle ?? reminder.title)
        reminder.notes = buildNote()
        if sprintTagging, let sprint = sprintName, !sprint.isEmpty {
            reminder.title = prependSprint(reminder.title, sprint: sprint)
        }
        if isStory {
            reminder.title = ensureStoryTag(in: reminder.title)
        }
    }

    private func makeReminderTitle(existing: String?) -> String {
        if let existing, !existing.isEmpty {
            return existing
        }
        switch entityType {
        case .task:
            return taskTitle ?? "BOB Task"
        case .story:
            return storyTitle.map { "#story \($0)" } ?? "#story BOB Story"
        }
    }

    private func prependSprint(_ title: String, sprint: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.contains("] ") {
            return trimmed
        }
        return "[\(sprint)] " + trimmed
    }

    private func ensureStoryTag(in title: String) -> String {
        if title.contains("#story") { return title }
        return "#story " + title
    }

    private func buildNote() -> String {
        var lines: [String] = []
        let dateFormatter = Self.displayDateFormatter
        let startString = formatted(date: startDate, formatter: dateFormatter)
        let endString = formatted(date: endDate, formatter: dateFormatter)
        let sprintString = sprintName ?? "-"

        let clean: (String?) -> String? = { value in
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }

        if entityType == .task {
            lines.append("Task: \(clean(taskTitle) ?? "-")")
            if let desc = clean(taskDescription) {
                lines.append("Description: \(desc)")
            }
        }

        let storyLine = clean(storyRef) ?? clean(storyTitle) ?? (isStory ? clean(taskTitle) : nil) ?? "-"
        lines.append("Story: \(storyLine)")

        if let storyName = clean(storyTitle) {
            lines.append("Story-Name: \(storyName)")
        }

        lines.append("Goal: \(clean(goalTitle) ?? "-")")
        lines.append("Theme: \(clean(themeName) ?? "-")")
        lines.append("Start: \(startString)")
        lines.append("End: \(endString)")
        lines.append("Sprint: \(clean(sprintName) ?? "-")")
        lines.append("BOB-ID: \(bobIdentifier)")
        lines.append(Self.dividerLine)
        lines.append(Self.syncMarker)
        return lines.joined(separator: "\n")
    }

    private func formatted(date: Date?, formatter: DateFormatter) -> String {
        guard let date else { return "-" }
        return formatter.string(from: date)
    }

    static func parse(note: String?) -> BobReminderMetadata? {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = note.split(separator: "\n").map { String($0) }
        var dict: [String: String] = [:]
        for line in lines {
            if line == dividerLine || line == syncMarker { continue }
            let comps = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard comps.count == 2 else { continue }
            dict[comps[0]] = comps[1]
        }

        guard let bobId = dict["BOB-ID"], let (type, id) = parseEntity(from: bobId) else { return nil }

        let formatter = displayDateFormatter
        let storyIdentifier = dict["Story"]
        let storyName = dict["Story-Name"] ?? storyIdentifier

        let metadata = BobReminderMetadata(
            entityType: type,
            entityId: id,
            taskTitle: dict["Task"],
            taskDescription: dict["Description"],
            storyTitle: storyName,
            storyRef: storyIdentifier,
            goalTitle: dict["Goal"],
            themeName: dict["Theme"],
            startDate: parseDate(dict["Start"], formatter: formatter),
            endDate: parseDate(dict["End"], formatter: formatter),
            sprintName: dict["Sprint"],
            lastSynced: Date()
        )
        return metadata
    }

    static func validate(note: String?) -> [ValidationError] {
        guard let note, !note.isEmpty else {
            return [.missingKey("BOB-ID")]
        }
        let lines = note.split(separator: "\n").map { String($0) }
        var presentKeys = Set<String>()
        for line in lines {
            if line == dividerLine || line == syncMarker { continue }
            let comps = line.split(separator: ":", maxSplits: 1)
            guard comps.count == 2 else { continue }
            presentKeys.insert(String(comps[0]))
        }

        var errors: [ValidationError] = []
        let required: [String] = ["Goal", "Theme", "Start", "End", "Sprint", "BOB-ID"]
        for key in required where !presentKeys.contains(key) {
            errors.append(.missingKey(key))
        }

        if let bobId = presentKeys.contains("BOB-ID") ? valueFor(key: "BOB-ID", in: lines) : nil {
            if parseEntity(from: bobId) == nil {
                errors.append(.malformedValue(key: "BOB-ID", value: bobId))
            }
        }
        return errors
    }

    private static func valueFor(key: String, in lines: [String]) -> String? {
        for line in lines {
            if line.hasPrefix("\(key):") {
                return line.split(separator: ":", maxSplits: 1).dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    private static func parseEntity(from bobId: String) -> (EntityType, String)? {
        let comps = bobId.split(separator: ":", maxSplits: 1).map { String($0) }
        guard comps.count == 2, let type = EntityType(rawValue: comps[0]), !comps[1].isEmpty else { return nil }
        return (type, comps[1])
    }

    private static func parseDate(_ raw: String?, formatter: DateFormatter) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "-" { return nil }
        return formatter.date(from: trimmed)
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension BobReminderMetadata {
    static func themeName(from rawTheme: Any?) -> String? {
        if let theme = rawTheme as? String, !theme.isEmpty { return normalizeTheme(theme) }
        if let themeNumber = rawTheme as? Int {
            return themeName(from: themeNumber)
        }
        if let themeDouble = rawTheme as? Double {
            return themeName(from: Int(themeDouble))
        }
        return nil
    }

    private static func normalizeTheme(_ value: String) -> String {
        let upper = value.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        switch upper {
        case "1", "Health": return "Health"
        case "2", "Growth": return "Growth"
        case "3", "Wealth": return "Wealth"
        case "4", "Tribe": return "Tribe"
        case "5", "Home": return "Home"
        default: return upper
        }
    }

    private static func themeName(from number: Int) -> String {
        switch number {
        case 1: return "Health"
        case 2: return "Growth"
        case 3: return "Wealth"
        case 4: return "Tribe"
        case 5: return "Home"
        default: return "Theme #\(number)"
        }
    }
}
