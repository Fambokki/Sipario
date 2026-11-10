import SwiftUI
import UIKit

struct DetailView: View {
    let id: String

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    @State private var extra: TMDB.Extra?
    @State private var season = 0
    @State private var seasonInfo: [Int: TMDB.SeasonEpisode] = [:]

    var body: some View {
        Group {
            if let item = store.item(id) {
                ScrollView { content(item) }
                    .task(id: item.meta?.tmdbId) { await loadExtra(item) }
            } else {
                ContentUnavailableView("Titolo non più disponibile", systemImage: "film",
                                       description: Text("Potrebbe essere stato rimosso dalla libreria."))
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: Contenuto

    private func content(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(item)
            VStack(alignment: .leading, spacing: 14) {
                playButton(item)
                if item.kind == .movie, let f = store.fraction(item.id) {
                    ProgressBar(value: f)
                }
                secondaryButtons(item)
                if let t = extra?.tagline {
                    Text(t).font(.subheadline.italic()).foregroundStyle(Theme.gold)
                }
                if let o = item.displayOverview ?? extra?.meta.overview {
                    ExpandableText(text: o)
                }
                infoLines(item)
            }
            .padding(.horizontal)

            if item.kind == .series && !item.episodes.isEmpty {
                episodesSection(item)
            }
            if let cast = extra?.cast, !cast.isEmpty {
                castRow(cast)
            }
            PosterRow(title: item.kind == .live ? "Altri canali" : "Titoli simili", items: store.similar(to: item))
        }
        .padding(.bottom, 40)
    }

    private func header(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if item.kind == .live {
                ZStack {
                    Theme.card
                    RemoteImage(url: item.posterURL, contentMode: .fit) { PosterPlaceholder(title: item.displayTitle, kind: .live) }
                        .frame(maxWidth: 220, maxHeight: 140)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            } else if let backdrop = item.backdropURL {
                FillImage(url: backdrop, height: 420)
            } else {
                FillImage(url: item.largePosterURL, height: 420)
                    .blur(radius: 24)
                    .opacity(0.6)
            }
            LinearGradient(colors: [.black.opacity(0.5), .clear, Theme.background.opacity(0.85), Theme.background],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 14) {
                if item.backdropURL == nil && item.kind != .live {
                    PosterImage(item: item, large: true)
                        .frame(width: 110, height: 165)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 14)
                }
                VStack(alignment: .leading, spacing: 8) {
                    TitleLogo(logo: extra?.logo ?? store.logos[item.id], title: item.displayTitle, maxHeight: 96, fontSize: 30)
                    metaLine(item)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
        .frame(height: item.kind == .live ? 300 : 420)
    }

    private func metaLine(_ item: MediaItem) -> some View {
        var parts: [String] = []
        if let y = item.displayYear { parts.append(String(y)) }
        if item.kind == .series && !item.episodes.isEmpty {
            let n = item.seasons.count
            parts.append(n == 1 ? "\(item.episodes.count) episodi" : "\(n) stagioni")
        } else if let r = extra?.runtime, r > 0, item.kind == .movie {
            parts.append(formatMinutes(r))
        }
        if item.kind == .live { parts.append("In diretta") }
        return HStack(spacing: 8) {
            if let v = item.meta?.rating, v > 0 {
                Label(String(format: "%.1f", v), systemImage: "star.fill").foregroundStyle(Theme.gold)
            }
            Text(parts.joined(separator: " · "))
        }
        .font(.caption.weight(.semibold))
    }

    private func playButton(_ item: MediaItem) -> some View {
        if item.lazyStream == StreamingServices.lazyKind {
            return PillButton(title: "Guarda su " + (item.group ?? "il sito"), systemImage: "arrow.up.right.square.fill", prominent: true) { playback.play(item) }
        }
        let title: String
        switch item.kind {
        case .live: title = "Guarda in diretta"
        case .movie: title = store.fraction(item.id) != nil ? "Riprendi" : "Riproduci"
        case .series:
            if let ep = store.resumeEpisode(for: item) {
                title = (store.fraction(ep.id) != nil ? "Riprendi " : "Riproduci ") + ep.code
            } else {
                title = "Riproduci"
            }
        }
        return PillButton(title: title, systemImage: "play.fill", prominent: true) { playback.play(item) }
    }

    private func secondaryButtons(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            PillButton(title: store.inList(item.id) ? "Nella lista" : "La mia lista",
                       systemImage: store.inList(item.id) ? "checkmark" : "plus") {
                withAnimation { store.toggleList(item.id) }
            }
            if let key = extra?.trailerKey, let u = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                PillButton(title: "Trailer", systemImage: "play.rectangle") { openURL(u) }
            }
            if let url = playableURL(item) {
                Menu {
                    openWithButtons(url)
                    if item.meta != nil {
                        Button(role: .destructive) { store.resetMatch(item.id); extra = nil } label: {
                            Label("Scheda sbagliata? Toglila", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 46)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func openWithButtons(_ url: URL) -> some View {
        ForEach(ExternalPlayer.allCases) { p in
            Button {
                if let u = p.link(for: url) { openURL(u) }
            } label: {
                Label("Apri in \(p.name)", systemImage: "arrow.up.forward.app")
            }
        }
        Button { UIPasteboard.general.url = url } label: { Label("Copia il link", systemImage: "doc.on.doc") }
    }

    private func playableURL(_ item: MediaItem) -> URL? {
        if item.kind == .series { return store.resumeEpisode(for: item)?.url }
        return item.url
    }

    private func infoLines(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !item.allGenres.isEmpty {
                (Text("Generi: ").foregroundColor(.secondary) + Text(item.allGenres.joined(separator: ", ")))
                    .font(.caption)
            }
            if let lib = store.library(item.libraryId) {
                (Text("Libreria: ").foregroundColor(.secondary) + Text(lib.name))
                    .font(.caption)
            }
            if let g = item.group, !item.allGenres.contains(g) {
                (Text("Categoria: ").foregroundColor(.secondary) + Text(g))
                    .font(.caption)
            }
        }
    }

    // MARK: Episodi

    private func episodesSection(_ item: MediaItem) -> some View {
        let seasons = item.seasons
        let current = seasons.contains(season) ? season : (store.resumeEpisode(for: item)?.season ?? seasons.first ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodi").font(.title3.bold())
                Spacer()
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons, id: \.self) { s in
                            Button("Stagione \(s)") { season = s }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Stagione \(current)")
                            Image(systemName: "chevron.down")
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
            }
            .padding(.horizontal)

            LazyVStack(spacing: 16) {
                ForEach(item.episodes(in: current)) { ep in
                    episodeRow(item, ep)
                }
            }
            .padding(.horizontal)
        }
        .task(id: "\(current)-\(item.meta?.tmdbId ?? 0)") { await loadSeason(item, current) }
    }

    private func episodeRow(_ item: MediaItem, _ ep: Episode) -> some View {
        let info = seasonInfo[ep.number]
        let still = tmdbImage(info?.stillPath, "w300") ?? ep.still ?? item.backdropURL
        let title = ep.title ?? info?.name ?? "Episodio \(ep.number)"
        let watched = store.isWatched(ep.id)
        return Button { playback.play(item, episode: ep) } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: still) { PosterPlaceholder(title: ep.code, kind: .series) }
                    .frame(width: 132, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        Image(systemName: watched ? "checkmark.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                    .overlay(alignment: .bottom) {
                        if let f = store.fraction(ep.id) { ProgressBar(value: f).padding(6) }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ep.number). \(title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let r = info?.runtime, r > 0 {
                        Text(formatMinutes(r)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let o = info?.overview?.nonEmpty {
                        Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .opacity(watched ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { store.setWatched(ep.id, seriesId: item.id, !watched) } label: {
                Label(watched ? "Segna come da vedere" : "Segna come visto", systemImage: watched ? "eye.slash" : "checkmark.circle")
            }
            openWithButtons(ep.url)
        }
    }

    private func castRow(_ cast: [TMDB.CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: "Cast")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { c in
                        VStack(spacing: 6) {
                            RemoteImage(url: tmdbImage(c.profilePath, "w185")) {
                                ZStack {
                                    Theme.card
                                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 70, height: 70)
                            .clipShape(Circle())
                            Text(c.name).font(.caption2.weight(.semibold)).lineLimit(2)
                            if let ch = c.character?.nonEmpty {
                                Text(ch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 78)
                        .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Caricamento

    private func loadExtra(_ item: MediaItem) async {
        guard settings.hasTMDB, let meta = item.meta else { return }
        if let e = try? await TMDB.details(item.kind, id: meta.tmdbId) {
            extra = e
            store.setLogo(e.logo, for: item.id)
        }
    }

    private func loadSeason(_ item: MediaItem, _ number: Int) async {
        guard settings.hasTMDB, let meta = item.meta else { seasonInfo = [:]; return }
        let eps = (try? await TMDB.season(tvId: meta.tmdbId, number: number)) ?? []
        var map: [Int: TMDB.SeasonEpisode] = [:]
        for e in eps { map[e.episodeNumber] = e }
        seasonInfo = map
    }
}
