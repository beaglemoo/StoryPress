import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import StoryPress

final class CoreTests: XCTestCase {
    func testStoryProviderSendsConcreteRequestAndParsesJSONPlan() async throws {
        let planJSON = """
        {"title":"The Little Fox","character_description":"A russet fox in a blue scarf.","pages":[
          {"text":"Fox finds a lantern.","image_prompt":"A small fox finding a lantern."},
          {"text":"Fox walks home.","image_prompt":"The fox walking under trees."},
          {"text":"Fox falls asleep.","image_prompt":"The fox sleeping in a cosy den."}]}
        """
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": planJSON]]]])
        let transport = RecordingTransport(payloads: [HTTPPayload(statusCode: 200, data: response)])
        let endpoint = URL(string: "http://127.0.0.1:8843/v1")!
        let settings = StoryProviderSettings(
            omlx: StoryProviderProfile(endpoint: endpoint, modelID: "discovered-local-model")
        )
        let result = try await StoryProviderClient(transport: transport).planStory(
            request: StoryRequest(theme: "A fox finds a lantern", age: "5–7 years", pageCount: 3, style: "Warm watercolor"),
            settings: settings,
            openRouterKey: nil
        )

        XCTAssertEqual(result.pages.count, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "http://127.0.0.1:8843/v1/chat/completions")
        let body = try XCTUnwrap(requests[0].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "discovered-local-model")
        XCTAssertLessThanOrEqual(object["max_tokens"] as? Int ?? Int.max, 8_192)
        XCTAssertEqual((object["response_format"] as? [String: String])?["type"], "json_object")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let userPrompt = try XCTUnwrap(messages.first(where: { $0["role"] == "user" })?["content"])
        XCTAssertTrue(userPrompt.contains("3-page"))
        XCTAssertTrue(userPrompt.contains("5–7 years"))
        XCTAssertTrue(userPrompt.contains("A fox finds a lantern"))
        XCTAssertTrue(userPrompt.contains("Warm watercolor"))
        XCTAssertFalse(userPrompt.contains("normalized."))
    }

    @MainActor
    func testStoryModelDiscoveryFiltersNonTextModelsAndPreservesValidSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressModelDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "Qwen3-Embedding-8B-4bit-DWQ", "name": "Qwen feature model"],
                ["id": "local-vector-model", "name": "Text Embedding Model"],
                ["id": "bge-reranker-v2", "name": "Ranking model"],
                ["id": "flux-image", "architecture": ["output_modalities": ["image"]]],
                ["id": "chat-model", "name": "Story Chat", "architecture": ["output_modalities": ["text"]]],
                ["id": "plain-completion", "name": "Completion model"]
            ]
        ])
        let transport = RecordingTransport(payloads: [HTTPPayload(statusCode: 200, data: catalog)])
        let app = AppModel(libraryRoot: root, transport: transport, keychain: TestCredentialStore(key: nil))
        await app.load()
        var settings = app.settings
        settings.storyProvider.modelID = "chat-model"
        app.settings = settings

        try await app.refreshStoryModels()

        XCTAssertEqual(Set(app.availableStoryModels.map(\.id)), Set(["chat-model", "plain-completion"]))
        XCTAssertEqual(app.settings.storyProvider.modelID, "chat-model")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        try await app.saveSettings()
    }

    func testOpenRouterStoryEndpointCannotSendKeyToAnotherHost() async throws {
        let transport = RecordingTransport(payloads: [])
        let settings = StoryProviderSettings(
            provider: .openrouter,
            openrouter: StoryProviderProfile(endpoint: URL(string: "https://example.invalid/api/v1")!, modelID: "cloud-model")
        )
        do {
            _ = try await StoryProviderClient(transport: transport).planStory(
                request: StoryRequest(theme: "A fox", age: "5–7", pageCount: 3, style: "Watercolor"),
                settings: settings,
                openRouterKey: "sk-or-v1-test-secret"
            )
            XCTFail("Expected endpoint rejection")
        } catch let error as StoryPressError {
            guard case .providerNotConfigured = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testStoryValidationRejectsIncorrectPageCountAndEmptyText() throws {
        XCTAssertThrowsError(try StoryRequestValidator.validate(StoryRequest(theme: "", age: "5–7", pageCount: 3, style: "Watercolor")))
        let invalid = StoryPlan(
            title: "A title",
            characterDescription: "A fox",
            pages: [.init(text: "  ", imagePrompt: "A fox by a tree.")]
        )
        XCTAssertThrowsError(try StoryRequestValidator.validate(invalid, expectedPageCount: 1))
    }

    func testStoryOutputGetsAtMostOneRepairRequest() async throws {
        let invalid = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "not JSON"]]]])
        let validPlan = """
        {"title":"The Little Fox","character_description":"A russet fox.","pages":[
          {"text":"Fox finds a lantern.","image_prompt":"A small fox finding a lantern."},
          {"text":"Fox walks home.","image_prompt":"The fox walking under trees."},
          {"text":"Fox falls asleep.","image_prompt":"The fox sleeping in a cosy den."}]}
        """
        let valid = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": validPlan]]]])
        let transport = RecordingTransport(payloads: [
            HTTPPayload(statusCode: 200, data: invalid),
            HTTPPayload(statusCode: 200, data: valid)
        ])
        let settings = StoryProviderSettings(omlx: StoryProviderProfile(
            endpoint: URL(string: "http://127.0.0.1:8843/v1")!,
            modelID: "discovered-model"
        ))
        _ = try await StoryProviderClient(transport: transport).planStory(
            request: StoryRequest(theme: "A fox finds a lantern", age: "5–7", pageCount: 3, style: "Watercolor"),
            settings: settings,
            openRouterKey: nil
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)

        let failingTransport = RecordingTransport(payloads: [
            HTTPPayload(statusCode: 200, data: invalid),
            HTTPPayload(statusCode: 200, data: invalid),
            HTTPPayload(statusCode: 200, data: valid)
        ])
        do {
            _ = try await StoryProviderClient(transport: failingTransport).planStory(
                request: StoryRequest(theme: "A fox finds a lantern", age: "5–7", pageCount: 3, style: "Watercolor"),
                settings: settings,
                openRouterKey: nil
            )
            XCTFail("Expected one-repair failure")
        } catch let error as StoryPressError {
            guard case .malformedStory = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let failingRequests = await failingTransport.requests
        XCTAssertEqual(failingRequests.count, 2)
    }

    func testAtomicLibraryRoundTripAndAssetPathGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoryLibraryPaths(rootURL: root)
        let store = StoryLibraryStore(paths: paths)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let page = StoryPage(
            pageNumber: 1,
            text: "The fox found a lantern.",
            imagePrompt: "A fox with a lantern.",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let book = StoryBook(
            title: "The Lantern Fox",
            theme: "A fox",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A russet fox.",
            pages: [page],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await store.saveBook(book)
        try await store.saveSettings(AppSettings())
        let result = try await store.loadBooks()
        let savedSettings = try await store.loadSettings()
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.books, [book])
        XCTAssertEqual(savedSettings, AppSettings())
        XCTAssertThrowsError(try paths.assetURL(bookID: book.id, relativePath: "../../outside.png"))
        XCTAssertThrowsError(try paths.assetURL(bookID: book.id, relativePath: "/tmp/outside.png"))
    }

    func testProviderSwitchKeepsEachEndpointAndDiscoveredModel() {
        var settings = StoryProviderSettings()
        settings.modelID = "local-model"
        settings.select(.dwarfstar)
        settings.modelID = "dwarfstar-model"
        settings.endpoint = URL(string: "http://127.0.0.1:8001/v1")!
        settings.select(.openrouter)
        settings.modelID = "cloud-model"
        settings.select(.omlx)
        XCTAssertEqual(settings.modelID, "local-model")
        XCTAssertEqual(settings.endpoint, StoryProviderKind.omlx.defaultEndpoint)
        settings.select(.dwarfstar)
        XCTAssertEqual(settings.modelID, "dwarfstar-model")
        XCTAssertEqual(settings.endpoint, URL(string: "http://127.0.0.1:8001/v1"))
        settings.select(.openrouter)
        XCTAssertEqual(settings.modelID, "cloud-model")
        XCTAssertEqual(settings.endpoint, StoryProviderKind.openrouter.defaultEndpoint)
    }

    func testWorkflowSubstitutionKeepsSeedNumericAndEscapesPromptSafely() throws {
        let template = Data(#"{"6":{"inputs":{"seed":"{{seed}}"}},"4":{"inputs":{"prompt":"{{prompt}}","image":"{{reference_image}}"}}}"#.utf8)
        try WorkflowTemplate.validate(template)
        let graph = try WorkflowTemplate.substitute(
            template,
            prompt: "A fox says \"goodnight\"\nunder the moon.",
            seed: 9_876_543,
            referenceImage: "inputs/StoryPress-fox.png"
        )
        let sampler = try XCTUnwrap(graph["6"] as? [String: Any])
        let samplerInputs = try XCTUnwrap(sampler["inputs"] as? [String: Any])
        let seed = try XCTUnwrap(samplerInputs["seed"] as? NSNumber)
        XCTAssertEqual(seed.int64Value, 9_876_543)
        let encoder = try XCTUnwrap(graph["4"] as? [String: Any])
        let inputs = try XCTUnwrap(encoder["inputs"] as? [String: Any])
        XCTAssertEqual(inputs["prompt"] as? String, "A fox says \"goodnight\"\nunder the moon.")
        XCTAssertEqual(inputs["image"] as? String, "inputs/StoryPress-fox.png")
    }

    func testCustomComfyWorkflowWithoutReferenceSlotDoesNotIgnoreReferenceArt() throws {
        let template = Data(#"{"1":{"inputs":{"seed":"{{seed}}","prompt":"{{prompt}}"}}}"#.utf8)
        XCTAssertThrowsError(try WorkflowTemplate.substitute(template, prompt: "A fox", seed: 1, referenceImage: "fox.png")) { error in
            XCTAssertTrue(error.localizedDescription.contains("{{reference_image}}"))
        }
    }

    func testComfyRejectsReferenceWorkflowMismatchBeforeUploading() async throws {
        let transport = RecordingTransport(payloads: [])
        let template = Data(#"{"1":{"inputs":{"seed":"{{seed}}","prompt":"{{prompt}}"}}}"#.utf8)
        do {
            _ = try await ComfyUIClient(transport: transport).submit(
                endpoint: URL(string: "http://127.0.0.1:8188")!,
                customWorkflow: template,
                prompt: "A fox",
                seed: 4,
                referenceImageURL: URL(fileURLWithPath: "/missing/reference.png")
            )
            XCTFail("Expected workflow mismatch")
        } catch let error as StoryPressError {
            guard case .invalidWorkflow = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testTimedOutComfySubmitIsNotAutomaticallyReplayed() async throws {
        let transport = RecordingTransport(error: StoryPressError.networkTimeout("test"))
        let workflow = Data(#"{"1":{"inputs":{"seed":"{{seed}}","prompt":"{{prompt}}"}}}"#.utf8)
        do {
            _ = try await ComfyUIClient(transport: transport).submit(
                endpoint: URL(string: "http://127.0.0.1:8188")!,
                customWorkflow: workflow,
                prompt: "A fox",
                seed: 3,
                referenceImageURL: nil
            )
            XCTFail("Expected timeout")
        } catch let error as StoryPressError {
            guard case .networkTimeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testComfyPollingPropagatesCancellationWithoutRetrying() async throws {
        let transport = RecordingTransport(error: StoryPressError.cancelled)
        do {
            _ = try await ComfyUIClient(transport: transport).waitForImage(
                jobID: UUID().uuidString,
                endpoint: URL(string: "http://127.0.0.1:8188")!,
                pollInterval: 10,
                timeout: 30
            )
            XCTFail("Expected cancellation")
        } catch let error as StoryPressError {
            guard case .cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOpenRouterReferenceCapabilityIsRequiredBeforeRequest() async throws {
        let transport = RecordingTransport(payloads: [HTTPPayload(statusCode: 200, data: Data())])
        let model = ProviderModel(id: "example/image-model", supportedParameters: ["output_format"])
        do {
            _ = try await OpenRouterImageClient(transport: transport).generate(
                endpoint: URL(string: "https://openrouter.ai/api/v1")!,
                model: model,
                prompt: "A fox beside a pond.",
                seed: 1,
                width: 1024,
                height: 1365,
                referenceImagePNG: Data([1, 2, 3]),
                apiKey: "sk-or-v1-test-secret"
            )
            XCTFail("Expected capability rejection")
        } catch let error as StoryPressError {
            guard case .providerNotConfigured = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testOpenRouterReferenceIsAttachedOnlyWhenModelAdvertisesSupport() async throws {
        let image = Data([7, 8, 9]).base64EncodedString()
        let response = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": image]]])
        let transport = RecordingTransport(payloads: [HTTPPayload(statusCode: 200, data: response)])
        let model = ProviderModel(id: "example/image-model", supportedParameters: ["input_references", "output_format"])
        _ = try await OpenRouterImageClient(transport: transport).generate(
            endpoint: URL(string: "https://openrouter.ai/api/v1")!,
            model: model,
            prompt: "A fox beside a pond.",
            seed: 13,
            width: 1024,
            height: 1365,
            referenceImagePNG: Data([1, 2, 3]),
            apiKey: "sk-or-v1-test-secret"
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-test-secret")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let references = try XCTUnwrap(object["input_references"] as? [[String: Any]])
        XCTAssertEqual(references.first?["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(references.first?["image_url"] as? [String: String])
        XCTAssertEqual(imageURL["url"], "data:image/png;base64,AQID")
    }

    func testOpenRouterMapsApproximatePortraitDimensionsToThreeByFour() async throws {
        let image = Data([7, 8, 9]).base64EncodedString()
        let response = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": image]]])
        let transport = RecordingTransport(payloads: [HTTPPayload(statusCode: 200, data: response)])
        let model = ProviderModel(id: "example/image-model", supportedParameters: ["aspect_ratio"])
        _ = try await OpenRouterImageClient(transport: transport).generate(
            endpoint: URL(string: "https://openrouter.ai/api/v1")!,
            model: model,
            prompt: "A fox beside a pond.",
            seed: 13,
            width: 1_024,
            height: 1_365,
            referenceImagePNG: nil,
            apiKey: "sk-or-v1-test-secret"
        )
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["aspect_ratio"] as? String, "3:4")
    }

    func testHTTPErrorBodyRedactsCredential() {
        let secret = "sk-or-v1-secret-value-123456"
        let data = Data("{\"error\":{\"message\":\"invalid token \(secret)\"}}".utf8)
        let message = HTTPRequestSupport.responseMessage(data, redacting: [secret])
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(message.contains("[redacted]"))
    }

    func testPDFHasSelectableTextAndOnePagePerStoryPagePlusCover() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressPDFTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoryLibraryPaths(rootURL: root)
        let store = StoryLibraryStore(paths: paths)
        let page = StoryPage(pageNumber: 1, text: "Pip carried his lantern home.", imagePrompt: "Pip in a forest.")
        let book = StoryBook(
            title: "Pip and the Lantern",
            theme: "Private theme prompt that must not appear on the cover",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "Pip is a fox.",
            pages: [page]
        )
        try await store.saveBook(book)
        let relativeImage = try await store.saveImage(Self.makePNG(), bookID: book.id, pageID: page.id)
        var withImage = book
        withImage.pages[0].imageFilename = relativeImage
        try await store.saveBook(withImage)
        let pdfURL = root.appending(path: "Pip.pdf")
        try PDFExporter(paths: paths).export(withImage, to: pdfURL)
        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(document.pageCount, 2)
        let extracted = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: " ")
        XCTAssertTrue(extracted.contains("Pip and the Lantern"))
        XCTAssertTrue(extracted.contains("Pip carried his lantern home."))
        XCTAssertFalse(extracted.contains("Private theme prompt"))
    }

    func testPDFRejectsMissingArtAndTextThatWouldOverflow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressPDFErrors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoryLibraryPaths(rootURL: root)
        let exporter = PDFExporter(paths: paths)
        let missing = StoryBook(
            title: "Missing Art",
            theme: "",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A fox",
            pages: [.init(pageNumber: 1, text: "A story page.", imagePrompt: "A fox.")]
        )
        XCTAssertThrowsError(try exporter.export(missing, to: root.appending(path: "missing.pdf")))

        let page = StoryPage(
            pageNumber: 1,
            text: String(repeating: "A very long story sentence for this page. ", count: 80),
            imagePrompt: "A fox under a tree."
        )
        let book = StoryBook(
            title: "Overflow",
            theme: "",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A fox",
            pages: [page]
        )
        let store = StoryLibraryStore(paths: paths)
        let imageName = try await store.saveImage(Self.makePNG(), bookID: book.id, pageID: page.id)
        var withImage = book
        withImage.pages[0].imageFilename = imageName
        XCTAssertThrowsError(try exporter.export(withImage, to: root.appending(path: "overflow.pdf"))) { error in
            guard let storyPressError = error as? StoryPressError,
                  case .exportLayout = storyPressError else {
                return XCTFail("Expected a fit error, got \(error)")
            }
        }
    }

    @MainActor
    func testAppModelProviderSwitchUsesSelectedCloudProviderInsteadOfInterruptedComfyJob() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressProviderSwitch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let comfyEndpoint = URL(string: "http://192.0.2.25:8188")!
        let oldJobID = UUID().uuidString
        let oldAttempt = IllustrationAttempt(
            provider: .comfyUI,
            endpoint: comfyEndpoint,
            modelID: nil,
            prompt: "Previously submitted ComfyUI prompt",
            seed: 31,
            comfyJobID: oldJobID,
            status: .pending
        )
        let page = StoryPage(
            pageNumber: 1,
            text: "The fox finds a lantern.",
            imagePrompt: "A fox beside a lantern.",
            comfyJobID: oldJobID,
            imageStatus: .pending,
            imageAttempts: [oldAttempt]
        )
        let book = StoryBook(
            title: "The Lantern Fox",
            theme: "A fox",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A russet fox.",
            pages: [page]
        )
        let paths = StoryLibraryPaths(rootURL: root)
        try await StoryLibraryStore(paths: paths).saveBook(book)
        let transport = RecordingTransport(payloads: [
            try Self.openRouterModelsPayload(),
            try Self.openRouterImagePayload(Self.makePNG())
        ])
        let app = AppModel(libraryRoot: root, transport: transport, keychain: TestCredentialStore(key: "test-openrouter-key"))
        await app.load()

        var settings = app.settings
        settings.illustration.provider = .openrouter
        settings.illustration.openRouterModelID = "example/image-model"
        app.settings = settings
        await app.generateMissingImages(for: book.id)

        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://openrouter.ai/api/v1/images/models",
            "https://openrouter.ai/api/v1/images"
        ])
        XCTAssertFalse(requests.contains { $0.url?.host == comfyEndpoint.host })
        XCTAssertFalse(requests.contains { $0.url?.path.contains(oldJobID) == true })
        let imageRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-openrouter-key")

        let saved = try XCTUnwrap(app.books.first(where: { $0.id == book.id }))
        let savedPage = try XCTUnwrap(saved.pages.first)
        XCTAssertEqual(savedPage.imageStatus, .complete)
        XCTAssertNil(savedPage.comfyJobID)
        XCTAssertEqual(savedPage.imageAttempts.count, 2)
        XCTAssertEqual(savedPage.imageAttempts.last?.provider, .openrouter)
        XCTAssertEqual(savedPage.imageAttempts.last?.endpoint, URL(string: "https://openrouter.ai/api/v1"))
        XCTAssertEqual(savedPage.imageAttempts.last?.modelID, "example/image-model")
        XCTAssertEqual(savedPage.imageAttempts.last?.status, .complete)
        try await app.saveSettings()
    }

    @MainActor
    func testAppModelCancellationKeepsInterruptedComfyJobAvailableForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressComfyResume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "http://127.0.0.1:8188")!
        let jobID = UUID().uuidString
        let attempt = IllustrationAttempt(
            provider: .comfyUI,
            endpoint: endpoint,
            prompt: "A fox beside a lantern.",
            seed: 47,
            comfyJobID: jobID,
            status: .generating
        )
        let page = StoryPage(
            pageNumber: 1,
            text: "The fox finds a lantern.",
            imagePrompt: "A fox beside a lantern.",
            comfyJobID: jobID,
            imageStatus: .generating,
            imageAttempts: [attempt]
        )
        let book = StoryBook(
            title: "The Lantern Fox",
            theme: "A fox",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A russet fox.",
            pages: [page]
        )
        let paths = StoryLibraryPaths(rootURL: root)
        try await StoryLibraryStore(paths: paths).saveBook(book)
        let history = Data("{\"\(jobID)\":{}}".utf8)
        let transport = RecordingTransport(payloads: [HTTPPayload(statusCode: 200, data: history)])
        let app = AppModel(libraryRoot: root, transport: transport, keychain: TestCredentialStore(key: nil))
        await app.load()
        XCTAssertEqual(app.books.first?.pages.first?.imageStatus, .pending)
        XCTAssertEqual(app.books.first?.pages.first?.imageAttempts.first?.status, .pending)

        let generation = Task { await app.generateMissingImages(for: book.id) }
        for _ in 0..<100 {
            if !(await transport.requests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requestsBeforeCancel = await transport.requests
        XCTAssertEqual(requestsBeforeCancel.count, 1)
        app.cancelGeneration()
        await generation.value

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, endpoint.appending(path: "history/\(jobID)").absoluteString)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/prompt") == true })
        let saved = try XCTUnwrap(app.books.first(where: { $0.id == book.id }))
        let savedPage = try XCTUnwrap(saved.pages.first)
        XCTAssertEqual(savedPage.imageStatus, .pending)
        XCTAssertEqual(savedPage.comfyJobID, jobID)
        XCTAssertEqual(savedPage.imageAttempts.first?.status, .pending)
        XCTAssertEqual(savedPage.imageAttempts.first?.comfyJobID, jobID)

        let reopened = AppModel(libraryRoot: root, transport: RecordingTransport(), keychain: TestCredentialStore(key: nil))
        await reopened.load()
        XCTAssertEqual(reopened.books.first?.pages.first?.comfyJobID, jobID)
        XCTAssertEqual(reopened.books.first?.pages.first?.imageStatus, .pending)
        try await app.saveSettings()
        try await reopened.saveSettings()
    }

    @MainActor
    func testAppModelGenerationStateSavePreservesEditsMadeDuringImageRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressGenerationMerge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let page = StoryPage(pageNumber: 1, text: "Original sentence.", imagePrompt: "A fox beside a lantern.")
        let book = StoryBook(
            title: "Original title",
            theme: "A fox",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A russet fox.",
            pages: [page]
        )
        try await StoryLibraryStore(paths: StoryLibraryPaths(rootURL: root)).saveBook(book)
        let transport = GatedImageTransport(modelPayload: try Self.openRouterModelsPayload())
        let app = AppModel(libraryRoot: root, transport: transport, keychain: TestCredentialStore(key: "test-openrouter-key"))
        await app.load()
        var settings = app.settings
        settings.illustration.provider = .openrouter
        settings.illustration.openRouterModelID = "example/image-model"
        app.settings = settings

        let generation = Task { await app.generateMissingImages(for: book.id) }
        await transport.waitForImageRequest()
        var edited = try XCTUnwrap(app.books.first(where: { $0.id == book.id }))
        edited.title = "Edited during illustration"
        edited.pages[0].text = "The fox carries the lantern home."
        try await app.saveEdits(edited)
        await transport.releaseImage(try Self.openRouterImagePayload(Self.makePNG()))
        await generation.value

        let saved = try XCTUnwrap(app.books.first(where: { $0.id == book.id }))
        XCTAssertEqual(saved.title, "Edited during illustration")
        XCTAssertEqual(saved.pages.first?.text, "The fox carries the lantern home.")
        XCTAssertEqual(saved.pages.first?.imageStatus, .complete)
        XCTAssertNotNil(saved.pages.first?.imageFilename)
        let diskBook = try await StoryLibraryStore(paths: StoryLibraryPaths(rootURL: root)).loadBook(id: book.id)
        XCTAssertEqual(diskBook?.title, "Edited during illustration")
        XCTAssertEqual(diskBook?.pages.first?.text, "The fox carries the lantern home.")
        XCTAssertEqual(diskBook?.pages.first?.imageStatus, .complete)
        try await app.saveSettings()
    }

    @MainActor
    func testAppModelFailedRegenerationKeepsPreviouslySavedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressOldImage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = UUID()
        let previousAttempt = IllustrationAttempt(
            provider: .comfyUI,
            endpoint: URL(string: "http://127.0.0.1:8188")!,
            prompt: "Previous fox illustration",
            seed: 9,
            imageFilename: "illustrations/previous.png",
            status: .complete
        )
        var page = StoryPage(
            id: pageID,
            pageNumber: 1,
            text: "The fox finds a lantern.",
            imagePrompt: "A fox beside a lantern.",
            imageStatus: .complete,
            imageAttempts: [previousAttempt]
        )
        let book = StoryBook(
            title: "The Lantern Fox",
            theme: "A fox",
            ageRange: "5–7",
            style: "Watercolor",
            characterDescription: "A russet fox.",
            pages: [page]
        )
        let paths = StoryLibraryPaths(rootURL: root)
        let store = StoryLibraryStore(paths: paths)
        try await store.saveBook(book)
        let oldImage = try await store.saveImage(Self.makePNG(), bookID: book.id, pageID: page.id)
        page.imageFilename = oldImage
        page.imageAttempts[0].imageFilename = oldImage
        var bookWithImage = book
        bookWithImage.pages = [page]
        try await store.saveBook(bookWithImage)
        let transport = RecordingTransport(error: StoryPressError.network("The test provider is unavailable."))
        let app = AppModel(libraryRoot: root, transport: transport, keychain: TestCredentialStore(key: nil))
        await app.load()
        var settings = app.settings
        settings.illustration.comfy.workflowJSON = Data(#"{"1":{"inputs":{"seed":"{{seed}}","prompt":"{{prompt}}"}}}"#.utf8)
        app.settings = settings

        await app.regeneratePage(bookID: book.id, pageID: page.id)

        let saved = try XCTUnwrap(app.books.first(where: { $0.id == book.id }))
        let savedPage = try XCTUnwrap(saved.pages.first)
        XCTAssertEqual(savedPage.imageStatus, .failed)
        XCTAssertEqual(savedPage.imageFilename, oldImage)
        XCTAssertNotNil(app.resolvedImageURL(for: savedPage, in: saved))
        XCTAssertEqual(savedPage.imageAttempts.first?.imageFilename, oldImage)
        XCTAssertEqual(savedPage.imageAttempts.first?.status, .complete)
        XCTAssertEqual(savedPage.imageAttempts.last?.status, .failed)
        XCTAssertTrue(app.errorMessage?.contains("test provider is unavailable") == true)
        try await app.saveSettings()
    }

    @MainActor
    func testAppModelDebouncedSettingsSavePersistsAllProviderProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StoryPressSettingsDebounce-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(libraryRoot: root, transport: RecordingTransport(), keychain: TestCredentialStore(key: nil))
        await app.load()
        var settings = app.settings
        settings.storyProvider.omlx = StoryProviderProfile(
            endpoint: URL(string: "http://127.0.0.1:9443/v1")!,
            modelID: "local-story-model"
        )
        settings.storyProvider.dwarfstar = StoryProviderProfile(
            endpoint: URL(string: "http://192.0.2.30:8001/v1")!,
            modelID: "remote-story-model"
        )
        settings.storyProvider.openrouter = StoryProviderProfile(
            endpoint: URL(string: "https://openrouter.ai/api/v1")!,
            modelID: "cloud-story-model"
        )
        settings.storyProvider.select(.openrouter)
        settings.storyProvider.maxOutputTokens = 4_096
        app.settings = settings
        try await Task.sleep(for: .milliseconds(450))

        let reopened = AppModel(libraryRoot: root, transport: RecordingTransport(), keychain: TestCredentialStore(key: nil))
        await reopened.load()
        XCTAssertEqual(reopened.settings, settings)
        reopened.settings.storyProvider.select(.omlx)
        XCTAssertEqual(reopened.settings.storyProvider.modelID, "local-story-model")
        reopened.settings.storyProvider.select(.dwarfstar)
        XCTAssertEqual(reopened.settings.storyProvider.modelID, "remote-story-model")
        reopened.settings.storyProvider.select(.openrouter)
        XCTAssertEqual(reopened.settings.storyProvider.modelID, "cloud-story-model")
        try await reopened.saveSettings()
    }

    private static func openRouterModelsPayload() throws -> HTTPPayload {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [["id": "example/image-model", "supported_parameters": ["output_format"]]]
        ])
        return HTTPPayload(statusCode: 200, data: data)
    }

    private static func openRouterImagePayload(_ image: Data) throws -> HTTPPayload {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [["b64_json": image.base64EncodedString()]]
        ])
        return HTTPPayload(statusCode: 200, data: data)
    }

    private static func makePNG() -> Data {
        let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

private actor RecordingTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let payloads: [HTTPPayload]
    private let error: Error?
    private var callCount = 0

    init(payloads: [HTTPPayload] = [], error: Error? = nil) {
        self.payloads = payloads
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> HTTPPayload {
        requests.append(request)
        if let error { throw error }
        guard payloads.indices.contains(callCount) else {
            throw StoryPressError.network("The test transport ran out of responses.")
        }
        defer { callCount += 1 }
        return payloads[callCount]
    }
}

private struct TestCredentialStore: OpenRouterCredentialStore {
    let key: String?

    var hasKey: Bool {
        guard let key else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() -> String? { key }

    func save(_ value: String) throws {
        throw StoryPressError.invalidInput("The test credential store is read-only.")
    }

    func delete() throws {
        throw StoryPressError.invalidInput("The test credential store is read-only.")
    }
}

private actor GatedImageTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let modelPayload: HTTPPayload
    private var imageContinuation: CheckedContinuation<HTTPPayload, Error>?
    private var imageRequestStarted = false
    private var imageRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(modelPayload: HTTPPayload) {
        self.modelPayload = modelPayload
    }

    func send(_ request: URLRequest) async throws -> HTTPPayload {
        requests.append(request)
        guard let path = request.url?.path else {
            throw StoryPressError.network("The test request had no URL.")
        }
        if path.hasSuffix("/images/models") { return modelPayload }
        if path.hasSuffix("/images") {
            return try await withCheckedThrowingContinuation { continuation in
                imageContinuation = continuation
                imageRequestStarted = true
                for waiter in imageRequestWaiters { waiter.resume() }
                imageRequestWaiters.removeAll()
            }
        }
        throw StoryPressError.network("The test transport received an unexpected request.")
    }

    func waitForImageRequest() async {
        guard !imageRequestStarted else { return }
        await withCheckedContinuation { imageRequestWaiters.append($0) }
    }

    func releaseImage(_ response: HTTPPayload) {
        imageContinuation?.resume(returning: response)
        imageContinuation = nil
    }
}
