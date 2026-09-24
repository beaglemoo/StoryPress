import Foundation

enum ImageGenerationStatus: String, Codable, Sendable {
    case pending
    case generating
    case complete
    case failed
}

struct StoryBook: Codable, Sendable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var id: UUID
    var title: String
    var theme: String
    var ageRange: String
    var style: String
    var characterDescription: String
    var pages: [StoryPage]
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
    var isSample: Bool
    var referenceImageFilename: String?

    init(
        id: UUID = UUID(),
        title: String,
        theme: String,
        ageRange: String,
        style: String,
        characterDescription: String,
        pages: [StoryPage],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = Self.currentSchemaVersion,
        isSample: Bool = false,
        referenceImageFilename: String? = nil
    ) {
        self.id = id
        self.title = title
        self.theme = theme
        self.ageRange = ageRange
        self.style = style
        self.characterDescription = characterDescription
        self.pages = pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
        self.isSample = isSample
        self.referenceImageFilename = referenceImageFilename
    }

    mutating func touch() {
        updatedAt = .now
    }
}

struct StoryPage: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var pageNumber: Int
    var text: String
    var imagePrompt: String
    var imageFilename: String?
    var seed: Int64?
    var comfyJobID: String?
    var imageStatus: ImageGenerationStatus
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var sampleImageAssetName: String?
    var imageAttempts: [IllustrationAttempt]

    init(
        id: UUID = UUID(),
        pageNumber: Int,
        text: String,
        imagePrompt: String,
        imageFilename: String? = nil,
        seed: Int64? = nil,
        comfyJobID: String? = nil,
        imageStatus: ImageGenerationStatus = .pending,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sampleImageAssetName: String? = nil,
        imageAttempts: [IllustrationAttempt] = []
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.text = text
        self.imagePrompt = imagePrompt
        self.imageFilename = imageFilename
        self.seed = seed
        self.comfyJobID = comfyJobID
        self.imageStatus = imageStatus
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sampleImageAssetName = sampleImageAssetName
        self.imageAttempts = imageAttempts
    }
}

struct IllustrationAttempt: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var provider: IllustrationProviderKind
    var endpoint: URL
    var modelID: String?
    var prompt: String
    var seed: Int64
    var imageFilename: String?
    var comfyJobID: String?
    var status: ImageGenerationStatus
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        provider: IllustrationProviderKind = .comfyUI,
        endpoint: URL = URL(string: "http://127.0.0.1:8188")!,
        modelID: String? = nil,
        prompt: String,
        seed: Int64,
        imageFilename: String? = nil,
        comfyJobID: String? = nil,
        status: ImageGenerationStatus = .pending,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.provider = provider
        self.endpoint = endpoint
        self.modelID = modelID
        self.prompt = prompt
        self.seed = seed
        self.imageFilename = imageFilename
        self.comfyJobID = comfyJobID
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct StoryPlan: Codable, Sendable, Equatable {
    struct Page: Codable, Sendable, Equatable {
        var text: String
        var imagePrompt: String

        enum CodingKeys: String, CodingKey {
            case text
            case imagePrompt = "image_prompt"
        }
    }

    var title: String
    var characterDescription: String
    var pages: [Page]

    enum CodingKeys: String, CodingKey {
        case title
        case characterDescription = "character_description"
        case pages
    }
}
