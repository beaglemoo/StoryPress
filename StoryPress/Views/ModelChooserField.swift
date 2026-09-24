import SwiftUI

@MainActor
struct ModelChooserField: View {
    let title: String
    @Binding var modelID: String
    let models: [ProviderModel]
    @State private var isPickerPresented = false
    @State private var query = ""

    private var matchingModels: [ProviderModel] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(60).map { $0 } }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(normalized) || $0.id.localizedCaseInsensitiveContains(normalized)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(100).map { $0 }
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $modelID)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
            Button {
                query = ""
                isPickerPresented = true
            } label: {
                Label("Choose", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.glass)
            .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
                pickerContents
            }
            .disabled(models.isEmpty)
            .help(models.isEmpty ? "Refresh the model list first" : "Search discovered models")
        }
    }

    private var pickerContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(matchingModels) { model in
                        Button {
                            modelID = model.id
                            isPickerPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(model.id)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 360, height: 280)
            if matchingModels.isEmpty {
                Text(query.isEmpty ? "No models discovered yet. Refresh the list." : "No matching models.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(width: 390)
    }
}
