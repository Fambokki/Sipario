import Foundation

// MARK: - Cataloghi dei servizi di streaming ("Dove guardarlo")

/// Il link di un servizio (RaiPlay, Netflix, CHILI…) diventa una libreria con tutti i film e le serie
/// disponibili su quel servizio in Italia, presi da TMDB con schede e locandine in italiano.
/// I video restano sul servizio: Riproduci apre il titolo nella sua app o sul suo sito.
enum StreamingServices {
    static let lazyKind = "external"

    struct Service {
        let name: String
        let hosts: [String]
        /// Nomi con cui TMDB chiama il servizio (confrontati senza spazi e maiuscole).
        let tmdbNames: [String]
        /// Ricerca del titolo sul servizio; senza, si apre la pagina "Dove guardarlo" di TMDB.
        let search: String?
    }

    static let all: [Service] = [
        Service(name: "RaiPlay", hosts: ["raiplay.it"], tmdbNames: ["raiplay"], search: "https://www.raiplay.it/ricerca.html?q="),
        Service(name: "CHILI", hosts: ["chili.com"], tmdbNames: ["chili"], search: nil),
        Service(name: "Netflix", hosts: ["netflix.com"], tmdbNames: ["netflix"], search: "https://www.netflix.com/search?q="),
        Service(name: "Prime Video", hosts: ["primevideo.com", "amazon.it"], tmdbNames: ["amazonprimevideo", "primevideo"], search: "https://www.primevideo.com/search/?phrase="),
        Service(name: "Disney+", hosts: ["disneyplus.com"], tmdbNames: ["disneyplus"], search: "https://www.disneyplus.com/search?q="),
        Service(name: "Mediaset Infinity", hosts: ["mediasetinfinity.it", "mediasetinfinity.mediaset.it"], tmdbNames: ["mediasetinfinity", "infinityplus", "infinityselection"], search: nil),
        Service(name: "NOW", hosts: ["nowtv.it", "now.it"], tmdbNames: ["now", "nowtv"], search: nil),
        Service(name: "TIMVISION", hosts: ["timvision.it"], tmdbNames: ["timvision"], search: nil),
        Service(name: "Apple TV+", hosts: ["tv.apple.com"], tmdbNames: ["appletvplus", "appletv"], search: nil),
        Service(name: "Paramount+", hosts: ["paramountplus.com"], tmdbNames: ["paramountplus"], search: nil),
        Service(name: "Pluto TV", hosts: ["pluto.tv"], tmdbNames: ["plutotv"], search: nil),
        Service(name: "RakutenTV", hosts: ["rakuten.tv"], tmdbNames: ["rakutentv"], search: nil),
    ]

    static func service(for url: URL) -> Service? {
        let host = url.host?.lowercased() ?? ""
        return all.first { s in s.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    static func handles(_ url: URL) -> Bool { service(for: url) != nil }

    // MARK: Importazione

    private struct Provider: Decodable { let providerId: Int; let providerName: String }
    private struct Providers: Decodable { let results: [Provider] }
    private struct Found: Decodable {
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
    }
    private struct Page: Decodable { let results: [Found]; let totalPages: Int? }

    static func items(for library: Library, url: URL) async throws -> [MediaItem] {
        guard let service = service(for: url) else { throw AppError.message("Servizio non riconosciuto.") }
        guard !TMDB.key.isEmpty else {
            throw AppError.message("Per importare il catalogo di \(service.name) serve la chiave TMDB: aggiungila in Impostazioni → Copertine e schede.")
        }

        // L'identificativo del servizio su TMDB, cercato per nome tra i servizi italiani.
        let wanted = Set(service.tmdbNames)
        var ids = Set<Int>()
        for type in ["movie", "tv"] {
            let p: Providers? = try? await TMDB.get("/watch/providers/\(type)", ["watch_region": "IT"])
            for prov in p?.results ?? [] where wanted.contains(normalizeKey(prov.providerName)) { ids.insert(prov.providerId) }
        }
        guard !ids.isEmpty else { throw AppError.message("TMDB non conosce \(service.name) tra i servizi disponibili in Italia.") }
        let providers = ids.map(String.init).joined(separator: "|")

        let genres = await TMDB.genreMap()
        // Film e serie più popolari sul servizio: fino a 400 film e 200 serie.
        let requests: [(String, Int)] = (1...20).map { ("movie", $0) } + (1...10).map { ("tv", $0) }
        let pages: [(String, [Found])] = await WebSources.parallelMap(requests, width: 4) { req in
            let (type, page) = req
            let result: Page? = try? await TMDB.get("/discover/\(type)", [
                "with_watch_providers": providers, "watch_region": "IT",
                "with_watch_monetization_types": "flatrate|free|ads|rent|buy",
                "sort_by": "popularity.desc", "page": "\(page)",
            ])
            return result.map { (type, $0.results) }
        }

        let lib = library.id.uuidString
        var seen = Set<String>()
        var out: [MediaItem] = []
        for (type, results) in pages {
            for f in results {
                guard let title = (f.title ?? f.name)?.nonEmpty else { continue }
                let kind: ItemKind = type == "tv" ? .series : .movie
                let id = stableID(lib + "|\(type)|\(f.id)")
                guard seen.insert(id).inserted else { continue }
                let year = (f.releaseDate ?? f.firstAirDate).flatMap { Int($0.prefix(4)) }
                let names = (f.genreIds ?? []).compactMap { genres[$0] }
                let link = watchLink(service: service, title: title, tmdbId: f.id, type: type)
                var item = MediaItem(id: id, libraryId: library.id, kind: kind, title: title, year: year,
                                     group: service.name, overview: f.overview?.nonEmpty, genres: names, url: link)
                item.meta = Meta(tmdbId: f.id, title: title, originalTitle: f.originalTitle ?? f.originalName,
                                 overview: f.overview?.nonEmpty, posterPath: f.posterPath, backdropPath: f.backdropPath,
                                 genres: names, rating: f.voteAverage, year: year)
                item.matchTried = true
                item.tmdbHint = f.id
                item.lazyStream = lazyKind
                out.append(item)
            }
        }
        guard !out.isEmpty else { throw AppError.message("Non ho trovato titoli disponibili su \(service.name).") }
        return out
    }

    private static func watchLink(service: Service, title: String, tmdbId: Int, type: String) -> URL? {
        if let search = service.search,
           let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") {
            return URL(string: search + q)
        }
        return URL(string: "https://www.themoviedb.org/\(type)/\(tmdbId)/watch?locale=IT")
    }
}
