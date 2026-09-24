import Foundation

struct StoryRequest: Sendable {
    var theme: String
    var age: String
    var pageCount: Int
    var style: String
}

struct StoryProviderClient: Sendable {
    private let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    func listModels(settings: StoryProviderSettings, openRouterKey: String?) async throws -> [ProviderModel] {
        try validateEndpoint(settings.endpoint, provider: settings.provider)
        var request = URLRequest(url: settings.endpoint.appending(path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let response = try await transport.send(request)
        try HTTPRequestSupport.check(response)
        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: response.data)
            return decoded.data
                .filter(\.canGenerateStoryText)
                .map { ProviderModel(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            throw StoryPressError.network("The provider returned an unrecognized model list.")
        }
    }

    func planStory(
        request story: StoryRequest,
        settings: StoryProviderSettings,
        openRouterKey: String?
    ) async throws -> StoryPlan {
        let normalized = try StoryRequestValidator.validate(story)
        guard let modelID = settings.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty else {
            throw StoryPressError.modelNotSelected
        }
        try validateEndpoint(settings.endpoint, provider: settings.provider)

        let maxTokens = min(max(settings.maxOutputTokens, 256), 8_192)
        let system = """
        You write warm, age-appropriate picture books for young children. Return only a JSON object with exactly these keys: title, character_description, pages. Each page has exactly text and image_prompt. Do not include analysis, chain of thought, markdown, or commentary. Keep each page text short enough to fit on a picture-book page. Keep recurring characters visually consistent in every image_prompt. Do not ask the image model to draw words or lettering.
        """
        let user = """
        Create a \(normalized.pageCount)-page illustrated story for children aged \(normalized.age).
        Theme: \(normalized.theme)
        Illustration style: \(normalized.style)
        Return exactly \(normalized.pageCount) pages. Make the story have a clear, gentle beginning, middle, and ending.
        """

        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user)
        ]
        do {
            let first: String
            do {
                first = try await completion(
                    modelID: modelID,
                    messages: messages,
                    maxTokens: maxTokens,
                    settings: settings,
                    openRouterKey: openRouterKey
                )
            } catch let error as StoryPressError {
                guard case .malformedStory = error else { throw error }
                return try await repair(
                    baseMessages: messages,
                    failedOutput: nil,
                    modelID: modelID,
                    maxTokens: maxTokens,
                    expectedPageCount: normalized.pageCount,
                    settings: settings,
                    openRouterKey: openRouterKey
                )
            } catch {
                throw error
            }
            do {
                return try StoryRequestValidator.validate(Self.decodePlan(first), expectedPageCount: normalized.pageCount)
            } catch {
                return try await repair(
                    baseMessages: messages,
                    failedOutput: first,
                    modelID: modelID,
                    maxTokens: maxTokens,
                    expectedPageCount: normalized.pageCount,
                    settings: settings,
                    openRouterKey: openRouterKey
                )
            }
        } catch is CancellationError {
            throw StoryPressError.cancelled
        } catch let error as StoryPressError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw StoryPressError.networkTimeout("Story planning")
        } catch {
            throw StoryPressError.network(error.localizedDescription)
        }
    }

    private func completion(
        modelID: String,
        messages: [ChatMessage],
        maxTokens: Int,
        settings: StoryProviderSettings,
        openRouterKey: String?
    ) async throws -> String {
        var request = URLRequest(url: settings.endpoint.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try addAuthorization(to: &request, provider: settings.provider, key: openRouterKey)
        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: modelID,
            messages: messages,
            maxTokens: maxTokens,
            responseFormat: .init(type: "json_object")
        ))
        let response = try await transport.send(request)
        try HTTPRequestSupport.check(response, redacting: openRouterKey.map { [$0] } ?? [])
        let decoded: ChatCompletionResponse
        do { decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: response.data) }
        catch { throw StoryPressError.malformedStory("The provider returned an invalid chat response.") }
        guard let text = decoded.choices.first?.message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoryPressError.malformedStory("The provider returned an empty story.")
        }
        return text
    }

    private func repair(
        baseMessages: [ChatMessage],
        failedOutput: String?,
        modelID: String,
        maxTokens: Int,
        expectedPageCount: Int,
        settings: StoryProviderSettings,
        openRouterKey: String?
    ) async throws -> StoryPlan {
        var messages = baseMessages
        if let failedOutput { messages.append(ChatMessage(role: "assistant", content: failedOutput)) }
        messages.append(ChatMessage(
            role: "user",
            content: "The previous response was empty or invalid. Return the required valid JSON object with exactly \(expectedPageCount) valid pages. Do not add explanation or reasoning."
        ))
        let repaired = try await completion(
            modelID: modelID,
            messages: messages,
            maxTokens: maxTokens,
            settings: settings,
            openRouterKey: openRouterKey
        )
        do {
            return try StoryRequestValidator.validate(Self.decodePlan(repaired), expectedPageCount: expectedPageCount)
        } catch {
            throw StoryPressError.malformedStory("The provider did not return the required title, character description, and page count after one repair attempt.")
        }
    }

    private func addAuthorization(to request: inout URLRequest, provider: StoryProviderKind, key: String?) throws {
        if provider == .openrouter {
            guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoryPressError.missingOpenRouterKey
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validateEndpoint(_ endpoint: URL, provider: StoryProviderKind) throws {
        guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme), endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw StoryPressError.providerNotConfigured("Enter a valid HTTP or HTTPS provider endpoint.")
        }
        if provider == .openrouter && (scheme != "https" || endpoint.host?.lowercased() != "openrouter.ai") {
            throw StoryPressError.providerNotConfigured("OpenRouter requests require HTTPS to openrouter.ai.")
        }
    }

    private static func decodePlan(_ content: String) throws -> StoryPlan {
        var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "", options: .regularExpression)
        }
        do {
            return try JSONDecoder().decode(StoryPlan.self, from: Data(json.utf8))
        } catch {
            throw StoryPressError.malformedStory("The provider response was not the expected JSON structure.")
        }
    }
}

private struct ModelsResponse: Decodable {
    struct Architecture: Decodable {
        var outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
        }
    }

    struct Item: Decodable {
        var id: String
        var name: String?
        var architecture: Architecture?

        var canGenerateStoryText: Bool {
            let descriptiveText = "\(id) \(name ?? "")"
            let nonTextModelPattern = "(?i)(embedding|embed|rerank)"
            guard descriptiveText.range(of: nonTextModelPattern, options: .regularExpression) == nil else { return false }
            guard let outputModalities = architecture?.outputModalities else { return true }
            return outputModalities.contains { $0.caseInsensitiveCompare("text") == .orderedSame }
        }
    }
    var data: [Item]
}

private struct ChatMessage: Codable, Sendable {
    var role: String
    var content: String
}

private struct ChatCompletionRequest: Encodable {
    struct ResponseFormat: Encodable {
        var type: String
    }

    var model: String
    var messages: [ChatMessage]
    var maxTokens: Int
    var responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}

enum StoryRequestValidator {
    static let pageCountRange = 3...24

    static func validate(_ request: StoryRequest) throws -> StoryRequest {
        let theme = request.theme.trimmingCharacters(in: .whitespacesAndNewlines)
        let age = request.age.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = request.style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.isEmpty, theme.count <= 240 else { throw StoryPressError.invalidInput("Enter a theme of up to 240 characters.") }
        guard !age.isEmpty, age.count <= 80 else { throw StoryPressError.invalidInput("Enter an age range of up to 80 characters.") }
        guard !style.isEmpty, style.count <= 240 else { throw StoryPressError.invalidInput("Enter an illustration style of up to 240 characters.") }
        guard pageCountRange.contains(request.pageCount) else {
            throw StoryPressError.invalidInput("Choose between \(pageCountRange.lowerBound) and \(pageCountRange.upperBound) pages.")
        }
        return StoryRequest(theme: theme, age: age, pageCount: request.pageCount, style: style)
    }

    static func validate(_ plan: StoryPlan, expectedPageCount: Int) throws -> StoryPlan {
        let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let character = plan.characterDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120,
              !character.isEmpty, character.count <= 1_200,
              plan.pages.count == expectedPageCount else {
            throw StoryPressError.malformedStory("The title, character description, or page count is invalid.")
        }
        for (index, page) in plan.pages.enumerated() {
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = page.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 900, !prompt.isEmpty, prompt.count <= 2_000 else {
                throw StoryPressError.malformedStory("Page \(index + 1) is missing text or an image prompt, or exceeds the page limit.")
            }
        }
        return StoryPlan(
            title: title,
            characterDescription: character,
            pages: plan.pages.map {
                StoryPlan.Page(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    imagePrompt: $0.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        )
    }
}
