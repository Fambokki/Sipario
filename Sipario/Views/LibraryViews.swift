import SwiftUI

// MARK: - Libreria Jellyfin

struct LibraryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: JellyfinLibrary

    enum LibSection: String, CaseIterable { case movies = "Film", series = "Serie" }
    enum Sort: String, CaseIterable {
        case recent = "Aggiunti di recente", title = "Titolo", year = "Anno", rating = "Voto", random = "Casuale"
        var key: String {
            switch self {
            case .recent: return "DateCreated"
            case .title: return "SortName"
            case .year: return "ProductionYear,SortName"
            case .rating: return "CommunityRating"
            case .random: return "Random"
            }
        }
        var descending: Bool { self == .recent || self == .year || self == .rating }
    }

    @State private var section: LibSection = .movies
    @State private var sort: Sort = .recent
    @State private var unwatchedOnly = false
    @State private var items: [JFItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showSettings = false

    var body: some View {
        Group {
            if settings.hasJellyfin {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        CardRow(title: "Continua a guardare",
                                cards: library.resume.map { Card.from($0, play: true) }, wide: true)
                        Picker("Sezione", selection: $section) {
                            ForEach(LibSection.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        if let errorText {
                            Text(errorText).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                        }
                        if loading && items.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else if items.isEmpty {
                            Text("Niente da mostrare qui.").foregroundStyle(.secondary).padding(.horizontal)
                        }
                        CardGrid(cards: items.map { Card.from($0) })
                    }
                    .padding(.vertical)
                }
                .refreshable {
                    await library.refresh(force: true)
                    await load()
                }
                .task(id: "\(section.rawValue)\(sort.rawValue)\(unwatchedOnly)") { await load() }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 54))
                            .foregroundStyle(Theme.gold)
                            .padding(.top, 60)
                        Text("La tua videoteca personale").font(.title2.bold())
                        Text("Collega il tuo server Jellyfin, Emby o Plex: i tuoi film e le tue serie compariranno qui e nella Home, con copertine, \"Continua a guardare\" e Picture in Picture.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 28)
                        Button("Collega il server") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                        Link("Non hai un server? Jellyfin è gratuito", destination: URL(string: "https://jellyfin.org/downloads/")!)
                            .font(.footnote)
                    }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Libreria")
        .toolbar {
            if settings.hasJellyfin {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Ordina", selection: $sort) {
                            ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        Toggle("Solo da vedere", isOn: $unwatchedOnly)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await Jellyfin.items(types: section == .movies ? "Movie" : "Series",
                                             sortBy: sort.key, descending: sort.descending,
                                             filters: unwatchedOnly ? "IsUnplayed" : nil)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Scheda di un elemento Jellyfin

struct JellyfinDetailView: View {
    let id: String

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: Playback

    @State private var item: JFItem?
    @State private var seasons: [JFItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [JFItem] = []
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            if let item {
                content(item)
            } else if let errorText {
                ContentUnavailableView("Non riesco a caricare", systemImage: "exclamationmark.triangle",
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

    @ViewBuilder
    private func content(_ item: JFItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                FillImage(url: item.backdropURL ?? item.posterURL, height: 300)
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.4), .clear, Theme.background], startPoint: .top, endPoint: .bottom)
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.isEpisode ? (item.seriesName ?? "") : "")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.gold)
                    Text(item.name ?? "")
                        .font(.system(size: 28, weight: .black, design: .serif))
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        if let y = item.productionYear { Text(String(y)) }
                        if let m = item.minutes, m > 0, !item.isSeries { Text(formatMinutes(m)) }
                        if let r = item.officialRating { Text(r).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary)) }
                        if let c = item.communityRating, c > 0 {
                            Label(String(format: "%.1f", c), systemImage: "star.fill").foregroundStyle(Theme.gold)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal)
            }

            VStack(alignment: .leading, spacing: 12) {
                if item.isPlayable {
                    PillButton(title: (item.progress ?? 0) > 0 ? "Riprendi" : "Riproduci", systemImage: "play.fill", prominent: true) {
                        playback.play(item)
                    }
                    if let p = item.progress, p > 0 { ProgressBar(value: p) }
                } else if item.isSeries, let next = nextEpisode {
                    PillButton(title: "Riproduci S\(next.parentIndexNumber ?? 1) E\(next.indexNumber ?? 1)", systemImage: "play.fill", prominent: true) {
                        playback.play(next)
                    }
                }
                HStack(spacing: 10) {
                    ListToggleButton(item: SavedItem(source: .jellyfin, key: item.id, title: item.name ?? "", imageURL: item.posterURL))
                    if settings.hasTMDB, let t = item.tmdbId, !item.isEpisode {
                        NavigationLink(value: Route.tmdb(item.isSeries ? .tv : .movie, t)) {
                            Label("Scheda completa", systemImage: "info.circle")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let o = item.overview, !o.isEmpty { ExpandableText(text: o) }
            }
            .padding(.horizontal)

            if item.isSeries && !seasons.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons) { s in
                                Button(s.name ?? "Stagione") { selectedSeason = s.id }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(selectedSeason == s.id ? Color.white : Color.white.opacity(0.12), in: Capsule())
                                    .foregroundStyle(selectedSeason == s.id ? Color.black : Color.white)
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    LazyVStack(spacing: 14) {
                        ForEach(episodes) { ep in
                            Button { playback.play(ep) } label: { episodeRow(ep) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .task(id: selectedSeason) { await loadEpisodes(item) }
            }
        }
        .padding(.bottom, 30)
    }

    private var nextEpisode: JFItem? {
        episodes.first { ($0.progress ?? 0) > 0 } ?? episodes.first { $0.userData?.played != true } ?? episodes.first
    }

    private func episodeRow(_ ep: JFItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: ep.thumbURL)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    Image(systemName: ep.userData?.played == true ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
                .overlay(alignment: .bottom) {
                    if let p = ep.progress { ProgressBar(value: p).padding(5) }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ep.indexNumber ?? 0). \(ep.name ?? "")").font(.subheadline.weight(.semibold)).lineLimit(2)
                if let m = ep.minutes, m > 0 { Text(formatMinutes(m)).font(.caption).foregroundStyle(.secondary) }
                if let o = ep.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            let i = try await Jellyfin.item(id)
            item = i
            if i.isSeries {
                seasons = (try? await Jellyfin.seasons(seriesId: i.id)) ?? []
                let current = seasons.first { ($0.userData?.unplayedItemCount ?? 0) > 0 } ?? seasons.first
                selectedSeason = current?.id
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadEpisodes(_ series: JFItem) async {
        guard let selectedSeason else { return }
        episodes = (try? await Jellyfin.episodes(seriesId: series.id, seasonId: selectedSeason)) ?? []
    }
}
