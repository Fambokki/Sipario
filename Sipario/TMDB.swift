import Foundation

/// Schede, locandine, sfondi e loghi da The Movie Database (serve una chiave gratuita).
enum TMDB {
    static var key: String { (UserDefaults.standard.string(forKey: "tmdbKey") ?? "").trimmed }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func get<T: Decodable>(_ path: String, _ params: [String: String] = [:], key override: String? = nil) async throws -> T {
        let apiKey = override ?? key
        guard !apiKey.isEmpty else { throw AppError.message("Manca la chiave TMDB.") }
        guard var comps = URLComponents(string: "https://api.themoviedb.org/3" + path) else { throw AppError.http(400) }
        var q = [URLQueryItem(name: "language", value: "it-IT")]
        for (k, v) in params { q.append(URLQueryItem(name: k, value: v)) }
        let bearer = apiKey.hasPrefix("eyJ")
        if !bearer { q.append(URLQueryItem(name: "api_key", value: apiKey)) }
        comps.queryItems = q
        guard let url = comps.url else { throw AppError.http(400) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 {
            // Troppe richieste: aspetta un attimo e riprova una volta.
            try await Task.sleep(for: .seconds(2))
            let (data2, resp2) = try await URLSession.shared.data(for: req)
            guard ((resp2 as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw AppError.http(429) }
            return try decoder.decode(T.self, from: data2)
        }
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        return try decoder.decode(T.self, from: data)
    }

    static func test(_ key: String) async -> Bool {
        struct G: Decodable { let genres: [Genre] }
        return (try? await get("/genre/movie/list", key: key.trimmed) as G) != nil
    }

    // MARK: Generi

    struct Genre: Decodable { let id: Int; let name: String }

    static func genreMap() async -> [Int: String] {
        struct G: Decodable { let genres: [Genre] }
        async let m: G? = try? await get("/genre/movie/list")
        async let t: G? = try? await get("/genre/tv/list")
        var out: [Int: String] = [:]
        for g in ((await m)?.genres ?? []) + ((await t)?.genres ?? []) { out[g.id] = g.name }
        return out
    }

    // MARK: Abbinamento dei titoli

    private struct Result: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let voteAverage: Double?
        let releaseDate: String?
        let firstAirDate: String?

        var year: Int? { (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) } }
    }

    private struct Page: Decodable { let results: [Result] }

    static func match(_ item: MediaItem, genres: [Int: String]) async -> Meta? {
        if let id = item.tmdbHint { return try? await details(item.kind, id: id).meta }
        let title = item.title
        guard title.count >= 2 else { return nil }
        let isTV = item.kind == .series
        let path = isTV ? "/search/tv" : "/search/movie"
        var params = ["query": title, "include_adult": "false"]
        if let y = item.year { params[isTV ? "first_air_date_year" : "year"] = String(y) }
        var results = ((try? await get(path, params)) as Page?)?.results ?? []
        if results.isEmpty, item.year != nil {
            params[isTV ? "first_air_date_year" : "year"] = nil
            results = ((try? await get(path, params)) as Page?)?.results ?? []
        }
        let wanted = normalizeKey(title)
        func names(_ r: Result) -> [String] {
            [r.title, r.name, r.originalTitle, r.originalName].compactMap { $0 }.map(normalizeKey)
        }
        let exact = results.first { names($0).contains(wanted) }
        let prefix = wanted.count >= 4 ? results.first { r in names(r).contains { $0.hasPrefix(wanted) || wanted.hasPrefix($0) && $0.count >= 4 } } : nil
        let byYear = item.year != nil ? results.first { $0.year == item.year } : nil
        guard let r = exact ?? prefix ?? byYear ?? (results.count == 1 ? results.first : nil) else { return nil }
        return Meta(tmdbId: r.id, title: (r.title ?? r.name ?? title), originalTitle: r.originalTitle ?? r.originalName,
                    overview: r.overview?.nonEmpty, posterPath: r.posterPath, backdropPath: r.backdropPath,
                    genres: (r.genreIds ?? []).compactMap { genres[$0] }, rating: r.voteAverage, year: r.year)
    }

    // MARK: Dettagli (cast, trailer, logo)

    struct CastMember: Decodable, Hashable, Identifiable {
        let id: Int
        let name: String
        let character: String?
        let profilePath: String?
    }

    private struct Credits: Decodable { let cast: [CastMember]? }
    private struct Video: Decodable { let key: String; let site: String; let type: String; let iso6391: String? }
    private struct Videos: Decodable { let results: [Video]? }
    private struct ImageFile: Decodable { let filePath: String; let iso6391: String?; let voteAverage: Double? }
    private struct Images: Decodable { let logos: [ImageFile]?; let backdrops: [ImageFile]? }

    private struct Detail: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let overview: String?
        let tagline: String?
        let runtime: Int?
        let episodeRunTime: [Int]?
        let numberOfSeasons: Int?
        let genres: [Genre]?
        let voteAverage: Double?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let credits: Credits?
        let videos: Videos?
        let images: Images?
    }

    struct Extra: Hashable {
        let meta: Meta
        let tagline: String?
        let runtime: Int?
        let cast: [CastMember]
        let trailerKey: String?
        let logo: URL?
    }

    static func details(_ kind: ItemKind, id: Int) async throws -> Extra {
        let path = (kind == .series ? "/tv/" : "/movie/") + String(id)
        let d: Detail = try await get(path, [
            "append_to_response": "credits,videos,images",
            "include_image_language": "it,en,null",
            "include_video_language": "it,en,null",
        ])
        let yt = (d.videos?.results ?? []).filter { $0.site == "YouTube" }
        let trailer = yt.first { $0.type == "Trailer" && $0.iso6391 == "it" } ?? yt.first { $0.type == "Trailer" } ?? yt.first
        let year = (d.releaseDate ?? d.firstAirDate).flatMap { Int($0.prefix(4)) }
        let meta = Meta(tmdbId: d.id, title: d.title ?? d.name ?? "", originalTitle: d.originalTitle ?? d.originalName,
                        overview: d.overview?.nonEmpty, posterPath: d.posterPath, backdropPath: d.backdropPath,
                        genres: (d.genres ?? []).map(\.name), rating: d.voteAverage, year: year)
        return Extra(meta: meta, tagline: d.tagline?.nonEmpty, runtime: d.runtime ?? d.episodeRunTime?.first,
                     cast: Array((d.credits?.cast ?? []).prefix(15)), trailerKey: trailer?.key,
                     logo: bestLogo(d.images?.logos))
    }

    static func logo(_ kind: ItemKind, id: Int) async -> URL? {
        let path = (kind == .series ? "/tv/" : "/movie/") + "\(id)/images"
        let imgs: Images? = try? await get(path, ["include_image_language": "it,en,null"])
        return bestLogo(imgs?.logos)
    }

    private static func bestLogo(_ logos: [ImageFile]?) -> URL? {
        let sorted = (logos ?? []).sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
        let pick = sorted.first { $0.iso6391 == "it" } ?? sorted.first { $0.iso6391 == "en" } ?? sorted.first
        guard var path = pick?.filePath else { return nil }
        if path.hasSuffix(".svg") { path = String(path.dropLast(4)) + ".png" }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    // MARK: Episodi

    struct SeasonEpisode: Decodable, Hashable {
        let episodeNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let runtime: Int?
    }

    static func season(tvId: Int, number: Int) async throws -> [SeasonEpisode] {
        struct S: Decodable { let episodes: [SeasonEpisode]? }
        let s: S = try await get("/tv/\(tvId)/season/\(number)")
        return s.episodes ?? []
    }
}
