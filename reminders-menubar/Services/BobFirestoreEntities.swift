#if canImport(FirebaseFirestore) && canImport(FirebaseCore)
import Foundation
import FirebaseFirestore

struct FirestoreTaskEntity {
    let id: String
    let title: String
    let description: String?
    let status: Int
    let reminderId: String?
    let storyId: String?
    let parentType: String?
    let parentId: String?
    let goalId: String?
    let sprintId: String?
    let startDate: Date?
    let dueDate: Date?
    let theme: Any?
    let isDeleted: Bool

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { return nil }

        self.id = document.documentID
        self.title = title
        self.description = (data["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = FirestoreValueDecoder.intValue(data["status"]) ?? 0
        self.reminderId = data["reminderId"] as? String
        self.storyId = data["storyId"] as? String ?? data["parentId"] as? String
        self.parentType = data["parentType"] as? String
        self.parentId = data["parentId"] as? String
        self.goalId = data["goalId"] as? String
        self.sprintId = data["sprintId"] as? String
        self.startDate = FirestoreValueDecoder.dateValue(data["startDate"]) ?? FirestoreValueDecoder.dateValue(data["start"])
        self.dueDate = FirestoreValueDecoder.dateValue(data["dueDate"]) ?? FirestoreValueDecoder.dateValue(data["dueAt"])
        self.theme = data["theme"]
        self.isDeleted = (data["deleted"] as? Bool) ?? false
    }

    var resolvedStoryId: String? {
        if let storyId, !storyId.isEmpty { return storyId }
        if parentType == "story", let parentId, !parentId.isEmpty { return parentId }
        return nil
    }

    var isCompleted: Bool { status == 2 }
}

struct FirestoreStoryEntity {
    let id: String
    let title: String
    let ref: String?
    let description: String?
    let goalId: String?
    let sprintId: String?
    let startDate: Date?
    let endDate: Date?
    let dueDate: Date?
    let reminderId: String?
    let status: Int
    let theme: Any?

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { return nil }
        self.id = document.documentID
        self.title = title
        self.ref = data["ref"] as? String
        self.description = (data["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.goalId = data["goalId"] as? String
        self.sprintId = data["sprintId"] as? String
        self.startDate = FirestoreValueDecoder.dateValue(data["startDate"]) ?? FirestoreValueDecoder.dateValue(data["start"])
        self.endDate = FirestoreValueDecoder.dateValue(data["endDate"]) ?? FirestoreValueDecoder.dateValue(data["end"])
        self.dueDate = FirestoreValueDecoder.dateValue(data["dueDate"])
        self.reminderId = data["reminderId"] as? String
        self.status = FirestoreValueDecoder.intValue(data["status"]) ?? 0
        self.theme = data["theme"]
    }

    var isCompleted: Bool { status >= 4 }
}

struct FirestoreGoalEntity {
    let id: String
    let title: String
    let theme: Any?

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { return nil }
        self.id = document.documentID
        self.title = title
        self.theme = data["theme"] ?? data["themeId"]
    }
}

struct FirestoreSprintEntity {
    let id: String
    let name: String
    let startDate: Date?
    let endDate: Date?

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return nil }
        self.id = document.documentID
        self.name = name
        self.startDate = FirestoreValueDecoder.dateValue(data["startDate"]) ?? FirestoreValueDecoder.dateValue(data["planningDate"])
        self.endDate = FirestoreValueDecoder.dateValue(data["endDate"]) ?? FirestoreValueDecoder.dateValue(data["retroDate"])
    }
}

enum FirestoreValueDecoder {
    static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let ts = value as? Timestamp { return ts.dateValue() }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return dateFromUnix(double)
        }
        if let double = value as? Double {
            return dateFromUnix(double)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let double = Double(trimmed) {
                return dateFromUnix(double)
            }
            let isoFormatter = ISO8601DateFormatter()
            if let isoDate = isoFormatter.date(from: trimmed) { return isoDate }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let simple = formatter.date(from: trimmed) { return simple }
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func dateFromUnix(_ value: Double) -> Date {
        let seconds = value > 10000000000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }
}

#endif
