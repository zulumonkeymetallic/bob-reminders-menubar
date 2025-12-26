import Foundation
import EventKit

// Lightweight, pluggable classifier that can route triage items to
// personal vs work without blocking the main sync flow. It first tries
// a configured HTTP endpoint, then falls back to simple heuristics.

enum TriagePersona: String {
    case personal
    case work
    case unknown
}

struct TriageClassification {
    let persona: TriagePersona
    let confidence: Double // 0.0 – 1.0
    let source: String // "llm" | "heuristic" | "disabled" | "tag"
    let suggestedTheme: String? // Optional hint for personal items
}

actor TriageClassifierService {
    static let shared = TriageClassifierService()
    private init() {}

    private let requestTimeout: TimeInterval = 3.0
    private let minDecisionConfidence: Double = 0.70

    func classify(title: String, notes: String?, tags: [String]) async -> TriageClassification {
        // Quick tag-based overrides
        let loweredTags = Set(tags.map { $0.lowercased() })
        if loweredTags.contains("work") {
            return .init(persona: .work, confidence: 0.95, source: "tag", suggestedTheme: nil)
        }
        if loweredTags.contains("personal") {
            return .init(persona: .personal, confidence: 0.95, source: "tag", suggestedTheme: nil)
        }

        // Disabled path
        let enabled = await MainActor.run { UserPreferences.shared.enableTriageClassification }
        if !enabled {
            return .init(persona: .unknown, confidence: 0.0, source: "disabled", suggestedTheme: nil)
        }

        // Try the configured endpoint first, if present
        if let endpointString = await MainActor.run({ UserPreferences.shared.llmTriageEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) }),
           let url = URL(string: endpointString), !endpointString.isEmpty {
            if let result = await classifyViaHTTP(url: url, title: title, notes: notes, tags: tags) {
                return result
            }
        }

        // Fallback: heuristics
        return classifyHeuristically(title: title, notes: notes, tags: tags)
    }

    // MARK: - HTTP endpoint integration
    private func classifyViaHTTP(url: URL, title: String, notes: String?, tags: [String]) async -> TriageClassification? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "title": title,
            "notes": notes ?? "",
            "tags": tags
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return nil }
        request.httpBody = body

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let rawPersona = (obj["persona"] as? String)?.lowercased()
            let confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0.0
            let persona: TriagePersona
            if rawPersona == "work" { persona = .work }
            else if rawPersona == "personal" { persona = .personal }
            else { persona = .unknown }
            // Optional theme hint if provided by endpoint
            let suggestedTheme = (obj["theme"] as? String) ?? (obj["suggestedTheme"] as? String)
            return .init(persona: persona, confidence: confidence, source: "llm", suggestedTheme: suggestedTheme)
        } catch {
            // Silently fall back to heuristics
            return nil
        }
    }

    // MARK: - Heuristic fallback
    private func classifyHeuristically(title: String, notes: String?, tags: [String]) -> TriageClassification {
        let text = "\(title)\n\(notes ?? "")".lowercased()
        let all = text + "\n" + tags.joined(separator: " ").lowercased()

        // Simple keyword tallies with light weighting
        let workKeywords: [(String, Double)] = [
            ("jira", 1.4), ("ticket", 1.2), ("deploy", 1.3), ("production", 1.3), ("prod", 1.1),
            ("oncall", 1.3), ("pagerduty", 1.3), ("client", 1.2), ("customer", 1.1), ("meeting", 1.0),
            ("standup", 1.2), ("sprint", 1.2), ("story", 1.0), ("epic", 1.0), ("bug", 1.0),
            ("pr ", 1.2), ("pull request", 1.2), ("merge", 1.0), ("release", 1.0),
            ("okr", 1.1), ("quarter", 1.0), ("roadmap", 1.0), ("production issue", 1.5),
            ("work", 1.0), ("office", 1.0), ("shift", 1.0), ("invoice", 1.1)
        ]
        let personalKeywords: [(String, Double)] = [
            ("wash", 1.2), ("washing machine", 1.6), ("laundry", 1.3), ("grocer", 1.1), ("shopping", 1.0),
            ("gym", 1.1), ("workout", 1.1), ("dentist", 1.3), ("doctor", 1.2), ("appointment", 1.0),
            ("kids", 1.2), ("school", 1.0), ("family", 1.0), ("home", 1.0), ("garden", 1.0),
            ("rent", 1.0), ("mortgage", 1.0), ("car", 1.0), ("oil change", 1.3), ("pharmacy", 1.1),
            ("vacation", 1.0), ("travel", 1.0), ("birthday", 1.0), ("cook", 1.0), ("meal", 1.0)
        ]

        func score(_ dict: [(String, Double)]) -> Double {
            dict.reduce(0.0) { partial, pair in
                let (needle, weight) = pair
                return partial + (all.contains(needle) ? weight : 0.0)
            }
        }

        let workScore = score(workKeywords)
        let personalScore = score(personalKeywords)
        let total = workScore + personalScore

        // Normalize a confidence metric; avoid division by zero
        let confidence: Double
        let persona: TriagePersona
        if total <= 0.0 {
            persona = .unknown
            confidence = 0.0
        } else if workScore >= personalScore {
            persona = .work
            confidence = workScore / max(total, 1.0)
        } else {
            persona = .personal
            confidence = personalScore / max(total, 1.0)
        }

        var suggestedTheme: String? = nil
        if persona == .personal {
            suggestedTheme = suggestPersonalTheme(from: all)
        }

        if confidence < minDecisionConfidence {
            return .init(persona: .unknown, confidence: confidence, source: "heuristic", suggestedTheme: suggestedTheme)
        }
        return .init(persona: persona, confidence: confidence, source: "heuristic", suggestedTheme: suggestedTheme)
    }

    private func suggestPersonalTheme(from text: String) -> String? {
        // Very light heuristic mapping from common phrases to theme names.
        // These should correspond to names in the Bob "themes" collection when possible.
        let pairs: [(needles: [String], theme: String)] = [
            (["wash", "washing machine", "laundry"], "Home"),
            (["dentist", "doctor", "pharmacy", "health"], "Health"),
            (["gym", "workout", "run", "exercise"], "Fitness"),
            (["rent", "mortgage", "invoice", "bill"], "Finance"),
            (["car", "oil change", "tyre", "tire", "garage"], "Car"),
            (["vacation", "trip", "flight", "travel"], "Travel"),
            (["garden", "yard", "lawn"], "Garden"),
            (["grocer", "shopping"], "Shopping")
        ]
        for (needles, theme) in pairs {
            if needles.contains(where: { text.contains($0) }) { return theme }
        }
        return nil
    }
}
