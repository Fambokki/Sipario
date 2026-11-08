import SwiftUI

// MARK: - Classici gratuiti

struct ClassicsView: View {
    @EnvironmentObject private var myList: MyList
    @EnvironmentObject private var matcher: ClassicMatcher
    @State private var rows: [String: [ArchiveItem]] = [:]
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Il grande cinema, gratis")
                        .font(.system(size: 26, weight: .black, design: .serif))
                    Text("Film e cartoni di pubblico dominio dall'Internet Archive: si guardano qui dentro, senza abbonamento e in modo legale.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                CardRow(title: "Continua a guardare",
                        cards: myList.recentArchive.map { Card.from($0.item, progress: $0.fraction, play: true) },
                        wide: true)

                if loading && rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(Archive.categories) { cat in
                    CardRow(title: cat.title, cards: (rows[cat.id] ?? []).map { Card.from($0) })
                }
            }
            .padding(.vertical)
        }
        .background(Theme.background)
        .task { if rows.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (String, [ArchiveItem]).self) { group in
            for cat in Archive.categories {
                group.addTask { (cat.id, (try? await Archive.search(cat.query, rows: 24)) ?? []) }
            }
            for await (id, items) in group {
                rows[id] = items
            }
        }
        // Le locandine arrivano riga per riga, partendo dalle prime.
        for cat in Archive.categories {
            await matcher.resolve(rows[cat.id] ?? [])
        }
    }
}

struct ArchiveDetailView: View {
    let item: ArchiveItem
    @EnvironmentObject private var myList: MyList
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var matcher: ClassicMatcher
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let progress = myList.archiveProgress[item.identifier]
        let m = matcher.match(item)
        let title = m?.title ?? ClassicMatcher.cleanTitle(item.title)
        let text = (m?.overview).flatMap { $0.isEmpty ? nil : $0 } ?? item.cleanDescription
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    if let backdrop = m?.backdropURL {
                        FillImage(url: backdrop, height: 320)
                    } else {
                        FillImage(url: m?.posterURL ?? item.thumbURL, height: 320)
                            .blur(radius: 30)
                            .opacity(0.5)
                    }
                    LinearGradient(colors: [.black.opacity(0.35), .clear, Theme.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 320)
                    HStack(alignment: .bottom, spacing: 14) {
                        RemoteImage(url: m?.posterURL ?? item.thumbURL, contentMode: m == nil ? .fit : .fill)
                            .frame(width: 110, height: 165)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(radius: 14)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("GRATIS · PUBBLICO DOMINIO")
                                    .font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.black)
                                if let y = item.year { Text(y).font(.caption.weight(.semibold)) }
                            }
                            Text(title)
                                .font(.system(size: 26, weight: .black, design: .serif))
                                .lineLimit(3)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 320)

                VStack(alignment: .leading, spacing: 12) {
                    PillButton(title: progress != nil ? "Riprendi" : "Guarda ora", systemImage: "play.fill", prominent: true) {
                        playback.play(item)
                    }
                    if let p = progress { ProgressBar(value: p.fraction) }
                    HStack(spacing: 10) {
                        ListToggleButton(item: SavedItem(source: .archive, key: item.identifier, title: title,
                                                         imageURL: m?.posterURL ?? item.thumbURL, archive: item))
                        if let m, settings.hasTMDB {
                            NavigationLink(value: Route.tmdb(.movie, m.tmdbId)) {
                                Label("Scheda", systemImage: "info.circle")
                                    .font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else if let u = item.pageURL {
                            Link(destination: u) {
                                Label("archive.org", systemImage: "safari")
                                    .font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !text.isEmpty {
                        ExpandableText(text: text, lines: 8)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await matcher.resolve([item]) }
    }
}

// MARK: - Ricerca

struct SearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: JellyfinLibrary
    @EnvironmentObject private var matcher: ClassicMatcher

    @State private var query = ""
    @State private var tmdb: [TMDBItem] = []
    @State private var mine: [JFItem] = []
    @State private var classics: [ArchiveItem] = []
    @State private var searching = false
    @State private var genres: [TMDBGenre] = []
    @State private var genreKind: MediaKind = .movie

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                browse
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if searching { ProgressView().frame(maxWidth: .infinity).padding(.top, 20) }
                    CardRow(title: "Sul tuo server", cards: mine.map { Card.from($0) })
                    CardRow(title: "Film e serie", cards: tmdb.map { Card.from($0, library: library) })
                    CardRow(title: "Classici gratuiti", cards: classics.map { Card.from($0) })
                    if !searching && tmdb.isEmpty && mine.isEmpty && classics.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .padding(.vertical)
            }
        }
        .background(Theme.background)
        .navigationTitle("Cerca")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Film, serie, attori…")
        .task(id: query) { await search() }
        .task(id: "\(genreKind.rawValue)\(settings.hasTMDB)") {
            genres = (try? await TMDB.genres(genreKind)) ?? []
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 14) {
            if settings.hasTMDB {
                HStack {
                    Text("Esplora per genere").font(.title3.bold())
                    Spacer()
                    Picker("Tipo", selection: $genreKind) {
                        Text("Film").tag(MediaKind.movie)
                        Text("Serie").tag(MediaKind.tv)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(genres.enumerated()), id: \.element.id) { i, g in
                        NavigationLink(value: Route.discover(title: g.name, kind: genreKind, params: ["with_genres": String(g.id)])) {
                            Text(g.name)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(
                                    LinearGradient(colors: [palette[i % palette.count], palette[i % palette.count].opacity(0.55)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            } else {
                Text("Cerca nei classici gratuiti e sul tuo server. Aggiungi la chiave TMDB nelle Impostazioni per cercare in tutto il catalogo.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .padding(.vertical)
    }

    private var palette: [Color] {
        [Color(red: 0.75, green: 0.16, blue: 0.24), Color(red: 0.20, green: 0.32, blue: 0.70),
         Color(red: 0.55, green: 0.25, blue: 0.70), Color(red: 0.10, green: 0.50, blue: 0.45),
         Color(red: 0.80, green: 0.45, blue: 0.12), Color(red: 0.30, green: 0.30, blue: 0.36)]
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { tmdb = []; mine = []; classics = []; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let useTMDB = settings.hasTMDB
        let useJF = settings.hasJellyfin
        async let t: [TMDBItem] = useTMDB ? ((try? await TMDB.search(q)) ?? []) : []
        async let j: [JFItem] = useJF ? ((try? await Jellyfin.items(types: "Movie,Series", search: q, limit: 20)) ?? []) : []
        async let a: [ArchiveItem] = (try? await Archive.searchTitle(q)) ?? []
        let (tr, jr, ar) = await (t, j, a)
        guard !Task.isCancelled else { return }
        tmdb = tr
        mine = jr
        classics = ar
        await matcher.resolve(ar)
    }
}

// MARK: - Elenco per genere / servizio

struct DiscoverGridView: View {
    let title: String
    let kind: MediaKind
    let params: [String: String]

    @EnvironmentObject private var library: JellyfinLibrary
    @State private var items: [TMDBItem] = []
    @State private var page = 1
    @State private var canLoadMore = true
    @State private var loading = false

    var body: some View {
        ScrollView {
            CardGrid(cards: items.map { Card.from($0, library: library) })
                .padding(.vertical)
            if canLoadMore && !items.isEmpty {
                ProgressView()
                    .padding()
                    .onAppear { Task { await loadMore() } }
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .task { if items.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, canLoadMore else { return }
        loading = true
        defer { loading = false }
        var p = params
        p["page"] = String(page)
        if kind == .movie, p["sort_by"] == nil { p["sort_by"] = "popularity.desc" }
        let more = (try? await TMDB.discover(kind, p)) ?? []
        let known = Set(items.map(\.id))
        items.append(contentsOf: more.filter { !known.contains($0.id) })
        page += 1
        canLoadMore = !more.isEmpty && page <= 20
    }
}

// MARK: - La mia lista

struct MyListView: View {
    @EnvironmentObject private var myList: MyList

    var body: some View {
        ScrollView {
            if myList.items.isEmpty {
                ContentUnavailableView("La tua lista è vuota", systemImage: "bookmark",
                                       description: Text("Tocca \"La mia lista\" su un film o una serie per ritrovarlo qui."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 140), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(myList.items) { saved in
                        if let route = saved.route {
                            NavigationLink(value: route) {
                                CardView(card: Card(id: saved.id, title: saved.title, imageURL: saved.imageURL,
                                                    badge: saved.source == .archive ? "Gratis" : nil,
                                                    action: .open(route)), width: 108)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { myList.remove(saved) } label: {
                                    Label("Togli dalla lista", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(Theme.background)
        .navigationTitle("La mia lista")
    }
}
