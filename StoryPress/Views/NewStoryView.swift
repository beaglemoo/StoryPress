import SwiftUI

@MainActor
struct NewStoryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var theme = ""
    @State private var ageRange = "5–7 years"
    @State private var pageCount = 6
    @State private var style = "Warm watercolor"
    @State private var isCreating = false
    @State private var errorText: String?
    @FocusState private var themeHasFocus: Bool

    private let ageRanges = ["3–5 years", "5–7 years", "7–9 years", "9–12 years"]
    private let styles = ["Warm watercolor", "Soft gouache", "Colored pencil", "Cut-paper collage", "Ink and wash"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start with a small idea")
                        .font(.system(size: 25, weight: .regular, design: .serif))
                    Text("StoryPress will turn the brief into editable pages. Illustrations come later, when you choose to make them.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 23)

            Form {
                Section("The story") {
                    TextField("A shy moon rabbit learns to ask for help", text: $theme, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($themeHasFocus)
                        .accessibilityLabel("Story theme")

                    Picker("For readers aged", selection: $ageRange) {
                        ForEach(ageRanges, id: \.self) { age in
                            Text(age).tag(age)
                        }
                    }

                    Stepper(value: $pageCount, in: 3...16) {
                        HStack {
                            Text("Page count")
                            Spacer()
                            Text("\(pageCount) pages")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Section("Art direction") {
                    Picker("Illustration style", selection: $style) {
                        ForEach(styles, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    Text("You can edit every page’s illustration prompt before generating images.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            HStack {
                Text("Uses \(appModel.settings.storyProvider.provider.displayName) for the text plan")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    createStory()
                } label: {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 120)
                    } else {
                        Label("Create story", systemImage: "sparkles")
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating || appModel.isBusy)
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 570, height: 600)
        .task {
            themeHasFocus = true
        }
    }

    private func createStory() {
        guard !isCreating else { return }
        isCreating = true
        errorText = nil
        Task {
            do {
                _ = try await appModel.newBook(
                    theme: theme.trimmingCharacters(in: .whitespacesAndNewlines),
                    age: ageRange,
                    pageCount: pageCount,
                    style: style
                )
                dismiss()
            } catch {
                errorText = error.localizedDescription
                isCreating = false
            }
        }
    }
}
