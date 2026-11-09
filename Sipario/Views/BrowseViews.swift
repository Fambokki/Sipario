import SwiftUI

enum CatalogSort: String, CaseIterable, Identifiable {
    case recent = "Aggiunti di recente"
    case title = "Titolo (A-Z)"
    case year = "Anno"
    case rating = "Voto"
    var id: String { rawValue }

    func apply(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .recent: return items.sorted { $0.added > $1.added }
        case .title: return items.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .year: return items.sorted { ($0.displayYear ?? 0) > ($1.displayYear ?? 0) }
        case .rating: return items.sorted { ($0.meta?.rating ?? 0) > ($1.meta?.rating ?? 0) }
        }
    }
}

struct SortMenu: View {
    @Binding var sort: CatalogSort
    var body: some View {
        Menu {
            Picker("Ordina", selection: $sort) {
                ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }
}

// MARK: - Film / Serie TV

struct BrowseView: View {
    let kind: ItemKind
    @EnvironmentObject private var store: LibraryStore
    @State private var category: String?
    @State private var sort: CatalogSort = .recent

    private var categories: [String] {
        kind == .movie ? store.catalog.movieCategories : store.catalog.seriesCategories
    }

    private var items: [MediaItem] {
        var base = kind == .movie ? store.catalog.movies : store.catalog.series
        if let category { base = base.filter { $0.allGenres.contains(category) || $0.group == category } }
        return sort.apply(base)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("Tutti", selected: category == nil) { category = nil }
                            ForEach(categories, id: \.self) { c in
                                chip(c, selected: category == c) { category = (category == c ? nil : c) }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                let list = items
                if list.isEmpty {
                    ContentUnavailableView(kind == .movie ? "Nessun film" : "Nessuna serie",
                                           systemImage: kind == .movie ? "film" : "tv",
                                           description: Text("Aggiungi una libreria dalla Home per vederli qui."))
                        .padding(.top, 60)
                } else {
                    Text(list.count == 1 ? "1 titolo" : "\(list.count) titoli")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    PosterGrid(items: list)
                }
            }
            .padding(.vertical)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(kind == .movie ? "Film" : "Serie TV")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(sort: $sort) } }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.white : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Elenco completo (genere, libreria, "Vedi tutti")

struct CollectionView: View {
    let title: String
    let filter: CollectionFilter
    @EnvironmentObject private var store: LibraryStore
    @State private var sort: CatalogSort = .recent

    var body: some View {
        let items = sort.apply(store.collection(filter))
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("Niente da mostrare", systemImage: "film")
                    .padding(.top, 60)
            } else {
                PosterGrid(items: items).padding(.vertical)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(sort: $sort) } }
    }
}

// MARK: - Cerca

struct SearchView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var results: [MediaItem] = []

    var body: some View {
        ScrollView {
            if query.trimmed.count < 2 {
                browse
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            } else {
                PosterGrid(items: results).padding(.vertical)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Cerca")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Film, serie, canali…")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = store.search(query)
        }
    }

    private var browse: some View {
        let cats = store.catalog.categories
        return VStack(alignment: .leading, spacing: 14) {
            if !cats.isEmpty {
                Text("Esplora").font(.title3.bold()).padding(.horizontal)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(cats, id: \.self) { c in
                        NavigationLink(value: Route.collection(c, .genre(c))) {
                            let color = Theme.posterPalette[c.colorSeed % Theme.posterPalette.count]
                            Text(c)
                                .font(.subheadline.weight(.bold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(8)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(LinearGradient(colors: [color, color.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            } else {
                Text("Cerca tra i titoli delle tue librerie.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .padding(.vertical)
    }
}

// MARK: - La mia lista

struct MyListView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let items = store.myList.compactMap { store.item($0) }
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("La tua lista è vuota", systemImage: "plus.rectangle.on.rectangle",
                                       description: Text("Tocca \"La mia lista\" su un film o una serie per ritrovarlo qui."))
                    .padding(.top, 80)
            } else {
                PosterGrid(items: items).padding(.vertical)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("La mia lista")
    }
}
