import Foundation

enum StoryProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case omlx
    case dwarfstar
    case openrouter

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .omlx: "oMLX"
        case .dwarfstar: "DwarfStar"
        case .openrouter: "OpenRouter"
        }
    }

    var defaultEndpoint: URL {
        switch self {
        case .omlx: URL(string: "http://127.0.0.1:8843/v1")!
        case .dwarfstar: URL(string: "http://127.0.0.1:8001/v1")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1")!
        }
    }
}

enum IllustrationProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfyUI
    case openrouter

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .comfyUI: "ComfyUI"
        case .openrouter: "OpenRouter"
        }
    }
}

struct ProviderModel: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var supportedParameters: [String]
    var resolutionOptions: [String]
    var aspectRatioOptions: [String]

    init(
        id: String,
        name: String? = nil,
        supportedParameters: [String] = [],
        resolutionOptions: [String] = [],
        aspectRatioOptions: [String] = []
    ) {
        self.id = id
        self.name = name?.isEmpty == false ? name! : id
        self.supportedParameters = supportedParameters
        self.resolutionOptions = resolutionOptions
        self.aspectRatioOptions = aspectRatioOptions
    }
}

struct StoryProviderSettings: Codable, Sendable, Equatable {
    var provider: StoryProviderKind
    var omlx: StoryProviderProfile
    var dwarfstar: StoryProviderProfile
    var openrouter: StoryProviderProfile
    var maxOutputTokens: Int

    init(
        provider: StoryProviderKind = .omlx,
        omlx: StoryProviderProfile = .init(endpoint: StoryProviderKind.omlx.defaultEndpoint),
        dwarfstar: StoryProviderProfile = .init(endpoint: StoryProviderKind.dwarfstar.defaultEndpoint),
        openrouter: StoryProviderProfile = .init(endpoint: StoryProviderKind.openrouter.defaultEndpoint),
        maxOutputTokens: Int = 2_048
    ) {
        self.provider = provider
        self.omlx = omlx
        self.dwarfstar = dwarfstar
        self.openrouter = openrouter
        self.maxOutputTokens = min(max(maxOutputTokens, 256), 8_192)
    }

    var endpoint: URL {
        get { profile(for: provider).endpoint }
        set { updateCurrentProfile { $0.endpoint = newValue } }
    }

    var modelID: String? {
        get { profile(for: provider).modelID }
        set { updateCurrentProfile { $0.modelID = newValue } }
    }

    mutating func select(_ provider: StoryProviderKind) {
        self.provider = provider
    }

    private func profile(for kind: StoryProviderKind) -> StoryProviderProfile {
        switch kind {
        case .omlx: omlx
        case .dwarfstar: dwarfstar
        case .openrouter: openrouter
        }
    }

    private mutating func updateCurrentProfile(_ update: (inout StoryProviderProfile) -> Void) {
        switch provider {
        case .omlx: update(&omlx)
        case .dwarfstar: update(&dwarfstar)
        case .openrouter: update(&openrouter)
        }
    }
}

struct StoryProviderProfile: Codable, Sendable, Equatable {
    var endpoint: URL
    var modelID: String?

    init(endpoint: URL, modelID: String? = nil) {
        self.endpoint = endpoint
        self.modelID = modelID
    }
}

struct ComfySettings: Codable, Sendable, Equatable {
    var endpoint: URL
    var workflowJSON: Data?
    var workflowDisplayName: String?
    var pollIntervalSeconds: Double
    var timeoutSeconds: Double

    init(
        endpoint: URL = URL(string: "http://127.0.0.1:8188")!,
        workflowJSON: Data? = nil,
        workflowDisplayName: String? = nil,
        pollIntervalSeconds: Double = 2,
        timeoutSeconds: Double = 600
    ) {
        self.endpoint = endpoint
        self.workflowJSON = workflowJSON
        self.workflowDisplayName = workflowDisplayName
        self.pollIntervalSeconds = min(max(pollIntervalSeconds, 0.25), 30)
        self.timeoutSeconds = min(max(timeoutSeconds, 10), 1_800)
    }
}

struct IllustrationSettings: Codable, Sendable, Equatable {
    var provider: IllustrationProviderKind
    var openRouterEndpoint: URL
    var openRouterModelID: String?
    var comfy: ComfySettings
    var width: Int
    var height: Int

    init(
        provider: IllustrationProviderKind = .comfyUI,
        openRouterEndpoint: URL = URL(string: "https://openrouter.ai/api/v1")!,
        openRouterModelID: String? = nil,
        comfy: ComfySettings = .init(),
        width: Int = 768,
        height: Int = 1_024
    ) {
        self.provider = provider
        self.openRouterEndpoint = openRouterEndpoint
        self.openRouterModelID = openRouterModelID
        self.comfy = comfy
        self.width = min(max(width, 256), 2_048)
        self.height = min(max(height, 256), 2_048)
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var storyProvider: StoryProviderSettings
    var illustration: IllustrationSettings

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        storyProvider: StoryProviderSettings = .init(),
        illustration: IllustrationSettings = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.storyProvider = storyProvider
        self.illustration = illustration
    }
}

struct GenerationProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case planning
        case illustrating
        case saving
    }

    var phase: Phase
    var current: Int
    var total: Int
    var pageNumber: Int?

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(current) / Double(total), 0), 1)
    }
}
