import Foundation

// MARK: - Modelli TMDB

enum MediaKind: String, Codable, Hashable {
    case movie, tv

    var label: String { self == .movie ? "Film" : "Serie TV" }
}

struct TMDBItem: Codable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?
    let mediaType: String?
    let genreIds: [Int]?
    var kindOverride: MediaKind? = nil

    var kind: MediaKind {
        if let kindOverride { return kindOverride }
        if mediaType == "tv" { return .tv }
        if mediaType == "movie" { return .movie }
        return title != nil ? .movie : .tv
    }

    var displayTitle: String { title ?? name ?? "Senza titolo" }
    var year: String? { (releaseDate ?? firstAirDate)?.yearPrefix }
    var posterURL: URL? { TMDB.image(posterPath, size: "w342") }
    var backdropURL: URL? { TMDB.image(backdropPath, size: "w1280") }
}

struct TMDBPage<T: Decodable>: Decodable {
    let results: [T]
    let totalPages: Int?
}

struct TMDBGenre: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
}

struct TMDBVideo: Codable, Hashable {
    let key: String
    let site: String
    let type: String
    let name: String?
    let iso6391: String?
}

struct TMDBVideoList: Codable, Hashable {
    let results: [TMDBVideo]
}

struct TMDBCast: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?
}

struct TMDBCredits: Codable, Hashable {
    let cast: [TMDBCast]
}

struct TMDBProvider: Codable, Hashable, Identifiable {
    let providerId: Int
    let providerName: String
    let logoPath: String?
    let displayPriority: Int?

    var id: Int { providerId }
    var logoURL: URL? { TMDB.image(logoPath, size: "w154") }
    var saved: SavedProvider { SavedProvider(id: providerId, name: providerName, logoPath: logoPath) }
}

struct TMDBCountryProviders: Codable, Hashable {
    let link: String?
    let flatrate: [TMDBProvider]?
    let rent: [TMDBProvider]?
    let buy: [TMDBProvider]?
    let free: [TMDBProvider]?
    let ads: [TMDBProvider]?
}

struct TMDBProvidersResponse: Codable, Hashable {
    let results: [String: TMDBCountryProviders]
}

struct TMDBProviderList: Codable {
    let results: [TMDBProvider]
}

struct TMDBSeasonSummary: Codable, Hashable, Identifiable {
    let seasonNumber: Int
    let name: String?
    let episodeCount: Int?
    let posterPath: String?
    var id: Int { seasonNumber }
}

struct TMDBEpisode: Codable, Hashable, Identifiable {
    let id: Int
    let name: String?
    let overview: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let stillPath: String?
    let runtime: Int?
    let airDate: String?

    var stillURL: URL? { TMDB.image(stillPath, size: "w300") }
}

struct TMDBSeasonDetail: Codable {
    let episodes: [TMDBEpisode]
}

struct TMDBDetail: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let tagline: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?
    let numberOfSeasons: Int?
    let seasons: [TMDBSeasonSummary]?
    let posterPath: String?
    let backdropPath: String?
    let videos: TMDBVideoList?
    let credits: TMDBCredits?
    let recommendations: TMDBPage<TMDBItem>?
    let watchProviders: TMDBProvidersResponse?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, tagline, runtime, episodeRunTime, genres, voteAverage
        case releaseDate, firstAirDate, numberOfSeasons, seasons, posterPath, backdropPath
        case videos, credits, recommendations
        case watchProviders = "watch/providers"
    }

    var displayTitle: String { title ?? name ?? "" }
    var year: String? { (releaseDate ?? firstAirDate)?.yearPrefix }
    var minutes: Int? { runtime ?? episodeRunTime?.first }
    var posterURL: URL? { TMDB.image(posterPath, size: "w500") }
    var backdropURL: URL? { TMDB.image(backdropPath, size: "w1280") }

    /// Il trailer migliore: prima in italiano, poi qualsiasi trailer su YouTube.
    var trailer: TMDBVideo? {
        let yt = (videos?.results ?? []).filter { $0.site == "YouTube" }
        return yt.first { $0.type == "Trailer" && $0.iso6391 == "it" }
            ?? yt.first { $0.type == "Trailer" }
            ?? yt.first { $0.type == "Teaser" }
            ?? yt.first
    }
}

// MARK: - Client

@MainActor
enum TMDB {
    private static let base = "https://api.themoviedb.org/3"

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    nonisolated static func image(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    static func get<T: Decodable>(_ path: String, _ params: [String: String] = [:], key: String? = nil) async throws -> T {
        let apiKey = key ?? AppSettings.shared.cleanTMDBKey
        guard !apiKey.isEmpty else { throw AppError.missingKey }
        guard var comps = URLComponents(string: base + path) else { throw AppError.message("Indirizzo non valido") }
        var items: [URLQueryItem] = []
        if params["language"] == nil { items.append(URLQueryItem(name: "language", value: "it-IT")) }
        for (k, v) in params { items.append(URLQueryItem(name: k, value: v)) }
        // Il "token di lettura" (v4) inizia con eyJ e va nell'intestazione; la chiave v3 va nella query.
        let bearer = apiKey.hasPrefix("eyJ")
        if !bearer { items.append(URLQueryItem(name: "api_key", value: apiKey)) }
        comps.queryItems = items
        guard let url = comps.url else { throw AppError.message("Indirizzo non valido") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw AppError.badKey }
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        return try decoder.decode(T.self, from: data)
    }

    /// Verifica che una chiave funzioni.
    static func test(key: String) async -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        do {
            let _: TMDBPage<TMDBItem> = try await get("/trending/movie/day", key: clean)
            return true
        } catch {
            return false
        }
    }

    static func list(_ path: String, _ params: [String: String] = [:], kind: MediaKind? = nil) async throws -> [TMDBItem] {
        let page: TMDBPage<TMDBItem> = try await get(path, params)
        return page.results.compactMap { (item: TMDBItem) -> TMDBItem? in
            if item.mediaType == "person" { return nil }
            var copy = item
            if let kind { copy.kindOverride = kind }
            return copy
        }
    }

    static func discover(_ kind: MediaKind, _ params: [String: String]) async throws -> [TMDBItem] {
        var p = params
        if p["sort_by"] == nil { p["sort_by"] = "popularity.desc" }
        if p["watch_region"] == nil { p["watch_region"] = AppSettings.shared.region }
        return try await list("/discover/\(kind.rawValue)", p, kind: kind)
    }

    /// Titoli popolari su uno o più servizi (film e serie alternati).
    static func onServices(_ ids: [Int], extra: [String: String] = [:]) async throws -> [TMDBItem] {
        let joined = ids.map(String.init).joined(separator: "|")
        var p = extra
        p["with_watch_providers"] = joined
        p["with_watch_monetization_types"] = "flatrate|free|ads"
        let params = p
        async let movies = discover(.movie, params)
        async let shows = discover(.tv, params)
        let (m, s) = try await (movies, shows)
        return interleave(m, s)
    }

    static func detail(_ kind: MediaKind, id: Int) async throws -> TMDBDetail {
        try await get("/\(kind.rawValue)/\(id)", [
            "append_to_response": "videos,credits,recommendations,watch/providers",
            "include_video_language": "it,en,null",
        ])
    }

    static func season(tvId: Int, number: Int) async throws -> TMDBSeasonDetail {
        try await get("/tv/\(tvId)/season/\(number)")
    }

    static func search(_ query: String) async throws -> [TMDBItem] {
        try await list("/search/multi", ["query": query, "include_adult": "false"])
    }

    static func providers() async throws -> [TMDBProvider] {
        let r: TMDBProviderList = try await get("/watch/providers/movie", ["watch_region": AppSettings.shared.region])
        return r.results.sorted { ($0.displayPriority ?? 999) < ($1.displayPriority ?? 999) }
    }

    static func genres(_ kind: MediaKind) async throws -> [TMDBGenre] {
        struct R: Decodable { let genres: [TMDBGenre] }
        let r: R = try await get("/genre/\(kind.rawValue)/list")
        return r.genres
    }
}

func interleave<T>(_ a: [T], _ b: [T]) -> [T] {
    var out: [T] = []
    let n = max(a.count, b.count)
    for i in 0..<n {
        if i < a.count { out.append(a[i]) }
        if i < b.count { out.append(b[i]) }
    }
    return out
}

// MARK: - Apertura delle app dei servizi

enum ProviderLinks {
    /// Prova ad aprire direttamente la ricerca del titolo nell'app/sito del servizio;
    /// se non conosco il servizio uso la pagina "dove guardarlo" di TMDB.
    static func url(for provider: TMDBProvider, title: String, fallback: String?) -> URL? {
        let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let n = provider.providerName.lowercased()
        let candidate: String?
        if n.contains("netflix") {
            candidate = "https://www.netflix.com/search?q=\(q)"
        } else if n.contains("amazon") || n.contains("prime video") {
            candidate = "https://www.primevideo.com/search/ref=atv_nb_sug?phrase=\(q)"
        } else if n.contains("disney") {
            candidate = "https://www.disneyplus.com/search?q=\(q)"
        } else if n.contains("apple tv") {
            candidate = "https://tv.apple.com/it/search?term=\(q)"
        } else if n.contains("raiplay") {
            candidate = "https://www.raiplay.it/ricerca.html?q=\(q)"
        } else if n.contains("youtube") {
            candidate = "https://www.youtube.com/results?search_query=\(q)"
        } else if n.contains("google play") {
            candidate = "https://play.google.com/store/search?q=\(q)&c=movies"
        } else {
            candidate = nil
        }
        if let candidate, let u = URL(string: candidate) { return u }
        if let fallback, let u = URL(string: fallback) { return u }
        return nil
    }
}
