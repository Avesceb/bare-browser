import AppKit
import MeridianCore
import SwiftUI

@main
struct MeridianBrowserApp: App {
    private enum Preferences {
        static let sidebarRevealEdgeKey = "SidebarRevealEdge"
    }

    private let sessionPersistence: SQLiteSessionPersistenceStore
    private let historyPersistence: SQLiteLocalHistoryPersistenceStore
    @StateObject private var store: BrowserStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let sessionPersistence = SQLiteSessionPersistenceStore()
        let historyPersistence = SQLiteLocalHistoryPersistenceStore()
        let loadResult = sessionPersistence.loadSnapshot()
        if loadResult.integrityRepairReport.didRepairIsolationState {
            ProfileIsolationDiagnosticArchive.save(loadResult.integrityRepairReport)
        }
        let retainedIsolationReport = loadResult.integrityRepairReport.didRepairIsolationState
            ? loadResult.integrityRepairReport
            : ProfileIsolationDiagnosticArchive.load() ?? SessionIntegrityRepairReport()
        let historyResult = historyPersistence.loadHistory(profiles: loadResult.snapshot.profiles)
        let sidebarRevealEdge = Self.savedSidebarRevealEdge()
        self.sessionPersistence = sessionPersistence
        self.historyPersistence = historyPersistence
        _store = StateObject(
            wrappedValue: BrowserStore(
                snapshot: loadResult.snapshot,
                localHistoryStore: LocalHistoryStore(entries: historyResult.entries),
                sidebarRevealEdge: sidebarRevealEdge,
                lastUserMessage: loadResult.recoveryReason?.userMessage
                    ?? historyResult.recoveryReason?.userMessage,
                profileIsolationRepairReport: retainedIsolationReport,
                profileIsolationRepairOccurredThisLaunch: loadResult.integrityRepairReport.didRepairIsolationState,
                sessionPersistence: sessionPersistence,
                localHistoryPersistence: historyPersistence
            )
        )
    }

    var body: some Scene {
        WindowGroup("Lumen Browser") {
            BrowserWindowView(store: store)
                .frame(minWidth: 900, minHeight: 620)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    store.open(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        store.flushScheduledSessionPersistence()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: context.defaultDisplay.visibleRect.size)
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    store.beginNewTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("New Space") {
                    _ = store.createSpace(name: "New Space")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Profile") {
                    store.presentProfileManager(creatingNewProfile: true)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("New Private Window") {
                    let profile = store.createProfile(name: "Private", ephemeral: true)
                    _ = store.createSpace(name: "Private", profileID: profile.id)
                    store.showCommandBar()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
            }

            CommandMenu("Tabs") {
                Button("Close Tab") {
                    store.closeSelectedTab()
                }
                .keyboardShortcut("w", modifiers: [.command])

                Divider()

                Button("Move Tab Up") {
                    store.moveSelectedTab(.up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!store.canMoveSelectedTab(.up))

                Button("Move Tab Down") {
                    store.moveSelectedTab(.down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!store.canMoveSelectedTab(.down))

                Divider()

                Button("Command Bar") {
                    store.showCommandBar()
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            CommandMenu("View") {
                Button("Toggle Sidebar") {
                    store.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Picker("Sidebar Reveal Edge", selection: Binding(
                    get: { store.sidebarRevealEdge },
                    set: { edge in
                        Self.saveSidebarRevealEdge(edge)
                        store.setSidebarRevealEdge(edge)
                    }
                )) {
                    ForEach(SidebarRevealEdge.allCases) { edge in
                        Text(edge.displayName).tag(edge)
                    }
                }
            }

            CommandMenu("Passwords") {
                Button("Password Manager") {
                    _ = store.openPasswordManager()
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }

            BrowserNavigationCommandMenu()

            CommandMenu("Profiles") {
                Button("New Profile") {
                    store.presentProfileManager(creatingNewProfile: true)
                }

                Divider()

                Button("Manage Profiles…") {
                    store.presentProfileManager(profileID: store.activeProfile?.id)
                }

                Divider()

                Button("Copy Profile Isolation Diagnostics") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(
                        store.profileIsolationDiagnostics().redactedText,
                        forType: .string
                    )
                    store.publishStatusMessage("Profile isolation diagnostics copied.")
                }
            }

            CommandMenu("History") {
                Button("Clear History for This Profile") {
                    store.clearHistoryForActiveProfile()
                }
            }
        }
    }

    private static func savedSidebarRevealEdge() -> SidebarRevealEdge {
        let rawValue = UserDefaults.standard.string(forKey: Preferences.sidebarRevealEdgeKey)
        return rawValue.flatMap(SidebarRevealEdge.init(rawValue:)) ?? .left
    }

    private static func saveSidebarRevealEdge(_ edge: SidebarRevealEdge) {
        UserDefaults.standard.set(edge.rawValue, forKey: Preferences.sidebarRevealEdgeKey)
    }
}

private struct BrowserNavigationCommandMenu: Commands {
    @FocusedValue(\.browserNavigationCommandContext)
    private var navigationCommandContext

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Back") {
                navigationCommandContext?.goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!(navigationCommandContext?.canGoBack ?? false))

            Button("Forward") {
                navigationCommandContext?.goForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!(navigationCommandContext?.canGoForward ?? false))

            Divider()

            Button("Reload") {
                navigationCommandContext?.reload()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!(navigationCommandContext?.canReload ?? false))

            Button("Stop") {
                navigationCommandContext?.stopLoading()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!(navigationCommandContext?.canStopLoading ?? false))
        }
    }
}
