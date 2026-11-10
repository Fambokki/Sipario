import Foundation

// MARK: - Jellyfin ed Emby

/// Importa l'intera libreria di un server Jellyfin o Emby: film, serie con stagioni ed episodi, copertine e trame.
/// Il link è l'indirizzo del server con la chiave API, ad esempio http://192.168.1.10:8096/?api_key=CHIAVE
/// (facoltativo &user=Nome per scegliere l'utente).
enum MediaServer {
    static func handles(_ url: URL) -> Bool { key(url) != nil }

    private static func key(_ url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { ["api_key", "apikey", "x-emby-token"].contains($0.name.lowercased()) }?.value?.nonEmpty
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == name }?.value?.nonEmpty
    }

    static func items(for library: Library, url: URL) async throws -> [MediaItem] {
        guard let key = key(url), let scheme = url.scheme, let host = url.host else {
            throw AppError.message("Al link del server manca la chiave API (?api_key=…).")
        }
        let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        let base = origin + (url.path.lowercased().hasPrefix("/emby") ? "/emby" : "")
        let auth = "api_key=" + (key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)

        func get(_ path: String) async throws -> Any {
            let sep = path.contains("?") ? "&" : "?"
            guard let u = URL(string: base + path + sep + auth) else { throw AppError.message("Indirizzo del server non valido.") }
            do { return try await WebSources.json(u) }
            catch AppError.http(let code) where code == 401 {
                throw AppError.message("Il server ha rifiutato la chiave API: controlla di averla copiata bene (Dashboard → Chiavi API).")
            }
        }

        // Utente: quello indicato con &user=, altrimenti il primo amministratore o il primo attivo.
        guard let users = try await get("/Users") as? [[String: Any]], !users.isEmpty else {
            throw AppError.message("Non riesco a leggere gli utenti del server: usa una chiave API creata dall'amministratore.")
        }
        let wanted = query(url, "user")?.lowercased()
        let user = users.first { ($0["Name"] as? String)?.lowercased() == wanted }
            ?? users.first { (($0["Policy"] as? [String: Any])?["IsAdministrator"] as? Bool) == true }
            ?? users[0]
        guard let uid = user["Id"] as? String else { throw AppError.message("Utente del server non valido.") }

        let fields = "Overview,Genres,ProviderIds,Path,ProductionYear"
        guard let root = try await get("/Users/\(uid)/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=\(fields)&SortBy=DateCreated&SortOrder=Descending") as? [String: Any],
              let list = root["Items"] as? [[String: Any]] else {
            throw AppError.message("Il server non ha restituito la libreria.")
        }

        let server = Server(base: base, auth: auth)

        let lib = library.id.uuidString
        var out: [MediaItem] = []
        var series: [(Int, String)] = []
        for j in list {
            guard let id = j["Id"] as? String, let name = (j["Name"] as? String)?.nonEmpty else { continue }
            let type = (j["Type"] as? String) ?? ""
            let tmdb = ((j["ProviderIds"] as? [String: Any])?["Tmdb"] as? String).flatMap { Int($0) }
            let hasBackdrop = !((j["BackdropImageTags"] as? [Any]) ?? []).isEmpty
            var item = MediaItem(id: stableID(lib + "|server|" + id), libraryId: library.id,
                                 kind: type == "Series" ? .series : .movie, title: name,
                                 year: j["ProductionYear"] as? Int,
                                 poster: server.image(id, "Primary", width: 500),
                                 backdrop: hasBackdrop ? server.image(id, "Backdrop", width: 1280) : nil,
                                 overview: (j["Overview"] as? String)?.nonEmpty,
                                 genres: (j["Genres"] as? [String]) ?? [],
                                 url: type == "Series" ? nil : server.stream(id, path: j["Path"] as? String))
            item.tmdbHint = tmdb
            if type == "Series" { series.append((out.count, id)) }
            out.append(item)
        }

        // Episodi di ogni serie, letti in parallelo.
        let episodes: [(Int, [Episode])] = await WebSources.parallelMap(series) { pair in
            let (index, sid) = pair
            guard let u = URL(string: server.base + "/Shows/\(sid)/Episodes?UserId=\(uid)&Fields=Path&" + server.auth),
                  let root = try? await WebSources.json(u) as? [String: Any],
                  let items = root["Items"] as? [[String: Any]] else { return nil }
            var eps: [Episode] = []
            for (n, e) in items.enumerated() {
                guard let eid = e["Id"] as? String, let s = server.stream(eid, path: e["Path"] as? String) else { continue }
                let hasImage = (e["ImageTags"] as? [String: Any])?["Primary"] != nil
                eps.append(Episode(id: stableID(lib + "|ep|" + eid),
                                   season: e["ParentIndexNumber"] as? Int ?? 1,
                                   number: e["IndexNumber"] as? Int ?? (n + 1),
                                   title: (e["Name"] as? String)?.nonEmpty, url: s,
                                   still: hasImage ? server.image(eid, "Primary", width: 400) : nil))
            }
            eps.sort { ($0.season, $0.number) < ($1.season, $1.number) }
            return (index, eps)
        }
        for (index, eps) in episodes { out[index].episodes = eps }
        out = out.filter { $0.kind != .series || !$0.episodes.isEmpty }
        guard !out.isEmpty else { throw AppError.message("Sul server non ci sono film o serie visibili per questo utente.") }
        return out
    }

    private struct Server: Sendable {
        let base: String
        let auth: String

        func image(_ id: String, _ kind: String, width: Int) -> URL? {
            URL(string: base + "/Items/\(id)/Images/\(kind)?maxWidth=\(width)&" + auth)
        }

        func stream(_ id: String, path: String?) -> URL? {
            let ext = ((path ?? "") as NSString).pathExtension.lowercased()
            if ["mp4", "m4v", "mov"].contains(ext) {
                return URL(string: base + "/Videos/\(id)/stream?static=true&" + auth)
            }
            // Altri formati (MKV, AVI…): il server li converte al volo in HLS, che il player di iOS legge.
            return URL(string: base + "/Videos/\(id)/master.m3u8?MediaSourceId=\(id)&DeviceId=sipario-ios&VideoCodec=h264&AudioCodec=aac&TranscodingMaxAudioChannels=2&SegmentContainer=ts&" + auth)
        }
    }
}
