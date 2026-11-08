import Foundation
import UIKit

// MARK: - Modello comune degli elementi del server personale (Jellyfin, Emby, Plex)

struct JFUserData: Codable, Hashable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let playedPercentage: Double?
    let unplayedItemCount: Int?
}

struct JFItem: Codable, Hashable, Identifiable {
    let id: String
    let name: String?
    let type: String?
    let overview: String?
    let productionYear: Int?
    let communityRating: Double?
    let officialRating: String?
    let runTimeTicks: Int64?
    let providerIds: [String: String]?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let userData: JFUserData?
    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    /// Immagini già pronte (usate per Plex, che ha un sistema diverso).
    let posterOverride: URL?
    let backdropOverride: URL?
    let thumbOverride: URL?

    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }
    var isSeason: Bool { type == "Season" }
    var isPlayable: Bool { type == "Movie" || type == "Episode" || type == "Video" || type == "MusicVideo" }

    var tmdbId: Int? { providerIds?.value(forInsensitive: "Tmdb").flatMap { Int($0) } }

    var displayName: String {
        if isEpisode, let s = parentIndexNumber, let e = indexNumber {
            return "\(seriesName ?? "") · S\(s) E\(e)"
        }
        return name ?? "Senza titolo"
    }

    var minutes: Int? { runTimeTicks.map { Int($0 / 600_000_000) } }

    var progress: Double? {
        guard let pos = userData?.playbackPositionTicks, pos > 0, let total = runTimeTicks, total > 0 else { return nil }
        return min(1, Double(pos) / Double(total))
    }

    var resumeSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / 10_000_000
    }

    var durationSeconds: Double { Double(runTimeTicks ?? 0) / 10_000_000 }

    @MainActor var posterURL: URL? {
        if let posterOverride { return posterOverride }
        if imageTags?.value(forInsensitive: "Primary") != nil {
            return Jellyfin.imageURL(id, type: "Primary", width: 400)
        }
        if let seriesId { return Jellyfin.imageURL(seriesId, type: "Primary", width: 400) }
        return Jellyfin.imageURL(id, type: "Primary", width: 400)
    }

    @MainActor var thumbURL: URL? {
        if let thumbOverride { return thumbOverride }
        // Per gli episodi la miniatura è l'immagine "Primary" dell'episodio stesso.
        if isEpisode && posterOverride == nil { return Jellyfin.imageURL(id, type: "Primary", width: 600) }
        return backdropURL ?? posterURL
    }

    @MainActor var backdropURL: URL? {
        if let backdropOverride { return backdropOverride }
        if posterOverride != nil { return nil }
        if let tags = backdropImageTags, !tags.isEmpty {
            return Jellyfin.imageURL(id, type: "Backdrop", width: 1280)
        }
        if let parent = parentBackdropItemId, let tags = parentBackdropImageTags, !tags.isEmpty {
            return Jellyfin.imageURL(parent, type: "Backdrop", width: 1280)
        }
        if let seriesId { return Jellyfin.imageURL(seriesId, type: "Backdrop", width: 1280) }
        return nil
    }
}

struct JFItems: Codable {
    let items: [JFItem]
}

private struct JFAuthResult: Codable {
    struct User: Codable { let id: String; let name: String? }
    let accessToken: String
    let user: User
}

private struct JFPlaybackInfo: Codable {
    struct Source: Codable { let id: String? }
    let mediaSources: [Source]?
    let playSessionId: String?
}

/// Dati per avviare e seguire una riproduzione dal server.
struct ServerPlayback {
    let url: URL
    let itemId: String
    let mediaSourceId: String
    let session: String
}

// MARK: - Client
//
// `Jellyfin` è la porta d'ingresso unica per il server personale: parla direttamente con
// Jellyfin ed Emby (che hanno la stessa API) e passa le richieste a `Plex` quando serve.

@MainActor
enum Jellyfin {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let raw = keys.last!.stringValue
            guard let first = raw.first else { return AnyCodingKey(stringValue: raw) }
            return AnyCodingKey(stringValue: first.lowercased() + raw.dropFirst())
        }
        return d
    }()

    static let fields = "Overview,ProviderIds,PrimaryImageAspectRatio,ParentId"

    private static var settings: AppSettings { AppSettings.shared }
    private static var isPlex: Bool { settings.serverKind == .plex }
    private static var isEmby: Bool { settings.serverKind == .emby }

    static func normalize(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }

    private static func clientFields() -> String {
        "Client=\"Sipario\", Device=\"\(UIDevice.current.model)\", DeviceId=\"\(settings.deviceId)\", Version=\"1.0.0\""
    }

    private static func applyAuth(_ req: inout URLRequest, token: String?, emby: Bool) {
        let tokenPart = (token?.isEmpty == false) ? ", Token=\"\(token!)\"" : ""
        if emby {
            req.setValue("Emby UserId=\"\(settings.jellyfinUserId)\", \(clientFields())\(tokenPart)", forHTTPHeaderField: "X-Emby-Authorization")
        } else {
            req.setValue("MediaBrowser \(clientFields())\(tokenPart)", forHTTPHeaderField: "Authorization")
        }
        if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
    }

    private static func url(_ path: String, _ query: [URLQueryItem] = [], server: String? = nil) -> URL? {
        guard var c = URLComponents(string: (server ?? settings.jellyfinServer) + path) else { return nil }
        if !query.isEmpty { c.queryItems = query }
        return c.url
    }

    @discardableResult
    private static func send(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Data {
        guard settings.hasJellyfin else { throw AppError.notLoggedIn }
        guard let u = url(path, query) else { throw AppError.message("Indirizzo del server non valido") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 20
        applyAuth(&req, token: settings.jellyfinToken, emby: isEmby)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw AppError.message("Sessione scaduta: accedi di nuovo al server nelle Impostazioni.") }
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        return data
    }

    /// Prova gli indirizzi in ordine: le versioni recenti di Jellyfin hanno cambiato alcuni percorsi,
    /// mentre Emby usa ancora quelli classici (per Emby l'ordine viene invertito).
    private static func get<T: Decodable>(_ paths: [String], _ query: [URLQueryItem]) async throws -> T {
        var lastError: Error = AppError.http(404)
        for p in (isEmby ? paths.reversed() : paths) {
            do {
                let data = try await send(p, query: query)
                return try decoder.decode(T.self, from: data)
            } catch AppError.http(let code) where code == 404 || code == 405 || code == 400 {
                lastError = AppError.http(code)
                continue
            }
        }
        throw lastError
    }

    private static var uid: String { settings.jellyfinUserId }
    private static var userQ: URLQueryItem { URLQueryItem(name: "userId", value: uid) }

    // MARK: Accesso (Jellyfin / Emby)

    static func login(kind: ServerKind, server: String, username: String, password: String) async throws {
        let base = normalize(server)
        guard let u = url("/Users/AuthenticateByName", server: base) else {
            throw AppError.message("Indirizzo del server non valido")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        applyAuth(&req, token: nil, emby: kind == .emby)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw AppError.message("Server non raggiungibile. Controlla l'indirizzo (es. http://192.168.1.10:8096) e di essere sulla stessa rete.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw AppError.message("Nome utente o password errati.") }
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        let r = try decoder.decode(JFAuthResult.self, from: data)
        settings.serverKind = kind
        settings.serverName = kind.name
        settings.jellyfinServer = base
        settings.jellyfinUserId = r.user.id
        settings.jellyfinUserName = r.user.name ?? username
        settings.jellyfinToken = r.accessToken
    }

    // MARK: Catalogo

    static func resume() async throws -> [JFItem] {
        if isPlex { return try await Plex.onDeck() }
        let q: [URLQueryItem] = [userQ, .init(name: "Limit", value: "20"), .init(name: "MediaTypes", value: "Video"), .init(name: "Fields", value: fields)]
        let r: JFItems = try await get(["/UserItems/Resume", "/Users/\(uid)/Items/Resume"], q)
        return r.items
    }

    static func nextUp() async throws -> [JFItem] {
        if isPlex { return [] }  // In Plex i prossimi episodi sono già in "Continua a guardare".
        let q: [URLQueryItem] = [userQ, .init(name: "Limit", value: "20"), .init(name: "Fields", value: fields)]
        let r: JFItems = try await get(["/Shows/NextUp"], q)
        return r.items
    }

    static func latest() async throws -> [JFItem] {
        if isPlex { return try await Plex.recentlyAdded() }
        let q: [URLQueryItem] = [userQ, .init(name: "Limit", value: "24"), .init(name: "Fields", value: fields),
                                 .init(name: "IncludeItemTypes", value: "Movie,Series,Episode"), .init(name: "GroupItems", value: "true")]
        let r: [JFItem] = try await get(["/Items/Latest", "/Users/\(uid)/Items/Latest"], q)
        return r
    }

    static func items(types: String, sortBy: String = "SortName", descending: Bool = false,
                      search: String? = nil, filters: String? = nil, limit: Int? = nil) async throws -> [JFItem] {
        if isPlex {
            return try await Plex.items(types: types, sortBy: sortBy, descending: descending,
                                        search: search, unwatched: filters == "IsUnplayed", limit: limit)
        }
        var q = [userQ,
                 URLQueryItem(name: "Recursive", value: "true"),
                 URLQueryItem(name: "IncludeItemTypes", value: types),
                 URLQueryItem(name: "SortBy", value: sortBy),
                 URLQueryItem(name: "SortOrder", value: descending ? "Descending" : "Ascending"),
                 URLQueryItem(name: "Fields", value: fields)]
        if let search, !search.isEmpty { q.append(URLQueryItem(name: "SearchTerm", value: search)) }
        if let filters { q.append(URLQueryItem(name: "Filters", value: filters)) }
        if let limit { q.append(URLQueryItem(name: "Limit", value: String(limit))) }
        let r: JFItems = try await get(["/Items", "/Users/\(uid)/Items"], q)
        return r.items
    }

    static func item(_ id: String) async throws -> JFItem {
        if isPlex { return try await Plex.item(id) }
        return try await get(["/Items/\(id)", "/Users/\(uid)/Items/\(id)"], [userQ])
    }

    static func seasons(seriesId: String) async throws -> [JFItem] {
        if isPlex { return try await Plex.children(seriesId).filter { $0.isSeason } }
        let r: JFItems = try await get(["/Shows/\(seriesId)/Seasons"], [userQ, .init(name: "Fields", value: fields)])
        return r.items
    }

    static func episodes(seriesId: String, seasonId: String? = nil) async throws -> [JFItem] {
        if isPlex {
            if let seasonId { return try await Plex.children(seasonId) }
            return try await Plex.allEpisodes(seriesId)
        }
        var q = [userQ, URLQueryItem(name: "Fields", value: fields)]
        if let seasonId { q.append(URLQueryItem(name: "seasonId", value: seasonId)) }
        let r: JFItems = try await get(["/Shows/\(seriesId)/Episodes"], q)
        return r.items
    }

    // MARK: Immagini e streaming

    static func imageURL(_ id: String, type: String, width: Int) -> URL? {
        guard settings.hasJellyfin, !isPlex else { return nil }
        return url("/Items/\(id)/Images/\(type)", [.init(name: "maxWidth", value: String(width)), .init(name: "quality", value: "85")])
    }

    /// Prepara la riproduzione: chiede al server il flusso giusto per questo elemento.
    static func playback(for item: JFItem) async throws -> ServerPlayback {
        if isPlex { return try await Plex.playback(for: item) }
        var session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var source = item.id
        // PlaybackInfo restituisce l'id della versione del file (necessario per Emby e per i film con più versioni).
        if let data = try? await send("/Items/\(item.id)/PlaybackInfo", query: [userQ, .init(name: "UserId", value: uid)],
                                      method: "POST", body: Data("{}".utf8)),
           let info = try? decoder.decode(JFPlaybackInfo.self, from: data) {
            if let s = info.mediaSources?.first?.id, !s.isEmpty { source = s }
            if let p = info.playSessionId, !p.isEmpty { session = p }
        }
        let token = settings.jellyfinToken
        guard let u = url("/Videos/\(item.id)/master.m3u8", [
            .init(name: "MediaSourceId", value: source),
            .init(name: "DeviceId", value: settings.deviceId),
            .init(name: "PlaySessionId", value: session),
            .init(name: "api_key", value: token),
            .init(name: "VideoCodec", value: "h264,hevc"),
            .init(name: "AudioCodec", value: "aac,mp3,ac3,eac3"),
            .init(name: "TranscodingMaxAudioChannels", value: "6"),
            .init(name: "MaxStreamingBitrate", value: String(settings.maxBitrate)),
            .init(name: "VideoBitrate", value: String(max(1_000_000, settings.maxBitrate - 384_000))),
            .init(name: "AudioBitrate", value: "384000"),
            .init(name: "SegmentContainer", value: "mp4"),
            .init(name: "MinSegments", value: "1"),
            .init(name: "BreakOnNonKeyFrames", value: "True"),
            .init(name: "RequireAvc", value: "false"),
            .init(name: "SubtitleMethod", value: "Hls"),
        ]) else { throw AppError.notLoggedIn }
        return ServerPlayback(url: u, itemId: item.id, mediaSourceId: source, session: session)
    }

    // MARK: Avanzamento (così "Continua a guardare" resta allineato anche sugli altri dispositivi)

    private static func report(_ path: String, _ p: ServerPlayback, seconds: Double, paused: Bool = false) async {
        let body: [String: Any] = [
            "ItemId": p.itemId,
            "MediaSourceId": p.mediaSourceId,
            "PlaySessionId": p.session,
            "PositionTicks": Int64(max(0, seconds) * 10_000_000),
            "CanSeek": true,
            "IsPaused": paused,
            "PlayMethod": "Transcode",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        _ = try? await send(path, method: "POST", body: data)
    }

    static func reportStart(_ p: ServerPlayback, seconds: Double, duration: Double) async {
        if isPlex { await Plex.timeline(p, state: "playing", seconds: seconds, duration: duration); return }
        await report("/Sessions/Playing", p, seconds: seconds)
    }

    static func reportProgress(_ p: ServerPlayback, seconds: Double, duration: Double, paused: Bool) async {
        if isPlex { await Plex.timeline(p, state: paused ? "paused" : "playing", seconds: seconds, duration: duration); return }
        await report("/Sessions/Playing/Progress", p, seconds: seconds, paused: paused)
    }

    static func reportStopped(_ p: ServerPlayback, seconds: Double, duration: Double) async {
        if isPlex { await Plex.stop(p, seconds: seconds, duration: duration); return }
        await report("/Sessions/Playing/Stopped", p, seconds: seconds)
        _ = try? await send("/Videos/ActiveEncodings", query: [
            .init(name: "deviceId", value: settings.deviceId),
            .init(name: "playSessionId", value: p.session),
        ], method: "DELETE")
    }
}

// MARK: - Indice della libreria (per collegare i titoli TMDB ai tuoi file)

@MainActor
final class JellyfinLibrary: ObservableObject {
    static let shared = JellyfinLibrary()

    @Published private(set) var movies: [Int: JFItem] = [:]
    @Published private(set) var series: [Int: JFItem] = [:]
    @Published private(set) var resume: [JFItem] = []
    @Published private(set) var nextUp: [JFItem] = []
    @Published private(set) var latest: [JFItem] = []
    @Published private(set) var lastError: String?
    private var lastIndex: Date?
    private var indexedServer = ""

    func match(_ kind: MediaKind, _ tmdbId: Int) -> JFItem? {
        kind == .movie ? movies[tmdbId] : series[tmdbId]
    }

    func refresh(force: Bool = false) async {
        let settings = AppSettings.shared
        guard settings.hasJellyfin else {
            movies = [:]; series = [:]; resume = []; nextUp = []; latest = []
            lastIndex = nil
            return
        }
        do {
            async let r = Jellyfin.resume()
            async let n = Jellyfin.nextUp()
            async let l = Jellyfin.latest()
            resume = (try? await r) ?? []
            nextUp = (try? await n) ?? []
            latest = try await l
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // L'indice completo serve solo ogni tanto (o se è cambiato il server).
        let serverKey = settings.serverKind.rawValue + settings.jellyfinServer
        if force || lastIndex == nil || indexedServer != serverKey || Date().timeIntervalSince(lastIndex!) > 600 {
            if let all = try? await Jellyfin.items(types: "Movie,Series") {
                var m: [Int: JFItem] = [:], s: [Int: JFItem] = [:]
                for item in all {
                    guard let t = item.tmdbId else { continue }
                    if item.isSeries { s[t] = item } else { m[t] = item }
                }
                movies = m
                series = s
                lastIndex = Date()
                indexedServer = serverKey
            }
        }
    }
}
