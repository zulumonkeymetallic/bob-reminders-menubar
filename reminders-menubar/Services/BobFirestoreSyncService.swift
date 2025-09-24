import Foundation
import EventKit

#if canImport(FirebaseFirestore) && canImport(FirebaseCore)
import FirebaseFirestore

@MainActor
private struct BobFirestoreSyncContext {
    let tasks: [FirestoreTaskEntity]
    let tasksById: [String: FirestoreTaskEntity]
    let stories: [String: FirestoreStoryEntity]
    let goals: [String: FirestoreGoalEntity]
    let sprints: [String: FirestoreSprintEntity]
    let storyTaskCounts: [String: Int]
}

@MainActor
class BobFirestoreSyncService: ObservableObject {
    static let shared = BobFirestoreSyncService()
    private init() {}

    private var db: Firestore { Firestore.firestore() }

    func syncFromBob() async {
        FirebaseManager.shared.configureIfNeeded()
        guard let uid = FirebaseManager.shared.currentUid else { return }

        do {
            let context = try await loadContext(for: uid)
            guard !context.tasks.isEmpty || !context.stories.isEmpty else { return }

            let defaultCalendar = RemindersService.shared.getDefaultCalendar() ?? RemindersService.shared.getCalendars().first
            guard let calendar = defaultCalendar else { return }

            var taskUpdates: [(String, String)] = []
            var storyUpdates: [(String, String)] = []

            for task in context.tasks {
                guard !task.isDeleted, let storyId = task.resolvedStoryId else { continue }
                guard let story = context.stories[storyId] else { continue }
                let goal = context.goal(for: task, story: story)
                let sprint = context.sprint(for: task, story: story)
                if let rid = upsertReminder(for: task, story: story, goal: goal, sprint: sprint, calendar: calendar), task.reminderId != rid {
                    taskUpdates.append((task.id, rid))
                }
            }

            for story in context.stories.values {
                let taskCount = context.storyTaskCounts[story.id, default: 0]
                guard taskCount == 0 else { continue }
                let goal = context.goal(for: story)
                let sprint = context.sprint(for: story)
                if let rid = upsertReminder(for: story, goal: goal, sprint: sprint, calendar: calendar), story.reminderId != rid {
                    storyUpdates.append((story.id, rid))
                }
            }

            try await persistReminderMappings(taskUpdates: taskUpdates, storyUpdates: storyUpdates)
            try await syncInboundChanges(context: context)
        } catch {
            print("BobFirestoreSyncService.syncFromBob error", error)
        }
    }

    func reportCompletion(for reminder: EKReminder) async {
        FirebaseManager.shared.configureIfNeeded()
        guard let uid = FirebaseManager.shared.currentUid else { return }
        do {
            // Find task by reminderId for this owner
            let q = db.collection("tasks").whereField("ownerUid", isEqualTo: uid).whereField("reminderId", isEqualTo: reminder.calendarItemIdentifier).limit(to: 1)
            let snap = try await q.getDocuments()
            if let doc = snap.documents.first {
                try await doc.reference.setData([
                    "status": reminder.isCompleted ? 2 : 0,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            } else {
                // Attempt to map to a standalone story reminder
                let storyQuery = db.collection("stories")
                    .whereField("ownerUid", isEqualTo: uid)
                    .whereField("reminderId", isEqualTo: reminder.calendarItemIdentifier)
                    .limit(to: 1)
                let storySnap = try await storyQuery.getDocuments()
                if let doc = storySnap.documents.first {
                    try await doc.reference.setData([
                        "status": reminder.isCompleted ? 4 : 1,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], merge: true)
                }
            }
        } catch {
            // ignore
        }
    }

    private func loadContext(for uid: String) async throws -> BobFirestoreSyncContext {
        let tasksSnap = try await db.collection("tasks").whereField("ownerUid", isEqualTo: uid).getDocuments()
        let taskEntities = tasksSnap.documents.compactMap { FirestoreTaskEntity(document: $0) }
        let tasksById = Dictionary(uniqueKeysWithValues: taskEntities.map { ($0.id, $0) })

        let storiesSnap = try await db.collection("stories").whereField("ownerUid", isEqualTo: uid).getDocuments()
        let storyEntities = storiesSnap.documents.compactMap { FirestoreStoryEntity(document: $0) }
        let storiesById = Dictionary(uniqueKeysWithValues: storyEntities.map { ($0.id, $0) })

        var storyTaskCounts: [String: Int] = [:]
        for task in taskEntities {
            if let storyId = task.resolvedStoryId {
                storyTaskCounts[storyId, default: 0] += 1
            }
        }

        var goalIds = Set<String>()
        for task in taskEntities {
            if let gid = task.goalId { goalIds.insert(gid) }
            if let storyId = task.resolvedStoryId, let story = storiesById[storyId], let gid = story.goalId {
                goalIds.insert(gid)
            }
        }
        for story in storyEntities {
            if let gid = story.goalId { goalIds.insert(gid) }
        }

        var sprintIds = Set<String>()
        for task in taskEntities {
            if let sid = task.sprintId { sprintIds.insert(sid) }
            if let storyId = task.resolvedStoryId, let story = storiesById[storyId], let sid = story.sprintId {
                sprintIds.insert(sid)
            }
        }
        for story in storyEntities {
            if let sid = story.sprintId { sprintIds.insert(sid) }
        }

        let goals = try await fetchGoals(ownerUid: uid, ids: goalIds)
        let sprints = try await fetchSprints(ownerUid: uid, ids: sprintIds)

        return BobFirestoreSyncContext(
            tasks: taskEntities,
            tasksById: tasksById,
            stories: storiesById,
            goals: goals,
            sprints: sprints,
            storyTaskCounts: storyTaskCounts
        )
    }

    private func fetchGoals(ownerUid uid: String, ids: Set<String>) async throws -> [String: FirestoreGoalEntity] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: FirestoreGoalEntity] = [:]
        let goalsSnap = try await db.collection("goals").whereField("ownerUid", isEqualTo: uid).getDocuments()
        for doc in goalsSnap.documents {
            if let goal = FirestoreGoalEntity(document: doc), ids.contains(goal.id) {
                result[goal.id] = goal
            }
        }
        return result
    }

    private func fetchSprints(ownerUid uid: String, ids: Set<String>) async throws -> [String: FirestoreSprintEntity] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: FirestoreSprintEntity] = [:]
        let sprintsSnap = try await db.collection("sprints").whereField("ownerUid", isEqualTo: uid).getDocuments()
        for doc in sprintsSnap.documents {
            if let sprint = FirestoreSprintEntity(document: doc), ids.contains(sprint.id) {
                result[sprint.id] = sprint
            }
        }
        return result
    }

    private func upsertReminder(
        for task: FirestoreTaskEntity,
        story: FirestoreStoryEntity?,
        goal: FirestoreGoalEntity?,
        sprint: FirestoreSprintEntity?,
        calendar: EKCalendar
    ) -> String? {
        guard let story else { return nil }

        let reminder = existingReminder(with: task.reminderId) ?? EKReminder(eventStore: RemindersService.shared.eventStore)
        if reminder.calendar == nil { reminder.calendar = calendar }

        reminder.title = task.title
        reminder.isCompleted = task.isCompleted

        let startDate = task.startDate ?? story.startDate ?? sprint?.startDate
        let endDate = resolveEndDate(taskEnd: task.dueDate, storyEnd: story.dueDate ?? story.endDate, sprintEnd: sprint?.endDate)
        apply(date: endDate, to: &reminder.dueDateComponents)
        apply(date: startDate, to: &reminder.startDateComponents)

        let themeSource: Any? = task.theme ?? goal?.theme ?? story.theme
        let metadata = BobReminderMetadata(
            entityType: .task,
            entityId: task.id,
            taskTitle: task.title,
            taskDescription: task.description,
            storyTitle: story.title,
            storyRef: story.ref,
            goalTitle: goal?.title,
            themeName: BobReminderMetadata.themeName(from: themeSource),
            startDate: startDate,
            endDate: endDate,
            sprintName: sprint?.name
        )
        metadata.apply(into: reminder, preferredTitle: task.title)
        validateMetadata(of: reminder, entityId: task.id)
        RemindersService.shared.save(reminder: reminder)
        return reminder.calendarItemIdentifier
    }

    private func upsertReminder(
        for story: FirestoreStoryEntity,
        goal: FirestoreGoalEntity?,
        sprint: FirestoreSprintEntity?,
        calendar: EKCalendar
    ) -> String? {
        let reminder = existingReminder(with: story.reminderId) ?? EKReminder(eventStore: RemindersService.shared.eventStore)
        if reminder.calendar == nil { reminder.calendar = calendar }
        reminder.title = story.title
        reminder.isCompleted = story.isCompleted

        let startDate = story.startDate ?? sprint?.startDate
        let endDate = resolveEndDate(taskEnd: story.dueDate ?? story.endDate, storyEnd: story.dueDate ?? story.endDate, sprintEnd: sprint?.endDate)
        apply(date: endDate, to: &reminder.dueDateComponents)
        apply(date: startDate, to: &reminder.startDateComponents)

        let themeSource: Any? = story.theme ?? goal?.theme
        let metadata = BobReminderMetadata(
            entityType: .story,
            entityId: story.id,
            taskTitle: nil,
            taskDescription: story.description,
            storyTitle: story.title,
            storyRef: story.ref,
            goalTitle: goal?.title,
            themeName: BobReminderMetadata.themeName(from: themeSource),
            startDate: startDate,
            endDate: endDate,
            sprintName: sprint?.name
        )
        metadata.apply(into: reminder, preferredTitle: story.title)
        validateMetadata(of: reminder, entityId: story.id)
        RemindersService.shared.save(reminder: reminder)
        return reminder.calendarItemIdentifier
    }

    private func existingReminder(with identifier: String?) -> EKReminder? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return RemindersService.shared.getReminder(withIdentifier: identifier)
    }

    private func resolveEndDate(taskEnd: Date?, storyEnd: Date?, sprintEnd: Date?) -> Date? {
        if let taskEnd { return taskEnd }
        if let storyEnd { return storyEnd }
        return sprintEnd
    }

    private func apply(date: Date?, to components: inout DateComponents?) {
        guard let date else {
            components = nil
            return
        }
        let calendar = Calendar.current
        let hasTime = calendar.component(.hour, from: date) != 0 || calendar.component(.minute, from: date) != 0
        components = date.dateComponents(withTime: hasTime)
    }

    private func persistReminderMappings(
        taskUpdates: [(String, String)],
        storyUpdates: [(String, String)]
    ) async throws {
        guard !taskUpdates.isEmpty || !storyUpdates.isEmpty else { return }
        let tasksCollection = db.collection("tasks")
        for (id, rid) in taskUpdates {
            try await tasksCollection.document(id).setData([
                "reminderId": rid,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }

        guard !storyUpdates.isEmpty else { return }
        let storiesCollection = db.collection("stories")
        for (id, rid) in storyUpdates {
            try await storiesCollection.document(id).setData([
                "reminderId": rid,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }

    private func validateMetadata(of reminder: EKReminder, entityId: String) {
        let errors = BobReminderMetadata.validate(note: reminder.notes)
        guard !errors.isEmpty else { return }
        let message = errors.map { $0.description }.joined(separator: "; ")
        print("Metadata validation issues for \(entityId): \(message)")
    }

    private func syncInboundChanges(context: BobFirestoreSyncContext) async throws {
        let calendars = RemindersService.shared.getCalendars()
        guard !calendars.isEmpty else { return }
        let reminders = await RemindersService.shared.loadReminders(in: calendars)
        guard !reminders.isEmpty else { return }

        var taskUpdates: [(id: String, payload: [String: Any])] = []
        var storyUpdates: [(id: String, payload: [String: Any])] = []

        for reminder in reminders {
            let metadata = BobReminderMetadata.parse(note: reminder.notes)
            if metadata == nil, let notes = reminder.notes, notes.contains(BobReminderMetadata.syncMarker) {
                print("Warning: Unable to parse BOB metadata for reminder \(reminder.calendarItemIdentifier)")
            }
            guard let metadata else { continue }
            switch metadata.entityType {
            case .task:
                if let update = buildInboundTaskUpdate(reminder: reminder, metadata: metadata, context: context) {
                    taskUpdates.append(update)
                }
            case .story:
                if let update = buildInboundStoryUpdate(reminder: reminder, metadata: metadata, context: context) {
                    storyUpdates.append(update)
                }
            }
        }

        if !taskUpdates.isEmpty {
            let collection = db.collection("tasks")
            for update in taskUpdates {
                try await collection.document(update.id).setData(update.payload, merge: true)
            }
        }

        if !storyUpdates.isEmpty {
            let collection = db.collection("stories")
            for update in storyUpdates {
                try await collection.document(update.id).setData(update.payload, merge: true)
            }
        }
    }

    private func buildInboundTaskUpdate(
        reminder: EKReminder,
        metadata: BobReminderMetadata,
        context: BobFirestoreSyncContext
    ) -> (id: String, payload: [String: Any])? {
        guard let task = context.task(for: metadata.entityId) else {
            return nil
        }

        var payload: [String: Any] = [:]
        var changed = false

        let sanitized = sanitizedTitle(from: reminder)
        if let inboundTitle = resolvedInboundTitle(current: task.title, metadataTitle: metadata.taskTitle, sanitizedTitle: sanitized) {
            payload["title"] = inboundTitle
            changed = true
        }

        if let desc = metadata.taskDescription, desc != (task.description ?? "") {
            payload["description"] = desc
            changed = true
        }

        if task.reminderId != reminder.calendarItemIdentifier {
            payload["reminderId"] = reminder.calendarItemIdentifier
            changed = true
        }

        let inboundEnd = metadata.endDate ?? date(from: reminder.dueDateComponents)
        if dateChanged(lhs: task.dueDate, rhs: inboundEnd) {
            if let inboundEnd {
                payload["dueDate"] = inboundEnd.timeIntervalSince1970 * 1000.0
            } else {
                payload["dueDate"] = FieldValue.delete()
            }
            changed = true
        }

        if reminder.isCompleted, !task.isCompleted {
            payload["status"] = 2
            changed = true
        }

        if changed {
            payload["updatedAt"] = FieldValue.serverTimestamp()
        }

        return changed ? (task.id, payload) : nil
    }

    private func buildInboundStoryUpdate(
        reminder: EKReminder,
        metadata: BobReminderMetadata,
        context: BobFirestoreSyncContext
    ) -> (id: String, payload: [String: Any])? {
        guard let story = context.story(for: metadata.entityId) else {
            return nil
        }

        var payload: [String: Any] = [:]
        var changed = false

        let sanitized = sanitizedTitle(from: reminder)
        if let inboundTitle = resolvedInboundTitle(current: story.title, metadataTitle: metadata.storyTitle, sanitizedTitle: sanitized) {
            payload["title"] = inboundTitle
            changed = true
        }

        if story.reminderId != reminder.calendarItemIdentifier {
            payload["reminderId"] = reminder.calendarItemIdentifier
            changed = true
        }

        let inboundEnd = metadata.endDate ?? date(from: reminder.dueDateComponents)
        if dateChanged(lhs: story.dueDate ?? story.endDate, rhs: inboundEnd) {
            if let inboundEnd {
                payload["dueDate"] = inboundEnd.timeIntervalSince1970 * 1000.0
            } else {
                payload["dueDate"] = FieldValue.delete()
            }
            changed = true
        }

        if reminder.isCompleted, !story.isCompleted {
            payload["status"] = 4
            changed = true
        }

        if changed {
            payload["updatedAt"] = FieldValue.serverTimestamp()
        }

        return changed ? (story.id, payload) : nil
    }

    private func sanitizedTitle(from reminder: EKReminder) -> String {
        var title = reminder.title ?? ""
        if title.hasPrefix("["), let closing = title.firstIndex(of: "]") {
            let afterBracket = title.index(after: closing)
            if afterBracket < title.endIndex {
                let start = title[afterBracket] == " " ? title.index(after: afterBracket) : afterBracket
                title = String(title[start...])
            } else {
                title = ""
            }
        }
        if title.hasPrefix("#story ") {
            title = String(title.dropFirst(7))
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedInboundTitle(current: String, metadataTitle: String?, sanitizedTitle: String) -> String? {
        let meta = metadataTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let meta, !meta.isEmpty, meta != current {
            return meta
        }
        let sanitized = sanitizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sanitized.isEmpty, sanitized != current {
            return sanitized
        }
        return nil
    }

    private func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var comps = components
        if comps.calendar == nil { comps.calendar = Calendar.current }
        return comps.date
    }

    private func dateChanged(lhs: Date?, rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return false
        case (let l?, let r?):
            return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) > 60
        default:
            return true
        }
    }
}

private extension BobFirestoreSyncContext {
    func goal(for task: FirestoreTaskEntity, story: FirestoreStoryEntity) -> FirestoreGoalEntity? {
        if let gid = task.goalId, let goal = goals[gid] {
            return goal
        }
        if let gid = story.goalId, let goal = goals[gid] {
            return goal
        }
        return nil
    }

    func sprint(for task: FirestoreTaskEntity, story: FirestoreStoryEntity?) -> FirestoreSprintEntity? {
        if let sid = task.sprintId, let sprint = sprints[sid] { return sprint }
        if let story, let sid = story.sprintId, let sprint = sprints[sid] { return sprint }
        return nil
    }

    func goal(for story: FirestoreStoryEntity) -> FirestoreGoalEntity? {
        guard let gid = story.goalId else { return nil }
        return goals[gid]
    }

    func sprint(for story: FirestoreStoryEntity) -> FirestoreSprintEntity? {
        guard let sid = story.sprintId else { return nil }
        return sprints[sid]
    }

    func task(for id: String) -> FirestoreTaskEntity? {
        tasksById[id]
    }

    func story(for id: String) -> FirestoreStoryEntity? {
        stories[id]
    }
}
#else
@MainActor
class BobFirestoreSyncService: ObservableObject {
    static let shared = BobFirestoreSyncService()
    private init() {}
    func syncFromBob() async { /* Firebase not available */ }
    func reportCompletion(for reminder: EKReminder) async { }
}
#endif
