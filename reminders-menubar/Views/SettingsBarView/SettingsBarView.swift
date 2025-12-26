import SwiftUI
import EventKit
import Foundation
#if canImport(FirebaseFirestore) && canImport(FirebaseAuth)
import FirebaseFirestore
import FirebaseAuth
#endif

struct SettingsBarView: View {
    var body: some View {
        HStack {
            SettingsBarFilterMenu()
            
            Spacer()
            
            SettingsBarToggleButton()
            
            // Keep sync indicator to the left, then show counts right next to the gear
            SettingsBarSyncIndicator()
            SettingsBarCountsView()
            SettingsBarGearMenu()
        }
        .frame(maxWidth: .infinity)
        .padding(10)
    }
}

// MARK: - Discreet counts: bob / mac

final class OpenCountsModel: ObservableObject {
    static let shared = OpenCountsModel()
    private init() {}

    @Published var bobOpenCount: Int = 0
    @Published var remindersOpenCount: Int = 0

    @MainActor
    func refresh() async {
        async let rem = Self.countOpenReminders()
        #if canImport(FirebaseFirestore) && canImport(FirebaseAuth)
        async let bob = Self.countOpenBobTasks()
        let (reminders, bobTasks) = await (rem, bob)
        self.remindersOpenCount = reminders
        self.bobOpenCount = bobTasks
        #else
        let reminders = await Self.countOpenReminders()
        self.remindersOpenCount = reminders
        self.bobOpenCount = 0
        #endif
    }

    private static func countOpenReminders() async -> Int {
        guard AppConstants.useNativeReminders else { return 0 }
        let hasAccess = await RemindersService.shared.hasFullRemindersAccess()
        guard hasAccess else { return 0 }
        let calendars = await RemindersService.shared.getCalendars()
        let reminders = await RemindersService.shared.fetchReminders(in: calendars)
        return reminders.filter { !$0.isCompleted }.count
    }

    #if canImport(FirebaseFirestore) && canImport(FirebaseAuth)
    private static func countOpenBobTasks() async -> Int {
        guard let db = FirebaseManager.shared.firestore, let user = Auth.auth().currentUser else { return 0 }
        do {
            var total = 0
            let qNum = db.collection("tasks").whereField("ownerUid", isEqualTo: user.uid).whereField("status", isEqualTo: 0).limit(to: 10000)
            let snapNum = try await qNum.getDocuments()
            total += snapNum.documents.filter { ($0.data()["deleted"] as? Bool) != true }.count
            let qStr = db.collection("tasks").whereField("ownerUid", isEqualTo: user.uid).whereField("status", isEqualTo: "open").limit(to: 10000)
            let snapStr = try await qStr.getDocuments()
            total += snapStr.documents.filter { ($0.data()["deleted"] as? Bool) != true }.count
            return total
        } catch {
            SyncLogService.shared.logEvent(tag: "counts", level: "ERROR", message: "Open counts failed: \(error.localizedDescription)")
            return 0
        }
    }
    #endif
}

struct SettingsBarCountsView: View {
    @ObservedObject var counts = OpenCountsModel.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("bob: \(counts.bobOpenCount)")
            Text("mac: \(counts.remindersOpenCount)")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .help("Open tasks – Bob and Mac Reminders")
    }
}

struct SettingsBarView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ForEach(ColorScheme.allCases, id: \.self) { color in
                SettingsBarView()
                    .environmentObject(RemindersData())
                    .colorScheme(color)
                    .previewDisplayName("\(color) mode")
            }
        }
    }
}
