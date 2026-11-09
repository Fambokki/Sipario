import Foundation
import SwiftUI

/// Indici precalcolati per mostrare in fretta le righe della Home.
struct Catalog {
    var movies: [MediaItem] = []
    var series: [MediaItem] = []
    var live: [MediaItem] = []
    var recent: [MediaItem] = []
    /// Generi (o, senza TMDB, categorie della playlist) in ordine di frequenza.
    var categories: [String] = []
    var movieCategories: [String] = []
    var seriesCategories: [String] = []
    var byCategory: [String: [MediaItem]] = [:]
    var backdropCount = 0
    var counts: [UUID: [ItemKind: Int]] = [:]
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var libraries: [Library] = []
    @Published private(set) var items: [MediaItem] = [] { didSet { rebuild() } }
    @Published private(set) var catalog = Catalog()
    @Published private(set) var watch: [String: WatchState] = [:]
    @Published private(set) var cursors: [String: String] = [:]
    @Published private(set) var myList: [String] = []
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var enrichDone = 0
    @Published private(set) var enrichTotal = 0
    @Published private(set) var logos: [String: URL] = [:]

    private var index: [String: Int] = [:]
    private var episodeOwner: [String: (Int, Int)] = [:]
    private var searchKeys: [String] = []
    private var enriching = false
    private var started = false
    private var saveTask: Task<Void, Never>?
    private var genreCache: [Int: String] = [:]
    private var logoRequests: Set<String> = []

    private struct Snapshot: Codable {
        var libraries: [Library]
        var items: [MediaItem]
        var watch: [String: WatchState]
        var cursors: [String: String]
        var myList: [String]
    }

    // MARK: File

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sipario", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var dataFile: URL { folder.appendingPathComponent("libreria.json") }

    private static func sourceFile(_ id: UUID) -> URL {
        folder.appendingPathComponent("sorgente-\(id.uuidString).dat")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.dataFile),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            libraries = snap.libraries
            items = snap.items
            watch = snap.watch
            cursors = snap.cursors
            myList = snap.myList
        }
        rebuild()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let snap = Snapshot(libraries: libraries, items: items, watch: watch, cursors: cursors, myList: myList)
            guard let data = try? JSONEncoder().encode(snap) else { return }
            let url = Self.dataFile
            await Task.detached { try? data.write(to: url, options: .atomic) }.value
        }
    }

    // MARK: Indici

    private func rebuild() {
        var idx: [String: Int] = [:]
        var owners: [String: (Int, Int)] = [:]
        var keys: [String] = []
        var c = Catalog()
        var catCount: [String: Int] = [:]
        var movieCat: [String: Int] = [:]
        var seriesCat: [String: Int] = [:]
        var hasGenres = false
        keys.reserveCapacity(items.count)

        for it in items where !it.allGenres.isEmpty && it.kind != .live {
            hasGenres = true
            break
        }

        for (i, it) in items.enumerated() {
            idx[it.id] = i
            keys.append(normalizeKey([it.displayTitle, it.title, it.meta?.originalTitle ?? "", it.group ?? ""].joined(separator: " ")))
            c.counts[it.libraryId, default: [:]][it.kind, default: 0] += 1
            switch it.kind {
            case .movie: c.movies.append(it)
            case .series:
                c.series.append(it)
                for (j, e) in it.episodes.enumerated() { owners[e.id] = (i, j) }
            case .live: c.live.append(it)
            }
            if it.backdropURL != nil && it.kind != .live { c.backdropCount += 1 }
            guard it.kind != .live else { continue }
            let cats = hasGenres ? it.allGenres : (it.group.map { [$0] } ?? [])
            for g in cats {
                catCount[g, default: 0] += 1
                if it.kind == .movie { movieCat[g, default: 0] += 1 } else { seriesCat[g, default: 0] += 1 }
                if (c.byCategory[g]?.count ?? 0) < 30 { c.byCategory[g, default: []].append(it) }
            }
        }
        func ranked(_ d: [String: Int]) -> [String] {
            d.filter { $0.value >= 2 || d.count < 6 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        }
        c.categories = ranked(catCount)
        c.movieCategories = ranked(movieCat)
        c.seriesCategories = ranked(seriesCat)
        c.recent = (c.movies + c.series).sorted { $0.added > $1.added }
        index = idx
        episodeOwner = owners
        searchKeys = keys
        catalog = c
    }

    // MARK: Accesso ai dati

    func item(_ id: String) -> MediaItem? { index[id].map { items[$0] } }
    func library(_ id: UUID) -> Library? { libraries.first { $0.id == id } }

    func collection(_ filter: CollectionFilter) -> [MediaItem] {
        switch filter {
        case .kind(let k):
            switch k {
            case .movie: return catalog.movies
            case .series: return catalog.series
            case .live: return catalog.live
            }
        case .genre(let g):
            return (catalog.movies + catalog.series).filter { $0.allGenres.contains(g) || $0.group == g }
        case .group(let g):
            return items.filter { $0.group == g }
        case .library(let id):
            return items.filter { $0.libraryId == id && $0.kind != .live }
        case .recent:
            return catalog.recent
        }
    }

    func search(_ text: String) -> [MediaItem] {
        let q = normalizeKey(text)
        guard q.count >= 2 else { return [] }
        var out: [MediaItem] = []
        for (i, key) in searchKeys.enumerated() where key.contains(q) {
            out.append(items[i])
            if out.count >= 200 { break }
        }
        // Prima i titoli che iniziano con la ricerca.
        return out.sorted { a, b in
            let pa = normalizeKey(a.displayTitle).hasPrefix(q), pb = normalizeKey(b.displayTitle).hasPrefix(q)
            return pa && !pb
        }
    }

    func similar(to item: MediaItem, limit: Int = 15) -> [MediaItem] {
        let genres = Set(item.allGenres + (item.group.map { [$0] } ?? []))
        guard !genres.isEmpty else { return [] }
        let pool = item.kind == .series ? catalog.series : (item.kind == .movie ? catalog.movies : catalog.live)
        let scored = pool.filter { $0.id != item.id }.map { other -> (MediaItem, Int) in
            let g = Set(other.allGenres + (other.group.map { [$0] } ?? []))
            return (other, g.intersection(genres).count)
        }.filter { $0.1 > 0 }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    func counts(for library: UUID) -> [ItemKind: Int] { catalog.counts[library] ?? [:] }

    // MARK: Librerie

    @discardableResult
    func addLibrary(name: String, source: String, hint: KindHint, fileData: Data? = nil) async throws -> [ItemKind: Int] {
        var lib = Library(name: name, source: source, hint: hint)
        if let fileData { try fileData.write(to: Self.sourceFile(lib.id)) }
        do {
            let new = try await load(lib)
            guard new.contains(where: { $0.kind != .series || !$0.episodes.isEmpty }) else {
                throw AppError.message("Non ho trovato film, serie o canali in questa libreria.")
            }
            lib.lastUpdated = Date()
            libraries.append(lib)
            replace(lib.id, with: new)
            scheduleSave()
            Task { await enrich() }
            return counts(for: lib.id)
        } catch {
            try? FileManager.default.removeItem(at: Self.sourceFile(lib.id))
            throw error
        }
    }

    func update(_ lib: Library) async {
        guard let i = libraries.firstIndex(where: { $0.id == lib.id }) else { return }
        let hintChanged = libraries[i].hint != lib.hint || libraries[i].source != lib.source
        libraries[i] = lib
        scheduleSave()
        if hintChanged { await refresh(lib.id) }
    }

    func remove(_ id: UUID) {
        libraries.removeAll { $0.id == id }
        items = items.filter { $0.libraryId != id }
        try? FileManager.default.removeItem(at: Self.sourceFile(id))
        scheduleSave()
    }

    func refresh(_ id: UUID) async {
        guard let lib = library(id), !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let new = try await load(lib)
            replace(id, with: new)
            if let i = libraries.firstIndex(where: { $0.id == id }) {
                libraries[i].lastUpdated = Date()
                libraries[i].lastError = nil
            }
        } catch {
            if let i = libraries.firstIndex(where: { $0.id == id }) {
                libraries[i].lastError = error.localizedDescription
            }
        }
        scheduleSave()
    }

    func refreshAll() async {
        for lib in libraries { await refresh(lib.id) }
        Task { await enrich() }
    }

    func startup() async {
        guard !started else { return }
        started = true
        let stale = libraries.contains { ($0.lastUpdated ?? .distantPast) < Date().addingTimeInterval(-6 * 3600) }
        if stale { await refreshAll() } else { await enrich() }
    }

    private func load(_ lib: Library) async throws -> [MediaItem] {
        if lib.isFile {
            guard let data = try? Data(contentsOf: Self.sourceFile(lib.id)) else {
                throw AppError.message("Il file della libreria non è più disponibile: importalo di nuovo.")
            }
            return try await Importer.items(for: lib, data: data, contentType: nil, base: nil)
        }
        guard let url = URL(string: lib.source.trimmed), url.scheme?.hasPrefix("http") == true else {
            throw AppError.message("Il link non è valido: deve iniziare con http:// o https://")
        }
        if Importer.isDirectVideo(url) {
            let entry = Importer.Entry(title: lib.name, url: url, guess: lib.hint == .live ? .live : .movie)
            return Importer.build([entry], library: lib)
        }
        let (data, type) = try await Importer.download(url)
        return try await Importer.items(for: lib, data: data, contentType: type, base: url)
    }

    /// Sostituisce i titoli di una libreria mantenendo schede e date di aggiunta già note.
    private func replace(_ libraryId: UUID, with newItems: [MediaItem]) {
        var old: [String: MediaItem] = [:]
        for it in items where it.libraryId == libraryId { old[it.id] = it }
        var merged = newItems
        let now = Date()
        for i in merged.indices {
            if let o = old[merged[i].id] {
                merged[i].meta = o.meta
                merged[i].matchTried = o.matchTried
                merged[i].added = o.added
            } else {
                // Piccolo scarto per mantenere l'ordine della playlist tra i nuovi arrivi.
                merged[i].added = now.addingTimeInterval(-Double(i) * 0.001)
            }
        }
        items = items.filter { $0.libraryId != libraryId } + merged
    }

    // MARK: Schede TMDB

    func enrich(force: Bool = false) async {
        guard AppSettings.shared.hasTMDB, !enriching else { return }
        enriching = true
        defer {
            enriching = false
            enrichTotal = 0
            enrichDone = 0
        }
        if force {
            var copy = items
            for i in copy.indices where copy[i].meta == nil { copy[i].matchTried = false }
            items = copy
        }
        if genreCache.isEmpty { genreCache = await TMDB.genreMap() }
        let genres = genreCache
        let todo = items.filter { $0.kind != .live && $0.meta == nil && !$0.matchTried }
        guard !todo.isEmpty else { return }
        enrichTotal = todo.count
        enrichDone = 0
        var start = 0
        while start < todo.count {
            let chunk = Array(todo[start..<min(start + 8, todo.count)])
            start += chunk.count
            var results: [(String, Meta?)] = []
            await withTaskGroup(of: (String, Meta?).self) { group in
                for it in chunk { group.addTask { (it.id, await TMDB.match(it, genres: genres)) } }
                for await r in group { results.append(r) }
            }
            var copy = items
            for (id, meta) in results {
                if let i = index[id] {
                    copy[i].meta = meta
                    copy[i].matchTried = true
                }
            }
            items = copy
            enrichDone = start
            if start % 96 == 0 { scheduleSave() }
        }
        scheduleSave()
    }

    func resetMatch(_ id: String) {
        guard let i = index[id] else { return }
        var copy = items
        copy[i].meta = nil
        copy[i].matchTried = true
        items = copy
        scheduleSave()
    }

    func loadLogo(_ id: String) async {
        guard logos[id] == nil, !logoRequests.contains(id), let it = item(id), let meta = it.meta else { return }
        logoRequests.insert(id)
        if let url = await TMDB.logo(it.kind, id: meta.tmdbId) { logos[id] = url }
    }

    func setLogo(_ url: URL?, for id: String) {
        if let url { logos[id] = url }
    }

    // MARK: Visione

    func state(_ pid: String) -> WatchState? { watch[pid] }

    func fraction(_ pid: String) -> Double? {
        guard let s = watch[pid], !s.finished, s.fraction > 0.01 else { return nil }
        return s.fraction
    }

    func isWatched(_ pid: String) -> Bool { watch[pid]?.finished == true }

    func resumePosition(_ pid: String) -> Double {
        guard let s = watch[pid], !s.finished, s.seconds > 10 else { return 0 }
        return s.seconds
    }

    func nextEpisode(after ep: Episode, in item: MediaItem) -> Episode? {
        guard let i = item.episodes.firstIndex(where: { $0.id == ep.id }), i + 1 < item.episodes.count else { return nil }
        return item.episodes[i + 1]
    }

    /// L'episodio da cui riprendere una serie.
    func resumeEpisode(for item: MediaItem) -> Episode? {
        guard item.kind == .series, let first = item.episodes.first else { return nil }
        if let cid = cursors[item.id], let ep = item.episodes.first(where: { $0.id == cid }) {
            if isWatched(ep.id) { return nextEpisode(after: ep, in: item) ?? first }
            return ep
        }
        return first
    }

    func record(_ pid: String, seriesId: String?, seconds: Double, duration: Double) {
        guard duration.isFinite, duration > 30, seconds.isFinite else { return }
        let finished = seconds / duration > 0.93
        guard finished || seconds > 15 else { return }
        watch[pid] = WatchState(seconds: finished ? 0 : seconds, duration: duration, updated: Date(), finished: finished)
        if let seriesId { cursors[seriesId] = pid }
        scheduleSave()
    }

    func setWatched(_ pid: String, seriesId: String?, _ watched: Bool) {
        if watched {
            watch[pid] = WatchState(seconds: 0, duration: 1, updated: Date(), finished: true)
            if let seriesId { cursors[seriesId] = pid }
        } else {
            watch[pid] = nil
        }
        scheduleSave()
    }

    func removeFromContinue(_ entry: ContinueEntry) {
        if entry.item.kind == .series {
            cursors[entry.item.id] = nil
            if let ep = entry.episode, watch[ep.id]?.finished == false { watch[ep.id] = nil }
        } else {
            watch[entry.item.id] = nil
        }
        scheduleSave()
    }

    var continueWatching: [ContinueEntry] {
        var out: [ContinueEntry] = []
        for (pid, s) in watch where !s.finished && s.fraction > 0.01 {
            if let i = index[pid], items[i].kind == .movie {
                out.append(ContinueEntry(item: items[i], episode: nil, fraction: s.fraction, updated: s.updated))
            }
        }
        for (sid, eid) in cursors {
            guard let i = index[sid], let owner = episodeOwner[eid], owner.0 == i else { continue }
            let item = items[i]
            let ep = item.episodes[owner.1]
            let s = watch[eid]
            if s?.finished == true {
                if let next = nextEpisode(after: ep, in: item) {
                    out.append(ContinueEntry(item: item, episode: next, fraction: fraction(next.id) ?? 0,
                                             updated: s?.updated ?? .distantPast))
                }
            } else {
                out.append(ContinueEntry(item: item, episode: ep, fraction: s?.fraction ?? 0, updated: s?.updated ?? .distantPast))
            }
        }
        return out.sorted { $0.updated > $1.updated }
    }

    // MARK: La mia lista

    func inList(_ id: String) -> Bool { myList.contains(id) }

    func toggleList(_ id: String) {
        if let i = myList.firstIndex(of: id) { myList.remove(at: i) } else { myList.insert(id, at: 0) }
        scheduleSave()
    }
}
