import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: JellyfinLibrary
    @EnvironmentObject private var myList: MyList
    @EnvironmentObject private var matcher: ClassicMatcher

    @State private var hero: [TMDBItem] = []
    @State private var heroArt: [Int: HeroArt] = [:]
    @State private var rows: [HomeRow] = []
    @State private var classics: [ArchiveItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showSettings = false
    @State private var showSurprise = false

    struct HomeRow: Identifiable {
        let id: String
        let title: String
        let items: [TMDBItem]
        var seeAll: Route? = nil
        var badge: String? = nil
    }

    private var reloadKey: String {
        "\(settings.cleanTMDBKey)|\(settings.services.map(\.id))|\(settings.hasJellyfin)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !hero.isEmpty {
                    HeroCarousel(items: hero, art: heroArt)
                } else if loading {
                    RoundedRectangle(cornerRadius: 22).fill(Theme.card)
                        .frame(height: 430)
                        .padding(.horizontal)
                        .overlay { ProgressView() }
                }

                if !settings.hasTMDB {
                    SetupCallout(icon: "sparkles.tv", title: "Accendi il catalogo",
                                 message: "Con una chiave gratuita di TMDB vedi tutti i film e le serie del momento e su quale servizio guardarli in Italia. I classici gratuiti funzionano già.",
                                 button: "Configura") { showSettings = true }
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                continueWatching

                CardRow(title: "Aggiunti di recente sul tuo server",
                        cards: library.latest.map { Card.from($0) })

                CardRow(title: "Prossimi episodi",
                        cards: library.nextUp.map { Card.from($0, play: true) }, wide: true)

                freeSitesStrip

                ForEach(rows) { row in
                    CardRow(title: row.title,
                            cards: row.items.map { Card.from($0, library: library, badge: row.badge) },
                            seeAll: row.seeAll)
                }

                CardRow(title: "Classici gratis da guardare subito",
                        cards: classics.map { Card.from($0) })
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("SIPARIO")
                    .font(.system(size: 22, weight: .black, design: .serif))
                    .kerning(3)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.gold], startPoint: .leading, endPoint: .trailing))
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showSurprise = true } label: { Image(systemName: "dice.fill") }
                    .accessibilityLabel("Sorprendimi")
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Impostazioni")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSurprise) { SurpriseView() }
        .task(id: reloadKey) { await load() }
        .refreshable { await load(force: true) }
    }

    // MARK: Siti gratuiti

    private var freeSitesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Siti gratuiti").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FreeSite.all) { site in
                        NavigationLink(value: Route.web(site.url, site.name)) {
                            HStack(spacing: 8) {
                                Image(systemName: site.symbol).font(.subheadline)
                                Text(site.name).font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(LinearGradient(colors: [site.color, site.color.opacity(0.6)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Continua a guardare (Jellyfin + classici)

    @ViewBuilder
    private var continueWatching: some View {
        let jf = library.resume.map { Card.from($0, play: true) }
        let ar = myList.recentArchive.map { Card.from($0.item, progress: $0.fraction, play: true) }
        CardRow(title: "Continua a guardare", cards: jf + ar, wide: true)
    }

    // MARK: Caricamento

    private typealias RowResult = (index: Int, result: Result<[TMDBItem], Error>)

    private struct RowSpec {
        let id: String
        let title: String
        let fetch: () async throws -> [TMDBItem]
        var seeAll: Route? = nil
        var badge: String? = nil
    }

    private func specs(free: [TMDBProvider]) -> [RowSpec] {
        var out: [RowSpec] = []
        out.append(RowSpec(id: "trend", title: "Di tendenza oggi") {
            try await TMDB.list("/trending/all/day")
        })
        // Film e serie da guardare gratis e legalmente sui siti dei servizi gratuiti.
        let freeParams = ["with_watch_monetization_types": "free|ads"]
        if free.count > 1 {
            let ids = free.map(\.providerId)
            out.append(RowSpec(id: "free", title: "Da guardare gratis", fetch: {
                try await TMDB.onServices(ids, extra: freeParams.merging(["vote_count.gte": "30"]) { a, _ in a })
            }, badge: "Gratis"))
        }
        for p in free {
            out.append(RowSpec(id: "free\(p.providerId)", title: "Gratis su \(p.providerName)", fetch: {
                try await TMDB.onServices([p.providerId], extra: freeParams)
            }, seeAll: .discover(title: "Gratis su \(p.providerName)", kind: .movie,
                                 params: ["with_watch_providers": String(p.providerId), "with_watch_monetization_types": "free|ads"]),
               badge: "Gratis"))
        }
        if settings.services.count > 1 {
            let ids = settings.services.map(\.id)
            out.append(RowSpec(id: "mine", title: "Nei tuoi abbonamenti") {
                try await TMDB.onServices(ids, extra: ["vote_count.gte": "50"])
            })
        }
        for p in settings.services {
            out.append(RowSpec(id: "svc\(p.id)", title: "Popolari su \(p.name)", fetch: {
                try await TMDB.onServices([p.id])
            }, seeAll: .discover(title: "Film su \(p.name)", kind: .movie,
                                 params: ["with_watch_providers": String(p.id), "with_watch_monetization_types": "flatrate|free|ads"])))
        }
        out.append(RowSpec(id: "popIT", title: "I film più visti in Italia", fetch: {
            try await TMDB.list("/movie/popular", ["region": "IT"], kind: .movie)
        }, seeAll: .discover(title: "Film popolari", kind: .movie, params: [:])))
        out.append(RowSpec(id: "tvweek", title: "Serie TV della settimana", fetch: {
            try await TMDB.list("/trending/tv/week", kind: .tv)
        }, seeAll: .discover(title: "Serie TV popolari", kind: .tv, params: [:])))
        out.append(RowSpec(id: "cinema", title: "Ora al cinema") {
            try await TMDB.list("/movie/now_playing", ["region": "IT"], kind: .movie)
        })
        out.append(RowSpec(id: "top", title: "I più amati di sempre", fetch: {
            try await TMDB.list("/movie/top_rated", kind: .movie)
        }, seeAll: .discover(title: "I più amati", kind: .movie,
                             params: ["sort_by": "vote_average.desc", "vote_count.gte": "3000"])))
        out.append(RowSpec(id: "tvtop", title: "Serie da non perdere") {
            try await TMDB.list("/tv/top_rated", kind: .tv)
        })
        out.append(RowSpec(id: "soon", title: "Prossimamente") {
            try await TMDB.list("/movie/upcoming", ["region": "IT"], kind: .movie)
        })
        return out
    }

    private func load(force: Bool = false) async {
        loading = true
        defer { loading = false }

        async let classicsTask = Archive.search(Archive.categories[0].query, rows: 20)
        await library.refresh(force: force)

        if settings.hasTMDB {
            let list = specs(free: await TMDB.freeProviders())
            var results: [Int: [TMDBItem]] = [:]
            var firstError: Error?
            await withTaskGroup(of: RowResult.self) { group in
                for (i, spec) in list.enumerated() {
                    group.addTask {
                        do { return (i, .success(try await spec.fetch())) }
                        catch { return (i, .failure(error)) }
                    }
                }
                for await (i, r) in group {
                    switch r {
                    case .success(let items): results[i] = items
                    case .failure(let e): if firstError == nil { firstError = e }
                    }
                }
            }
            var built: [HomeRow] = []
            for (i, spec) in list.enumerated() {
                guard let items = results[i], !items.isEmpty else { continue }
                built.append(HomeRow(id: spec.id, title: spec.title, items: items, seeAll: spec.seeAll, badge: spec.badge))
            }
            rows = built
            if let trend = results[0] {
                hero = Array(trend.filter { $0.backdropPath != nil }.prefix(7))
                await loadHeroArt()
            }
            errorText = built.isEmpty ? firstError?.localizedDescription : nil
        } else {
            rows = []
            hero = []
            errorText = nil
        }
        classics = (try? await classicsTask) ?? classics
        await matcher.resolve(classics + myList.recentArchive.map(\.item))
    }
}

// MARK: - Carosello in alto

/// Logo ufficiale e sfondo senza scritte di un titolo in evidenza.
struct HeroArt: Hashable {
    let logo: URL?
    let backdrop: URL?
}

extension HomeView {
    fileprivate func loadHeroArt() async {
        let items = hero
        var out: [Int: HeroArt] = [:]
        await withTaskGroup(of: (Int, HeroArt?).self) { group in
            for item in items {
                group.addTask {
                    guard let img = try? await TMDB.images(item.kind, id: item.id) else { return (item.id, nil) }
                    let backdrop = TMDB.image(img.cleanBackdropPath, size: "w1280")
                    return (item.id, HeroArt(logo: img.logoURL, backdrop: backdrop))
                }
            }
            for await (id, art) in group {
                if let art { out[id] = art }
            }
        }
        heroArt = out
    }
}

struct HeroCarousel: View {
    let items: [TMDBItem]
    var art: [Int: HeroArt] = [:]
    @State private var index = 0
    @EnvironmentObject private var library: JellyfinLibrary
    @EnvironmentObject private var playback: Playback

    private let timer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                slide(item).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 450)
        .onReceive(timer) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
        }
    }

    private func slide(_ item: TMDBItem) -> some View {
        let owned = library.match(item.kind, item.id)
        return ZStack(alignment: .bottomLeading) {
            NavigationLink(value: Route.tmdb(item.kind, item.id)) {
                GeometryReader { geo in
                    RemoteImage(url: art[item.id]?.backdrop ?? item.backdropURL)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay {
                            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.95)],
                                           startPoint: .center, endPoint: .bottom)
                        }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(item.kind == .movie ? "FILM" : "SERIE")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                    if let y = item.year { Text(y).font(.caption.weight(.semibold)) }
                    if let v = item.voteAverage, v > 0 {
                        Label(String(format: "%.1f", v), systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.gold)
                    }
                    if owned != nil {
                        Text("· Nel tuo server").font(.caption.weight(.semibold)).foregroundStyle(Theme.gold)
                    }
                }
                TitleLogo(logo: art[item.id]?.logo, title: item.displayTitle, maxHeight: 96, fontSize: 30)
                if let o = item.overview, !o.isEmpty {
                    Text(o).font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let owned {
                        PillButton(title: "Riproduci", systemImage: "play.fill", prominent: true) {
                            playback.play(jellyfinId: owned.id)
                        }
                    }
                    NavigationLink(value: Route.tmdb(item.kind, item.id)) {
                        Label(owned == nil ? "Dove vederlo" : "Dettagli", systemImage: owned == nil ? "play.tv" : "info.circle")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(owned == nil ? Color.white : Color.white.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(owned == nil ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                    ListToggleButton(item: .tmdb(item.kind, id: item.id, title: item.displayTitle, poster: item.posterURL))
                }
            }
            .padding(18)
            .padding(.bottom, 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal)
    }
}
