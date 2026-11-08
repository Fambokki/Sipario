import SwiftUI

struct TMDBDetailView: View {
    let kind: MediaKind
    let id: Int

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: JellyfinLibrary
    @EnvironmentObject private var playback: Playback
    @Environment(\.openURL) private var openURL

    @State private var detail: TMDBDetail?
    @State private var errorText: String?
    @State private var season: Int = 1
    @State private var episodes: [TMDBEpisode] = []
    @State private var loadingEpisodes = false
    /// Episodi presenti sul server Jellyfin, indicizzati per "stagione-episodio".
    @State private var ownedEpisodes: [String: JFItem] = [:]

    private var owned: JFItem? { library.match(kind, id) }

    var body: some View {
        ScrollView {
            if let d = detail {
                content(d)
            } else if let errorText {
                ContentUnavailableView("Non riesco a caricare la scheda", systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
                    .padding(.top, 80)
            } else {
                ProgressView().padding(.top, 160)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    // MARK: Contenuto

    @ViewBuilder
    private func content(_ d: TMDBDetail) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(d)

            VStack(alignment: .leading, spacing: 14) {
                actions(d)
                if let t = d.tagline, !t.isEmpty {
                    Text(t).font(.subheadline.italic()).foregroundStyle(Theme.gold)
                }
                if let o = d.overview, !o.isEmpty {
                    ExpandableText(text: o)
                }
            }
            .padding(.horizontal)

            WhereToWatch(country: d.watchProviders?.results[settings.region], title: d.displayTitle,
                         owned: owned != nil, mine: settings.serviceIds)

            if kind == .tv, let seasons = d.seasons?.filter({ $0.seasonNumber > 0 }), !seasons.isEmpty {
                seasonSection(seasons)
            }

            if let cast = d.credits?.cast, !cast.isEmpty {
                castRow(Array(cast.prefix(15)))
            }

            if let recs = d.recommendations?.results, !recs.isEmpty {
                CardRow(title: "Potrebbe piacerti anche",
                        cards: recs.map { item -> Card in
                            var copy = item
                            if copy.mediaType == nil { copy.kindOverride = kind }
                            return Card.from(copy, library: library)
                        })
            }

            Text("Dati e disponibilità da TMDB e JustWatch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 30)
        }
    }

    private func header(_ d: TMDBDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            FillImage(url: d.backdropURL ?? d.posterURL, height: 330)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.4), .clear, Theme.background.opacity(0.85), Theme.background],
                                   startPoint: .top, endPoint: .bottom)
                }
            HStack(alignment: .bottom, spacing: 14) {
                RemoteImage(url: d.posterURL)
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.displayTitle)
                        .font(.system(size: 26, weight: .black, design: .serif))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    metaLine(d)
                }
            }
            .padding(.horizontal)
        }
    }

    private func metaLine(_ d: TMDBDetail) -> some View {
        var parts: [String] = []
        if let y = d.year { parts.append(y) }
        if let m = d.minutes, m > 0 { parts.append(formatMinutes(m)) }
        if kind == .tv, let n = d.numberOfSeasons { parts.append(n == 1 ? "1 stagione" : "\(n) stagioni") }
        let genres = (d.genres ?? []).prefix(3).map(\.name).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let v = d.voteAverage, v > 0 {
                    Label(String(format: "%.1f", v), systemImage: "star.fill")
                        .foregroundStyle(Theme.gold)
                }
                Text(parts.joined(separator: " · "))
            }
            .font(.caption.weight(.semibold))
            if !genres.isEmpty {
                Text(genres).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ d: TMDBDetail) -> some View {
        VStack(spacing: 10) {
            if let owned {
                if kind == .movie {
                    PillButton(title: (owned.progress ?? 0) > 0 ? "Riprendi dal tuo server" : "Riproduci dal tuo server",
                               systemImage: "play.fill", prominent: true) {
                        playback.play(jellyfinId: owned.id)
                    }
                } else {
                    NavigationLink(value: Route.jellyfin(owned.id)) {
                        Label("Apri la serie sul tuo server", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                if let t = d.trailer {
                    PillButton(title: "Trailer", systemImage: "play.rectangle") {
                        if let u = URL(string: "https://www.youtube.com/watch?v=\(t.key)") { openURL(u) }
                    }
                }
                ListToggleButton(item: .tmdb(kind, id: id, title: d.displayTitle, poster: d.posterURL))
                if let u = URL(string: "https://www.themoviedb.org/\(kind.rawValue)/\(id)") {
                    ShareLink(item: u) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 46)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Stagioni ed episodi

    private func seasonSection(_ seasons: [TMDBSeasonSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodi").font(.title3.bold())
                Spacer()
                Menu {
                    ForEach(seasons) { s in
                        Button(s.name ?? "Stagione \(s.seasonNumber)") { season = s.seasonNumber }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(seasons.first { $0.seasonNumber == season }?.name ?? "Stagione \(season)")
                        Image(systemName: "chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal)

            if loadingEpisodes {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            LazyVStack(spacing: 14) {
                ForEach(episodes) { ep in
                    episodeRow(ep)
                }
            }
            .padding(.horizontal)
        }
        .task(id: season) { await loadSeason() }
    }

    private func episodeRow(_ ep: TMDBEpisode) -> some View {
        let mine = ownedEpisodes["\(ep.seasonNumber)-\(ep.episodeNumber)"]
        return Button {
            if let mine { playback.play(mine) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: ep.stillURL)
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if mine != nil {
                            Image(systemName: "play.circle.fill").font(.title)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.4))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let p = mine?.progress { ProgressBar(value: p).padding(5) }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ep.episodeNumber). \(ep.name ?? "Episodio \(ep.episodeNumber)")")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let r = ep.runtime, r > 0 { Text(formatMinutes(r)) }
                        if mine != nil { Text("· Sul tuo server").foregroundStyle(Theme.gold) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let o = ep.overview, !o.isEmpty {
                        Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .disabled(mine == nil)
    }

    private func castRow(_ cast: [TMDBCast]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Cast")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { c in
                        VStack(spacing: 6) {
                            RemoteImage(url: TMDB.image(c.profilePath, size: "w185"), placeholderIcon: "person.fill")
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                            Text(c.name).font(.caption2.weight(.semibold)).lineLimit(2)
                            if let ch = c.character, !ch.isEmpty {
                                Text(ch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 80)
                        .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Caricamento

    private func load() async {
        do {
            let d = try await TMDB.detail(kind, id: id)
            detail = d
            if kind == .tv, let first = d.seasons?.first(where: { $0.seasonNumber > 0 }) {
                if season == 1 && first.seasonNumber != 1 { season = first.seasonNumber }
            }
        } catch {
            errorText = error.localizedDescription
        }
        if kind == .tv, let owned {
            if let eps = try? await Jellyfin.episodes(seriesId: owned.id) {
                var map: [String: JFItem] = [:]
                for e in eps {
                    if let s = e.parentIndexNumber, let n = e.indexNumber { map["\(s)-\(n)"] = e }
                }
                ownedEpisodes = map
            }
        }
    }

    private func loadSeason() async {
        guard kind == .tv else { return }
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        episodes = (try? await TMDB.season(tvId: id, number: season).episodes) ?? []
    }
}

// MARK: - Dove guardarlo

struct WhereToWatch: View {
    let country: TMDBCountryProviders?
    let title: String
    let owned: Bool
    let mine: Set<Int>
    @Environment(\.openURL) private var openURL

    private struct ProviderGroup: Identifiable {
        let id: String
        let providers: [TMDBProvider]
    }

    private var groups: [ProviderGroup] {
        guard let c = country else { return [] }
        var out: [ProviderGroup] = []
        if let f = c.flatrate, !f.isEmpty { out.append(ProviderGroup(id: "In abbonamento", providers: f)) }
        var free: [TMDBProvider] = []
        for p in (c.free ?? []) + (c.ads ?? []) where !free.contains(where: { $0.providerId == p.providerId }) {
            free.append(p)
        }
        if !free.isEmpty { out.append(ProviderGroup(id: "Gratis", providers: free)) }
        if let r = c.rent, !r.isEmpty { out.append(ProviderGroup(id: "Noleggio", providers: r)) }
        if let b = c.buy, !b.isEmpty { out.append(ProviderGroup(id: "Acquisto", providers: b)) }
        return out
    }

    private var includedInMine: TMDBProvider? {
        let pool = (country?.flatrate ?? []) + (country?.free ?? []) + (country?.ads ?? [])
        return pool.first { mine.contains($0.providerId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Dove guardarlo in Italia")

            if let p = includedInMine {
                Button {
                    if let u = ProviderLinks.url(for: p, title: title, fallback: country?.link) { openURL(u) }
                } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: p.logoURL)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Incluso nel tuo abbonamento").font(.caption).foregroundStyle(.black.opacity(0.65))
                            Text("Guarda su \(p.providerName)").font(.headline).foregroundStyle(.black)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.black)
                    }
                    .padding(12)
                    .background(LinearGradient(colors: [Theme.gold, Color(red: 1, green: 0.88, blue: 0.6)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }

            if groups.isEmpty {
                Text(owned ? "Non è in streaming in Italia, ma ce l'hai sul tuo server."
                           : "Al momento non risulta disponibile in streaming in Italia.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.id).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                        .padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(group.providers) { p in
                                Button {
                                    if let u = ProviderLinks.url(for: p, title: title, fallback: country?.link) { openURL(u) }
                                } label: {
                                    VStack(spacing: 5) {
                                        RemoteImage(url: p.logoURL)
                                            .frame(width: 54, height: 54)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            .overlay {
                                                if mine.contains(p.providerId) {
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .stroke(Theme.gold, lineWidth: 2.5)
                                                }
                                            }
                                        Text(p.providerName)
                                            .font(.system(size: 10))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(width: 64)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
    }
}
