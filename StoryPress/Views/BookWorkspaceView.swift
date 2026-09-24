import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BookWorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    private let book: StoryBook
    @State private var draft: StoryBook
    @State private var selectedPageID: UUID?
    @State private var saveTask: Task<Void, Never>?
    @State private var isDirty = false
    @State private var terminationHandlerID = UUID()
    @State private var saveState: SaveState = .saved
    @State private var errorText: String?
    @State private var isReferenceImporterPresented = false

    init(book: StoryBook) {
        self.book = book
        _draft = State(initialValue: book)
        _selectedPageID = State(initialValue: book.pages.first?.id)
    }

    private var liveBook: StoryBook {
        appModel.books.first { $0.id == draft.id } ?? book
    }

    private var displayBook: StoryBook {
        var merged = draft
        let latest = liveBook
        merged.referenceImageFilename = latest.referenceImageFilename
        for index in merged.pages.indices {
            guard let livePage = latest.pages.first(where: { $0.id == merged.pages[index].id }) else { continue }
            merged.pages[index].imageFilename = livePage.imageFilename
            merged.pages[index].seed = livePage.seed
            merged.pages[index].comfyJobID = livePage.comfyJobID
            merged.pages[index].imageStatus = livePage.imageStatus
            merged.pages[index].errorMessage = livePage.errorMessage
            merged.pages[index].sampleImageAssetName = livePage.sampleImageAssetName ?? merged.pages[index].sampleImageAssetName
        }
        return merged
    }

    private var selectedPage: StoryPage? {
        if let selectedPageID, let page = draft.pages.first(where: { $0.id == selectedPageID }) {
            return page
        }
        return draft.pages.first
    }

    private var selectedDisplayPage: StoryPage? {
        guard let selectedPage else { return nil }
        return displayBook.pages.first { $0.id == selectedPage.id } ?? selectedPage
    }

    private var pageCountWithArtwork: Int {
        displayBook.pages.filter { page in
            page.sampleImageAssetName != nil || page.imageFilename != nil
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 25) {
                pagePreviewColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.vertical, 4)

                pageInspector
                    .frame(width: 355)
            }
            .padding(.horizontal, 26)
            .padding(.top, 21)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)

            if let progress = appModel.progress {
                generationStatus(progress)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }

            PageFilmstrip(book: displayBook, selectedPageID: $selectedPageID)
                .padding(.horizontal, 22)
                .padding(.top, 11)
                .padding(.bottom, 14)
                .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: book.updatedAt) { _, _ in
            guard !isDirty else { return }
            draft = book
            if !book.pages.contains(where: { $0.id == selectedPageID }) {
                selectedPageID = book.pages.first?.id
            }
        }
        .onChange(of: draft.id) { _, _ in
            selectedPageID = draft.pages.first?.id
        }
        .onChange(of: selectedPageID) { _, _ in
            guard isDirty else { return }
            Task { _ = await flushEdits() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, isDirty else { return }
            Task { _ = await flushEdits() }
        }
        .fileImporter(
            isPresented: $isReferenceImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importReferenceArtwork
        )
        .alert("Could not update this book", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            PendingSaveRegistry.register(id: terminationHandlerID) {
                await flushEdits()
            }
        }
        .onDisappear {
            Task {
                let didSave = await flushEdits()
                if didSave {
                    PendingSaveRegistry.unregister(id: terminationHandlerID)
                }
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(draft.title.isEmpty ? "Untitled story" : draft.title)
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .lineLimit(1)
                    if draft.isSample {
                        Text("Offline sample")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                HStack(spacing: 7) {
                    Text("\(draft.pages.count) pages")
                    Text("·")
                    Text(draft.ageRange)
                    Text("·")
                    Text(saveState.label)
                        .foregroundStyle(isSaveFailed ? Color.red : Color.secondary)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button {
                isReferenceImporterPresented = true
            } label: {
                Label(displayBook.referenceImageFilename == nil ? "Add reference art" : "Change reference art", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.glass)
            .help("Import artwork to guide the illustrations")

            Button(action: exportPDF) {
                Label("Export PDF", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(pageCountWithArtwork != displayBook.pages.count)
            .help("Export this book as a PDF (⌘⇧E)")

            if displayBook.referenceImageFilename != nil {
                Menu {
                    Button("Remove reference artwork", systemImage: "trash", role: .destructive, action: clearReferenceArtwork)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .frame(width: 34, height: 30)
                }
                .help("More book actions")
            }

            if appModel.isBusy {
                Button("Cancel") {
                    appModel.cancelGeneration()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    Task { await generateMissingIllustrations() }
                } label: {
                    Label("Generate illustrations", systemImage: "sparkles")
                }
                .buttonStyle(.glassProminent)
                .disabled(displayBook.pages.allSatisfy { $0.sampleImageAssetName != nil || ($0.imageStatus == .complete && $0.imageFilename != nil) })
            }
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 17)
    }

    private var pagePreviewColumn: some View {
        VStack(spacing: 11) {
            HStack {
                Label("Page preview", systemImage: "book.pages")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let selectedPage {
                    Text("Page \(selectedPage.pageNumber) of \(draft.pages.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let selectedPage, let selectedDisplayPage {
                StoryPagePreviewView(book: displayBook, page: selectedDisplayPage)
                    .frame(maxWidth: 465, maxHeight: .infinity)
                    .accessibilityIdentifier("story-page-preview")
            } else {
                ContentUnavailableView("No pages in this book", systemImage: "doc.text")
            }

            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                Text("Narration stays as editable text in your book and PDF.")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 465, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageInspector: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Book details")
                    .font(.system(size: 14, weight: .semibold))
                TextField("Book title", text: Binding(
                    get: { draft.title },
                    set: { draft.title = $0; markEdited() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .accessibilityLabel("Book title")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Character description")
                    .font(.system(size: 11, weight: .semibold))
                TextEditor(text: Binding(
                    get: { draft.characterDescription },
                    set: { draft.characterDescription = $0; markEdited() }
                ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 72)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary, lineWidth: 1))
                .accessibilityLabel("Character description")
            }

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)

            if let selectedPage, let index = draft.pages.firstIndex(where: { $0.id == selectedPage.id }) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Page \(selectedPage.pageNumber) narration")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        statusLabel(for: selectedDisplayPage ?? selectedPage)
                    }
                    TextEditor(text: Binding(
                        get: { draft.pages[index].text },
                        set: { draft.pages[index].text = $0; markEdited() }
                    ))
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 134, maxHeight: 190)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary, lineWidth: 1))
                    .accessibilityLabel("Page \(selectedPage.pageNumber) narration")
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Illustration prompt")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if appModel.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .help("Illustration work is in progress")
                        } else {
                            Button {
                                Task { await regenerateSelectedPage(id: selectedPage.id) }
                            } label: {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(draft.isSample && selectedDisplayPage?.sampleImageAssetName != nil)
                            .help("Create new artwork for this page")
                        }
                    }
                    TextEditor(text: Binding(
                        get: { draft.pages[index].imagePrompt },
                        set: { draft.pages[index].imagePrompt = $0; markEdited() }
                    ))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 92, maxHeight: 145)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary, lineWidth: 1))
                    .accessibilityLabel("Page \(selectedPage.pageNumber) illustration prompt")

                    if let message = (selectedDisplayPage ?? selectedPage).errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
            }

            referenceArtworkRow

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

        }
        .padding(17)
        }
        .scrollIndicators(.hidden)
        .frame(width: 355)
        .background(
            reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(.white.opacity(reduceTransparency ? 0.18 : 0.48), lineWidth: 1)
        }
    }

    private var referenceArtworkRow: some View {
        HStack(spacing: 10) {
            Group {
                if let url = appModel.resolvedReferenceImageURL(for: liveBook), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.accentColor.opacity(0.07))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(liveBook.referenceImageFilename == nil ? "Reference artwork" : "Reference added")
                    .font(.system(size: 11, weight: .semibold))
                Text("Used only with a provider that accepts image input")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                isReferenceImporterPresented = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.glass)
            .help("Import reference artwork")
            .accessibilityLabel("Import reference artwork")
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func statusLabel(for page: StoryPage) -> some View {
        let title: String
        let symbol: String
        let color: Color
        if page.sampleImageAssetName != nil || page.imageStatus == .complete {
            title = "Illustrated"
            symbol = "checkmark.circle.fill"
            color = .green
        } else if page.imageStatus == .generating {
            title = "Generating"
            symbol = "arrow.trianglehead.2.clockwise"
            color = .orange
        } else if page.imageStatus == .failed {
            title = "Needs retry"
            symbol = "exclamationmark.circle.fill"
            color = .red
        } else {
            title = "Ready to illustrate"
            symbol = "circle.dashed"
            color = .secondary
        }
        return Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var isSaveFailed: Bool {
        if case .failed = saveState { return true }
        return false
    }

    private func generationStatus(_ progress: GenerationProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.fractionCompleted)
                .frame(width: 130)
            VStack(alignment: .leading, spacing: 2) {
                Text(progressDescription(progress))
                    .font(.system(size: 11, weight: .medium))
                Text("\(progress.current) of \(progress.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Cancel generation") {
                appModel.cancelGeneration()
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generation progress")
    }

    private func progressDescription(_ progress: GenerationProgress) -> String {
        switch progress.phase {
        case .planning:
            "Planning your story"
        case .illustrating:
            if let pageNumber = progress.pageNumber { "Illustrating page \(pageNumber)" }
            else { "Illustrating pages" }
        case .saving:
            "Saving your book"
        }
    }

    private func markEdited() {
        draft.touch()
        isDirty = true
        saveState = .saving
        saveTask?.cancel()
        let snapshot = draft
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                try await appModel.saveEdits(snapshot)
                guard !Task.isCancelled else { return }
                if draft.updatedAt == snapshot.updatedAt {
                    isDirty = false
                    saveState = .saved
                }
            } catch is CancellationError {
                return
            } catch {
                saveState = .failed(error.localizedDescription)
                errorText = "Your latest edits could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func flushEdits() async -> Bool {
        let pendingTask = saveTask
        saveTask = nil
        pendingTask?.cancel()
        if let pendingTask {
            await pendingTask.value
        }
        guard isDirty else { return true }
        saveState = .saving
        let snapshot = draft
        do {
            try await appModel.saveEdits(snapshot)
            if draft.updatedAt == snapshot.updatedAt {
                isDirty = false
                saveState = .saved
                errorText = nil
                return true
            }
            return !isDirty
        } catch {
            saveState = .failed(error.localizedDescription)
            errorText = "Your latest edits could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private func generateMissingIllustrations() async {
        guard !appModel.isBusy else { return }
        guard await flushEdits() else { return }
        await appModel.generateMissingImages(for: draft.id)
    }

    private func regenerateSelectedPage(id pageID: UUID) async {
        guard !appModel.isBusy else { return }
        guard await flushEdits() else { return }
        await appModel.regeneratePage(bookID: draft.id, pageID: pageID)
    }

    private func importReferenceArtwork(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            Task {
                do {
                    try await appModel.importReferenceImage(bookID: draft.id, from: url)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clearReferenceArtwork() {
        Task {
            do {
                try await appModel.clearReferenceArtwork(bookID: draft.id)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = safeFilename(for: draft.title) + ".pdf"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard await flushEdits() else { return }
                do {
                    _ = try appModel.exportPDF(bookID: draft.id, to: url)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func safeFilename(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "StoryPress-book" : cleaned
    }
}

private enum SaveState: Equatable {
    case saved
    case saving
    case failed(String)

    var label: String {
        switch self {
        case .saved: "All changes saved"
        case .saving: "Saving changes…"
        case .failed(let message): "Save failed: \(message)"
        }
    }
}

@MainActor
private struct PageFilmstrip: View {
    @Environment(AppModel.self) private var appModel
    let book: StoryBook
    @Binding var selectedPageID: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .center, spacing: 9) {
                ForEach(book.pages) { page in
                    let selected = page.id == selectedPageID
                    Button {
                        selectedPageID = page.id
                    } label: {
                        HStack(spacing: 8) {
                            PageArtworkThumbnail(book: book, page: page)
                                .frame(width: 40, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Page \(page.pageNumber)")
                                    .font(.system(size: 11, weight: .semibold))
                    Text(thumbnailStatus(for: page))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 76, alignment: .leading)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select page \(page.pageNumber)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 64)
        .accessibilityLabel("Book pages")
    }

    private func thumbnailStatus(for page: StoryPage) -> String {
        if page.imageStatus == .failed { return "Needs retry" }
        if page.imageStatus == .generating { return "Generating" }
        if page.imageFilename != nil || page.sampleImageAssetName != nil { return "Artwork ready" }
        return "No image yet"
    }
}

@MainActor
private struct PageArtworkThumbnail: View {
    @Environment(AppModel.self) private var appModel
    let book: StoryBook
    let page: StoryPage

    var body: some View {
        Group {
            if let asset = page.sampleImageAssetName {
                Image(asset).resizable().aspectRatio(contentMode: .fill)
            } else if let url = appModel.resolvedImageURL(for: page, in: book), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.accentColor.opacity(0.07)
                    Image(systemName: page.imageStatus == .failed ? "arrow.clockwise" : "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(page.imageStatus == .failed ? Color.red : Color.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private struct StoryPagePreviewView: View {
    @Environment(AppModel.self) private var appModel
    let book: StoryBook
    let page: StoryPage

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                artwork
                    .frame(width: geometry.size.width, height: geometry.size.height * 0.56)
                    .clipped()

                VStack(spacing: 11) {
                    HStack(spacing: 7) {
                        Rectangle()
                            .fill(Color(red: 0.64, green: 0.47, blue: 0.28).opacity(0.55))
                            .frame(width: 22, height: 1)
                        Text("Page \(page.pageNumber)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.4, green: 0.35, blue: 0.29))
                        Rectangle()
                            .fill(Color(red: 0.64, green: 0.47, blue: 0.28).opacity(0.55))
                            .frame(width: 22, height: 1)
                    }

                    Text(page.text.isEmpty ? "Your story text will appear here." : page.text)
                        .font(.system(size: min(max(geometry.size.width * 0.046, 16), 22), weight: .regular, design: .serif))
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.20))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)

                    Spacer(minLength: 0)

                    Text(book.title)
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(Color(red: 0.45, green: 0.43, blue: 0.39))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 15)
                .background(Color(red: 0.995, green: 0.987, blue: 0.965))
            }
            .background(Color(red: 0.995, green: 0.987, blue: 0.965))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.11), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 11)
        }
        .aspectRatio(0.735, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(page.pageNumber) preview. \(page.text)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let assetName = page.sampleImageAssetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .accessibilityLabel("Sample illustration")
        } else if let url = appModel.resolvedImageURL(for: page, in: book), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .accessibilityLabel("Generated illustration")
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.91, green: 0.93, blue: 0.96), Color(red: 0.84, green: 0.88, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 11) {
                    Image(systemName: page.imageStatus == .failed ? "arrow.clockwise.circle" : "sparkles")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color(red: 0.25, green: 0.34, blue: 0.52))
                    Text(placeholderTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.25, green: 0.31, blue: 0.44))
                    if page.imageStatus == .generating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(20)
            }
        }
    }

    private var placeholderTitle: String {
        switch page.imageStatus {
        case .pending: "Illustration ready when you are"
        case .generating: "Making this page"
        case .complete: "Illustration unavailable"
        case .failed: "Illustration needs another try"
        }
    }
}
