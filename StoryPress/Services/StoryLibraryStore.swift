import Foundation

struct StoryLibraryPaths: Sendable {
    let rootURL: URL

    init(rootURL: URL = StoryLibraryPaths.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "StoryPress", directoryHint: .isDirectory)
    }

    var booksDirectory: URL { rootURL.appending(path: "Books", directoryHint: .isDirectory) }
    var settingsURL: URL { rootURL.appending(path: "settings.json") }

    func bookDirectory(for bookID: UUID) -> URL {
        booksDirectory.appending(path: bookID.uuidString, directoryHint: .isDirectory)
    }

    func bookURL(for bookID: UUID) -> URL {
        bookDirectory(for: bookID).appending(path: "book.json")
    }

    func assetURL(bookID: UUID, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw StoryPressError.unsafeAssetPath
        }
        let bookDirectory = bookDirectory(for: bookID).standardizedFileURL
        let candidate = bookDirectory.appending(path: relativePath).standardizedFileURL
        let bookPath = bookDirectory.resolvingSymlinksInPath().path
        let candidatePath = candidate.resolvingSymlinksInPath().path
        guard candidatePath.hasPrefix(bookPath + "/") else { throw StoryPressError.unsafeAssetPath }
        return candidate
    }
}

struct LibraryLoadResult: Sendable {
    var books: [StoryBook]
    var skippedCount: Int
}

actor StoryLibraryStore {
    let paths: StoryLibraryPaths
    private let fileManager: FileManager

    init(paths: StoryLibraryPaths = .init(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadSettings() throws -> AppSettings {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else { return .init() }
        do {
            let data = try Data(contentsOf: paths.settingsURL)
            let settings = try Self.decoder().decode(AppSettings.self, from: data)
            guard settings.schemaVersion <= AppSettings.currentSchemaVersion else {
                throw StoryPressError.storage("Settings were saved by a newer StoryPress version.")
            }
            return settings
        } catch let error as StoryPressError {
            throw error
        } catch {
            throw StoryPressError.storage("Settings could not be read: \(error.localizedDescription)")
        }
    }

    func saveSettings(_ settings: AppSettings) throws {
        var current = settings
        current.schemaVersion = AppSettings.currentSchemaVersion
        try write(Self.encoder().encode(current), to: paths.settingsURL)
    }

    func loadBooks() throws -> LibraryLoadResult {
        guard fileManager.fileExists(atPath: paths.booksDirectory.path) else { return LibraryLoadResult(books: [], skippedCount: 0) }
        do {
            let directories = try fileManager.contentsOfDirectory(
                at: paths.booksDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var valid = [StoryBook]()
            var skipped = 0
            for directory in directories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard let data = try? Data(contentsOf: directory.appending(path: "book.json")),
                      let book = try? Self.decoder().decode(StoryBook.self, from: data),
                      book.schemaVersion <= StoryBook.currentSchemaVersion,
                      hasUniquePageIDs(book) else {
                    skipped += 1
                    continue
                }
                valid.append(book)
            }
            valid.sort { $0.updatedAt > $1.updatedAt }
            return LibraryLoadResult(books: valid, skippedCount: skipped)
        } catch {
            throw StoryPressError.storage("The library could not be listed: \(error.localizedDescription)")
        }
    }

    func loadBook(id: UUID) throws -> StoryBook? {
        let url = paths.bookURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let book = try Self.decoder().decode(StoryBook.self, from: Data(contentsOf: url))
            guard book.schemaVersion <= StoryBook.currentSchemaVersion else {
                throw StoryPressError.storage("This book was saved by a newer StoryPress version.")
            }
            guard hasUniquePageIDs(book) else {
                throw StoryPressError.storage("This book contains duplicate page IDs and cannot be edited safely.")
            }
            return book
        } catch let error as StoryPressError {
            throw error
        } catch {
            throw StoryPressError.storage("The book could not be read: \(error.localizedDescription)")
        }
    }

    func saveBook(_ book: StoryBook) throws {
        try save(book)
    }

    func setReferenceImage(_ relativePath: String?, bookID: UUID) throws -> StoryBook {
        guard var book = try loadBook(id: bookID) else { throw StoryPressError.storage("The selected book no longer exists.") }
        if let relativePath { _ = try paths.assetURL(bookID: bookID, relativePath: relativePath) }
        book.referenceImageFilename = relativePath
        book.touch()
        try save(book)
        return book
    }

    /// Applies user-edited text and metadata while retaining the latest media state on disk.
    func saveEdits(_ edited: StoryBook) throws -> StoryBook {
        var merged = try loadBook(id: edited.id) ?? edited
        merged.title = edited.title
        merged.theme = edited.theme
        merged.ageRange = edited.ageRange
        merged.style = edited.style
        merged.characterDescription = edited.characterDescription

        guard hasUniquePageIDs(merged), hasUniquePageIDs(edited) else {
            throw StoryPressError.storage("This book contains duplicate page IDs and cannot be edited safely.")
        }
        let oldPages = Dictionary(merged.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pages = edited.pages.map { draft -> StoryPage in
            guard var existing = oldPages[draft.id] else { return draft }
            existing.pageNumber = draft.pageNumber
            existing.text = draft.text
            existing.imagePrompt = draft.imagePrompt
            existing.updatedAt = .now
            return existing
        }
        let editedIDs = Set(pages.map(\.id))
        pages.append(contentsOf: merged.pages.filter { !editedIDs.contains($0.id) })
        merged.pages = pages.sorted { $0.pageNumber < $1.pageNumber }
        merged.touch()
        try save(merged)
        return merged
    }

    /// Applies generation-owned fields to the latest text, so an in-flight image response cannot erase edits.
    func saveGenerationState(_ update: StoryBook) throws -> StoryBook {
        guard var current = try loadBook(id: update.id) else {
            try save(update)
            return update
        }
        guard hasUniquePageIDs(current), hasUniquePageIDs(update) else {
            throw StoryPressError.storage("This book contains duplicate page IDs and cannot be updated safely.")
        }
        let updatePages = Dictionary(update.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in current.pages.indices {
            guard let generated = updatePages[current.pages[index].id] else { continue }
            current.pages[index].imageFilename = generated.imageFilename
            current.pages[index].seed = generated.seed
            current.pages[index].comfyJobID = generated.comfyJobID
            current.pages[index].imageStatus = generated.imageStatus
            current.pages[index].errorMessage = generated.errorMessage
            current.pages[index].imageAttempts = generated.imageAttempts
            current.pages[index].updatedAt = generated.updatedAt
        }
        current.updatedAt = update.updatedAt
        try save(current)
        return current
    }

    func saveImage(_ data: Data, bookID: UUID, pageID: UUID) throws -> String {
        let relativePath = "illustrations/\(pageID.uuidString)-\(UUID().uuidString).png"
        let destination = try paths.assetURL(bookID: bookID, relativePath: relativePath)
        try write(data, to: destination)
        return relativePath
    }

    func saveReferenceImage(_ data: Data, bookID: UUID, fileExtension: String) throws -> String {
        let allowed = Set(["png", "jpg", "jpeg", "heic", "webp"])
        let ext = fileExtension.lowercased()
        guard allowed.contains(ext) else { throw StoryPressError.invalidInput("Choose a PNG, JPEG, HEIC, or WebP image.") }
        let relativePath = "reference/reference-\(UUID().uuidString).\(ext)"
        let destination = try paths.assetURL(bookID: bookID, relativePath: relativePath)
        try write(data, to: destination)
        return relativePath
    }

    func imageURL(bookID: UUID, relativePath: String) -> URL? {
        guard let url = try? paths.assetURL(bookID: bookID, relativePath: relativePath),
              fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func save(_ book: StoryBook) throws {
        var normalized = book
        guard hasUniquePageIDs(normalized) else {
            throw StoryPressError.storage("The book contains duplicate page IDs.")
        }
        normalized.schemaVersion = StoryBook.currentSchemaVersion
        do {
            try write(Self.encoder().encode(normalized), to: paths.bookURL(for: book.id))
        } catch let error as StoryPressError {
            throw error
        } catch {
            throw StoryPressError.storage("The book could not be written: \(error.localizedDescription)")
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoryPressError.storage("A file could not be written: \(error.localizedDescription)")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func hasUniquePageIDs(_ book: StoryBook) -> Bool {
        Set(book.pages.map(\.id)).count == book.pages.count
    }
}
