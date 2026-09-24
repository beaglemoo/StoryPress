import AppKit
import SwiftUI

@MainActor
struct LibrarySidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isNewStoryPresented: Bool
    let onOpenSample: () -> Void
    let isLoadingSample: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var orderedBooks: [StoryBook] {
        appModel.books.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            List(selection: Binding(
                get: { appModel.selectedBookID },
                set: { appModel.selectedBookID = $0 }
            )) {
                Section("Your library") {
                    ForEach(orderedBooks) { book in
                        LibraryBookRow(book: book)
                            .tag(book.id)
                    }
                }

                if orderedBooks.isEmpty {
                    ContentUnavailableView(
                        "A story begins here",
                        systemImage: "books.vertical",
                        description: Text("Create a new book or open the offline sample.")
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .listRowSeparator(.hidden)

            providerFooter
        }
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        .focusedSceneValue(\.newStoryAction, { isNewStoryPresented = true })
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("StoryPress")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Picture book studio")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                isNewStoryPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .help("Create a new story")
            .accessibilityLabel("New story")
        }
        .padding(.horizontal, 17)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var providerFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)

            HStack(alignment: .center, spacing: 9) {
                VStack(alignment: .leading, spacing: 6) {
                    providerStatusRow(
                        title: "Story · \(appModel.settings.storyProvider.provider.displayName)",
                        symbol: appModel.settings.storyProvider.provider == .openrouter ? "cloud" : "desktopcomputer"
                    )
                    providerStatusRow(
                        title: "Art · \(appModel.settings.illustration.provider.displayName)",
                        symbol: appModel.settings.illustration.provider == .openrouter ? "cloud" : "desktopcomputer"
                    )
                }
                Spacer()
                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func providerStatusRow(title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

@MainActor
private struct LibraryBookRow: View {
    @Environment(AppModel.self) private var appModel
    let book: StoryBook

    private var leadingImage: NSImage? {
        guard let page = book.pages.first else { return nil }
        if let assetName = page.sampleImageAssetName {
            return NSImage(named: NSImage.Name(assetName))
        }
        guard let url = appModel.resolvedImageURL(for: page, in: book) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let leadingImage {
                    Image(nsImage: leadingImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.accentColor.opacity(0.09))
                        Image(systemName: "book.closed")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .frame(width: 42, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(book.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if book.isSample {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Offline sample book")
                    }
                }
                Text("\(book.pages.count) pages · \(book.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.pages.count) pages\(book.isSample ? ", offline sample" : "")")
    }
}
