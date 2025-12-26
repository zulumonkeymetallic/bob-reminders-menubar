import Foundation
import EventKit

extension EKReminder {
    private var maxDueDate: Date? {
        guard let date = dueDateComponents?.date else {
            return nil
        }
        
        if hasTime {
            // if the reminder has a time then it expires after its own date.
            return date
        }

        // if the reminder doesn’t have a time then it expires the next day.
        return Calendar.current.date(byAdding: .day, value: 1, to: date)
    }
    
    var hasDueDate: Bool {
        return dueDateComponents != nil
    }
    
    var hasTime: Bool {
        return dueDateComponents?.hour != nil
    }
    
    var ekPriority: EKReminderPriority {
        get {
            return EKReminderPriority(rawValue: UInt(self.priority)) ?? .none
        }
        set {
            self.priority = Int(newValue.rawValue)
        }
    }
    
    var isExpired: Bool {
        maxDueDate?.isPast ?? false
    }
    
    var relativeDateDescription: String? {
        guard let date = dueDateComponents?.date else {
            return nil
        }
        
        return date.relativeDateDescription(withTime: hasTime)
    }
    
    private var reminderBackingObject: AnyObject? {
        let backingObjectSelector = NSSelectorFromString("backingObject")
        let reminderSelector = NSSelectorFromString("_reminder")
        
        guard let unmanagedBackingObject = self.perform(backingObjectSelector),
              let unmanagedReminder = unmanagedBackingObject.takeUnretainedValue().perform(reminderSelector) else {
            return nil
        }
        
        return unmanagedReminder.takeUnretainedValue()
    }
    
    // NOTE: This is a workaround to access the URL saved in a reminder.
    // This property is not accessible through the conventional API.
    var attachedUrl: URL? {
        let attachmentsSelector = NSSelectorFromString("attachments")
        
        guard let unmanagedAttachments = reminderBackingObject?.perform(attachmentsSelector),
              let attachments = unmanagedAttachments.takeUnretainedValue() as? [AnyObject] else {
            return nil
        }
        
        for item in attachments {
            // NOTE: Attachments can be of type REMURLAttachment or REMImageAttachment.
            let attachmentType = type(of: item).description()
            guard attachmentType == "REMURLAttachment" else {
                continue
            }
            
            guard let unmanagedUrl = item.perform(NSSelectorFromString("url")),
                  let url = unmanagedUrl.takeUnretainedValue() as? URL else {
                continue
            }
            
            return url
        }
        
        return nil
    }
    
    // NOTE: This is a workaround to access the mail linked to a reminder.
    // This property is not accessible through the conventional API.
    var mailUrl: URL? {
        let userActivitySelector = NSSelectorFromString("userActivity")
        let storageSelector = NSSelectorFromString("storage")
        
        guard let unmanagedUserActivity = reminderBackingObject?.perform(userActivitySelector),
              let unmanagedUserActivityStorage = unmanagedUserActivity.takeUnretainedValue().perform(storageSelector),
              let userActivityStorageData = unmanagedUserActivityStorage.takeUnretainedValue() as? Data else {
            return nil
        }
        
        // NOTE: UserActivity type is UniversalLink, so in theory it could be targeting apps other than Mail.
        // If it starts with "message:" then it is related to Mail.
        guard let userActivityStorageString = String(bytes: userActivityStorageData, encoding: .utf8),
              userActivityStorageString.starts(with: "message:") else {
            return nil
        }
        
        return URL(string: userActivityStorageString)
    }
    
    // NOTE: This is a workaround to access the parent reminder id of a reminder.
    // This property is not accessible through the conventional API.
    var parentId: String? {
        let parentReminderSelector = NSSelectorFromString("parentReminderID")
        let uuidSelector = NSSelectorFromString("uuid")
        
        guard let unmanagedParentReminder = reminderBackingObject?.perform(parentReminderSelector),
              let unmanagedParentReminderId = unmanagedParentReminder.takeUnretainedValue().perform(uuidSelector),
              let parentReminderId = unmanagedParentReminderId.takeUnretainedValue() as? UUID else {
            return nil
        }
        
        return parentReminderId.uuidString
    }
    
    func update(with rmbReminder: RmbReminder) {
        let trimmedTitle = rmbReminder.title.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            title = trimmedTitle
        }
        
        notes = rmbReminder.notes
        
        // NOTE: Preventing unnecessary reminder dueDate/EKAlarm overwriting.
        if rmbReminder.hasDateChanges {
            removeDueDateAndAlarms()
            if rmbReminder.hasDueDate {
                addDueDateAndAlarm(for: rmbReminder.date, withTime: rmbReminder.hasTime)
            } else {
                // NOTE: A reminder that has no due date cannot be a repeating reminder
                removeAllRecurrenceRules()
            }
        }
        
        ekPriority = rmbReminder.priority
        calendar = rmbReminder.calendar
    }
    
    func removeDueDateAndAlarms() {
        dueDateComponents = nil
        alarms?.forEach { alarm in
            removeAlarm(alarm)
        }
    }

    func removeAllRecurrenceRules() {
        recurrenceRules?.forEach { rule in
            removeRecurrenceRule(rule)
        }
    }

    func addDueDateAndAlarm(for date: Date, withTime hasTime: Bool) {
        let dateComponents = date.dateComponents(withTime: hasTime)
        dueDateComponents = dateComponents

        // NOTE: In Apple Reminders only reminders with time have an alarm.
        if hasTime, let dueDate = dateComponents.date {
            let ekAlarm = EKAlarm(absoluteDate: dueDate)
            addAlarm(ekAlarm)
        }
    }

    @MainActor
    @discardableResult
    func rmbUpdateTag(newTag: String?, removing previousTag: String?) -> Bool {
        // Simplified: read current tags, apply change, and write via rmbSetTagsList
        func normalized(_ string: String?) -> String? {
            guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        var tags = rmbCurrentTags()
        if let prev = normalized(previousTag) {
            if let idx = tags.firstIndex(where: { $0.compare(prev, options: .caseInsensitive) == .orderedSame }) {
                tags.remove(at: idx)
            }
        }
        if let desired = normalized(newTag) {
            // Canonicalize to single explicit tag
            tags = [desired]
        }
        return rmbSetTagsList(newTags: tags)
    }

    @MainActor
    func rmbCurrentTags() -> [String] {
        // Read canonical tags from note metadata (#tags: value)
        // Supports comma-separated tags: "#tags: tagA, tagB, tagC"
        let content = notes ?? ""
        let parts = content.components(separatedBy: "\n")
        if let sep = parts.lastIndex(of: "-------") {
            for line in parts.suffix(from: sep + 1) where line.hasPrefix("#tags: ") {
                let raw = String(line.dropFirst("#tags: ".count))
                let tokens = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                let cleaned = tokens.filter { !$0.isEmpty }
                return cleaned
            }
        }
        return []
    }

    @MainActor
    @discardableResult
    func rmbSetTagsList(newTags: [String]) -> Bool {
        // Write the #tags line using a comma-separated list. Removes the line if list is empty.
        var seen = Set<String>()
        let desiredList = newTags.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let key = trimmed.lowercased()
            if seen.contains(key) { return nil }
            seen.insert(key)
            return trimmed
        }
        let desired = desiredList.joined(separator: ", ")

        let originalNotes = notes ?? ""
        var lines = originalNotes.components(separatedBy: "\n")
        if let sepIndex = lines.lastIndex(of: "-------") {
            var meta = Array(lines.suffix(from: sepIndex + 1))
            var head = meta.first ?? "BOB:"
            if !head.hasPrefix("BOB:") {
                head = "BOB:"
                meta.insert(head, at: 0)
            }
            let tagIdx = meta.firstIndex(where: { $0.hasPrefix("#tags:") })
            let newLine = desired.isEmpty ? nil : "#tags: \(desired)"
            var changed = false
            if let idx = tagIdx {
                if let newLine {
                    if meta[idx] != newLine { meta[idx] = newLine; changed = true }
                } else {
                    meta.remove(at: idx)
                    changed = true
                }
            } else if let newLine {
                meta.append(newLine)
                changed = true
            }
            if changed {
                let prefix = Array(lines.prefix(upTo: sepIndex + 1))
                let rebuilt = prefix + meta
                notes = rebuilt.joined(separator: "\n")
                return true
            }
            return false
        }
        // No metadata yet; only add if we have tags
        guard !desired.isEmpty else { return false }
        var rebuilt = lines
        if !rebuilt.isEmpty,
           let last = rebuilt.last,
           !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rebuilt.append("")
        }
        rebuilt.append("-------")
        rebuilt.append("BOB:")
        rebuilt.append("#tags: \(desired)")
        notes = rebuilt.joined(separator: "\n")
        return true
    }
}
