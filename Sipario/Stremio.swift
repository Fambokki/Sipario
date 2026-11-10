import Foundation

// MARK: - Addon Stremio

/// Sipario parla il protocollo degli addon Stremio: una libreria è il link del manifest di un addon
/// (https://…/manifest.json oppure stremio://…/manifest.json).
/// - Gli addon con cataloghi riempiono la Home con film, serie e canali (schede ed episodi compresi).
/// - Quando premi Play, Sipario chiede il video a tutti gli addon installati che forniscono flussi per quel titolo.
/// Sono supportati i flussi con un link web (MP4, HLS…) e i link esterni; i flussi torrent no.
enum Stremio {
    /// Indirizzo interno di un titolo il cui video va chiesto agli addon al momento del Play.
    static let scheme = "sipario-stremio"
    static let cinemeta = "https://v3-cinemeta.strem.io"

    static func isManifest(_ source: String) -> Bool {
        let s = source.trimmed.lowercased()
        return s.hasPrefix("stremio://") || (s.hasPrefix("http") && (URL(string: s)?.path.hasSuffix("/manifest.json") ?? false))
    }

    static func normalize(_ source: String) -> String {
        let s = source.trimmed
        return s.lowercased().hasPrefix("stremio://") ? "https://" + s.dropFirst("stremio://".count) : s
    }

    // MARK: Manifest

    struct Resource: Sendable {
        let types: [String]
        let prefixes: [String]?
    }

    struct Addon: Sendable {
        let base: String
        let name: String
        let resources: [String: Resource]

        func supports(_ resource: String, type: String, id: String) -> Bool {
            guard let r = resources[resource], r.types.contains(type) else { return false }
            guard let prefixes = r.prefixes, !prefixes.isEmpty else { return true }
            return prefixes.contains { id.hasPrefix($0) }
        }
    }

    private static func base(of manifest: URL) -> String {
        var s = manifest.absoluteString
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if s.hasSuffix("/manifest.json") { s = String(s.dropLast("/manifest.json".count)) }
        return s
    }

    static func manifest(_ url: URL) async throws -> (Addon, [String: Any]) {
        let raw: Any
        do { raw = try await WebSources.json(url) }
        catch { throw AppError.message("Non riesco a leggere il manifest dell'addon: controlla il link.") }
        guard let m = raw as? [String: Any], m["id"] != nil else {
            throw AppError.message("Questo link non è il manifest di un addon Stremio.")
        }
        let types = m["types"] as? [String] ?? []
        let prefixes = m["idPrefixes"] as? [String]
        var resources: [String: Resource] = [:]
        for r in m["resources"] as? [Any] ?? [] {
            if let name = r as? String {
                resources[name] = Resource(types: types, prefixes: prefixes)
            } else if let d = r as? [String: Any], let name = d["name"] as? String {
                resources[name] = Resource(types: d["types"] as? [String] ?? types, prefixes: d["idPrefixes"] as? [String] ?? prefixes)
            }
        }
        let addon = Addon(base: base(of: url), name: (m["name"] as? String)?.nonEmpty ?? "Addon", resources: resources)
        return (addon, m)
    }

    private static func encode(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    static func ref(type: String, id: String) -> URL? {
        URL(string: "\(scheme)://\(type)/\(encode(id))")
    }

    // MARK: Cataloghi

    static func items(for library: Library, url: URL) async throws -> [MediaItem] {
        let (addon, m) = try await manifest(url)
        let catalogs = m["catalogs"] as? [[String: Any]] ?? []
        let lib = library.id.uuidString

        var metas: [(meta: [String: Any], group: String)] = []
        for c in catalogs {
            guard let type = c["type"] as? String, let cid = c["id"] as? String else { continue }
            let extra = c["extra"] as? [[String: Any]] ?? []
            let required = (c["extraRequired"] as? [String] ?? []) + extra.filter { $0["isRequired"] as? Bool == true }.compactMap { $0["name"] as? String }
            if !required.isEmpty { continue }   // cataloghi solo di ricerca
            let canSkip = extra.contains { $0["name"] as? String == "skip" } || (c["extraSupported"] as? [String] ?? []).contains("skip")
            let group = (c["name"] as? String)?.nonEmpty ?? addon.name

            var skip = 0
            for _ in 0..<(canSkip ? 10 : 1) {
                let path = "/catalog/\(type)/\(encode(cid))" + (skip > 0 ? "/skip=\(skip)" : "") + ".json"
                guard let u = URL(string: addon.base + path),
                      let page = try? await WebSources.json(u) as? [String: Any],
                      let batch = page["metas"] as? [[String: Any]], !batch.isEmpty else { break }
                metas += batch.map { ($0, group) }
                skip += batch.count
                if metas.count > 3000 { break }
            }
        }

        var out: [MediaItem] = []
        var seen = Set<String>()
        var series: [SeriesRef] = []
        for (meta, group) in metas {
            guard let id = meta["id"] as? String, let name = (meta["name"] as? String)?.nonEmpty,
                  let type = meta["type"] as? String else { continue }
            let kind: ItemKind = type == "series" ? .series : (["tv", "channel"].contains(type) ? .live : .movie)
            let key = stableID(lib + "|stremio|\(type)|\(id)")
            if seen.contains(key) {
                // Lo stesso titolo in più cataloghi: si tiene il primo.
                continue
            }
            seen.insert(key)
            let item = MediaItem(id: key, libraryId: library.id, kind: kind, title: name,
                                 year: (meta["releaseInfo"] as? String ?? meta["year"] as? String).flatMap { Int($0.prefix(4)) },
                                 group: group,
                                 poster: (meta["poster"] as? String).flatMap { URL(string: $0) },
                                 backdrop: (meta["background"] as? String).flatMap { URL(string: $0) },
                                 overview: (meta["description"] as? String)?.nonEmpty,
                                 genres: meta["genres"] as? [String] ?? meta["genre"] as? [String] ?? [],
                                 url: kind == .series ? nil : ref(type: type, id: id))
            if kind == .series { series.append(SeriesRef(index: out.count, type: type, id: id)) }
            out.append(item)
        }

        // Episodi delle serie, dalla scheda dell'addon (o da Cinemeta per gli id IMDb).
        let wanted = Array(series.prefix(400))
        let episodes: [(Int, [Episode])] = await WebSources.parallelMap(wanted, width: 8) { s in
            let base: String
            if addon.supports("meta", type: s.type, id: s.id) { base = addon.base }
            else if s.id.hasPrefix("tt") { base = cinemeta }
            else { return nil }
            guard let u = URL(string: base + "/meta/\(s.type)/\(encode(s.id)).json"),
                  let root = try? await WebSources.json(u) as? [String: Any],
                  let meta = root["meta"] as? [String: Any],
                  let videos = meta["videos"] as? [[String: Any]] else { return nil }
            var eps: [Episode] = []
            for (n, v) in videos.enumerated() {
                guard let vid = v["id"] as? String, let url = ref(type: s.type, id: vid) else { continue }
                eps.append(Episode(id: stableID(lib + "|ep|" + vid),
                                   season: (v["season"] as? Int) ?? 1,
                                   number: (v["episode"] as? Int) ?? (v["number"] as? Int) ?? (n + 1),
                                   title: ((v["title"] as? String) ?? (v["name"] as? String))?.nonEmpty,
                                   url: url,
                                   still: (v["thumbnail"] as? String).flatMap { URL(string: $0) }))
            }
            // Gli speciali (stagione 0) vanno in fondo.
            eps.sort { ($0.season == 0 ? 999 : $0.season, $0.number) < ($1.season == 0 ? 999 : $1.season, $1.number) }
            return (s.index, eps)
        }
        for (i, eps) in episodes { out[i].episodes = eps }
        return out.filter { $0.kind != .series || !$0.episodes.isEmpty }
    }

    private struct SeriesRef: Sendable {
        let index: Int
        let type: String
        let id: String
    }

    // MARK: Flussi

    struct StreamOption: Identifiable, Sendable {
        let id = UUID()
        let addon: String
        let label: String
        /// Video da riprodurre in Sipario.
        let url: URL?
        /// Link da aprire fuori da Sipario (es. YouTube).
        let external: URL?
        let headers: [String: String]
    }

    /// Chiede il video di un titolo a tutti gli addon installati che forniscono flussi per quel tipo e quell'id.
    static func streams(for ref: URL, addonSources: [String]) async throws -> [StreamOption] {
        guard let type = ref.host, let id = String(ref.path.dropFirst()).removingPercentEncoding, !id.isEmpty else {
            throw AppError.message("Titolo non valido.")
        }
        let manifests = addonSources.compactMap { URL(string: normalize($0)) }
        let addons: [Addon] = await WebSources.parallelMap(manifests) { u in try? await manifest(u).0 }
        let providers = addons.filter { $0.supports("stream", type: type, id: id) }
        guard !providers.isEmpty else {
            throw AppError.message("Nessuno dei tuoi addon fornisce video per questo titolo. Aggiungi tra le librerie il manifest di un addon che offre flussi (stream).")
        }

        let results: [(options: [StreamOption], torrents: Int)] = await WebSources.parallelMap(providers) { addon in
            guard let u = URL(string: addon.base + "/stream/\(type)/\(encode(id)).json"),
                  let root = try? await WebSources.json(u) as? [String: Any],
                  let list = root["streams"] as? [[String: Any]] else { return nil }
            var options: [StreamOption] = []
            var torrents = 0
            for s in list {
                let name = ((s["name"] as? String) ?? addon.name).replacingOccurrences(of: "\n", with: " ").trimmed
                let detail = ((s["title"] as? String) ?? (s["description"] as? String) ?? "")
                    .components(separatedBy: .newlines).first?.trimmed ?? ""
                let label = detail.isEmpty ? name : "\(name) · \(detail)"
                let hints = s["behaviorHints"] as? [String: Any]
                let headers = ((hints?["proxyHeaders"] as? [String: Any])?["request"] as? [String: String]) ?? [:]
                if let raw = s["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    options.append(StreamOption(addon: addon.name, label: label, url: url, external: nil, headers: headers))
                } else if let yt = s["ytId"] as? String, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") {
                    options.append(StreamOption(addon: addon.name, label: label + " (YouTube)", url: nil, external: url, headers: [:]))
                } else if let raw = s["externalUrl"] as? String, let url = URL(string: raw) {
                    options.append(StreamOption(addon: addon.name, label: label + " (esterno)", url: nil, external: url, headers: [:]))
                } else if s["infoHash"] != nil {
                    torrents += 1
                }
            }
            return (options, torrents)
        }
        let options = results.flatMap(\.options)
        guard !options.isEmpty else {
            if results.contains(where: { $0.torrents > 0 }) {
                throw AppError.message("Gli addon hanno risposto solo con flussi torrent, che Sipario non supporta.")
            }
            throw AppError.message("Nessun addon ha trovato un video per questo titolo.")
        }
        return options
    }
}
