import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var showSettings = false
    @State private var showAdd = false
    @State private var showFormats = false
    @State private var heroIDs: [String] = []

    var body: some View {
        Group {
            if store.libraries.isEmpty {
                WelcomeView(onAdd: { showAdd = true }, onFormats: { showFormats = true })
            } else {
                content
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Brand() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !store.libraries.isEmpty {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Aggiungi libreria")
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Impostazioni")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAdd) { LibraryEditorView(library: nil) }
        .sheet(isPresented: $showFormats) { NavigationStack { FormatsHelpView() } }
    }

    private var heroKey: String { "\(store.items.count)|\(min(store.catalog.backdropCount, 6))" }

    private var content: some View {
        let c = store.catalog
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !heroIDs.isEmpty {
                    HeroCarousel(ids: heroIDs)
                }
                StatusBanner()
                ContinueRow()
                PosterRow(title: "La mia lista", items: store.myList.compactMap { store.item($0) })
                PosterRow(title: "Aggiunti di recente", items: Array(c.recent.prefix(20)),
                          seeAll: .collection("Aggiunti di recente", .recent))
                PosterRow(title: "Film", items: Array(c.movies.prefix(20)), seeAll: .collection("Film", .kind(.movie)))
                PosterRow(title: "Serie TV", items: Array(c.series.prefix(20)), seeAll: .collection("Serie TV", .kind(.series)))
                PosterRow(title: "In diretta", items: Array(c.live.prefix(30)), seeAll: .collection("In diretta", .kind(.live)))
                ForEach(Array(c.categories.prefix(10)), id: \.self) { cat in
                    PosterRow(title: cat, items: c.byCategory[cat] ?? [], seeAll: .collection(cat, .genre(cat)))
                }
                if store.libraries.count > 1 {
                    ForEach(store.libraries) { lib in
                        PosterRow(title: "Da «\(lib.name)»",
                                  items: Array(store.collection(.library(lib.id)).prefix(20)),
                                  seeAll: .collection(lib.name, .library(lib.id)))
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .refreshable { await store.refreshAll() }
        .task(id: heroKey) { pickHero() }
    }

    private func pickHero() {
        let pool = (store.catalog.movies + store.catalog.series)
        let withBackdrop = pool.filter { $0.backdropURL != nil }
        let source = withBackdrop.count >= 3 ? withBackdrop : pool
        heroIDs = Array(source.shuffled().prefix(6).map(\.id))
    }
}

struct Brand: View {
    var body: some View {
        Text("SIPARIO")
            .font(.system(size: 22, weight: .black, design: .serif))
            .kerning(3)
            .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.gold], startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Carosello in alto

struct HeroCarousel: View {
    let ids: [String]
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var playback: Playback
    @State private var index = 0

    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        let items = ids.compactMap { store.item($0) }
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                slide(item).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 560)
        .onReceive(timer) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
        }
        .task(id: ids) {
            for id in ids { await store.loadLogo(id) }
        }
    }

    private func slide(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottom) {
            NavigationLink(value: Route.item(item.id)) {
                GeometryReader { geo in
                    RemoteImage(url: item.backdropURL ?? item.largePosterURL) { PosterPlaceholder(title: item.displayTitle, kind: item.kind) }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay {
                            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, Theme.background.opacity(0.9), Theme.background],
                                           startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 12) {
                TitleLogo(logo: store.logos[item.id], title: item.displayTitle, maxHeight: 110, fontSize: 34)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text(subtitle(item))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    PillButton(title: playTitle(item), systemImage: "play.fill", prominent: true) {
                        playback.play(item)
                    }
                    PillButton(title: store.inList(item.id) ? "Nella lista" : "La mia lista",
                               systemImage: store.inList(item.id) ? "checkmark" : "plus") {
                        withAnimation { store.toggleList(item.id) }
                    }
                }
                .padding(.horizontal, 30)
            }
            .padding(.bottom, 40)
        }
    }

    private func subtitle(_ item: MediaItem) -> String {
        var parts: [String] = [item.kind.label]
        parts += item.allGenres.prefix(2)
        if let y = item.displayYear { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    private func playTitle(_ item: MediaItem) -> String {
        if item.kind == .series, let ep = store.resumeEpisode(for: item) {
            return (store.fraction(ep.id) != nil ? "Riprendi " : "Riproduci ") + ep.code
        }
        return store.fraction(item.id) != nil ? "Riprendi" : "Riproduci"
    }
}

// MARK: - Primo avvio

struct WelcomeView: View {
    let onAdd: () -> Void
    let onFormats: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "theatermasks.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.gold], startPoint: .top, endPoint: .bottom))
                    .padding(.top, 70)
                Text("Il tuo cinema personale")
                    .font(.system(size: 30, weight: .black, design: .serif))
                    .multilineTextAlignment(.center)
                Text("Incolla il link di una tua libreria di film e serie: Sipario la trasforma in un catalogo come quello di Netflix, con copertine, stagioni, episodi e \"Continua a guardare\".")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 30)
                VStack(alignment: .leading, spacing: 12) {
                    feature("list.and.film", "Playlist M3U", "Con categorie, copertine ed episodi riconosciuti dai nomi")
                    feature("curlybraces", "Cataloghi JSON", "Film e serie con stagioni, trame e immagini")
                    feature("externaldrive.connected.to.line.below", "Cartelle web", "Ad esempio quella del tuo NAS: Sipario esplora le sottocartelle")
                }
                .padding()
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
                Button(action: onAdd) {
                    Label("Aggiungi una libreria", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                Button("Che link posso usare?", action: onFormats)
                    .font(.subheadline)
            }
            .padding(.bottom, 40)
        }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.gold)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
