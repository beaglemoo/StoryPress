import SwiftUI

@MainActor
struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel
    let onNewStory: () -> Void
    let onOpenSample: () -> Void
    let isLoadingSample: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let stacksContent = geometry.size.width < 1_100
            let stackedCardWidth = min(max(geometry.size.width - 84, 360), 620)
            let introWidth = min(430, max(340, geometry.size.width * 0.36))
            let sideBySideCardWidth = min(500, max(400, geometry.size.width * 0.34))

            ScrollView {
                VStack(spacing: 26) {
                    Group {
                        if stacksContent {
                            VStack(alignment: .center, spacing: 30) {
                                intro
                                    .frame(maxWidth: 460, alignment: .leading)
                                sampleArtwork(width: stackedCardWidth)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 38) {
                                intro
                                    .frame(width: introWidth, alignment: .leading)
                                sampleArtwork(width: sideBySideCardWidth)
                            }
                        }
                    }
                    .frame(maxWidth: 1_080, alignment: .center)
                    .padding(.horizontal, 42)
                    .padding(.top, 56)

                    providerNote
                        .frame(maxWidth: 900)
                        .padding(.horizontal, 42)
                        .padding(.bottom, 30)
                }
                .frame(maxWidth: .infinity)
            }
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.045), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Make a story,\none page at a time.")
                .font(.system(size: 41, weight: .regular, design: .serif))
                .tracking(-1.5)
                .lineSpacing(-4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("Shape a little world, give its characters a voice, and turn each page into a picture you can keep.")
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 11) {
                Button(action: onNewStory) {
                    Label("Create a new story", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button(action: onOpenSample) {
                    HStack {
                        Label("Open the sample book", systemImage: "book.closed")
                        Spacer()
                        if isLoadingSample {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Offline sample")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(isLoadingSample)
            }
            .frame(maxWidth: 330)
        }
    }

    private func sampleArtwork(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("SamplePath")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: 315, alignment: .center)
                .clipped()

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pip’s little lantern")
                        .font(.system(size: 16, weight: .medium, design: .serif))
                    Text("A peek inside the offline sample")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black.opacity(0.62))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: width, alignment: .leading)
            .foregroundStyle(Color.black.opacity(0.84))
            .background(Color(red: 0.995, green: 0.99, blue: 0.96))
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 30, x: 0, y: 15)
        .rotationEffect(.degrees(1.3))
        .accessibilityLabel("Artwork from Pip’s Little Lantern offline sample book")
    }

    private var providerNote: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("You choose where each part happens")
                    .font(.system(size: 12, weight: .semibold))
                Text("Story planning and illustrations have separate provider settings. Local and cloud choices are always explicit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Label("Provider settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.55), lineWidth: 1)
        }
    }
}
