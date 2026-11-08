import SwiftUI

// MARK: - Immagine remota

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholderIcon = "film"

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            default:
                ZStack {
                    Theme.card
                    Image(systemName: placeholderIcon)
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
    }
}

// MARK: - Riquadro generico

/// Cosa succede toccando un riquadro.
enum CardAction: Hashable {
    case open(Route)
    case playJellyfin(JFItem)
    case playArchive(ArchiveItem)
}

struct Card: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let imageURL: URL?
    var progress: Double? = nil
    var badge: String? = nil
    let action: CardAction
}

extension Card {
    @MainActor
    static func from(_ item: TMDBItem, library: JellyfinLibrary, badge: String? = nil) -> Card {
        Card(id: "t\(item.kind.rawValue)\(item.id)", title: item.displayTitle, subtitle: item.year,
             imageURL: item.posterURL,
             badge: library.match(item.kind, item.id) != nil ? "In libreria" : badge,
             action: .open(.tmdb(item.kind, item.id)))
    }

    @MainActor
    static func from(_ item: JFItem, play: Bool = false) -> Card {
        let subtitle: String?
        if item.isEpisode, let s = item.parentIndexNumber, let e = item.indexNumber {
            subtitle = "S\(s) E\(e) · \(item.name ?? "")"
        } else {
            subtitle = item.productionYear.map(String.init)
        }
        let title = item.isEpisode ? (item.seriesName ?? item.name ?? "") : (item.name ?? "")
        return Card(id: "j\(item.id)", title: title, subtitle: subtitle, imageURL: item.posterURL,
                    progress: item.progress, action: play ? .playJellyfin(item) : .open(.jellyfin(item.id)))
    }

    @MainActor
    static func from(_ item: ArchiveItem, progress: Double? = nil, play: Bool = false) -> Card {
        let m = ClassicMatcher.shared.match(item)
        return Card(id: "a\(item.identifier)", title: m?.title ?? ClassicMatcher.cleanTitle(item.title), subtitle: item.year,
                    imageURL: m?.posterURL ?? item.thumbURL,
                    progress: progress, badge: "Gratis", action: play ? .playArchive(item) : .open(.archive(item)))
    }
}

struct CardView: View {
    let card: Card
    var width: CGFloat = 118
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RemoteImage(url: card.imageURL)
                    .frame(width: width, height: wide ? width * 9 / 16 : width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let p = card.progress, p > 0 {
                            ProgressBar(value: p)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 6)
                        }
                    }
                    .overlay {
                        if isPlayable { playGlyph }
                    }
                if let badge = card.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(badge == "Gratis" ? Theme.gold : Theme.accent, in: Capsule())
                        .foregroundStyle(badge == "Gratis" ? .black : .white)
                        .padding(6)
                }
            }
            Text(card.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if let s = card.subtitle, !s.isEmpty {
                Text(s)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var isPlayable: Bool {
        switch card.action {
        case .open: return false
        case .playJellyfin, .playArchive: return true
        }
    }

    private var playGlyph: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 34))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.45))
    }
}

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

/// Un riquadro che naviga o fa partire il video, a seconda dell'azione.
struct CardLink: View {
    let card: Card
    var width: CGFloat = 118
    var wide = false
    @EnvironmentObject private var playback: Playback

    var body: some View {
        switch card.action {
        case .open(let route):
            NavigationLink(value: route) { CardView(card: card, width: width, wide: wide) }
                .buttonStyle(.plain)
        case .playJellyfin(let item):
            Button { playback.play(item) } label: { CardView(card: card, width: width, wide: wide) }
                .buttonStyle(.plain)
        case .playArchive(let item):
            Button { playback.play(item) } label: { CardView(card: card, width: width, wide: wide) }
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Riga orizzontale

struct CardRow: View {
    let title: String
    let cards: [Card]
    var wide = false
    var seeAll: Route? = nil

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    if let seeAll {
                        NavigationLink(value: seeAll) {
                            Text("Vedi tutti").font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(cards) { card in
                            CardLink(card: card, width: wide ? 220 : 118, wide: wide)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - Griglia

struct CardGrid: View {
    let cards: [Card]

    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 140), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(cards) { card in
                CardLink(card: card, width: 108)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Pulsanti

struct PillButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.14)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct ListToggleButton: View {
    let item: SavedItem
    @EnvironmentObject private var myList: MyList

    var body: some View {
        let saved = myList.contains(item.id)
        PillButton(title: saved ? "Nella lista" : "La mia lista",
                   systemImage: saved ? "checkmark" : "plus") {
            withAnimation(.spring(duration: 0.3)) { myList.toggle(item) }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

/// Testo lungo che si espande al tocco.
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

/// Riquadro che invita a configurare qualcosa.
struct SetupCallout: View {
    let icon: String
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
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

/// Il logo ufficiale del titolo; finché non arriva (o se manca) mostra il titolo scritto.
struct TitleLogo: View {
    let logo: URL?
    let title: String
    var maxHeight: CGFloat = 90
    var fontSize: CGFloat = 28

    var body: some View {
        if let logo {
            AsyncImage(url: logo, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: maxHeight, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                        .accessibilityLabel(title)
                case .failure:
                    textTitle
                default:
                    Color.clear.frame(width: 200, height: maxHeight * 0.6)
                }
            }
        } else {
            textTitle
        }
    }

    private var textTitle: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .black, design: .serif))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }
}
