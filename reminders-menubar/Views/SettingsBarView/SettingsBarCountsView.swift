import SwiftUI

struct SettingsBarCountsView: View {
    @ObservedObject var counts = CountService.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("bob: \(counts.bobOpenCount)")
            Text("mac: \(counts.remindersOpenCount)")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .onAppear {
            Task { await CountService.shared.refresh() }
        }
        .help("Open tasks – Bob and Mac Reminders")
    }
}

