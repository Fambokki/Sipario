import Foundation

// MARK: - Riconoscimento dei titoli dai nomi

enum NameParser {
    struct Parsed {
        var title: String
        var year: Int?
        var season: Int?
        var episode: Int?
        var episodeTitle: String?
    }

    private static let junk = "\\b(2160p|1080p|720p|576p|480p|4k|uhd|hdr10|hdr|dv|x264|x265|h ?264|h ?265|hevc|avc|bluray|blu-ray|brrip|bdrip|bdmux|web-?dl|web-?rip|webmux|dvdrip|dvdscr|hdtv|hdrip|remux|ac3|aac|dts|ddp?5 ?1|ita|eng|multi|sub ?ita|subbed|dubbed|extended|proper|repack)\\b"

    static func parse(_ raw: String) -> Parsed {
        var s = raw
        let ext = (s as NSString).pathExtension.lowercased()
        if Importer.videoExtensions.contains(ext) { s = (s as NSString).deletingPathExtension }
        s = s.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)

        var season: Int?
        var episode: Int?
        var episodeTitle: String?
        let patterns = [
            "\\bS(\\d{1,2}) ?[-xE]? ?E(\\d{1,3})\\b",
            "\\b(\\d{1,2})x(\\d{2,3})\\b",
            "\\bStagione ?(\\d{1,2}) ?[-,]? ?Episodio ?(\\d{1,3})\\b",
            "\\bSeason ?(\\d{1,2}) ?[-,]? ?Episode ?(\\d{1,3})\\b",
        ]
        for p in patterns {
            if let hit = firstHit(p, in: s) {
                season = Int(hit.groups.first.flatMap { $0 } ?? "")
                episode = Int(hit.groups.dropFirst().first.flatMap { $0 } ?? "")
                episodeTitle = clean(String(s[hit.range.upperBound...])).nonEmpty
                s = String(s[..<hit.range.lowerBound])
                break
            }
        }

        var year: Int?
        if let hit = lastHit("[\\(\\[](19[0-9]{2}|20[0-9]{2})[\\)\\]]", in: s), hit.range.lowerBound > s.startIndex {
            year = Int(hit.groups.first.flatMap { $0 } ?? "")
            s = String(s[..<hit.range.lowerBound])
        } else if let hit = lastHit("\\b(19[2-9][0-9]|20[0-3][0-9])\\b", in: s), hit.range.lowerBound > s.startIndex {
            year = Int(hit.groups.first.flatMap { $0 } ?? "")
            s = String(s[..<hit.range.lowerBound])
        }
        return Parsed(title: clean(s), year: year, season: season, episode: episode, episodeTitle: episodeTitle)
    }

    static func clean(_ input: String) -> String {
        var s = input
        if let hit = firstHit(junk, in: s), hit.range.lowerBound > s.startIndex {
            s = String(s[..<hit.range.lowerBound])
        }
        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:|,;()[]+")))
    }

    /// "Season 2", "Stagione 02", "S2" → 2
    static func seasonNumber(fromFolder name: String) -> Int? {
        guard let hit = firstHit("^(?:season|stagione|serie|s)\\s*0*(\\d{1,2})\\b", in: name.trimmed) else { return nil }
        return Int(hit.groups.first.flatMap { $0 } ?? "")
    }
}

// MARK: - Importazione

enum Importer {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "3gp", "ogv"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    struct Entry {
        var title: String
        var url: URL
        var logo: URL?
        var group: String?
        var seriesHint: String?
        var seasonHint: Int?
        var guess: ItemKind
        var folderKey: String?
    }

    // MARK: Scaricamento

    static func download(_ url: URL, timeout: TimeInterval = 60) async throws -> (Data, String?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Sipario/2.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw AppError.message("Non riesco a raggiungere l'indirizzo. Controlla il link e la connessione.")
        }
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        return (data, http?.value(forHTTPHeaderField: "Content-Type"))
    }

    static func isDirectVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Legge una libreria (testo già scaricato) e restituisce film, serie e canali.
    static func items(for library: Library, data: Data, contentType: String?, base: URL?) async throws -> [MediaItem] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let head = String(text.prefix(4000)).trimmed
        let lowerHead = head.lowercased()

        if head.hasPrefix("{") || head.hasPrefix("[") {
            return try parseJSON(data, library: library, base: base)
        }
        if text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-TARGETDURATION") {
            // È un singolo flusso HLS, non un elenco.
            guard let base else { throw AppError.message("Questo file è un singolo flusso video: aggiungilo come link.") }
            let guess: ItemKind = library.hint == .movies || library.hint == .series ? .movie : .live
            return build([Entry(title: library.name, url: base, guess: guess)], library: library)
        }
        if text.contains("#EXTM3U") || text.contains("#EXTINF") {
            let entries = parseM3U(text, base: base)
            guard !entries.isEmpty else { throw AppError.message("La playlist non contiene video.") }
            return build(entries, library: library)
        }
        if lowerHead.contains("<html") || lowerHead.contains("<a ") || lowerHead.contains("<!doctype") || (contentType ?? "").contains("html") {
            guard let base else { throw AppError.message("Le cartelle web vanno aggiunte con il loro link.") }
            return try await crawl(root: base, firstPage: text, library: library)
        }
        throw AppError.message("Formato non riconosciuto. Sono supportate playlist M3U, cataloghi JSON e cartelle web con file video.")
    }

    // MARK: M3U

    static func parseM3U(_ text: String, base: URL?) -> [Entry] {
        var out: [Entry] = []
        var title: String?
        var logo: URL?
        var group: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                title = extinfTitle(line)?.nonEmpty ?? attribute("tvg-name", in: line)
                logo = attribute("tvg-logo", in: line).flatMap { URL(string: $0) }
                group = attribute("group-title", in: line)
                continue
            }
            if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8)).nonEmpty
                continue
            }
            if line.hasPrefix("#") { continue }
            let resolved = URL(string: line, relativeTo: base)
                ?? URL(string: line.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "", relativeTo: base)
            if let url = resolved?.absoluteURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                let t = title ?? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                out.append(Entry(title: t, url: url, logo: logo, group: group, seriesHint: group,
                                 guess: autoKind(url: url, group: group)))
            }
            title = nil
            logo = nil
            group = nil
        }
        return out
    }

    /// Il titolo è dopo la prima virgola che non sta dentro un attributo tra virgolette.
    private static func extinfTitle(_ line: String) -> String? {
        var inQuotes = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if c == "\"" { inQuotes.toggle() }
            if c == "," && !inQuotes {
                return String(line[line.index(after: idx)...]).trimmed
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=\"", options: .caseInsensitive) else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end]).nonEmpty
    }

    static func autoKind(url: URL, group: String?) -> ItemKind {
        let path = url.path.lowercased()
        if path.contains("/movie/") || path.contains("/movies/") || path.contains("/film/") || path.contains("/vod/") { return .movie }
        if path.contains("/series/") || path.contains("/serie/") { return .series }
        if path.contains("/live/") { return .live }
        let g = (group ?? "").lowercased()
        if ["serie", "series", "show", "stagion", "season"].contains(where: { g.contains($0) }) { return .series }
        if ["film", "movie", "cinema", "vod"].contains(where: { g.contains($0) }) { return .movie }
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) && ext != "ts" { return .movie }
        return .live
    }

    // MARK: Catalogo JSON

    private struct FlexInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i }
            else if let d = try? c.decode(Double.self) { value = Int(d) }
            else if let s = try? c.decode(String.self) { value = Int(s.prefix(4)) ?? Int(s) }
            else { value = nil }
        }
    }

    private struct JEpisode: Decodable {
        var season: FlexInt?
        var episode: FlexInt?
        var number: FlexInt?
        var title: String?
        var name: String?
        var url: String?
        var stream: String?
        var still: String?
        var image: String?
        var thumbnail: String?
    }

    private struct JSeason: Decodable {
        var season: FlexInt?
        var number: FlexInt?
        var episodes: [JEpisode]?
    }

    private struct JItem: Decodable {
        var type: String?
        var title: String?
        var name: String?
        var year: FlexInt?
        var poster: String?
        var image: String?
        var logo: String?
        var backdrop: String?
        var fanart: String?
        var overview: String?
        var description: String?
        var plot: String?
        var genres: [String]?
        var genre: String?
        var group: String?
        var category: String?
        var url: String?
        var stream: String?
        var seasons: [JSeason]?
        var episodes: [JEpisode]?
        var tmdb: FlexInt?
        var tmdbId: FlexInt?

        func with(type t: String) -> JItem {
            var c = self
            if c.type == nil { c.type = t }
            return c
        }
    }

    private struct JCatalog: Decodable {
        var name: String?
        var items: [JItem]?
        var movies: [JItem]?
        var films: [JItem]?
        var series: [JItem]?
        var shows: [JItem]?
        var live: [JItem]?
        var channels: [JItem]?
    }

    static func parseJSON(_ data: Data, library: Library, base: URL?) throws -> [MediaItem] {
        let dec = JSONDecoder()
        var list: [JItem] = []
        if let arr = try? dec.decode([JItem].self, from: data) {
            list = arr
        } else {
            let c: JCatalog
            do { c = try dec.decode(JCatalog.self, from: data) }
            catch { throw AppError.message("Il catalogo JSON non è valido: controlla il formato nelle Impostazioni → Formati supportati.") }
            list = (c.items ?? [])
                + ((c.movies ?? []) + (c.films ?? [])).map { $0.with(type: "movie") }
                + ((c.series ?? []) + (c.shows ?? [])).map { $0.with(type: "series") }
                + ((c.live ?? []) + (c.channels ?? [])).map { $0.with(type: "live") }
        }

        func resolve(_ s: String?) -> URL? {
            guard let s = s?.nonEmpty else { return nil }
            return URL(string: s, relativeTo: base)?.absoluteURL
                ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "", relativeTo: base)?.absoluteURL
        }

        let lib = library.id.uuidString
        var out: [MediaItem] = []
        var seen = Set<String>()
        for j in list {
            let title = (j.title ?? j.name)?.nonEmpty ?? "Senza titolo"
            let hasEpisodes = j.seasons != nil || j.episodes != nil
            var type = (j.type ?? (hasEpisodes ? "series" : "movie")).lowercased()
            if ["tv", "show", "serie", "tvshow"].contains(type) { type = "series" }
            if ["channel", "canale", "diretta"].contains(type) { type = "live" }
            if library.hint == .live { type = "live" }
            let genres = j.genres ?? (j.genre.map { $0.split(separator: ",").map { String($0).trimmed } } ?? [])
            let poster = resolve(j.poster ?? j.image ?? j.logo)
            let backdrop = resolve(j.backdrop ?? j.fanart)
            let overview = (j.overview ?? j.description ?? j.plot)?.nonEmpty
            let tmdb = j.tmdb?.value ?? j.tmdbId?.value

            if type == "series" {
                var eps: [Episode] = []
                func add(_ e: JEpisode, season: Int, fallbackNumber: Int) {
                    guard let u = resolve(e.url ?? e.stream) else { return }
                    eps.append(Episode(id: stableID(lib + "|ep|" + u.absoluteString),
                                       season: e.season?.value ?? season,
                                       number: e.episode?.value ?? e.number?.value ?? fallbackNumber,
                                       title: (e.title ?? e.name)?.nonEmpty, url: u,
                                       still: resolve(e.still ?? e.image ?? e.thumbnail)))
                }
                for (si, s) in (j.seasons ?? []).enumerated() {
                    let n = s.season?.value ?? s.number?.value ?? (si + 1)
                    for (ei, e) in (s.episodes ?? []).enumerated() { add(e, season: n, fallbackNumber: ei + 1) }
                }
                for (ei, e) in (j.episodes ?? []).enumerated() { add(e, season: 1, fallbackNumber: ei + 1) }
                guard !eps.isEmpty else { continue }
                eps.sort { ($0.season, $0.number) < ($1.season, $1.number) }
                let id = stableID(lib + "|series|" + normalizeKey(title) + "|\(j.year?.value ?? 0)")
                guard seen.insert(id).inserted else { continue }
                out.append(MediaItem(id: id, libraryId: library.id, kind: .series, title: title, year: j.year?.value,
                                     group: (j.group ?? j.category)?.nonEmpty, poster: poster, backdrop: backdrop,
                                     overview: overview, genres: genres, url: nil, episodes: eps, tmdbHint: tmdb))
            } else {
                guard let u = resolve(j.url ?? j.stream) else { continue }
                let kind: ItemKind = type == "live" ? .live : .movie
                let id = stableID(lib + "|\(kind.rawValue)|" + u.absoluteString)
                guard seen.insert(id).inserted else { continue }
                out.append(MediaItem(id: id, libraryId: library.id, kind: kind, title: title, year: j.year?.value,
                                     group: (j.group ?? j.category)?.nonEmpty, poster: poster, backdrop: backdrop,
                                     overview: overview, genres: genres, url: u, tmdbHint: tmdb))
            }
        }
        guard !out.isEmpty else { throw AppError.message("Il catalogo non contiene titoli con un link video.") }
        return out
    }

    // MARK: Cartelle web (indice dei file di un NAS o di un server)

    private static func hrefs(_ html: String) -> [String] {
        regexMatches("href\\s*=\\s*[\"']([^\"'#]+)[\"']", in: html).compactMap { m in
            regexHit(m, in: html)?.groups.first.flatMap { $0 }
        }
    }

    private static func fetchText(_ url: URL) async -> String? {
        guard let (data, _) = try? await download(url, timeout: 30) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func crawl(root: URL, firstPage: String, library: Library) async throws -> [MediaItem] {
        let rootURL = root.absoluteString.hasSuffix("/") ? root : URL(string: root.absoluteString + "/") ?? root
        var entries: [Entry] = []
        var folderImages: [String: URL] = [:]
        var visited: Set<String> = [rootURL.absoluteString]
        var level: [(URL, [String])] = [(rootURL, [])]
        var pages: [String: String] = [rootURL.absoluteString: firstPage]
        var fetched = 0

        for depth in 0...5 {
            if level.isEmpty || fetched > 400 || entries.count > 8000 { break }
            let toFetch = level.map(\.0).filter { pages[$0.absoluteString] == nil }
            fetched += toFetch.count
            await withTaskGroup(of: (String, String?).self) { group in
                var iterator = toFetch.makeIterator()
                for _ in 0..<6 {
                    if let u = iterator.next() { group.addTask { (u.absoluteString, await fetchText(u)) } }
                }
                while let result = await group.next() {
                    pages[result.0] = result.1
                    if let u = iterator.next() { group.addTask { (u.absoluteString, await fetchText(u)) } }
                }
            }

            var next: [(URL, [String])] = []
            for (folderURL, folders) in level {
                guard let html = pages[folderURL.absoluteString] else { continue }
                let current = folderURL.absoluteString
                for href in hrefs(html) {
                    if href.hasPrefix("?") || href.hasPrefix("..") || href.lowercased().hasPrefix("mailto:") || href.lowercased().hasPrefix("javascript:") { continue }
                    guard let u = URL(string: href, relativeTo: folderURL)?.absoluteURL
                            ?? URL(string: href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "", relativeTo: folderURL)?.absoluteURL
                    else { continue }
                    let s = u.absoluteString
                    // Solo i file e le cartelle dentro quella attuale.
                    guard s.hasPrefix(current), s != current else { continue }
                    let name = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
                    if s.hasSuffix("/") {
                        if depth < 5, visited.insert(s).inserted { next.append((u, folders + [name])) }
                        continue
                    }
                    let ext = u.pathExtension.lowercased()
                    if videoExtensions.contains(ext) {
                        let joined = folders.joined(separator: "/").lowercased()
                        let seriesLike = ["serie", "series", "season", "stagion", "tv show", "tvshow", "anime"].contains { joined.contains($0) }
                        let seasonHint = folders.last.flatMap { NameParser.seasonNumber(fromFolder: $0) }
                        var seriesFolder = folders.last
                        if seasonHint != nil, folders.count >= 2 { seriesFolder = folders[folders.count - 2] }
                        entries.append(Entry(title: name, url: u, group: folders.first,
                                             seriesHint: seriesFolder.map { NameParser.parse($0).title },
                                             seasonHint: seasonHint,
                                             guess: (seriesLike || seasonHint != nil) ? .series : .movie,
                                             folderKey: current))
                    } else if imageExtensions.contains(ext) {
                        let lower = name.lowercased()
                        if ["poster", "folder", "cover", "locandina", "show"].contains(where: { lower.hasPrefix($0) }) {
                            folderImages[current] = u
                        }
                    }
                }
            }
            level = next
        }
        guard !entries.isEmpty else { throw AppError.message("Non ho trovato file video in questa cartella o nelle sue sottocartelle.") }
        return build(entries, library: library, folderImages: folderImages)
    }

    // MARK: Costruzione di film, serie e canali

    static func build(_ entries: [Entry], library: Library, folderImages: [String: URL] = [:]) -> [MediaItem] {
        let lib = library.id.uuidString
        var items: [MediaItem] = []
        var seriesIndex: [String: Int] = [:]
        var counters: [String: Int] = [:]
        var seen = Set<String>()

        func folderImage(_ key: String?) -> URL? {
            guard let key else { return nil }
            if let img = folderImages[key] { return img }
            guard let u = URL(string: key) else { return nil }
            return folderImages[u.deletingLastPathComponent().absoluteString]
        }

        for e in entries {
            let urlString = e.url.absoluteString
            guard seen.insert(urlString).inserted else { continue }
            let p = NameParser.parse(e.title)
            let kind: ItemKind
            switch library.hint {
            case .live: kind = .live
            case .movies: kind = .movie
            case .series: kind = .series
            case .auto: kind = p.episode != nil ? .series : e.guess
            }
            let image = e.logo ?? folderImage(e.folderKey)

            switch kind {
            case .live:
                items.append(MediaItem(id: stableID(lib + "|live|" + urlString), libraryId: library.id, kind: .live,
                                       title: e.title.trimmed, group: e.group, poster: e.logo, url: e.url))
            case .movie:
                items.append(MediaItem(id: stableID(lib + "|movie|" + urlString), libraryId: library.id, kind: .movie,
                                       title: p.title.nonEmpty ?? e.title.trimmed, year: p.year, group: e.group,
                                       poster: image, url: e.url))
            case .series:
                let explicit = p.episode != nil && !p.title.isEmpty
                let name = explicit ? p.title : (e.seriesHint?.nonEmpty ?? e.group?.nonEmpty ?? p.title.nonEmpty ?? e.title.trimmed)
                let key = normalizeKey(name)
                let idx: Int
                if let i = seriesIndex[key] {
                    idx = i
                } else {
                    let group = (e.group.map(normalizeKey) == key) ? nil : e.group
                    items.append(MediaItem(id: stableID(lib + "|series|" + key), libraryId: library.id, kind: .series,
                                           title: name, year: p.year, group: group, poster: image, url: nil))
                    idx = items.count - 1
                    seriesIndex[key] = idx
                }
                if items[idx].poster == nil { items[idx].poster = image }
                let season = p.season ?? e.seasonHint ?? 1
                let counterKey = key + "#\(season)"
                let number = p.episode ?? ((counters[counterKey] ?? 0) + 1)
                counters[counterKey] = max(counters[counterKey] ?? 0, number)
                let epTitle = p.episodeTitle ?? (p.episode == nil ? p.title.nonEmpty : nil)
                let still = (e.logo != nil && e.logo != items[idx].poster) ? e.logo : nil
                items[idx].episodes.append(Episode(id: stableID(lib + "|ep|" + urlString), season: season, number: number,
                                                   title: epTitle, url: e.url, still: still))
            }
        }
        for i in items.indices where items[i].kind == .series {
            items[i].episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }
        }
        return items
    }
}
