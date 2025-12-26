import SwiftUI

struct SettingsBarGearMenu: View {
    @EnvironmentObject var remindersData: RemindersData
    @ObservedObject var userPreferences = UserPreferences.shared
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    
    @State var gearIsHovered = false
    
    @ObservedObject var appUpdateCheckHelper = AppUpdateCheckHelper.shared
    @ObservedObject var keyboardShortcutService = KeyboardShortcutService.shared
    @ObservedObject var manualSyncService = ManualSyncService.shared
    
    var body: some View {
        Menu {
            VStack {
                if appUpdateCheckHelper.isOutdated {
                    Button(action: {
                        if let url = URL(string: GithubConstants.latestReleasePage) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "exclamationmark.circle")
                        Text(rmbLocalized(.updateAvailableNoticeButton))
                    }

                    Divider()
                }

                Button(action: {
                    FirebaseAuthView.showWindow()
                }) {
                    Label("Sign In to Bob…", systemImage: "person.crop.circle.badge.checkmark")
                }

                Button(action: {
                    userPreferences.launchAtLoginIsEnabled.toggle()
                }) {
                    let isSelected = userPreferences.launchAtLoginIsEnabled
                    SelectableView(
                        title: rmbLocalized(.launchAtLoginOptionButton),
                        isSelected: isSelected,
                        withPadding: false
                    )
                }

                Button(action: {
                    userPreferences.showBobMetadataInNotes.toggle()
                }) {
                    SelectableView(
                        title: "Show Bob Metadata in Notes",
                        isSelected: userPreferences.showBobMetadataInNotes,
                        withPadding: false
                    )
                }

                visualCustomizationOptions()

                // Bob Auth & Sync
                Menu {
                    Button("Sync with Bob") { ManualSyncService.shared.trigger(reason: "Settings Menu") }
                    .disabled(manualSyncService.isSyncing)
                    Button("Open Sync Log") {
                        SyncLogService.shared.revealLogInFinder()
                    }
                    Button("Open Log Folder") {
                        SyncLogService.shared.openLogsFolder()
                    }
                    Divider()
                    // Background sync controls
                    Button(action: {
                        userPreferences.enableBackgroundSync.toggle()
                        BackgroundSyncService.shared.applyPreference()
                    }) {
                        SelectableView(title: "Enable Background Sync", isSelected: userPreferences.enableBackgroundSync)
                    }
                    Menu("Background Sync Interval") {
                        ForEach([15, 30, 60, 120, 240], id: \.self) { minutes in
                            Button(action: {
                                userPreferences.backgroundSyncIntervalMinutes = minutes
                                if userPreferences.enableBackgroundSync { BackgroundSyncService.shared.applyPreference() }
                            }) {
                                SelectableView(title: "Every \(minutes) min", isSelected: userPreferences.backgroundSyncIntervalMinutes == minutes)
                            }
                        }
                    }
                    Divider()
                    // Duplicate maintenance
                    Menu("Duplicates") {
                        Button("Mark Duplicates Complete (TTL)") {
                            Task {
                                let res = await FirebaseSyncService.shared.deleteAllDuplicates(hardDelete: false)
                                if let err = res.error {
                                    SyncLogService.shared.logEvent(tag: "dedupe", level: "ERROR", message: err)
                                    await SyncFeedbackService.shared.show(message: "Dedupe failed: \(err)")
                                } else {
                                    let msg = "Completed \(res.deleted) duplicates across \(res.groups) groups"
                                    SyncLogService.shared.logEvent(tag: "dedupe", level: "INFO", message: msg)
                                    await SyncFeedbackService.shared.show(message: msg)
                                }
                            }
                        }
                        Button("Diagnose Duplicates (Debug)") {
                            Task {
                                let diag = await FirebaseSyncService.shared.diagnoseDuplicates()
                                if let err = diag.error {
                                    SyncLogService.shared.logEvent(tag: "dedupe", level: "ERROR", message: err)
                                    await SyncFeedbackService.shared.show(message: "Diagnose error: \(err)")
                                } else {
                                    let msg = "Diagnosed \(diag.processed) tasks, groups: key=\(diag.keyGroups) rid=\(diag.ridGroups)"
                                    SyncLogService.shared.logEvent(tag: "dedupe", level: "INFO", message: msg)
                                    await SyncFeedbackService.shared.show(message: msg)
                                }
                            }
                        }
                        Button("Delete Duplicates Now (Hard Delete)") {
                            Task {
                                let res = await FirebaseSyncService.shared.deleteAllDuplicates(hardDelete: true)
                                if let err = res.error {
                                    SyncLogService.shared.logEvent(tag: "dedupe", level: "ERROR", message: err)
                                    await SyncFeedbackService.shared.show(message: "Dedupe failed: \(err)")
                                } else {
                                    let msg = "Deleted \(res.deleted) duplicates across \(res.groups) groups"
                                    SyncLogService.shared.logEvent(tag: "dedupe", level: "INFO", message: msg)
                                    await SyncFeedbackService.shared.show(message: msg)
                                }
                            }
                        }
                    }
                    Button(action: { userPreferences.syncDryRun.toggle() }) {
                        SelectableView(title: "Dry-Run Mode (no writes)", isSelected: userPreferences.syncDryRun)
                    }
                    // Theme → List Mapping removed; handled via tags
                    if let summary = UserPreferences.shared.lastSyncSummary, !summary.isEmpty {
                        Divider()
                        Text("Last Sync: \(summary)")
                            .font(.footnote)
                    }
                } label: {
                    Text("Bob")
                }

                Button {
                    KeyboardShortcutView.showWindow()
                } label: {
                    let activeShortcut = keyboardShortcutService.activeShortcut(for: .openRemindersMenuBar)
                    let activeShortcutText = Text(verbatim: "     \(activeShortcut)").foregroundColor(.gray)
                    Text(rmbLocalized(.keyboardShortcutOptionButton)) + activeShortcutText
                }
                
                Divider()


                Button(action: {
                    Task {
                        await remindersData.update()
                    }
                }) {
                    Text(rmbLocalized(.reloadRemindersDataButton))
                }
                
                Divider()
                
                Button(action: {
                    AboutView.showWindow()
                }) {
                    Text(rmbLocalized(.appAboutButton))
                }
                
                Button(action: {
                    NSApplication.shared.terminate(self)
                }) {
                    Text(rmbLocalized(.appQuitButton))
                }
            }
        } label: {
            Image(systemName: appUpdateCheckHelper.isOutdated ? "exclamationmark.circle" : "gear")
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .frame(width: 32, height: 16)
        .padding(3)
        .background(gearIsHovered ? Color.rmbColor(for: .buttonHover, and: colorSchemeContrast) : nil)
        .cornerRadius(4)
        .onHover { isHovered in
            gearIsHovered = isHovered
        }
        .help(rmbLocalized(.settingsButtonHelp))
    }
    
    @ViewBuilder
    func visualCustomizationOptions() -> some View {
        Divider()
        
        appAppearanceMenu()
        
        menuBarIconMenu()
        
        menuBarCounterMenu()
        
        preferredLanguageMenu()
        
        Divider()
    }
    
    func appAppearanceMenu() -> some View {
        Menu {
            ForEach(RmbColorScheme.allCases, id: \.rawValue) { colorScheme in
                Button(action: { userPreferences.rmbColorScheme = colorScheme }) {
                    let isSelected = colorScheme == userPreferences.rmbColorScheme
                    SelectableView(title: colorScheme.title, isSelected: isSelected)
                }
            }
            
            Divider()
            
            let isIncreasedContrastEnabled = colorSchemeContrast == .increased
            let isTransparencyEnabled = userPreferences.backgroundIsTransparent && !isIncreasedContrastEnabled
            
            Button(action: {
                userPreferences.backgroundIsTransparent = false
            }) {
                let isSelected = !isTransparencyEnabled
                SelectableView(
                    title: rmbLocalized(.appAppearanceMoreOpaqueOptionButton),
                    isSelected: isSelected
                )
            }
            .disabled(isIncreasedContrastEnabled)
            
            Button(action: {
                userPreferences.backgroundIsTransparent = true
            }) {
                let isSelected = isTransparencyEnabled
                SelectableView(
                    title: rmbLocalized(.appAppearanceMoreTransparentOptionButton),
                    isSelected: isSelected
                )
            }
            .disabled(isIncreasedContrastEnabled)
        } label: {
            Text(rmbLocalized(.appAppearanceMenu))
        }
    }
    
    func menuBarIconMenu() -> some View {
        Menu {
            ForEach(RmbIcon.allCases, id: \.self) { icon in
                Button(action: {
                    userPreferences.reminderMenuBarIcon = icon
                    AppDelegate.shared.loadMenuBarIcon()
                }) {
                    Image(nsImage: icon.image)
                    Text(icon.name)
                }
            }
        } label: {
            Text(rmbLocalized(.menuBarIconSettingsMenu))
        }
    }
    
    func menuBarCounterMenu() -> some View {
        Menu {
            ForEach(RmbMenuBarCounterType.allCases, id: \.rawValue) { counterType in
                Button(action: { userPreferences.menuBarCounterType = counterType }) {
                    let isSelected = counterType == userPreferences.menuBarCounterType
                    SelectableView(title: counterType.title, isSelected: isSelected)
                }
            }
            
            Divider()
            
            Button(action: {
                userPreferences.filterMenuBarCountByCalendar.toggle()
            }) {
                SelectableView(
                    title: rmbLocalized(.filterMenuBarCountByCalendarOptionButton),
                    isSelected: userPreferences.filterMenuBarCountByCalendar
                )
            }
        } label: {
            Text(rmbLocalized(.menuBarCounterSettingsMenu))
        }
    }
    
    func preferredLanguageMenu() -> some View {
        Menu {
            Button(action: {
                userPreferences.preferredLanguage = nil
            }) {
                let isSelected = userPreferences.preferredLanguage == nil
                SelectableView(
                    title: rmbLocalized(.preferredLanguageSystemOptionButton),
                    isSelected: isSelected
                )
            }
            
            Divider()
                            
            ForEach(rmbAvailableLocales(), id: \.identifier) { locale in
                let localeIdentifier = locale.identifier
                Button(action: {
                    userPreferences.preferredLanguage = localeIdentifier
                }) {
                    let isSelected = userPreferences.preferredLanguage == localeIdentifier
                    SelectableView(title: locale.name, isSelected: isSelected)
                }
            }
        } label: {
            Text(rmbLocalized(.preferredLanguageMenu))
        }
    }
}

struct SettingsBarGearMenu_Previews: PreviewProvider {
    static var previews: some View {
        SettingsBarGearMenu()
    }
}
