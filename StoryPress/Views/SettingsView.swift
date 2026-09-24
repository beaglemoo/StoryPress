import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var draftSettings = AppSettings()
    @State private var storyEndpointText = StoryProviderKind.omlx.defaultEndpoint.absoluteString
    @State private var illustrationEndpointText = "https://openrouter.ai/api/v1"
    @State private var comfyEndpointText = "http://127.0.0.1:8188"
    @State private var openRouterKeyDraft = ""
    @State private var messageText: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var isWorkflowImporterPresented = false
    @State private var terminationHandlerID = UUID()

    var body: some View {
        TabView {
            storyProviderSettings
                .tabItem { Label("Story", systemImage: "text.book.closed") }
            illustrationSettings
                .tabItem { Label("Illustrations", systemImage: "photo.artframe") }
            privacySettings
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(23)
        .frame(width: 770, height: 650)
        .task {
            loadDraftSettings()
        }
        .onAppear {
            PendingSaveRegistry.register(id: terminationHandlerID) {
                await flushPendingSettings()
            }
        }
        .onDisappear {
            Task {
                let didSave = await flushPendingSettings()
                if didSave {
                    PendingSaveRegistry.unregister(id: terminationHandlerID)
                }
            }
        }
        .onChange(of: appModel.settings) { _, settings in
            guard settings != draftSettings else { return }
            draftSettings = settings
            syncEndpointText()
        }
        .fileImporter(
            isPresented: $isWorkflowImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importWorkflow
        )
        .alert("Settings could not be saved", isPresented: Binding(
            get: { messageText != nil },
            set: { if !$0 { messageText = nil } }
        )) {
            Button("OK", role: .cancel) { messageText = nil }
        } message: {
            Text(messageText ?? "")
        }
    }

    private var storyProviderSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                settingsHeading(
                    title: "Choose a story planner",
                    description: "The planner creates the title, character description, page text, and illustration prompts."
                )

                SettingsSurface(reduceTransparency: reduceTransparency) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Story provider")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 9) {
                            providerChoice(
                                title: "Local on this Mac",
                                detail: "oMLX",
                                symbol: "desktopcomputer",
                                isCloud: false,
                                isSelected: draftSettings.storyProvider.provider == .omlx
                            ) { selectStoryProvider(.omlx) }
                            providerChoice(
                                title: "Local server",
                                detail: "DwarfStar",
                                symbol: "server.rack",
                                isCloud: false,
                                isSelected: draftSettings.storyProvider.provider == .dwarfstar
                            ) { selectStoryProvider(.dwarfstar) }
                            providerChoice(
                                title: "OpenRouter cloud",
                                detail: "Remote model",
                                symbol: "cloud",
                                isCloud: true,
                                isSelected: draftSettings.storyProvider.provider == .openrouter
                            ) { selectStoryProvider(.openrouter) }
                        }

                        Divider()

                        HStack {
                            Label("\(draftSettings.storyProvider.provider.displayName) endpoint", systemImage: draftSettings.storyProvider.provider == .openrouter ? "cloud" : "network")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Button("Use default") {
                                storyEndpointText = draftSettings.storyProvider.provider.defaultEndpoint.absoluteString
                                updateDraft { $0.storyProvider.endpoint = draftSettings.storyProvider.provider.defaultEndpoint }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                        }

                        TextField("http://127.0.0.1:8843/v1", text: $storyEndpointText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onChange(of: storyEndpointText) { _, value in
                                guard let endpoint = validEndpoint(value) else { return }
                                updateDraft { $0.storyProvider.endpoint = endpoint }
                            }

                        HStack(spacing: 9) {
                            ModelChooserField(
                                title: "Choose a story model",
                                modelID: Binding(
                                    get: { draftSettings.storyProvider.modelID ?? "" },
                                    set: { value in updateDraft { $0.storyProvider.modelID = value.isEmpty ? nil : value } }
                                ),
                                models: appModel.availableStoryModels
                            )
                            Button {
                                Task { await refreshStoryModels() }
                            } label: {
                                if appModel.isRefreshingModels {
                                    ProgressView().controlSize(.small).frame(width: 24)
                                } else {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(appModel.isRefreshingModels)
                            .help("Ask only the selected endpoint for available models")
                        }

                        HStack {
                            Text("Maximum story output")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Stepper(value: Binding(
                                get: { draftSettings.storyProvider.maxOutputTokens },
                                set: { value in updateDraft { $0.storyProvider.maxOutputTokens = value } }
                            ), in: 256...8_192, step: 256) {
                                Text("\(draftSettings.storyProvider.maxOutputTokens.formatted()) tokens")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if draftSettings.storyProvider.provider == .openrouter {
                    openRouterKeyCard
                } else {
                    providerInformation(
                        title: "Local story planning",
                        message: "Story text and prompts are sent to the local endpoint shown above. StoryPress does not start the model service or download model files.",
                        symbol: "lock.shield"
                    )
                }

                if let messageText {
                    Label(messageText, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private var illustrationSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                settingsHeading(
                    title: "Choose an illustration provider",
                    description: "Create artwork after reviewing the text plan. This choice is independent from your story planner."
                )

                SettingsSurface(reduceTransparency: reduceTransparency) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Illustration provider")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 10) {
                            providerChoice(
                                title: "ComfyUI",
                                detail: "Local workflow",
                                symbol: "server.rack",
                                isCloud: false,
                                isSelected: draftSettings.illustration.provider == .comfyUI
                            ) { selectIllustrationProvider(.comfyUI) }
                            providerChoice(
                                title: "OpenRouter cloud",
                                detail: "Remote image model",
                                symbol: "cloud",
                                isCloud: true,
                                isSelected: draftSettings.illustration.provider == .openrouter
                            ) { selectIllustrationProvider(.openrouter) }
                        }

                        Divider()

                        if draftSettings.illustration.provider == .comfyUI {
                            comfySettings
                        } else {
                            openRouterIllustrationSettings
                        }
                    }
                }

                if draftSettings.illustration.provider == .openrouter {
                    openRouterKeyCard
                } else {
                    providerInformation(
                        title: "Reference art stays explicit",
                        message: "Imported reference artwork is sent only to the selected ComfyUI endpoint and only when its workflow supports the reference image input.",
                        symbol: "photo.on.rectangle.angled"
                    )
                }

                if let messageText {
                    Label(messageText, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private var comfySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ComfyUI endpoint")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Use local default") {
                    comfyEndpointText = "http://127.0.0.1:8188"
                    updateDraft { $0.illustration.comfy.endpoint = URL(string: "http://127.0.0.1:8188")! }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            }
            TextField("http://127.0.0.1:8188", text: $comfyEndpointText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: comfyEndpointText) { _, value in
                    guard let endpoint = validEndpoint(value) else { return }
                    updateDraft { $0.illustration.comfy.endpoint = endpoint }
                }

            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workflow")
                        .font(.system(size: 11, weight: .semibold))
                    Text(draftSettings.illustration.comfy.workflowDisplayName ?? "Bundled default workflow")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Import JSON…") {
                    isWorkflowImporterPresented = true
                }
                .buttonStyle(.glass)
                if draftSettings.illustration.comfy.workflowJSON != nil {
                    Button("Reset") {
                        Task { await resetWorkflow() }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(comfyDimensionDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var comfyDimensionDescription: String {
        if draftSettings.illustration.comfy.workflowJSON == nil {
            return "The bundled text-to-image workflow renders 1024 × 1024 artwork. The reference workflow derives its output size from the imported image."
        }
        return "Output dimensions are defined by the selected workflow. Review its latent-size inputs to see the resulting image size."
    }

    private var openRouterIllustrationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenRouter endpoint")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Use default") {
                    illustrationEndpointText = "https://openrouter.ai/api/v1"
                    updateDraft { $0.illustration.openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1")! }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            }
            TextField("https://openrouter.ai/api/v1", text: $illustrationEndpointText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: illustrationEndpointText) { _, value in
                    guard let endpoint = validEndpoint(value) else { return }
                    updateDraft { $0.illustration.openRouterEndpoint = endpoint }
                }

            HStack(spacing: 9) {
                ModelChooserField(
                    title: "Choose an image model",
                    modelID: Binding(
                        get: { draftSettings.illustration.openRouterModelID ?? "" },
                        set: { value in updateDraft { $0.illustration.openRouterModelID = value.isEmpty ? nil : value } }
                    ),
                    models: appModel.availableIllustrationModels
                )
                Button {
                    Task { await refreshIllustrationModels() }
                } label: {
                    if appModel.isRefreshingModels {
                        ProgressView().controlSize(.small).frame(width: 24)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.glass)
                .disabled(appModel.isRefreshingModels)
            }

            HStack {
                Text("Requested image size")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(draftSettings.illustration.width) × \(draftSettings.illustration.height)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var openRouterKeyCard: some View {
        SettingsSurface(reduceTransparency: reduceTransparency) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: appModel.hasOpenRouterAPIKey ? "key.fill" : "key")
                        .foregroundStyle(appModel.hasOpenRouterAPIKey ? Color.green : Color.secondary)
                    Text("OpenRouter API key")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(appModel.hasOpenRouterAPIKey ? "Saved in Keychain" : "Not configured")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(appModel.hasOpenRouterAPIKey ? Color.green : Color.secondary)
                }

                HStack(spacing: 8) {
                    SecureField("Paste API key", text: $openRouterKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save key") {
                        saveOpenRouterKey()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if appModel.hasOpenRouterAPIKey {
                        Button("Forget") {
                            do {
                                try appModel.deleteOpenRouterAPIKey()
                                messageText = "The saved OpenRouter key was removed from Keychain."
                            } catch {
                                messageText = error.localizedDescription
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }

                Text("The key is stored in macOS Keychain. It is not written to book files or provider settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacySettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeading(
                    title: "Your books and provider choices",
                    description: "Story and image services are selected separately, and errors never trigger a provider switch."
                )

                SettingsSurface(reduceTransparency: reduceTransparency) {
                    VStack(alignment: .leading, spacing: 13) {
                        privacyRow("Book library", "Story text, prompts, and imported artwork are kept in the local app library.", symbol: "books.vertical")
                        Divider()
                        privacyRow("Provider traffic", "Requests go only to the endpoint and model currently selected for that action.", symbol: "arrow.up.right.square")
                        Divider()
                        privacyRow("Credentials", "OpenRouter keys are stored in macOS Keychain, separate from saved settings.", symbol: "key")
                        Divider()
                        privacyRow("File access", "StoryPress asks for access when you import a workflow or reference image, or save a PDF.", symbol: "folder")
                    }
                }

                providerInformation(
                    title: "Cloud use is opt-in",
                    message: "OpenRouter receives content only when you choose it as the story or illustration provider. Local failures stay visible and are never sent to the cloud as a fallback.",
                    symbol: "hand.raised"
                )
            }
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private func settingsHeading(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .regular, design: .serif))
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private func providerChoice(
        title: String,
        detail: String,
        symbol: String,
        isCloud: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: isCloud ? "cloud" : "lock.fill")
                    Text(isCloud ? "Cloud" : "Local")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isCloud ? Color.orange : Color.green)
            }
            .frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.085) : Color(nsColor: .controlBackgroundColor).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.09), lineWidth: 1)
            }
        }
        .buttonStyle(.glass)
        .accessibilityLabel("\(title), \(isCloud ? "cloud" : "local") provider")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(title): \(detail)")
    }

    private func providerInformation(title: String, message: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func privacyRow(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadDraftSettings() {
        draftSettings = appModel.settings
        syncEndpointText()
    }

    private func syncEndpointText() {
        storyEndpointText = draftSettings.storyProvider.endpoint.absoluteString
        illustrationEndpointText = draftSettings.illustration.openRouterEndpoint.absoluteString
        comfyEndpointText = draftSettings.illustration.comfy.endpoint.absoluteString
    }

    private func selectStoryProvider(_ provider: StoryProviderKind) {
        guard provider != draftSettings.storyProvider.provider else { return }
        updateDraft { $0.storyProvider.select(provider) }
        storyEndpointText = draftSettings.storyProvider.endpoint.absoluteString
        Task { await refreshStoryModels() }
    }

    private func selectIllustrationProvider(_ provider: IllustrationProviderKind) {
        guard provider != draftSettings.illustration.provider else { return }
        updateDraft { $0.illustration.provider = provider }
        if provider == .openrouter {
            Task { await refreshIllustrationModels() }
        }
    }

    private func updateDraft(_ update: (inout AppSettings) -> Void) {
        var updated = draftSettings
        update(&updated)
        draftSettings = updated
        scheduleSave(updated)
    }

    private func scheduleSave(_ settings: AppSettings) {
        appModel.settings = settings
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                try await appModel.saveSettings()
                messageText = nil
            } catch is CancellationError {
                return
            } catch {
                messageText = error.localizedDescription
            }
        }
    }

    private func flushPendingSettings() async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        do {
            try await appModel.saveSettings()
            return true
        } catch {
            messageText = "Your settings could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private func validEndpoint(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private func refreshStoryModels() async {
        do {
            try await appModel.refreshStoryModels()
            messageText = nil
        } catch {
            messageText = error.localizedDescription
        }
    }

    private func refreshIllustrationModels() async {
        do {
            try await appModel.refreshIllustrationModels()
            messageText = nil
        } catch {
            messageText = error.localizedDescription
        }
    }

    private func saveOpenRouterKey() {
        do {
            try appModel.setOpenRouterAPIKey(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            openRouterKeyDraft = ""
            messageText = nil
            Task {
                if draftSettings.storyProvider.provider == .openrouter {
                    await refreshStoryModels()
                }
                if draftSettings.illustration.provider == .openrouter {
                    await refreshIllustrationModels()
                }
            }
        } catch {
            messageText = error.localizedDescription
        }
    }

    private func importWorkflow(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            Task {
                do {
                    try await appModel.importComfyWorkflow(from: url)
                    draftSettings = appModel.settings
                    messageText = nil
                } catch {
                    messageText = error.localizedDescription
                }
            }
        } catch {
            messageText = error.localizedDescription
        }
    }

    private func resetWorkflow() async {
        do {
            try await appModel.resetComfyWorkflowToBundled()
            draftSettings = appModel.settings
            messageText = nil
        } catch {
            messageText = error.localizedDescription
        }
    }
}

private struct SettingsSurface<Content: View>: View {
    let reduceTransparency: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(reduceTransparency ? 0.15 : 0.45), lineWidth: 1)
            }
    }
}
