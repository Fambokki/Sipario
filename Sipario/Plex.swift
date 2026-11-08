import Foundation
import UIKit

// MARK: - Modelli Plex

private struct PlexGuid: Decodable { let id: String }

private struct PlexMeta: Decodable {
    let ratingKey: String
    let type: String?
    let title: String?
    let summary: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let index: Int?
    let parentIndex: Int?
    let parentTitle: String?
    let grandparentTitle: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let audienceRating: Double?
    let rating: Double?
    let contentRating: String?
    let guids: [PlexGuid]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, summary, year, thumb, art, parentThumb, grandparentThumb, grandparentArt
        case duration, viewOffset, viewCount, leafCount, viewedLeafCount, index, parentIndex
        case parentTitle, grandparentTitle, parentRatingKey, grandparentRatingKey
        case audienceRating, rating, contentRating
        case guids = "Guid"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ratingKey a volte arriva come numero.
        if let s = try? c.decode(String.self, forKey: .ratingKey) {
            ratingKey = s
        } else {
            ratingKey = String(try c.decode(Int.self, forKey: .ratingKey))
        }
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        art = try? c.decodeIfPresent(String.self, forKey: .art)
        parentThumb = try? c.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentThumb = try? c.decodeIfPresent(String.self, forKey: .grandparentThumb)
        grandparentArt = try? c.decodeIfPresent(String.self, forKey: .grandparentArt)
        duration = try? c.decodeIfPresent(Int.self, forKey: .duration)
        viewOffset = try? c.decodeIfPresent(Int.self, forKey: .viewOffset)
        viewCount = try? c.decodeIfPresent(Int.self, forKey: .viewCount)
        leafCount = try? c.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try? c.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        index = try? c.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try? c.decodeIfPresent(Int.self, forKey: .parentIndex)
        parentTitle = try? c.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentTitle = try? c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        parentRatingKey = Self.stringOrInt(c, .parentRatingKey)
        grandparentRatingKey = Self.stringOrInt(c, .grandparentRatingKey)
        audienceRating = try? c.decodeIfPresent(Double.self, forKey: .audienceRating)
        rating = try? c.decodeIfPresent(Double.self, forKey: .rating)
        contentRating = try? c.decodeIfPresent(String.self, forKey: .contentRating)
        guids = try? c.decodeIfPresent([PlexGuid].self, forKey: .guids)
    }

    private static func stringOrInt(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
        if let n = try? c.decodeIfPresent(Int.self, forKey: k) { return String(n) }
        return nil
    }
}

private struct PlexDirectory: Decodable {
    let key: String
    let type: String?
    let title: String?
}

private struct PlexHub: Decodable {
    let type: String?
    let metadata: [PlexMeta]?
    enum CodingKeys: String, CodingKey { case type; case metadata = "Metadata" }
}

private struct PlexContainer: Decodable {
    struct Inner: Decodable {
        let metadata: [PlexMeta]?
        let directory: [PlexDirectory]?
        let hub: [PlexHub]?
        enum CodingKeys: String, CodingKey {
            case metadata = "Metadata", directory = "Directory", hub = "Hub"
        }
    }
    let mediaContainer: Inner
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexServer: Decodable, Identifiable, Hashable {
    struct Connection: Decodable, Hashable {
        let uri: String
        let local: Bool?
        let relay: Bool?
    }
    let name: String
    let clientIdentifier: String
    let provides: String?
    let accessToken: String?
    let owned: Bool?
    let connections: [Connection]?

    var id: String { clientIdentifier }
    var isServer: Bool { (provides ?? "").contains("server") }
}

// MARK: - Client

@MainActor
enum Plex {
    private static var settings: AppSettings { AppSettings.shared }

    private static func applyHeaders(_ req: inout URLRequest, token: String?) {
        let h: [String: String] = [
            "Accept": "application/json",
            "X-Plex-Product": "Sipario",
            "X-Plex-Version": "1.0",
            "X-Plex-Client-Identifier": settings.deviceId,
            "X-Plex-Platform": "iOS",
            "X-Plex-Platform-Version": UIDevice.current.systemVersion,
            "X-Plex-Device": UIDevice.current.model,
            "X-Plex-Device-Name": "Sipario (\(UIDevice.current.model))",
        ]
        for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
        if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
    }

    private static func request(_ urlString: String, query: [URLQueryItem] = [], method: String = "GET",
                                token: String?, timeout: TimeInterval = 20) async throws -> Data {
        guard var c = URLComponents(string: urlString) else { throw AppError.message("Indirizzo non valido") }
        if !query.isEmpty { c.queryItems = (c.queryItems ?? []) + query }
        guard let u = c.url else { throw AppError.message("Indirizzo non valido") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = timeout
        applyHeaders(&req, token: token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw AppError.message("Accesso a Plex scaduto: accedi di nuovo nelle Impostazioni.") }
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        return data
    }

    private static func server(_ path: String, _ query: [URLQueryItem] = []) async throws -> PlexContainer.Inner {
        guard settings.hasJellyfin else { throw AppError.notLoggedIn }
        let data = try await request(settings.jellyfinServer + path, query: query, token: settings.jellyfinToken)
        return try JSONDecoder().decode(PlexContainer.self, from: data).mediaContainer
    }

    // MARK: Accesso con PIN (funziona anche con la verifica in due passaggi)

    static func createPin() async throws -> PlexPin {
        let data = try await request("https://plex.tv/api/v2/pins", query: [.init(name: "strong", value: "true")],
                                     method: "POST", token: nil)
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    static func authURL(_ pin: PlexPin) -> URL? {
        let code = pin.code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? pin.code
        return URL(string: "https://app.plex.tv/auth#?clientID=\(settings.deviceId)&code=\(code)&context%5Bdevice%5D%5Bproduct%5D=Sipario")
    }

    /// Restituisce il token dell'account quando l'utente ha completato l'accesso nel browser.
    static func checkPin(_ pin: PlexPin) async throws -> String? {
        let data = try await request("https://plex.tv/api/v2/pins/\(pin.id)", token: nil)
        let p = try JSONDecoder().decode(PlexPin.self, from: data)
        if let t = p.authToken, !t.isEmpty { return t }
        return nil
    }

    static func username(accountToken: String) async -> String {
        struct U: Decodable { let username: String?; let title: String? }
        guard let data = try? await request("https://plex.tv/api/v2/user", token: accountToken),
              let u = try? JSONDecoder().decode(U.self, from: data) else { return "Plex" }
        return u.username ?? u.title ?? "Plex"
    }

    static func servers(accountToken: String) async throws -> [PlexServer] {
        let data = try await request("https://plex.tv/api/v2/resources",
                                     query: [.init(name: "includeHttps", value: "1"), .init(name: "includeRelay", value: "1")],
                                     token: accountToken)
        return try JSONDecoder().decode([PlexServer].self, from: data).filter(\.isServer)
    }

    /// Trova un indirizzo funzionante del server (prima in casa, poi da remoto, infine tramite relay)
    /// e salva l'accesso.
    static func connect(_ server: PlexServer, accountToken: String, username: String) async throws {
        let token = server.accessToken ?? accountToken
        let conns = (server.connections ?? []).sorted { a, b in
            func rank(_ c: PlexServer.Connection) -> Int { c.relay == true ? 2 : (c.local == true ? 0 : 1) }
            return rank(a) < rank(b)
        }
        for c in conns {
            if (try? await request(c.uri + "/identity", token: token, timeout: 5)) != nil {
                settings.serverKind = .plex
                settings.serverName = server.name
                settings.jellyfinServer = c.uri
                settings.jellyfinUserId = server.clientIdentifier
                settings.jellyfinUserName = username
                settings.jellyfinToken = token
                return
            }
        }
        throw AppError.message("Non riesco a raggiungere \(server.name). Controlla che il server Plex sia acceso e, fuori casa, che l'accesso remoto sia attivo.")
    }

    // MARK: Conversione nel modello comune

    private static func image(_ path: String?, w: Int, h: Int) -> URL? {
        guard let path, !path.isEmpty, var c = URLComponents(string: settings.jellyfinServer + "/photo/:/transcode") else { return nil }
        c.queryItems = [
            .init(name: "width", value: String(w)), .init(name: "height", value: String(h)),
            .init(name: "minSize", value: "1"), .init(name: "upscale", value: "1"),
            .init(name: "url", value: path), .init(name: "X-Plex-Token", value: settings.jellyfinToken),
        ]
        return c.url
    }

    private static func convert(_ m: PlexMeta) -> JFItem? {
        var d: [String: Any] = ["Id": m.ratingKey]
        let t = m.type ?? ""
        switch t {
        case "movie": d["Type"] = "Movie"
        case "show": d["Type"] = "Series"
        case "season": d["Type"] = "Season"
        case "episode": d["Type"] = "Episode"
        case "clip": d["Type"] = "Video"
        default: return nil
        }
        d["Name"] = m.title ?? ""
        if let v = m.summary { d["Overview"] = v }
        if let v = m.year { d["ProductionYear"] = v }
        if let v = m.audienceRating ?? m.rating { d["CommunityRating"] = v }
        if let v = m.contentRating { d["OfficialRating"] = v }
        if let v = m.duration { d["RunTimeTicks"] = Int64(v) * 10_000 }
        if let v = m.index { d["IndexNumber"] = v }
        if let v = m.parentIndex { d["ParentIndexNumber"] = v }

        var ud: [String: Any] = [:]
        if let v = m.viewOffset { ud["PlaybackPositionTicks"] = Int64(v) * 10_000 }
        if let leaves = m.leafCount {
            let seen = m.viewedLeafCount ?? 0
            ud["UnplayedItemCount"] = max(0, leaves - seen)
            ud["Played"] = leaves > 0 && seen >= leaves
        } else {
            ud["Played"] = (m.viewCount ?? 0) > 0
        }
        d["UserData"] = ud

        if let tmdb = m.guids?.first(where: { $0.id.hasPrefix("tmdb://") }) {
            d["ProviderIds"] = ["Tmdb": String(tmdb.id.dropFirst("tmdb://".count))]
        }

        switch t {
        case "episode":
            d["SeriesId"] = m.grandparentRatingKey
            d["SeasonId"] = m.parentRatingKey
            d["SeriesName"] = m.grandparentTitle
            d["PosterOverride"] = image(m.grandparentThumb ?? m.parentThumb ?? m.thumb, w: 400, h: 600)?.absoluteString
            d["ThumbOverride"] = image(m.thumb, w: 640, h: 360)?.absoluteString
            d["BackdropOverride"] = image(m.grandparentArt ?? m.art, w: 1280, h: 720)?.absoluteString
        case "season":
            d["SeriesId"] = m.parentRatingKey
            d["SeriesName"] = m.parentTitle
            d["PosterOverride"] = image(m.thumb ?? m.parentThumb, w: 400, h: 600)?.absoluteString
            d["BackdropOverride"] = image(m.art, w: 1280, h: 720)?.absoluteString
        default:
            d["PosterOverride"] = image(m.thumb, w: 400, h: 600)?.absoluteString
            d["BackdropOverride"] = image(m.art, w: 1280, h: 720)?.absoluteString
        }
        d["ImageTags"] = ["Primary": "plex"]

        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return try? Jellyfin.decoder.decode(JFItem.self, from: data)
    }

    private static func convertAll(_ list: [PlexMeta]?) -> [JFItem] {
        (list ?? []).compactMap(convert)
    }

    // MARK: Catalogo

    static func onDeck() async throws -> [JFItem] {
        convertAll(try await server("/library/onDeck", [.init(name: "includeGuids", value: "1")]).metadata)
    }

    static func recentlyAdded() async throws -> [JFItem] {
        let list = try await server("/library/recentlyAdded", [
            .init(name: "X-Plex-Container-Start", value: "0"),
            .init(name: "X-Plex-Container-Size", value: "30"),
            .init(name: "includeGuids", value: "1"),
        ]).metadata ?? []
        var out: [JFItem] = []
        var seen = Set<String>()
        for m in list {
            // Le stagioni aggiunte diventano la serie a cui appartengono.
            if m.type == "season", let show = m.parentRatingKey {
                guard !seen.contains(show) else { continue }
                if let item = try? await Self.item(show) { out.append(item); seen.insert(show) }
                continue
            }
            if let item = convert(m), !seen.contains(item.id) {
                out.append(item)
                seen.insert(item.id)
            }
        }
        return Array(out.prefix(24))
    }

    static func items(types: String, sortBy: String, descending: Bool, search: String?, unwatched: Bool, limit: Int?) async throws -> [JFItem] {
        let wantMovies = types.contains("Movie")
        let wantShows = types.contains("Series")
        let sections = try await server("/library/sections").directory ?? []
        let sortKey: String
        switch sortBy {
        case "DateCreated": sortKey = "addedAt"
        case "ProductionYear,SortName": sortKey = "year"
        case "CommunityRating": sortKey = "audienceRating"
        case "Random": sortKey = "random"
        default: sortKey = "titleSort"
        }
        var out: [JFItem] = []
        for s in sections {
            let plexType: String
            if s.type == "movie" && wantMovies { plexType = "1" }
            else if s.type == "show" && wantShows { plexType = "2" }
            else { continue }
            var q: [URLQueryItem] = [
                .init(name: "type", value: plexType),
                .init(name: "includeGuids", value: "1"),
                .init(name: "sort", value: sortKey == "random" ? "random" : sortKey + (descending ? ":desc" : "")),
            ]
            if unwatched { q.append(.init(name: "unwatched", value: "1")) }
            if let search, !search.isEmpty { q.append(.init(name: "title", value: search)) }
            if let limit {
                q.append(.init(name: "X-Plex-Container-Start", value: "0"))
                q.append(.init(name: "X-Plex-Container-Size", value: String(limit)))
            }
            out += convertAll(try await server("/library/sections/\(s.key)/all", q).metadata)
        }
        if sortKey == "random" { out.shuffle() }
        if let limit { out = Array(out.prefix(limit)) }
        return out
    }

    static func item(_ id: String) async throws -> JFItem {
        guard let m = try await server("/library/metadata/\(id)", [.init(name: "includeGuids", value: "1")]).metadata?.first,
              let item = convert(m) else { throw AppError.http(404) }
        return item
    }

    static func children(_ id: String) async throws -> [JFItem] {
        convertAll(try await server("/library/metadata/\(id)/children", [.init(name: "includeGuids", value: "1")]).metadata)
    }

    static func allEpisodes(_ showId: String) async throws -> [JFItem] {
        convertAll(try await server("/library/metadata/\(showId)/allLeaves", [.init(name: "includeGuids", value: "1")]).metadata)
    }

    // MARK: Riproduzione

    private static func transcodeQuery(_ item: JFItem, session: String) -> [URLQueryItem] {
        let kbps = max(1000, settings.maxBitrate / 1000)
        return [
            .init(name: "path", value: "/library/metadata/\(item.id)"),
            .init(name: "mediaIndex", value: "0"),
            .init(name: "partIndex", value: "0"),
            .init(name: "protocol", value: "hls"),
            .init(name: "fastSeek", value: "1"),
            .init(name: "directPlay", value: "0"),
            .init(name: "directStream", value: "1"),
            .init(name: "directStreamAudio", value: "1"),
            .init(name: "videoQuality", value: "100"),
            .init(name: "maxVideoBitrate", value: String(kbps)),
            .init(name: "subtitles", value: "auto"),
            .init(name: "copyts", value: "1"),
            .init(name: "session", value: session),
            .init(name: "X-Plex-Session-Identifier", value: session),
            .init(name: "X-Plex-Token", value: settings.jellyfinToken),
            .init(name: "X-Plex-Client-Identifier", value: settings.deviceId),
            .init(name: "X-Plex-Product", value: "Sipario"),
            .init(name: "X-Plex-Platform", value: "iOS"),
            .init(name: "X-Plex-Device", value: UIDevice.current.model),
        ]
    }

    static func playback(for item: JFItem) async throws -> ServerPlayback {
        let session = UUID().uuidString.lowercased()
        let q = transcodeQuery(item, session: session)
        // La "decision" prepara la sessione sul server; se fallisce si prova comunque.
        _ = try? await request(settings.jellyfinServer + "/video/:/transcode/universal/decision", query: q,
                               token: settings.jellyfinToken)
        guard var c = URLComponents(string: settings.jellyfinServer + "/video/:/transcode/universal/start.m3u8") else {
            throw AppError.notLoggedIn
        }
        c.queryItems = q
        guard let u = c.url else { throw AppError.notLoggedIn }
        return ServerPlayback(url: u, itemId: item.id, mediaSourceId: item.id, session: session)
    }

    static func timeline(_ p: ServerPlayback, state: String, seconds: Double, duration: Double) async {
        _ = try? await request(settings.jellyfinServer + "/:/timeline", query: [
            .init(name: "ratingKey", value: p.itemId),
            .init(name: "key", value: "/library/metadata/\(p.itemId)"),
            .init(name: "state", value: state),
            .init(name: "time", value: String(Int(max(0, seconds) * 1000))),
            .init(name: "duration", value: String(Int(max(0, duration) * 1000))),
            .init(name: "X-Plex-Session-Identifier", value: p.session),
        ], token: settings.jellyfinToken)
    }

    static func stop(_ p: ServerPlayback, seconds: Double, duration: Double) async {
        await timeline(p, state: "stopped", seconds: seconds, duration: duration)
        _ = try? await request(settings.jellyfinServer + "/video/:/transcode/universal/stop",
                               query: [.init(name: "session", value: p.session)], token: settings.jellyfinToken)
    }
}
