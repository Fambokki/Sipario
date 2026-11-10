import Foundation
import UIKit
import WebKit

// MARK: - Video trovati su siti web

/// Un video trovato da un adattatore o da una pagina web.
struct FoundVideo {
    var title: String
    var url: URL
    var poster: URL?
    var overview: String?
    var year: Int?
    var genres: [String] = []
    var live = false
    /// Pagina da cui proviene il flusso: alcuni server lo chiedono come Referer.
    var referer: URL?
}

enum WebSources {

    // MARK: Adattatori dedicati

    /// Titoli da un sito con un adattatore dedicato, oppure nil se l'indirizzo non è di uno di questi siti.
    static func adapterItems(for library: Library, url: URL) async throws -> [MediaItem]? {
        if Stremio.isManifest(url.absoluteString) {
            return try await Stremio.items(for: library, url: url)
        }
        if StreamingServices.handles(url) {
            return try await StreamingServices.items(for: library, url: url)
        }
        if MediaServer.handles(url) {
            return try await MediaServer.items(for: library, url: url)
        }
        if InternetArchive.handles(url) {
            return try await InternetArchive.items(for: library, url: url)
        }
        if PeerTube.looksLikePeerTube(url), await PeerTube.isInstance(url) {
            return try await PeerTube.items(for: library, url: url)
        }
        return nil
    }

    // MARK: Flussi cercati al momento della visione

    /// I cataloghi grandi si importano senza i link ai video: il flusso si cerca quando premi Play.
    static func resolveStream(_ kind: String, page: URL) async throws -> URL {
        switch kind {
        case InternetArchive.lazyKind:
            let parts = page.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2, let meta = URL(string: "https://archive.org/metadata/\(parts[1])"),
                  let root = try await json(meta) as? [String: Any],
                  let first = InternetArchive.videosOf(id: parts[1], root: root).first else {
                throw AppError.message("Questo titolo di Internet Archive non ha più un video riproducibile.")
            }
            return first.url
        case PeerTube.lazyKind:
            guard let scheme = page.scheme, let host = page.host, let id = page.pathComponents.last,
                  let v = await PeerTube.video(id, origin: "\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? "")) else {
                throw AppError.message("Questo video PeerTube non è più disponibile.")
            }
            return v.url
        default:
            throw AppError.message("Non so come aprire questo titolo.")
        }
    }

    // MARK: Pagine web qualsiasi

    /// Cerca il video di una pagina: prima leggendo l'HTML, poi aprendola in un browser invisibile.
    static func pageItems(for library: Library, url: URL, html: String?) async throws -> [MediaItem] {
        var meta = PageMeta()
        if let html {
            meta = PageMeta(html: html)
            // Video incorporati da siti con un adattatore (es. un embed di Internet Archive o PeerTube).
            for frame in iframeSources(html, base: url) {
                if let items = try? await adapterItems(for: library, url: frame), !items.isEmpty { return items }
            }
            let found = staticCandidates(html, base: url)
            if !found.isEmpty {
                return make(found.map { meta.video($0, page: url) }, library: library, seriesTitle: meta.title)
            }
        }

        let scan = try await PageSniffer.sniff(url)
        if scan.drm {
            throw AppError.message("Questa pagina protegge il video con DRM: Sipario non può importarlo. Guardalo sull'app o sul sito ufficiale.")
        }
        for frame in scan.iframes {
            if let items = try? await adapterItems(for: library, url: frame), !items.isEmpty { return items }
        }
        meta.merge(scan.meta)
        guard let best = bestCandidate(scan.videos.map(\.url)) else {
            throw AppError.message("Non ho trovato un video in questa pagina. Funzionano le pagine con un video in chiaro (MP4 o HLS), Internet Archive, PeerTube e le cartelle web con file video.")
        }
        let referer = scan.videos.first { $0.url == best }?.frame ?? url
        var video = meta.video(best, page: url)
        video.referer = referer
        return make([video], library: library, seriesTitle: nil)
    }

    // MARK: Lettura dell'HTML

    struct PageMeta {
        var title: String?
        var image: URL?
        var description: String?

        init() {}

        init(html: String) {
            title = WebSources.metaContent(["og:title", "twitter:title"], in: html)
                ?? firstHit("<title[^>]*>([^<]+)</title>", in: html)?.groups.first.flatMap { $0 }.map(WebSources.decodeEntities)
            image = WebSources.metaContent(["og:image", "og:image:url", "twitter:image"], in: html).flatMap { URL(string: $0) }
            description = WebSources.metaContent(["og:description", "description", "twitter:description"], in: html)
        }

        mutating func merge(_ other: PageMeta) {
            title = title ?? other.title
            image = image ?? other.image
            description = description ?? other.description
        }

        func video(_ url: URL, page: URL) -> FoundVideo {
            let name = title?.nonEmpty ?? page.host ?? url.lastPathComponent
            let parsed = NameParser.parse(name)
            return FoundVideo(title: parsed.title.nonEmpty ?? name, url: url, poster: image,
                              overview: description, year: parsed.year, referer: page)
        }
    }

    static func metaContent(_ names: [String], in html: String) -> String? {
        for name in names {
            let n = NSRegularExpression.escapedPattern(for: name)
            let patterns = [
                "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(n)[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)[\"']",
                "<meta[^>]+content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*(?:property|name)\\s*=\\s*[\"']\(n)[\"']",
            ]
            for p in patterns {
                if let v = firstHit(p, in: html)?.groups.first.flatMap({ $0 })?.nonEmpty { return decodeEntities(v) }
            }
        }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmed
    }

    static func stripTags(_ s: String?) -> String? {
        guard let s else { return nil }
        let text = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text).nonEmpty
    }

    private static func resolve(_ raw: String, base: URL) -> URL? {
        let s = decodeEntities(raw.replacingOccurrences(of: "\\/", with: "/"))
        guard !s.hasPrefix("blob:"), !s.hasPrefix("data:"), !s.hasPrefix("javascript:") else { return nil }
        guard let u = URL(string: s, relativeTo: base)?.absoluteURL
                ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "", relativeTo: base)?.absoluteURL,
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    static func iframeSources(_ html: String, base: URL) -> [URL] {
        regexMatches("<iframe[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']", in: html).compactMap { m in
            regexHit(m, in: html)?.groups.first.flatMap { $0 }.flatMap { resolve($0, base: base) }
        }
    }

    /// Video in chiaro scritti direttamente nell'HTML: meta og:video, tag <video>/<source>, dati strutturati e link a .m3u8/.mp4.
    static func staticCandidates(_ html: String, base: URL) -> [URL] {
        var raw: [String] = []
        if let v = metaContent(["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"], in: html) { raw.append(v) }

        var tagged: [String] = []
        for p in ["<video[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']", "<source[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']"] {
            tagged += regexMatches(p, in: html).compactMap { regexHit($0, in: html)?.groups.first.flatMap { $0 } }
        }
        let ld = regexMatches("\"contentUrl\"\\s*:\\s*\"([^\"]+)\"", in: html).compactMap { regexHit($0, in: html)?.groups.first.flatMap { $0 } }
        let loose = regexMatches("(https?:(?:\\\\?/){2}[^\"'\\s<>()]+?\\.(?:m3u8|mp4|m4v|mov)(?:\\?[^\"'\\s<>()]*)?)[\"'\\s<>)]", in: html)
            .compactMap { regexHit($0, in: html)?.groups.first.flatMap { $0 } }

        let urls = (raw + tagged + ld + loose).compactMap { resolve($0, base: base) }
            .filter { !AdFilter.isAd($0) && isPlayableLink($0) }
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.absoluteString).inserted }
        guard !unique.isEmpty else { return [] }

        // Una galleria di più <video> distinti diventa più titoli; altrimenti si tiene il flusso migliore.
        let taggedURLs = Set(tagged.compactMap { resolve($0, base: base)?.absoluteString })
        let gallery = unique.filter { taggedURLs.contains($0.absoluteString) }
        if gallery.count >= 3 { return gallery }
        return bestCandidate(unique).map { [$0] } ?? []
    }

    private static func isPlayableLink(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || Importer.videoExtensions.contains(ext) { return true }
        // Senza estensione (es. /stream?id=…): accettato, il player proverà ad aprirlo.
        return ext.isEmpty
    }

    /// Il flusso più adatto: HLS principale, poi HLS, poi MP4, poi il resto.
    static func bestCandidate(_ urls: [URL]) -> URL? {
        let clean = urls.filter { !AdFilter.isAd($0) }
        func score(_ u: URL) -> Int {
            let s = u.absoluteString.lowercased()
            let ext = u.pathExtension.lowercased()
            var v = 0
            if ext == "m3u8" { v = 60; if s.contains("master") || s.contains("index") || s.contains("playlist") { v += 15 } }
            else if ["mp4", "m4v", "mov"].contains(ext) { v = 40 }
            else if Importer.videoExtensions.contains(ext) { v = 25 }
            else { v = 10 }
            if s.contains("preview") || s.contains("thumb") || s.contains("teaser") || s.contains("sample") { v -= 30 }
            for q in ["2160", "1080", "720"] where s.contains(q) { v += Int(q)! / 200 }
            return v
        }
        return clean.max { score($0) < score($1) }
    }

    // MARK: Costruzione dei titoli

    /// Trasforma i video trovati in film, canali o — se più video sono puntate della stessa serie — una serie.
    static func make(_ videos: [FoundVideo], library: Library, seriesTitle: String?,
                     seriesPoster: URL? = nil, seriesOverview: String? = nil, lazy: String? = nil) -> [MediaItem] {
        let lib = library.id.uuidString
        let asSeries = library.hint == .series
            || (library.hint == .auto && seriesTitle != nil && videos.count > 1
                && videos.allSatisfy { !$0.live } && videos.contains { NameParser.parse($0.title).episode != nil })

        if asSeries, let seriesTitle = (seriesTitle ?? videos.first?.title)?.nonEmpty {
            let entries = videos.map {
                Importer.Entry(title: $0.title, url: $0.url, logo: $0.poster, seriesHint: seriesTitle, guess: .series)
            }
            var items = Importer.build(entries, library: library)
            let referers = Dictionary(videos.map { ($0.url.absoluteString, $0.referer) }, uniquingKeysWith: { a, _ in a })
            for i in items.indices {
                if let p = seriesPoster { items[i].poster = p }
                if items[i].overview == nil { items[i].overview = seriesOverview }
                for e in items[i].episodes.indices {
                    items[i].episodes[e].referer = referers[items[i].episodes[e].url.absoluteString] ?? nil
                }
            }
            return items
        }

        var seen = Set<String>()
        return videos.compactMap { v in
            let kind: ItemKind = (library.hint == .live || v.live) ? .live : .movie
            let id = stableID(lib + "|\(kind.rawValue)|" + v.url.absoluteString)
            guard seen.insert(id).inserted else { return nil }
            var item = MediaItem(id: id, libraryId: library.id, kind: kind, title: v.title, year: v.year,
                                 poster: v.poster, overview: v.overview, genres: v.genres, url: v.url)
            item.referer = v.referer
            item.lazyStream = lazy
            return item
        }
    }

    // MARK: Utilità di rete

    static func json(_ url: URL) async throws -> Any {
        let (data, _) = try await Importer.download(url, timeout: 30)
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw AppError.message("Il sito ha risposto con dati non validi.") }
    }

    /// Esegue `work` su più elementi in parallelo (al massimo `width` alla volta), mantenendo l'ordine.
    static func parallelMap<T, R>(_ input: [T], width: Int = 6, _ work: @escaping @Sendable (T) async -> R?) async -> [R] where T: Sendable, R: Sendable {
        var results = [R?](repeating: nil, count: input.count)
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            while next < min(width, input.count) {
                let i = next, value = input[i]
                group.addTask { (i, await work(value)) }
                next += 1
            }
            while let (i, r) = await group.next() {
                results[i] = r
                if next < input.count {
                    let j = next, value = input[j]
                    group.addTask { (j, await work(value)) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }
}

// MARK: - Pubblicità

/// Riconosce le richieste dei circuiti pubblicitari, per non scambiare uno spot per il video.
enum AdFilter {
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "imasdk.googleapis.com", "adservice.google.com",
        "2mdn.net", "adnxs.com", "adsrvr.org", "amazon-adsystem.com", "criteo.com", "criteo.net", "taboola.com",
        "outbrain.com", "pubmatic.com", "rubiconproject.com", "openx.net", "smartadserver.com", "spotxchange.com",
        "spotx.tv", "springserve.com", "teads.tv", "adform.net", "moatads.com", "fwmrm.net", "innovid.com",
        "serving-sys.com", "aniview.com", "vidoomy.com", "yieldmo.com", "popads.net", "popcash.net",
        "propellerads.com", "exoclick.com", "adsterra.com", "juicyads.com", "trafficjunky.net", "adcolony.com",
        "unrulymedia.com", "tremorhub.com", "lkqd.net", "vidazoo.com", "primis.tech", "sascdn.com",
    ]

    private static let pathHints = ["/vast", "vast.xml", "/vmap", "preroll", "pre-roll", "midroll", "/ads/", "/adserver", "/ad/", "advert"]

    static func isAd(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = (url.path + "?" + (url.query ?? "")).lowercased()
        return pathHints.contains { path.contains($0) }
    }

    /// Regole del blocco contenuti di WebKit: le richieste verso i circuiti pubblicitari non partono proprio.
    static var contentRules: String {
        let rules = domains.map { d -> String in
            let escaped = d.replacingOccurrences(of: ".", with: "\\\\.")
            return "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?\(escaped)[:/]\"},\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }
}

// MARK: - Internet Archive

enum InternetArchive {
    static func handles(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "archive.org" || host == "www.archive.org"
    }

    static func items(for library: Library, url: URL) async throws -> [MediaItem] {
        let parts = url.pathComponents.filter { $0 != "/" }
        let first = parts.first?.lowercased() ?? ""

        if first == "search" || first == "search.php" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let q = comps?.queryItems?.first(where: { $0.name == "query" })?.value?.nonEmpty else {
                throw AppError.message("Nel link di ricerca di Internet Archive manca il testo da cercare.")
            }
            return try await search("(\(q)) AND mediatype:movies", library: library, name: q)
        }

        guard ["details", "embed", "download"].contains(first), parts.count >= 2 else {
            throw AppError.message("Link di Internet Archive non riconosciuto: usa l'indirizzo di un video (archive.org/details/…), di una collezione o di una ricerca.")
        }
        let id = parts[1]
        guard let root = try await WebSources.json(URL(string: "https://archive.org/metadata/\(id)")!) as? [String: Any],
              let meta = root["metadata"] as? [String: Any] else {
            throw AppError.message("Questo elemento di Internet Archive non esiste o non è pubblico.")
        }
        if (meta["mediatype"] as? String) == "collection" {
            return try await search("collection:(\(id)) AND mediatype:movies", library: library, name: string(meta["title"]) ?? id)
        }
        let videos = videosOf(id: id, root: root)
        guard !videos.isEmpty else { throw AppError.message("Questo elemento di Internet Archive non contiene video riproducibili.") }
        let title = string(meta["title"]) ?? id
        return WebSources.make(videos, library: library, seriesTitle: videos.count > 1 ? title : nil,
                               seriesPoster: poster(id), seriesOverview: WebSources.stripTags(string(meta["description"])))
    }

    static let lazyKind = "archive"

    /// Ricerca o collezione: fino a 1000 titoli, importati subito con scheda e copertina; il video si cerca al Play.
    private static func search(_ query: String, library: Library, name: String) async throws -> [MediaItem] {
        var docs: [[String: Any]] = []
        for page in 1...5 {
            var comps = URLComponents(string: "https://archive.org/advancedsearch.php")!
            comps.queryItems = [URLQueryItem(name: "q", value: query)]
                + ["identifier", "title", "year", "date", "description", "subject"].map { URLQueryItem(name: "fl[]", value: $0) }
                + [URLQueryItem(name: "sort[]", value: "downloads desc"), URLQueryItem(name: "rows", value: "200"),
                   URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "output", value: "json")]
            guard let root = try await WebSources.json(comps.url!) as? [String: Any],
                  let response = root["response"] as? [String: Any],
                  let batch = response["docs"] as? [[String: Any]] else {
                if page == 1 { throw AppError.message("Internet Archive non ha risposto alla ricerca.") }
                break
            }
            docs += batch
            let total = response["numFound"] as? Int ?? 0
            if batch.count < 200 || docs.count >= total { break }
        }
        let videos: [FoundVideo] = docs.compactMap { d in
            guard let id = d["identifier"] as? String, let page = URL(string: "https://archive.org/details/\(id)") else { return nil }
            let subject = (d["subject"] as? [String]) ?? string(d["subject"]).map { $0.split(separator: ";").map { String($0).trimmed } } ?? []
            return FoundVideo(title: string(d["title"]) ?? id, url: page, poster: poster(id),
                              overview: WebSources.stripTags(string(d["description"])),
                              year: (string(d["year"]) ?? string(d["date"])).flatMap { Int($0.prefix(4)) },
                              genres: Array(subject.prefix(4)))
        }
        guard !videos.isEmpty else { throw AppError.message("La ricerca \"\(name)\" su Internet Archive non ha trovato video.") }
        return WebSources.make(videos, library: library, seriesTitle: nil, lazy: lazyKind)
    }

    /// I video di un elemento, un file per opera (si preferisce l'MP4 di qualità migliore).
    static func videosOf(id: String, root: [String: Any]) -> [FoundVideo] {
        let meta = root["metadata"] as? [String: Any] ?? [:]
        let files = root["files"] as? [[String: Any]] ?? []
        let title = string(meta["title"]) ?? id
        let year = (string(meta["year"]) ?? string(meta["date"])).flatMap { Int($0.prefix(4)) }
        let overview = WebSources.stripTags(string(meta["description"]))
        let genres = (meta["subject"] as? [String]) ?? string(meta["subject"]).map { $0.split(separator: ";").map { String($0).trimmed } } ?? []

        func base(_ name: String) -> String {
            var s = (name as NSString).deletingPathExtension.lowercased()
            for suffix in ["_512kb", ".512kb", "_hq", ".ia", "_h264", ".h264"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
            return s
        }
        func rank(_ f: [String: Any]) -> Int {
            let name = (string(f["name"]) ?? "").lowercased()
            let ext = (name as NSString).pathExtension
            let format = (string(f["format"]) ?? "").lowercased()
            var v = ["mp4", "m4v", "mov"].contains(ext) ? 50 : 10
            if format.contains("h.264") && !format.contains("ia") { v += 10 }
            if name.contains("512kb") { v -= 15 }
            if string(f["source"]) == "original" { v += 3 }
            return v
        }

        var best: [String: [String: Any]] = [:]
        var order: [String] = []
        for f in files {
            guard let name = string(f["name"]) else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard Importer.videoExtensions.contains(ext) || ext == "m3u8" else { continue }
            let lower = name.lowercased()
            if lower.contains("sample") || lower.hasSuffix(".gif") { continue }
            let key = base(name)
            if let current = best[key] {
                if rank(f) > rank(current) { best[key] = f }
            } else {
                best[key] = f
                order.append(key)
            }
        }
        let many = order.count > 1
        return order.compactMap { key -> FoundVideo? in
            guard let f = best[key], let name = string(f["name"]) else { return nil }
            let path = name.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            guard let url = URL(string: "https://archive.org/download/\(id)/\(path)") else { return nil }
            let fileTitle = string(f["title"]) ?? ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            return FoundVideo(title: many ? fileTitle : title, url: url, poster: poster(id), overview: overview,
                              year: year, genres: Array(genres.prefix(4)))
        }
    }

    static func poster(_ id: String) -> URL? { URL(string: "https://archive.org/services/img/\(id)") }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s.nonEmpty }
        if let a = any as? [String] { return a.first?.nonEmpty }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}

// MARK: - PeerTube

enum PeerTube {
    private enum Target {
        case video(String)
        case channel(String)
        case account(String)
        case playlist(String)
        case instance
    }

    static let lazyKind = "peertube"

    private static func target(_ url: URL) -> Target? {
        let p = url.pathComponents.filter { $0 != "/" }
        // La home dell'istanza o le sue pagine di esplorazione: tutto il catalogo dei video locali.
        if p.isEmpty || (p.first == "videos" && ["browse", "local", "recently-added", "trending", "overview"].contains(p.count > 1 ? p[1] : "")) {
            return .instance
        }
        guard p.count >= 2 else { return nil }
        switch (p[0], p[1]) {
        case ("w", "p") where p.count >= 3: return .playlist(p[2])
        case ("w", _): return .video(p[1])
        case ("videos", "watch") where p.count >= 4 && p[2] == "playlist": return .playlist(p[3])
        case ("videos", "watch") where p.count >= 3, ("videos", "embed") where p.count >= 3: return .video(p[2])
        case ("c", _), ("video-channels", _): return .channel(p[1])
        case ("a", _), ("accounts", _): return .account(p[1])
        default: return nil
        }
    }

    static func looksLikePeerTube(_ url: URL) -> Bool { target(url) != nil }

    /// Conferma che il sito sia davvero un'istanza PeerTube.
    static func isInstance(_ url: URL) async -> Bool {
        guard let origin = origin(url), let api = URL(string: origin + "/api/v1/config"),
              let cfg = try? await WebSources.json(api) as? [String: Any] else { return false }
        return cfg["instance"] != nil && cfg["serverVersion"] != nil
    }

    static func items(for library: Library, url: URL) async throws -> [MediaItem] {
        guard let origin = origin(url), let target = target(url) else {
            throw AppError.message("Link PeerTube non riconosciuto.")
        }
        switch target {
        case .video(let id):
            guard let v = await video(id, origin: origin) else { throw AppError.message("Questo video PeerTube non è disponibile o non è pubblico.") }
            return WebSources.make([v], library: library, seriesTitle: nil)
        case .channel(let name):
            return try await catalog(origin + "/api/v1/video-channels/\(name)/videos?", origin: origin, library: library)
        case .account(let name):
            return try await catalog(origin + "/api/v1/accounts/\(name)/videos?", origin: origin, library: library)
        case .instance:
            return try await catalog(origin + "/api/v1/videos?isLocal=true&", origin: origin, library: library)
        case .playlist(let id):
            var title: String?
            if let u = URL(string: origin + "/api/v1/video-playlists/\(id)"), let info = try? await WebSources.json(u) as? [String: Any] {
                title = info["displayName"] as? String
            }
            return try await list(origin + "/api/v1/video-playlists/\(id)/videos", origin: origin, library: library,
                                  title: title ?? "Playlist", playlist: true)
        }
    }

    /// Catalogo grande (istanza, canale, account): fino a 1000 video con scheda e copertina; il flusso si cerca al Play.
    private static func catalog(_ endpoint: String, origin: String, library: Library) async throws -> [MediaItem] {
        var videos: [FoundVideo] = []
        var start = 0
        while start < 1000 {
            guard let u = URL(string: endpoint + "count=100&start=\(start)&sort=-publishedAt"),
                  let page = try await WebSources.json(u) as? [String: Any],
                  let data = page["data"] as? [[String: Any]] else { break }
            for v in data {
                guard let name = (v["name"] as? String)?.nonEmpty,
                      let id = (v["shortUUID"] as? String) ?? (v["uuid"] as? String),
                      let watch = URL(string: origin + "/w/\(id)") else { continue }
                let date = (v["originallyPublishedAt"] as? String) ?? (v["publishedAt"] as? String)
                let category = (v["category"] as? [String: Any])?["label"] as? String
                videos.append(FoundVideo(title: name, url: watch,
                                         poster: (v["previewPath"] as? String ?? v["thumbnailPath"] as? String).flatMap { URL(string: origin + $0) },
                                         overview: (v["description"] as? String)?.nonEmpty,
                                         year: date.flatMap { Int($0.prefix(4)) },
                                         genres: category.map { [$0] } ?? [],
                                         live: v["isLive"] as? Bool ?? false))
            }
            let total = page["total"] as? Int ?? 0
            start += 100
            if data.isEmpty || start >= total { break }
        }
        guard !videos.isEmpty else { throw AppError.message("Non ci sono video pubblici in questo canale o istanza PeerTube.") }
        return WebSources.make(videos, library: library, seriesTitle: nil, lazy: lazyKind)
    }

    private static func list(_ endpoint: String, origin: String, library: Library, title: String, playlist: Bool) async throws -> [MediaItem] {
        var ids: [String] = []
        var start = 0
        while start < 300 {
            guard let u = URL(string: endpoint + "?count=100&start=\(start)" + (playlist ? "" : "&sort=-publishedAt")),
                  let page = try await WebSources.json(u) as? [String: Any],
                  let data = page["data"] as? [[String: Any]] else { break }
            ids += data.compactMap { (playlist ? $0["video"] as? [String: Any] : $0)?["uuid"] as? String }
            let total = page["total"] as? Int ?? 0
            start += 100
            if data.isEmpty || start >= total { break }
        }
        guard !ids.isEmpty else { throw AppError.message("Non ci sono video pubblici in questo canale o playlist PeerTube.") }
        let videos: [FoundVideo] = await WebSources.parallelMap(ids) { await PeerTube.video($0, origin: origin) }
        guard !videos.isEmpty else { throw AppError.message("I video di questo canale PeerTube non sono riproducibili.") }
        return WebSources.make(videos, library: library, seriesTitle: playlist ? title : nil)
    }

    static func video(_ id: String, origin: String) async -> FoundVideo? {
        guard let u = URL(string: origin + "/api/v1/videos/\(id)"),
              let v = try? await WebSources.json(u) as? [String: Any],
              let name = (v["name"] as? String)?.nonEmpty else { return nil }

        var stream: URL?
        if let hls = (v["streamingPlaylists"] as? [[String: Any]])?.first, let s = hls["playlistUrl"] as? String {
            stream = URL(string: s)
        }
        if stream == nil, let files = v["files"] as? [[String: Any]] {
            let sorted = files.sorted {
                (($0["resolution"] as? [String: Any])?["id"] as? Int ?? 0) > (($1["resolution"] as? [String: Any])?["id"] as? Int ?? 0)
            }
            stream = sorted.compactMap { ($0["fileUrl"] as? String).flatMap { URL(string: $0) } }.first
        }
        guard let stream else { return nil }

        let image = (v["previewPath"] as? String ?? v["thumbnailPath"] as? String).flatMap { URL(string: origin + $0) }
        let date = (v["originallyPublishedAt"] as? String) ?? (v["publishedAt"] as? String)
        let category = (v["category"] as? [String: Any])?["label"] as? String
        let watch = URL(string: origin + "/w/\(v["shortUUID"] as? String ?? id)")
        return FoundVideo(title: name, url: stream, poster: image,
                          overview: (v["description"] as? String)?.nonEmpty,
                          year: date.flatMap { Int($0.prefix(4)) },
                          genres: category.map { [$0] } ?? [],
                          live: v["isLive"] as? Bool ?? false, referer: watch)
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
}

// MARK: - Browser invisibile

/// Apre una pagina in un WKWebView nascosto, blocca i circuiti pubblicitari e annota i flussi video che il player carica.
@MainActor
final class PageSniffer: NSObject, WKNavigationDelegate {
    struct Candidate { let url: URL; let frame: URL? }
    struct Result {
        var videos: [Candidate] = []
        var iframes: [URL] = []
        var meta = WebSources.PageMeta()
        var drm = false
    }

    private let start: URL
    private var webView: WKWebView?
    private var result = Result()
    private var seen = Set<String>()
    private var firstLoadDone = false
    private var finished = false
    private var continuation: CheckedContinuation<Result, Error>?
    private var settleTask: Task<Void, Never>?
    private static var rules: WKContentRuleList?

    private init(_ url: URL) { start = url }

    static func sniff(_ url: URL, timeout: TimeInterval = 22) async throws -> Result {
        let sniffer = PageSniffer(url)
        return try await sniffer.run(timeout: timeout)
    }

    private func run(timeout: TimeInterval) async throws -> Result {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(WeakHandler(self), name: "sipario")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let rules = await Self.loadRules() { controller.add(rules) }
        config.userContentController = controller

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: config)
        wv.navigationDelegate = self
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        // Va inserito in una finestra, altrimenti WebKit rallenta timer e player; sta dietro a tutto.
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) {
            window.insertSubview(wv, at: 0)
        }
        webView = wv

        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            var req = URLRequest(url: start)
            req.timeoutInterval = 20
            wv.load(req)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish()
            }
        }
    }

    private static func loadRules() async -> WKContentRuleList? {
        if let rules { return rules }
        let compiled: WKContentRuleList? = await withCheckedContinuation { cont in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sipario-ads", encodedContentRuleList: AdFilter.contentRules) { list, _ in
                cont.resume(returning: list)
            }
        }
        rules = compiled
        return compiled
    }

    fileprivate func receive(_ body: Any) {
        guard !finished, let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        let frame = (msg["frame"] as? String).flatMap { URL(string: $0) }
        switch type {
        case "url":
            guard let s = msg["data"] as? String, let u = URL(string: s), !AdFilter.isAd(u), seen.insert(s).inserted else { return }
            let ext = u.pathExtension.lowercased()
            guard ext == "m3u8" || Importer.videoExtensions.contains(ext) || ext.isEmpty else { return }
            // I segmenti di un flusso HLS non sono video da importare.
            if ext == "ts" || s.contains(".m4s") { return }
            result.videos.append(Candidate(url: u, frame: frame))
            scheduleSettle()
        case "iframe":
            if let s = msg["data"] as? String, let u = URL(string: s), !AdFilter.isAd(u),
               !result.iframes.contains(u) { result.iframes.append(u) }
        case "drm":
            result.drm = true
        case "meta":
            guard frame == nil || frame?.host == start.host || result.meta.title == nil,
                  let d = msg["data"] as? [String: Any] else { return }
            var m = WebSources.PageMeta()
            m.title = (d["title"] as? String)?.nonEmpty
            m.image = (d["image"] as? String).flatMap { URL(string: $0) }
            m.description = (d["description"] as? String)?.nonEmpty
            result.meta.merge(m)
        default: break
        }
    }

    /// Trovato un video, si aspetta ancora un attimo: spesso dopo arriva la playlist HLS principale.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.finish() }
        }
    }

    private func finish(error: Error? = nil) {
        guard !finished else { return }
        finished = true
        settleTask?.cancel()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sipario")
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        if let error, result.videos.isEmpty { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: result) }
        continuation = nil
    }

    // MARK: Navigazione

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if AdFilter.isAd(url) || !(scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob") {
            decisionHandler(.cancel); return
        }
        // Dopo il primo caricamento la pagina principale non può essere portata altrove (pop-under, redirect pubblicitari).
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if mainFrame && firstLoadDone { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        firstLoadDone = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        firstLoadDone = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(error: AppError.message("Non riesco ad aprire la pagina. Controlla il link e la connessione."))
    }

    // MARK: Script iniettato

    private static let script = """
    (function(){
      if (window.__sipario) return; window.__sipario = true;
      var post = function(type, data){ try { window.webkit.messageHandlers.sipario.postMessage({type: type, data: data, frame: location.href}); } catch(e){} };
      var media = /\\.(m3u8|mp4|m4v|mov|webm|mkv)(\\?|#|$)/i;
      var seen = {};
      var report = function(u){
        try {
          if (!u || typeof u !== 'string' || u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
          var abs = new URL(u, location.href).href;
          if (seen[abs]) return; seen[abs] = 1; post('url', abs);
        } catch(e){}
      };
      var check = function(u){ try { u = String(u || ''); if (media.test(u)) report(u); } catch(e){} };
      try {
        var of = window.fetch;
        if (of) window.fetch = function(i){ try { check(typeof i === 'string' ? i : (i && i.url)); } catch(e){} return of.apply(this, arguments); };
        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(m, u){ check(u); return oo.apply(this, arguments); };
      } catch(e){}
      try {
        if (navigator.requestMediaKeySystemAccess) {
          var orig = navigator.requestMediaKeySystemAccess.bind(navigator);
          navigator.requestMediaKeySystemAccess = function(k){ post('drm', String(k)); return orig.apply(null, arguments); };
        }
        if (window.WebKitMediaKeys) {
          var WK = window.WebKitMediaKeys;
          window.WebKitMediaKeys = function(k){ post('drm', String(k)); return new WK(k); };
          window.WebKitMediaKeys.isTypeSupported = WK.isTypeSupported;
        }
      } catch(e){}
      var clicked = false;
      var scan = function(){
        try {
          document.querySelectorAll('video').forEach(function(v){
            report(v.currentSrc || v.src);
            v.querySelectorAll('source').forEach(function(s){ report(s.src); });
            v.muted = true; v.playsInline = true;
            if (v.paused && !v.__sp) { v.__sp = 1; var p = v.play(); if (p && p.catch) p.catch(function(){}); }
          });
          performance.getEntriesByType('resource').forEach(function(e){ check(e.name); });
          document.querySelectorAll('iframe[src]').forEach(function(f){ post('iframe', f.src); });
          if (!clicked && document.readyState === 'complete') {
            clicked = true;
            var b = document.querySelector('[class*="play-button" i], [class*="play_button" i], [class*="vjs-big-play" i], [class*="jw-display-icon" i], [aria-label*="play" i], [aria-label*="riproduci" i], button[title*="play" i]');
            if (b && b.tagName !== 'A') { try { b.click(); } catch(e){} }
          }
        } catch(e){}
      };
      var meta = function(){
        var get = function(sel){ var m = document.querySelector(sel); return m ? (m.content || '') : ''; };
        post('meta', {
          title: get('meta[property="og:title"]') || document.title || '',
          image: get('meta[property="og:image"]'),
          description: get('meta[property="og:description"]') || get('meta[name="description"]')
        });
        document.querySelectorAll('meta[property^="og:video"]').forEach(function(m){ report(m.content); });
      };
      document.addEventListener('DOMContentLoaded', function(){ meta(); scan(); });
      setInterval(scan, 700);
    })();
    """
}

/// Evita il ciclo di riferimenti tra WKUserContentController e chi riceve i messaggi.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: PageSniffer?
    init(_ target: PageSniffer) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
