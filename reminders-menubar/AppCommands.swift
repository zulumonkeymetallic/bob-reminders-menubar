import SwiftUI

struct AppCommands: Commands {
    @ObservedObject private var manualSyncService = ManualSyncService.shared
    @ObservedObject private var prefs = UserPreferences.shared

    @CommandsBuilder var body: some Commands {
        CommandMenu(Text(verbatim: "Bob")) {
            Button("Sync with Bob") { ManualSyncService.shared.trigger(reason: "Command Menu") }
                .keyboardShortcut(KeyEquivalent("s"), modifiers: [.command, .shift])
                .disabled(manualSyncService.isSyncing)

            Button("Sign In to Bob…") { FirebaseAuthView.showWindow() }
                .keyboardShortcut(KeyEquivalent("b"), modifiers: [.command, .option])

            // Theme → List Mapping removed; handled via tags

            Divider()

            // Stay Signed In toggle
            Toggle(isOn: $prefs.staySignedIn) {
                Text("Stay Signed In")
            }

            Toggle(isOn: $prefs.showBobMetadataInNotes) {
                Text("Show Bob Metadata in Notes")
            }

            // Delete all duplicates action
            Button("Delete All Duplicates…") {
                Task {
                    let result = await FirebaseSyncService.shared.deleteAllDuplicates(hardDelete: true)
                    let msg = result.error == nil ?
                        "Deleted \(result.deleted) duplicates across \(result.groups) groups" :
                        "Delete duplicates failed: \(result.error!)"
                    SyncLogService.shared.logEvent(tag: "dedupe", level: result.error == nil ? "INFO" : "ERROR", message: msg)
                }
            }

            Divider()

            Button("Reveal Sync Log") { SyncLogService.shared.revealLogInFinder() }
        }

        CommandMenu(Text(verbatim: "Edit")) {
            // NOTE: macOS 13.0 already has the below shortcuts for TextField.
            // Shortcuts only need to be registered for versions earlier than macOS 13.0.
            if #unavailable(macOS 13.0) {
                Button {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } label: {
                    Text(verbatim: "Select All")
                }
                .keyboardShortcut(KeyEquivalent("a"), modifiers: .command)
                
                Button {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } label: {
                    Text(verbatim: "Cut")
                }
                .keyboardShortcut(KeyEquivalent("x"), modifiers: .command)
                
                Button {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } label: {
                    Text(verbatim: "Copy")
                }
                .keyboardShortcut(KeyEquivalent("c"), modifiers: .command)
                
                Button {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } label: {
                    Text(verbatim: "Paste")
                }
                .keyboardShortcut(KeyEquivalent("v"), modifiers: .command)
                
                Button {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } label: {
                    Text(verbatim: "Undo")
                }
                .keyboardShortcut(KeyEquivalent("z"), modifiers: .command)
                
                Button {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } label: {
                    Text(verbatim: "Redo")
                }
                .keyboardShortcut(KeyEquivalent("z"), modifiers: [.command, .shift])
            }
        }
    }
}
