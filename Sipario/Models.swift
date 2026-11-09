import Foundation

enum ItemKind: String, Codable, CaseIterable, Hashable {
    case movie, series, live

    var label: String {
        switch self {
        case .movie: return "Film"
        case .series: return "Serie TV"
        case .live: return "Diretta"
        }
    }
}

/// Che cosa contiene una libreria (aiuta a riconoscere i titoli).
enum KindHint: String, Codable, CaseIterable, Identifiable {
    case auto, movies, series, live
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Riconosci da solo"
        case .movies: return "Solo film"
        case .series: return "Solo serie TV"
        case .live: return "Canali in diretta"
        }
    }
}

/// Dati della scheda ricavati da TMDB.
struct Meta: Codable, Hashable {
    var tmdbId: Int
    var title: String
    var originalTitle: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genres: [String]
    var rating: Double?
    var year: Int?
}

struct Episode: Codable, Hashable, Identifiable {
    var id: String
    var season: Int
    var number: Int
    var title: String?
    var url: URL
    var still: URL?

    var code: String { "S\(season) E\(number)" }
}

struct MediaItem: Codable, Hashable, Identifiable {
    var id: String
    var libraryId: UUID
    var kind: ItemKind
    var title: String
    var year: Int?
    var group: String?
    var poster: URL?
    var backdrop: URL?
    var overview: String?
    var genres: [String] = []
    var url: URL?
    var episodes: [Episode] = []
    var added: Date = Date()
    var meta: Meta?
    var matchTried: Bool = false
    var tmdbHint: Int?

    var displayTitle: String { meta?.title ?? title }
    var displayYear: Int? { year ?? meta?.year }
    var displayOverview: String? { (overview?.nonEmpty) ?? meta?.overview?.nonEmpty }
    var posterURL: URL? { tmdbImage(meta?.posterPath, "w342") ?? poster }
    var largePosterURL: URL? { tmdbImage(meta?.posterPath, "w500") ?? poster }
    var backdropURL: URL? { tmdbImage(meta?.backdropPath, "w1280") ?? backdrop }
    var allGenres: [String] { (meta?.genres.isEmpty == false) ? meta!.genres : genres }
    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    func episodes(in season: Int) -> [Episode] { episodes.filter { $0.season == season } }
}

struct Library: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Indirizzo web oppure "file:<nome>" per i file importati.
    var source: String
    var hint: KindHint = .auto
    var lastUpdated: Date?
    var lastError: String?

    var isFile: Bool { source.hasPrefix("file:") }
    var sourceLabel: String {
        if isFile { return String(source.dropFirst(5)) }
        return URL(string: source)?.host ?? source
    }
}

/// Stato di visione di un film o di un episodio.
struct WatchState: Codable, Hashable {
    var seconds: Double
    var duration: Double
    var updated: Date
    var finished: Bool

    var fraction: Double { duration > 0 ? min(1, seconds / duration) : 0 }
}

struct ContinueEntry: Identifiable, Hashable {
    let item: MediaItem
    let episode: Episode?
    let fraction: Double
    let updated: Date
    var id: String { item.id }
}

enum CollectionFilter: Hashable {
    case kind(ItemKind)
    case genre(String)
    case group(String)
    case library(UUID)
    case recent
}
