import Foundation

struct ComfyUIClient: Sendable {
    private let transport: any HTTPTransport
    private let bundle: Bundle

    init(transport: any HTTPTransport = URLSessionHTTPTransport(), bundle: Bundle = .main) {
        self.transport = transport
        self.bundle = bundle
    }

    func submit(
        endpoint: URL,
        customWorkflow: Data?,
        prompt: String,
        seed: Int64,
        referenceImageURL: URL?
    ) async throws -> String {
        try validateEndpoint(endpoint)
        let source = try WorkflowTemplate.load(
            customWorkflow: customWorkflow,
            hasReference: referenceImageURL != nil,
            bundle: bundle
        )
        try WorkflowTemplate.validate(source, requiresReference: referenceImageURL != nil)
        let uploadedReference: String?
        if let referenceImageURL {
            uploadedReference = try await uploadImage(referenceImageURL, endpoint: endpoint)
        } else {
            uploadedReference = nil
        }
        let workflow = try WorkflowTemplate.substitute(source, prompt: prompt, seed: seed, referenceImage: uploadedReference)
        var request = URLRequest(url: endpoint.appending(path: "prompt"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": workflow, "client_id": UUID().uuidString])
        do {
            let payload = try await transport.send(request)
            try HTTPRequestSupport.check(payload)
            let response = try JSONDecoder().decode(QueueResponse.self, from: payload.data)
            guard let id = response.promptID, UUID(uuidString: id) != nil else {
                throw StoryPressError.invalidWorkflow("ComfyUI did not return a job ID.")
            }
            return id
        } catch let error as StoryPressError {
            if case .networkTimeout = error {
                throw StoryPressError.networkTimeout("ComfyUI submission. The job may have been accepted; check ComfyUI history before retrying.")
            }
            throw error
        } catch {
            throw error
        }
    }

    func waitForImage(jobID: String, endpoint: URL, pollInterval: Double = 2, timeout: Double = 600) async throws -> Data {
        try validateEndpoint(endpoint)
        guard UUID(uuidString: jobID) != nil else { throw StoryPressError.invalidInput("The ComfyUI job ID is invalid.") }
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        var transientPollErrors = 0

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                if let image = try await fetchCompletedImage(jobID: jobID, endpoint: endpoint) { return image }
                transientPollErrors = 0
            } catch let error as StoryPressError {
                if case .httpStatus(let status, _) = error, status == 404 {
                    // ComfyUI may not have a history entry until execution starts.
                    transientPollErrors += 1
                } else {
                    throw error
                }
            } catch is CancellationError {
                throw StoryPressError.cancelled
            } catch {
                transientPollErrors += 1
                if transientPollErrors >= 3 { throw error }
            }
            try await Task.sleep(for: .seconds(max(pollInterval, 0.25)))
        }
        throw StoryPressError.networkTimeout("ComfyUI image generation")
    }

    private func fetchCompletedImage(jobID: String, endpoint: URL) async throws -> Data? {
        var request = URLRequest(url: endpoint.appending(path: "history/\(jobID)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let payload = try await transport.send(request)
        try HTTPRequestSupport.check(payload)
        let history = try JSONDecoder().decode([String: HistoryJob].self, from: payload.data)
        guard let job = history[jobID] else { return nil }
        if let state = job.status?.statusString?.lowercased(), ["error", "failed", "interrupted"].contains(state) {
            throw StoryPressError.invalidWorkflow("ComfyUI job \(state). Open ComfyUI for details, then retry the page.")
        }
        let preferred = job.outputs?["8"]?.images ?? []
        let image = preferred.first ?? job.outputs?.values.map(\.images).flatMap { $0 }.first
        guard let image else { return nil }
        var components = URLComponents(url: endpoint.appending(path: "view"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "filename", value: image.filename),
            URLQueryItem(name: "subfolder", value: image.subfolder ?? ""),
            URLQueryItem(name: "type", value: image.type ?? "output")
        ]
        guard let url = components?.url else { throw StoryPressError.invalidWorkflow("ComfyUI returned an invalid output path.") }
        var imageRequest = URLRequest(url: url)
        imageRequest.httpMethod = "GET"
        imageRequest.timeoutInterval = 60
        let result = try await transport.send(imageRequest)
        try HTTPRequestSupport.check(result)
        guard !result.data.isEmpty else { throw StoryPressError.invalidWorkflow("ComfyUI returned an empty image.") }
        return result.data
    }

    private func uploadImage(_ sourceURL: URL, endpoint: URL) async throws -> String {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: sourceURL) }
        catch { throw StoryPressError.missingAsset("reference image could not be read") }
        guard !data.isEmpty, data.count <= 40 * 1_024 * 1_024 else {
            throw StoryPressError.invalidInput("The reference image must be smaller than 40 MB.")
        }

        let basename = sourceURL.lastPathComponent
            .unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }
        let safeName = "StoryPress-\(UUID().uuidString)-\(String(String.UnicodeScalarView(basename)))"
        let boundary = "StoryPress-\(UUID().uuidString)"
        var body = Data()
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n", to: &body)
        body.append(data)
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\ninput\r\n", to: &body)
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n", to: &body)

        var request = URLRequest(url: endpoint.appending(path: "upload/image"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response = try await transport.send(request)
        try HTTPRequestSupport.check(response)
        let uploaded = try JSONDecoder().decode(UploadResponse.self, from: response.data)
        guard !uploaded.name.isEmpty else { throw StoryPressError.invalidWorkflow("ComfyUI did not return the uploaded reference image name.") }
        let subfolder = (uploaded.subfolder ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return subfolder.isEmpty ? uploaded.name : "\(subfolder)/\(uploaded.name)"
    }

    private func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private func validateEndpoint(_ endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw StoryPressError.providerNotConfigured("Enter a valid ComfyUI HTTP or HTTPS endpoint without URL credentials, query items, or fragments.")
        }
    }
}

enum WorkflowTemplate {
    static func load(customWorkflow: Data?, hasReference: Bool, bundle: Bundle = .main) throws -> Data {
        if let customWorkflow {
            return customWorkflow
        }
        let name = hasReference ? "StoryPress-Qwen-Image-2.1-Reference.api" : "qwen-image-2.1-api"
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw StoryPressError.providerNotConfigured("The bundled ComfyUI workflow \(name).json is missing.")
        }
        do { return try Data(contentsOf: url) }
        catch { throw StoryPressError.invalidWorkflow("The bundled workflow could not be read.") }
    }

    static func substitute(_ template: Data, prompt: String, seed: Int64, referenceImage: String?) throws -> [String: Any] {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: template) }
        catch { throw StoryPressError.invalidWorkflow("The workflow file is not valid JSON.") }
        guard let graph = object as? [String: Any] else { throw StoryPressError.invalidWorkflow("The workflow root must be a JSON object.") }
        var foundPrompt = false
        var foundSeed = false
        var foundReference = false
        let updated = replaceTokens(
            in: graph,
            prompt: prompt,
            seed: seed,
            referenceImage: referenceImage,
            foundPrompt: &foundPrompt,
            foundSeed: &foundSeed,
            foundReference: &foundReference
        )
        guard foundPrompt, foundSeed else { throw StoryPressError.invalidWorkflow("The workflow needs {{prompt}} and {{seed}} fields.") }
        if referenceImage != nil && !foundReference {
            throw StoryPressError.invalidWorkflow("This workflow has no {{reference_image}} field. Import the reference workflow or remove the reference artwork.")
        }
        if referenceImage == nil && foundReference {
            throw StoryPressError.invalidWorkflow("This workflow requires reference artwork. Add a reference image or choose the text-to-image workflow.")
        }
        guard let result = updated as? [String: Any], JSONSerialization.isValidJSONObject(result) else {
            throw StoryPressError.invalidWorkflow("The workflow placeholders produced invalid JSON values.")
        }
        return result
    }

    static func validate(_ template: Data, requiresReference: Bool? = nil) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: template) }
        catch { throw StoryPressError.invalidWorkflow("The workflow file is not valid JSON.") }
        guard let graph = object as? [String: Any] else { throw StoryPressError.invalidWorkflow("The workflow root must be a JSON object.") }
        var hasPrompt = false
        var hasSeed = false
        var foundReference = false
        _ = replaceTokens(in: graph, prompt: "validation", seed: 7, referenceImage: "reference.png",
                          foundPrompt: &hasPrompt, foundSeed: &hasSeed, foundReference: &foundReference)
        guard hasPrompt, hasSeed else { throw StoryPressError.invalidWorkflow("The workflow needs {{prompt}} and {{seed}} fields.") }
        if requiresReference == true && !foundReference {
            throw StoryPressError.invalidWorkflow("The selected workflow does not support reference artwork.")
        }
        if requiresReference == false && foundReference {
            throw StoryPressError.invalidWorkflow("This workflow requires reference artwork. Add a reference image or choose the text-to-image workflow.")
        }
    }

    private static func replaceTokens(
        in value: Any,
        prompt: String,
        seed: Int64,
        referenceImage: String?,
        foundPrompt: inout Bool,
        foundSeed: inout Bool,
        foundReference: inout Bool
    ) -> Any {
        if let string = value as? String {
            if string == "{{seed}}" {
                foundSeed = true
                return NSNumber(value: seed)
            }
            var result = string
            if result.contains("{{prompt}}") {
                foundPrompt = true
                result = result.replacingOccurrences(of: "{{prompt}}", with: prompt)
            }
            if result.contains("{{reference_image}}") {
                foundReference = true
                result = result.replacingOccurrences(of: "{{reference_image}}", with: referenceImage ?? "")
            }
            return result
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues {
                replaceTokens(in: $0, prompt: prompt, seed: seed, referenceImage: referenceImage,
                              foundPrompt: &foundPrompt, foundSeed: &foundSeed, foundReference: &foundReference)
            }
        }
        if let array = value as? [Any] {
            return array.map {
                replaceTokens(in: $0, prompt: prompt, seed: seed, referenceImage: referenceImage,
                              foundPrompt: &foundPrompt, foundSeed: &foundSeed, foundReference: &foundReference)
            }
        }
        return value
    }
}

private struct QueueResponse: Decodable { var promptID: String?; enum CodingKeys: String, CodingKey { case promptID = "prompt_id" } }
private struct UploadResponse: Decodable { var name: String; var subfolder: String? }
private struct HistoryJob: Decodable {
    struct Status: Decodable {
        var statusString: String?
        enum CodingKeys: String, CodingKey { case statusString = "status_str" }
    }
    struct Output: Decodable {
        var images: [Image]

        private enum CodingKeys: String, CodingKey { case images }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            images = try container.decodeIfPresent([Image].self, forKey: .images) ?? []
        }
    }
    struct Image: Decodable { var filename: String; var subfolder: String?; var type: String? }
    var status: Status?
    var outputs: [String: Output]?
}
