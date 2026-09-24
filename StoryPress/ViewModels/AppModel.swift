import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var books: [StoryBook] = []
    var selectedBookID: UUID?
    var settings = AppSettings() {
        didSet {
            if oldValue.storyProvider.provider != settings.storyProvider.provider || oldValue.storyProvider.endpoint != settings.storyProvider.endpoint {
                availableStoryModels = []
            }
            if oldValue.illustration.openRouterEndpoint != settings.illustration.openRouterEndpoint {
                availableIllustrationModels = []
            }
            scheduleSettingsSave()
        }
    }
    private(set) var availableStoryModels: [ProviderModel] = []
    private(set) var availableIllustrationModels: [ProviderModel] = []
    private(set) var isRefreshingModels = false
    private(set) var isBusy = false
    private(set) var progress: GenerationProgress?
    private(set) var errorMessage: String?
    private(set) var warningMessage: String?
    private(set) var hasOpenRouterAPIKey: Bool

    @ObservationIgnored private let store: StoryLibraryStore
    @ObservationIgnored private let paths: StoryLibraryPaths
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let keychain: any OpenRouterCredentialStore
    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var planningTask: Task<StoryPlan, Error>?
    @ObservationIgnored private var activeGenerationTask: Task<Void, Never>?
    @ObservationIgnored private var illustrationModelsEndpoint: URL?

    init(
        libraryRoot: URL = StoryLibraryPaths.defaultRootURL,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        keychain: any OpenRouterCredentialStore = OpenRouterKeychain(),
        bundle: Bundle = .main
    ) {
        let paths = StoryLibraryPaths(rootURL: libraryRoot)
        self.paths = paths
        self.store = StoryLibraryStore(paths: paths)
        self.transport = transport
        self.keychain = keychain
        self.bundle = bundle
        self.hasOpenRouterAPIKey = keychain.hasKey
    }

    func load() async {
        errorMessage = nil
        do {
            settings = try await store.loadSettings()
            hasOpenRouterAPIKey = keychain.hasKey
            let result = try await store.loadBooks()
            books = result.books
            selectedBookID = books.first?.id
            if result.skippedCount > 0 {
                warningMessage = "\(result.skippedCount) library item\(result.skippedCount == 1 ? " was" : "s were") unreadable and were left in the library folder."
            }
            for bookIndex in books.indices {
                var book = books[bookIndex]
                var changed = false
                for pageIndex in book.pages.indices where book.pages[pageIndex].imageStatus == .generating {
                    book.pages[pageIndex].imageStatus = .pending
                    book.pages[pageIndex].errorMessage = "Generation stopped before the app closed. Resume this page to check its saved ComfyUI job or start another attempt."
                    book.pages[pageIndex].updatedAt = .now
                    if let attemptIndex = book.pages[pageIndex].imageAttempts.indices.last(where: {
                        book.pages[pageIndex].imageAttempts[$0].status == .generating
                    }) {
                        book.pages[pageIndex].imageAttempts[attemptIndex].status = .pending
                        book.pages[pageIndex].imageAttempts[attemptIndex].updatedAt = .now
                    }
                    changed = true
                }
                if changed {
                    do {
                        books[bookIndex] = try await store.saveGenerationState(book)
                    } catch {
                        warningMessage = "A book has an interrupted generation that could not be updated. Its saved files remain in the library."
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSettings() async throws {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        try await store.saveSettings(settings)
    }

    func refreshStoryModels() async throws {
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        let settingsSnapshot = settings.storyProvider
        do {
            let models = try await StoryProviderClient(transport: transport).listModels(
                settings: settingsSnapshot,
                openRouterKey: nil
            )
            guard settings.storyProvider.provider == settingsSnapshot.provider,
                  settings.storyProvider.endpoint == settingsSnapshot.endpoint else { return }
            availableStoryModels = models
            if let selected = settingsSnapshot.modelID,
               !availableStoryModels.contains(where: { $0.id == selected }) {
                settings.storyProvider.modelID = nil
                try await saveSettings()
            }
            errorMessage = nil
        } catch {
            guard settings.storyProvider.provider == settingsSnapshot.provider,
                  settings.storyProvider.endpoint == settingsSnapshot.endpoint else { return }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func refreshIllustrationModels() async throws {
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        let endpoint = settings.illustration.openRouterEndpoint
        do {
            let models = try await OpenRouterImageClient(transport: transport).listModels(endpoint: endpoint)
            guard settings.illustration.openRouterEndpoint == endpoint else { return }
            availableIllustrationModels = models
            illustrationModelsEndpoint = endpoint
            if let selected = settings.illustration.openRouterModelID,
               !availableIllustrationModels.contains(where: { $0.id == selected }) {
                settings.illustration.openRouterModelID = nil
                try await saveSettings()
            }
            errorMessage = nil
        } catch {
            guard settings.illustration.openRouterEndpoint == endpoint else { return }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func setOpenRouterAPIKey(_ value: String) throws {
        try keychain.save(value)
        hasOpenRouterAPIKey = true
    }

    func deleteOpenRouterAPIKey() throws {
        try keychain.delete()
        hasOpenRouterAPIKey = false
    }

    func clearError() { errorMessage = nil }
    func clearWarning() { warningMessage = nil }

    func newBook(theme: String, age: String, pageCount: Int, style: String) async throws -> UUID {
        guard !isBusy else { throw StoryPressError.providerNotConfigured("Wait for the current generation to finish or cancel it first.") }
        errorMessage = nil
        isBusy = true
        progress = GenerationProgress(phase: .planning, current: 0, total: 1)
        defer {
            isBusy = false
            progress = nil
            planningTask = nil
        }

        let storySettings = settings.storyProvider
        let key = storySettings.provider == .openrouter ? keychain.load() : nil
        let client = StoryProviderClient(transport: transport)
        let request = StoryRequest(theme: theme, age: age, pageCount: pageCount, style: style)
        let task = Task { try await client.planStory(request: request, settings: storySettings, openRouterKey: key) }
        planningTask = task
        do {
            let plan = try await task.value
            let normalizedRequest = try StoryRequestValidator.validate(request)
            var book = StoryBook(
                title: plan.title,
                theme: normalizedRequest.theme,
                ageRange: normalizedRequest.age,
                style: normalizedRequest.style,
                characterDescription: plan.characterDescription,
                pages: plan.pages.enumerated().map { offset, page in
                    StoryPage(pageNumber: offset + 1, text: page.text, imagePrompt: page.imagePrompt)
                }
            )
            book.touch()
            try await store.saveBook(book)
            books.insert(book, at: 0)
            selectedBookID = book.id
            errorMessage = nil
            return book.id
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func openSampleBook() async throws -> UUID {
        if let sample = books.first(where: \.isSample) {
            selectedBookID = sample.id
            return sample.id
        }
        let sample = StoryBook(
            title: "Pip’s Little Lantern",
            theme: "A quiet evening walk through the woods",
            ageRange: "3–6",
            style: "Soft storybook watercolor and gouache with warm lantern light",
            characterDescription: "Pip is a small russet fox with a cream muzzle, a blue scarf, and a little brass lantern.",
            pages: [
                StoryPage(
                    pageNumber: 1,
                    text: "Pip carried his little lantern along the woodland path. The sky grew blue, and the leaves whispered goodnight.",
                    imagePrompt: "Pip, a small russet fox in a blue scarf, carrying a glowing brass lantern along a woodland path at dusk.",
                    imageStatus: .complete,
                    sampleImageAssetName: "SamplePath"
                ),
                StoryPage(
                    pageNumber: 2,
                    text: "Beside the quiet pond, Pip saw Hedgehog heading home. “Goodnight,” he called softly. “Sleep well.”",
                    imagePrompt: "Pip the russet fox with a brass lantern greets a small hedgehog beside a quiet moonlit pond.",
                    imageStatus: .complete,
                    sampleImageAssetName: "SamplePond"
                ),
                StoryPage(
                    pageNumber: 3,
                    text: "At home, Pip curled up in his cosy den. His little walk was over. It was time to dream.",
                    imagePrompt: "Pip the russet fox, blue scarf beside him, curled safely in a cosy woodland den as his lantern glows softly.",
                    imageStatus: .complete,
                    sampleImageAssetName: "SampleDen"
                )
            ],
            isSample: true
        )
        try await store.saveBook(sample)
        books.insert(sample, at: 0)
        selectedBookID = sample.id
        errorMessage = nil
        return sample.id
    }

    func saveEdits(_ editedBook: StoryBook) async throws {
        do {
            let saved = try await store.saveEdits(editedBook)
            replaceBook(saved)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func generateMissingImages(for bookID: UUID) async {
        await startImageGeneration(bookID: bookID, pageID: nil, forceNew: false)
    }

    func regeneratePage(bookID: UUID, pageID: UUID) async {
        await startImageGeneration(bookID: bookID, pageID: pageID, forceNew: true)
    }

    func cancelGeneration() {
        planningTask?.cancel()
        activeGenerationTask?.cancel()
    }

    func resolvedImageURL(for page: StoryPage, in book: StoryBook) -> URL? {
        guard let name = page.imageFilename else { return nil }
        guard let url = try? paths.assetURL(bookID: book.id, relativePath: name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func resolvedReferenceImageURL(for book: StoryBook) -> URL? {
        guard let name = book.referenceImageFilename else { return nil }
        guard let url = try? paths.assetURL(bookID: book.id, relativePath: name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func importReferenceImage(bookID: UUID, from sourceURL: URL) async throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: sourceURL) }
        catch { throw StoryPressError.missingAsset("reference image could not be read") }
        guard !data.isEmpty, data.count <= 40 * 1_024 * 1_024 else {
            throw StoryPressError.invalidInput("The reference image must be smaller than 40 MB.")
        }
        let filename = try await store.saveReferenceImage(data, bookID: bookID, fileExtension: sourceURL.pathExtension)
        let book = try await store.setReferenceImage(filename, bookID: bookID)
        replaceBook(book)
    }

    func clearReferenceArtwork(bookID: UUID) async throws {
        let book = try await store.setReferenceImage(nil, bookID: bookID)
        replaceBook(book)
    }

    func importComfyWorkflow(from sourceURL: URL) async throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: sourceURL) }
        catch { throw StoryPressError.invalidWorkflow("The selected workflow file could not be read.") }
        guard data.count <= 4 * 1_024 * 1_024 else { throw StoryPressError.invalidWorkflow("Workflow files must be smaller than 4 MB.") }
        try WorkflowTemplate.validate(data)
        settings.illustration.comfy.workflowJSON = data
        settings.illustration.comfy.workflowDisplayName = sourceURL.lastPathComponent
        try await saveSettings()
    }

    func resetComfyWorkflowToBundled() async throws {
        settings.illustration.comfy.workflowJSON = nil
        settings.illustration.comfy.workflowDisplayName = nil
        try await saveSettings()
    }

    func exportPDF(bookID: UUID, to url: URL) throws -> URL {
        guard let book = books.first(where: { $0.id == bookID }) else {
            throw StoryPressError.exportLayout("The selected book no longer exists.")
        }
        return try PDFExporter(paths: paths, bundle: bundle).export(book, to: url)
    }

    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                try await self.store.saveSettings(self.settings)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func startImageGeneration(bookID: UUID, pageID: UUID?, forceNew: Bool) async {
        guard !isBusy, activeGenerationTask == nil else { return }
        guard books.contains(where: { $0.id == bookID }) else {
            errorMessage = "The selected book no longer exists."
            return
        }
        errorMessage = nil
        isBusy = true
        let task = Task { await self.generatePages(bookID: bookID, onlyPageID: pageID, forceNew: forceNew) }
        activeGenerationTask = task
        await task.value
        activeGenerationTask = nil
        isBusy = false
        progress = nil
    }

    private func generatePages(bookID: UUID, onlyPageID: UUID?, forceNew: Bool) async {
        guard let initial = books.first(where: { $0.id == bookID }), !initial.isSample else { return }
        let illustrationSettings = settings.illustration
        let imageClient = OpenRouterImageClient(transport: transport)
        var selectedImageModel: ProviderModel?
        if illustrationSettings.provider == .openrouter,
           let selectedID = illustrationSettings.openRouterModelID {
            if illustrationModelsEndpoint == illustrationSettings.openRouterEndpoint {
                selectedImageModel = availableIllustrationModels.first(where: { $0.id == selectedID })
            }
            if selectedImageModel == nil {
                do {
                    let discovered = try await imageClient.listModels(endpoint: illustrationSettings.openRouterEndpoint)
                    selectedImageModel = discovered.first(where: { $0.id == selectedID })
                    if settings.illustration.openRouterEndpoint == illustrationSettings.openRouterEndpoint {
                        availableIllustrationModels = discovered
                        illustrationModelsEndpoint = illustrationSettings.openRouterEndpoint
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }
        if illustrationSettings.provider == .openrouter, selectedImageModel == nil {
            errorMessage = StoryPressError.modelNotSelected.localizedDescription
            return
        }
        let book = initial
        let candidatePageIDs = book.pages.indices.filter { index in
            guard onlyPageID == nil || book.pages[index].id == onlyPageID else { return false }
            if onlyPageID != nil { return true }
            return book.pages[index].imageStatus != .complete || book.pages[index].imageFilename == nil
        }.map { book.pages[$0].id }
        if onlyPageID != nil, candidatePageIDs.isEmpty {
            errorMessage = "The selected page no longer exists."
            return
        }
        progress = GenerationProgress(phase: .illustrating, current: 0, total: candidatePageIDs.count)
        let comfyClient = ComfyUIClient(transport: transport, bundle: bundle)
        let key = illustrationSettings.provider == .openrouter ? keychain.load() : nil

        for (offset, pageID) in candidatePageIDs.enumerated() {
            guard !Task.isCancelled else { break }
            guard var latest = books.first(where: { $0.id == bookID }),
                  let pageIndex = latest.pages.firstIndex(where: { $0.id == pageID }) else { continue }
            var page = latest.pages[pageIndex]
            progress = GenerationProgress(phase: .illustrating, current: offset, total: candidatePageIDs.count, pageNumber: page.pageNumber)

            let existingAttempt = page.imageAttempts.last(where: {
                $0.comfyJobID != nil && $0.provider == .comfyUI && $0.imageFilename == nil
            })
            let resumesComfyJob = !forceNew
                && illustrationSettings.provider == .comfyUI
                && illustrationSettings.comfy.endpoint == existingAttempt?.endpoint
                && existingAttempt != nil
            let seed = resumesComfyJob ? existingAttempt!.seed : Int64.random(in: 1...Int64.max)
            let prompt = resumesComfyJob ? existingAttempt!.prompt : Self.composedImagePrompt(book: latest, page: page)
            let endpoint: URL
            let modelID: String?
            let provider: IllustrationProviderKind
            if resumesComfyJob, let existingAttempt {
                endpoint = existingAttempt.endpoint
                provider = .comfyUI
                modelID = existingAttempt.modelID
            } else {
                provider = illustrationSettings.provider
                endpoint = provider == .comfyUI ? illustrationSettings.comfy.endpoint : illustrationSettings.openRouterEndpoint
                modelID = provider == .openrouter ? illustrationSettings.openRouterModelID : nil
            }

            var attempt: IllustrationAttempt
            if resumesComfyJob, let existingAttempt {
                attempt = existingAttempt
                attempt.status = .generating
                attempt.errorMessage = nil
                attempt.updatedAt = .now
                page.comfyJobID = existingAttempt.comfyJobID
                if let attemptIndex = page.imageAttempts.firstIndex(where: { $0.id == existingAttempt.id }) {
                    page.imageAttempts[attemptIndex] = attempt
                }
            } else {
                attempt = IllustrationAttempt(
                    provider: provider,
                    endpoint: endpoint,
                    modelID: modelID,
                    prompt: prompt,
                    seed: seed,
                    status: .generating
                )
                page.comfyJobID = nil
                page.imageAttempts.append(attempt)
            }
            page.seed = seed
            page.imageStatus = .generating
            page.errorMessage = nil
            page.updatedAt = .now
            latest.pages[pageIndex] = page
            latest.touch()
            do {
                latest = try await store.saveGenerationState(latest)
                replaceBook(latest)
            } catch {
                errorMessage = error.localizedDescription
                break
            }

            do {
                let imageData: Data
                if resumesComfyJob, let jobID = attempt.comfyJobID {
                    imageData = try await comfyClient.waitForImage(
                        jobID: jobID,
                        endpoint: endpoint,
                        pollInterval: illustrationSettings.comfy.pollIntervalSeconds,
                        timeout: illustrationSettings.comfy.timeoutSeconds
                    )
                } else if provider == .comfyUI {
                    let reference: URL?
                    if let relativePath = latest.referenceImageFilename {
                        guard let url = try? paths.assetURL(bookID: latest.id, relativePath: relativePath),
                              FileManager.default.fileExists(atPath: url.path) else {
                            throw StoryPressError.missingAsset("reference artwork")
                        }
                        reference = url
                    } else {
                        reference = nil
                    }
                    let jobID = try await comfyClient.submit(
                        endpoint: illustrationSettings.comfy.endpoint,
                        customWorkflow: illustrationSettings.comfy.workflowJSON,
                        prompt: prompt,
                        seed: seed,
                        referenceImageURL: reference
                    )
                    if let liveBookIndex = books.firstIndex(where: { $0.id == bookID }),
                       let livePageIndex = books[liveBookIndex].pages.firstIndex(where: { $0.id == page.id }) {
                        var withJob = books[liveBookIndex]
                        withJob.pages[livePageIndex].comfyJobID = jobID
                        if let attemptIndex = withJob.pages[livePageIndex].imageAttempts.firstIndex(where: { $0.id == attempt.id }) {
                            withJob.pages[livePageIndex].imageAttempts[attemptIndex].comfyJobID = jobID
                            withJob.pages[livePageIndex].imageAttempts[attemptIndex].updatedAt = .now
                        }
                        withJob.pages[livePageIndex].updatedAt = .now
                        withJob.touch()
                        latest = try await store.saveGenerationState(withJob)
                        replaceBook(latest)
                    }
                    imageData = try await comfyClient.waitForImage(
                        jobID: jobID,
                        endpoint: illustrationSettings.comfy.endpoint,
                        pollInterval: illustrationSettings.comfy.pollIntervalSeconds,
                        timeout: illustrationSettings.comfy.timeoutSeconds
                    )
                } else {
                    guard let selectedImageModel else { throw StoryPressError.modelNotSelected }
                    let referenceImageData: Data?
                    if let referencePath = latest.referenceImageFilename {
                        guard let referenceURL = try? paths.assetURL(bookID: latest.id, relativePath: referencePath) else {
                            throw StoryPressError.unsafeAssetPath
                        }
                        referenceImageData = try ImageAssetCodec.normalizedPNG(at: referenceURL)
                    } else {
                        referenceImageData = nil
                    }
                    imageData = try await imageClient.generate(
                        endpoint: illustrationSettings.openRouterEndpoint,
                        model: selectedImageModel,
                        prompt: prompt,
                        seed: seed,
                        width: illustrationSettings.width,
                        height: illustrationSettings.height,
                        referenceImagePNG: referenceImageData,
                        apiKey: key
                    )
                }

                try Task.checkCancellation()
                progress = GenerationProgress(phase: .saving, current: offset, total: candidatePageIDs.count, pageNumber: page.pageNumber)
                let normalizedImage = try ImageAssetCodec.normalizedPNG(imageData)
                let imageFilename = try await store.saveImage(normalizedImage, bookID: bookID, pageID: page.id)
                guard let liveBookIndex = books.firstIndex(where: { $0.id == bookID }),
                      let livePageIndex = books[liveBookIndex].pages.firstIndex(where: { $0.id == page.id }) else { break }
                var completed = books[liveBookIndex]
                completed.pages[livePageIndex].imageFilename = imageFilename
                completed.pages[livePageIndex].comfyJobID = nil
                completed.pages[livePageIndex].imageStatus = .complete
                completed.pages[livePageIndex].errorMessage = nil
                completed.pages[livePageIndex].updatedAt = .now
                if let attemptIndex = completed.pages[livePageIndex].imageAttempts.firstIndex(where: { $0.id == attempt.id }) {
                    completed.pages[livePageIndex].imageAttempts[attemptIndex].imageFilename = imageFilename
                    completed.pages[livePageIndex].imageAttempts[attemptIndex].status = .complete
                    completed.pages[livePageIndex].imageAttempts[attemptIndex].updatedAt = .now
                }
                completed.touch()
                let saved = try await store.saveGenerationState(completed)
                replaceBook(saved)
            } catch {
                guard let liveBookIndex = books.firstIndex(where: { $0.id == bookID }),
                      let livePageIndex = books[liveBookIndex].pages.firstIndex(where: { $0.id == page.id }) else { break }
                var failed = books[liveBookIndex]
                let wasCancelled = Task.isCancelled || error is CancellationError || (error as? StoryPressError) == .cancelled
                failed.pages[livePageIndex].imageStatus = wasCancelled ? .pending : .failed
                failed.pages[livePageIndex].errorMessage = wasCancelled ? nil : error.localizedDescription
                failed.pages[livePageIndex].updatedAt = .now
                if let attemptIndex = failed.pages[livePageIndex].imageAttempts.firstIndex(where: { $0.id == attempt.id }) {
                    failed.pages[livePageIndex].imageAttempts[attemptIndex].status = wasCancelled ? .pending : .failed
                    failed.pages[livePageIndex].imageAttempts[attemptIndex].errorMessage = wasCancelled ? nil : error.localizedDescription
                    failed.pages[livePageIndex].imageAttempts[attemptIndex].updatedAt = .now
                }
                failed.touch()
                do {
                    let saved = try await store.saveGenerationState(failed)
                    replaceBook(saved)
                } catch {
                    errorMessage = error.localizedDescription
                }
                if !wasCancelled { errorMessage = error.localizedDescription }
                if wasCancelled { break }
            }
            progress = GenerationProgress(phase: .illustrating, current: offset + 1, total: candidatePageIDs.count)
        }
        if Task.isCancelled { errorMessage = nil }
    }

    private func replaceBook(_ book: StoryBook) {
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
        else { books.insert(book, at: 0) }
    }

    private static func composedImagePrompt(book: StoryBook, page: StoryPage) -> String {
        """
        Create one full-page children's picture-book illustration. Keep the recurring character consistent: \(book.characterDescription)
        Art direction: \(book.style)
        Scene: \(page.imagePrompt)
        The scene should match this page's story: \(page.text)
        Do not include text, lettering, captions, signs, borders, or page numbers in the image.
        """
    }
}
