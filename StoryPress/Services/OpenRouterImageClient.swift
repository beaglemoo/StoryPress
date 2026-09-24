import Foundation

struct OpenRouterImageClient: Sendable {
    private let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    func listModels(endpoint: URL) async throws -> [ProviderModel] {
        try validateEndpoint(endpoint)
        var request = URLRequest(url: endpoint.appending(path: "images/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let payload = try await transport.send(request)
        try HTTPRequestSupport.check(payload)
        do {
            let response = try JSONDecoder().decode(ImageModelsResponse.self, from: payload.data)
            return response.data.map {
                ProviderModel(
                    id: $0.id,
                    name: $0.name,
                    supportedParameters: $0.parameters.sorted(),
                    resolutionOptions: $0.resolutionOptions,
                    aspectRatioOptions: $0.aspectRatioOptions
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            throw StoryPressError.network("OpenRouter returned an unrecognized image model list.")
        }
    }

    func generate(
        endpoint: URL,
        model: ProviderModel,
        prompt: String,
        seed: Int64,
        width: Int,
        height: Int,
        referenceImagePNG: Data?,
        apiKey: String?
    ) async throws -> Data {
        try validateEndpoint(endpoint)
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoryPressError.missingOpenRouterKey
        }
        guard !model.id.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoryPressError.invalidInput("Choose an image model and enter an image prompt.")
        }
        let parameters = Set(model.supportedParameters)
        if referenceImagePNG != nil && !parameters.contains("input_references") {
            throw StoryPressError.providerNotConfigured("The selected OpenRouter image model does not advertise reference-image input. Choose another model or use ComfyUI.")
        }

        var body: [String: Any] = ["model": model.id, "prompt": prompt, "n": 1]
        if parameters.contains("output_format") { body["output_format"] = "png" }
        if parameters.contains("aspect_ratio") {
            guard let ratio = Self.aspectRatio(width: width, height: height, supported: model.aspectRatioOptions) else {
                throw StoryPressError.providerNotConfigured("The selected image model does not support an aspect ratio close to the requested dimensions.")
            }
            body["aspect_ratio"] = ratio
        }
        if parameters.contains("seed") { body["seed"] = seed }
        if parameters.contains("resolution"), !model.resolutionOptions.isEmpty {
            body["resolution"] = model.resolutionOptions.first(where: { $0 == "1K" }) ?? model.resolutionOptions[0]
        }
        if parameters.contains("quality") { body["quality"] = "medium" }
        if let referenceImagePNG {
            body["input_references"] = [[
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(referenceImagePNG.base64EncodedString())"]
            ]]
        }

        var request = URLRequest(url: endpoint.appending(path: "images"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let payload = try await transport.send(request)
        try HTTPRequestSupport.check(payload, redacting: [apiKey])
        let response: ImagesResponse
        do { response = try JSONDecoder().decode(ImagesResponse.self, from: payload.data) }
        catch { throw StoryPressError.network("OpenRouter returned an unrecognized image response.") }
        guard let result = response.data.first else { throw StoryPressError.network("OpenRouter returned no image.") }
        if let encoded = result.b64Json, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty {
            return data
        }
        if let imageURLString = result.url, let imageURL = URL(string: imageURLString), imageURL.scheme == "https" {
            var imageRequest = URLRequest(url: imageURL)
            imageRequest.httpMethod = "GET"
            imageRequest.timeoutInterval = 90
            let image = try await transport.send(imageRequest)
            try HTTPRequestSupport.check(image)
            guard image.contentType?.lowercased().hasPrefix("image/") == true, !image.data.isEmpty else {
                throw StoryPressError.network("OpenRouter returned an invalid image URL.")
            }
            return image.data
        }
        throw StoryPressError.network("OpenRouter returned an empty image.")
    }

    private func validateEndpoint(_ endpoint: URL) throws {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.lowercased() == "openrouter.ai",
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw StoryPressError.providerNotConfigured("OpenRouter requests require HTTPS to openrouter.ai, with no credentials in the URL.")
        }
    }

    private static func aspectRatio(width: Int, height: Int, supported: [String]) -> String? {
        guard width > 0, height > 0 else { return nil }
        if !supported.isEmpty {
            let requested = Double(width) / Double(height)
            let choices = supported.compactMap { value -> (name: String, ratio: Double)? in
                let parts = value.split(separator: ":")
                guard parts.count == 2,
                      let numerator = Double(parts[0]),
                      let denominator = Double(parts[1]),
                      denominator > 0 else { return nil }
                return (value, numerator / denominator)
            }
            guard let best = choices.min(by: { abs($0.ratio - requested) < abs($1.ratio - requested) }),
                  abs(best.ratio - requested) <= 0.02 else { return nil }
                return best.name
        }
        let requested = Double(width) / Double(height)
        let divisor = gcd(width, height)
        let w = width / divisor
        let h = height / divisor
        if w <= 9, h <= 16 { return "\(w):\(h)" }

        let commonRatios: [(name: String, ratio: Double)] = [
            ("1:1", 1), ("4:5", 4.0 / 5), ("3:4", 3.0 / 4), ("2:3", 2.0 / 3),
            ("9:16", 9.0 / 16), ("5:4", 5.0 / 4), ("4:3", 4.0 / 3),
            ("3:2", 3.0 / 2), ("16:9", 16.0 / 9)
        ]
        guard let closest = commonRatios.min(by: { abs($0.ratio - requested) < abs($1.ratio - requested) }),
              abs(closest.ratio - requested) <= 0.02 else { return nil }
        return closest.name
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var left = a
        var right = b
        while right != 0 { (left, right) = (right, left % right) }
        return max(left, 1)
    }
}

private struct ImageModelsResponse: Decodable {
    struct ParameterSpec: Decodable {
        var values: [String]?
    }

    struct Item: Decodable {
        var id: String
        var name: String?
        var parameters: Set<String>
        var resolutionOptions: [String]
        var aspectRatioOptions: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case supportedParameters = "supported_parameters"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            if let specs = try? container.decode([String: ParameterSpec].self, forKey: .supportedParameters) {
                parameters = Set(specs.keys)
                resolutionOptions = specs["resolution"]?.values ?? []
                aspectRatioOptions = specs["aspect_ratio"]?.values ?? []
            } else if let names = try? container.decode([String].self, forKey: .supportedParameters) {
                parameters = Set(names)
                resolutionOptions = []
                aspectRatioOptions = []
            } else {
                parameters = []
                resolutionOptions = []
                aspectRatioOptions = []
            }
        }
    }

    var data: [Item]
}

private struct ImagesResponse: Decodable {
    struct Item: Decodable {
        var b64Json: String?
        var url: String?
        enum CodingKeys: String, CodingKey { case url; case b64Json = "b64_json" }
    }
    var data: [Item]
}
