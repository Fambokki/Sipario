import SwiftUI

// MARK: - Immagini

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if let url {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
                default: placeholder()
                }
            }
        } else {
            placeholder()
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = { Theme.card }
    }
}

/// Immagine a riempimento di altezza fissa che non allarga mai la pagina.
struct FillImage: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { RemoteImage(url: url) }
            .clipped()
    }
}

/// Copertina "di riserva" quando un titolo non ha immagine.
struct PosterPlaceholder: View {
    let title: String
    var kind: ItemKind = .movie

    var body: some View {
        let color = Theme.posterPalette[title.colorSeed % Theme.posterPalette.count]
        ZStack {
            LinearGradient(colors: [color, color.opacity(0.45), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: kind == .series ? "tv" : (kind == .live ? "dot.radiowaves.left.and.right" : "film"))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
            }
            .padding(10)
        }
    }
}

struct PosterImage: View {
    let item: MediaItem
    var large = false

    var body: some View {
        let url = large ? item.largePosterURL : item.posterURL
        if item.kind == .live {
            ZStack {
                Theme.card
                RemoteImage(url: url, contentMode: .fit) { PosterPlaceholder(title: item.displayTitle, kind: .live) }
                    .padding(url == nil ? 0 : 14)
            }
        } else {
            RemoteImage(url: url) { PosterPlaceholder(title: item.displayTitle, kind: item.kind) }
        }
    }
}

// MARK: - Elementi grafici

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.accent).frame(width: geo.size.width * max(0.03, min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

struct PillButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PillLabel(title: title, systemImage: systemImage, prominent: prominent)
        }
        .buttonStyle(.plain)
    }
}

struct PillLabel: View {
    let title: String
    let systemImage: String
    var prominent = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(prominent ? Color.black : Color.white)
    }
}

struct ExpandableText: View {
    let text: String
    var lines = 4
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(expanded ? nil : lines)
            .onTapGesture { withAnimation { expanded.toggle() } }
    }
}

/// Il logo ufficiale del titolo; finché non arriva (o se manca) mostra il titolo scritto.
struct TitleLogo: View {
    let logo: URL?
    let title: String
    var maxHeight: CGFloat = 90
    var fontSize: CGFloat = 30

    var body: some View {
        if let logo {
            AsyncImage(url: logo, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 270, maxHeight: maxHeight, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                        .accessibilityLabel(title)
                case .failure: textTitle
                default: Color.clear.frame(width: 200, height: maxHeight * 0.6)
                }
            }
        } else {
            textTitle
        }
    }

    private var textTitle: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .black, design: .serif))
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.5), radius: 6)
    }
}

// MARK: - Copertine e righe

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 116
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        NavigationLink(value: Route.item(item.id)) {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(item: item)
                    .frame(width: width, height: item.kind == .live ? width * 0.75 : width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if item.kind == .movie, let f = store.fraction(item.id) {
                            ProgressBar(value: f).padding(.horizontal, 6).padding(.bottom, 6)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if item.kind == .live {
                            Text("LIVE")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                                .padding(6)
                        }
                    }
                Text(item.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PosterRow: View {
    let title: String
    let items: [MediaItem]
    var seeAll: Route? = nil

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeader(title: title, seeAll: seeAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(items) { PosterCard(item: $0) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

struct RowHeader: View {
    let title: String
    var seeAll: Route? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let seeAll {
                NavigationLink(value: seeAll) {
                    HStack(spacing: 3) {
                        Text("Vedi tutti")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }
}

struct PosterGrid: View {
    let items: [MediaItem]
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { PosterCard(item: $0, width: 106) }
        }
        .padding(.horizontal)
    }
}

// MARK: - Continua a guardare

struct ContinueRow: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var playback: Playback

    var body: some View {
        let entries = store.continueWatching
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeader(title: "Continua a guardare")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(entries) { entry in
                            Button { playback.play(entry.item, episode: entry.episode) } label: { card(entry) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if let ep = entry.episode {
                                        Button { store.setWatched(ep.id, seriesId: entry.item.id, true) } label: {
                                            Label("Segna come visto", systemImage: "checkmark.circle")
                                        }
                                    }
                                    Button(role: .destructive) { store.removeFromContinue(entry) } label: {
                                        Label("Togli dalla fila", systemImage: "xmark.circle")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func card(_ entry: ContinueEntry) -> some View {
        let image = entry.episode?.still ?? entry.item.backdropURL ?? entry.item.posterURL
        return VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: image) { PosterPlaceholder(title: entry.item.displayTitle, kind: entry.item.kind) }
                .frame(width: 228, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 38))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .overlay(alignment: .bottom) {
                    if entry.fraction > 0 { ProgressBar(value: entry.fraction).padding(.horizontal, 8).padding(.bottom, 8) }
                }
            Text(entry.item.displayTitle).font(.caption.weight(.semibold)).lineLimit(1)
            if let ep = entry.episode {
                Text(ep.title.map { "\(ep.code) · \($0)" } ?? ep.code)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 228, alignment: .leading)
    }
}

// MARK: - Avvisi in Home

struct StatusBanner: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.refreshing.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Aggiorno le librerie…").font(.footnote)
                }
            } else if store.enrichTotal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preparo copertine e schede: \(store.enrichDone) di \(store.enrichTotal)").font(.footnote)
                    ProgressView(value: Double(store.enrichDone), total: Double(max(1, store.enrichTotal)))
                        .tint(Theme.accent)
                }
            }
            ForEach(store.libraries.filter { $0.lastError != nil }) { lib in
                Label("«\(lib.name)»: \(lib.lastError ?? "")", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
    }
}
