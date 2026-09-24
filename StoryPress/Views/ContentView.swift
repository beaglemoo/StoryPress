import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isNewStoryPresented = false
    @State private var isLoadingSample = false
    @State private var localErrorText: String?
    @State private var dismissedWarningMessage: String?

    private var selectedBook: StoryBook? {
        guard let selectedID = appModel.selectedBookID else { return nil }
        return appModel.books.first { $0.id == selectedID }
    }

    private var visibleWarningMessage: String? {
        guard let warningMessage = appModel.warningMessage,
              warningMessage != dismissedWarningMessage else { return nil }
        return warningMessage
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                isNewStoryPresented: $isNewStoryPresented,
                onOpenSample: openSampleBook,
                isLoadingSample: isLoadingSample
            )
            .navigationSplitViewColumnWidth(min: 235, ideal: 270, max: 330)
        } detail: {
            VStack(spacing: 0) {
                if let visibleWarningMessage {
                    warningBanner(visibleWarningMessage)
                }

                Group {
                    if let selectedBook {
                        BookWorkspaceView(book: selectedBook)
                            .id(selectedBook.id)
                    } else {
                        WelcomeView(
                            onNewStory: { isNewStoryPresented = true },
                            onOpenSample: openSampleBook,
                            isLoadingSample: isLoadingSample
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isNewStoryPresented = true
                } label: {
                    Label("New story", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appModel.isBusy)
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .help("Choose story and illustration providers")
            }
        }
        .sheet(isPresented: $isNewStoryPresented) {
            NewStoryView()
                .environment(appModel)
        }
        .task {
            await appModel.load()
        }
        .onChange(of: appModel.warningMessage) { _, warning in
            if warning == nil { dismissedWarningMessage = nil }
        }
        .focusedSceneValue(\.newStoryAction, { isNewStoryPresented = true })
        .alert(
            "StoryPress could not complete that action",
            isPresented: Binding(
                get: { (!isNewStoryPresented && appModel.errorMessage != nil) || localErrorText != nil },
                set: {
                    if !$0 {
                        appModel.clearError()
                        localErrorText = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                appModel.clearError()
                localErrorText = nil
            }
        } message: {
            Text(localErrorText ?? appModel.errorMessage ?? "")
        }
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("Dismiss") {
                dismissedWarningMessage = message
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Dismiss library warning")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color.orange.opacity(0.09)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.orange.opacity(0.24))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func openSampleBook() {
        guard !isLoadingSample else { return }
        isLoadingSample = true
        Task {
            defer { isLoadingSample = false }
            do {
                appModel.selectedBookID = try await appModel.openSampleBook()
            } catch {
                localErrorText = error.localizedDescription
            }
        }
    }
}
