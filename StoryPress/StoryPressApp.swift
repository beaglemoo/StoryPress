import SwiftUI
import AppKit

@main
struct StoryPressApp: App {
    @NSApplicationDelegateAdaptor(StoryPressApplicationDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .frame(minWidth: 1_140, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
        .commands {
            StoryPressCommands()
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

@MainActor
final class StoryPressApplicationDelegate: NSObject, NSApplicationDelegate {
    private var isWaitingForSave = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForSave else { return .terminateCancel }
        guard !PendingSaveRegistry.isEmpty else { return .terminateNow }

        isWaitingForSave = true
        Task { @MainActor in
            let mayTerminate = await PendingSaveRegistry.flushAll()
            isWaitingForSave = false
            NSApp.reply(toApplicationShouldTerminate: mayTerminate)
        }
        return .terminateLater
    }
}

private struct StoryPressCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.newStoryAction) private var newStoryAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Story") {
                newStoryAction?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(newStoryAction == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

private struct NewStoryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newStoryAction: (() -> Void)? {
        get { self[NewStoryActionKey.self] }
        set { self[NewStoryActionKey.self] = newValue }
    }
}
