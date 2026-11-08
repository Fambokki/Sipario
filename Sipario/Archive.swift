import Foundation

// MARK: - Film di pubblico dominio dall'Internet Archive

struct ArchiveItem: Codable, Hashable, Identifiable {
    let identifier: String
    let title: String
    let year: String?
    let description: String?
    let downloads: Int?

    var id: String { identifier }
    var thumbURL: URL? { URL(string: "https://archive.org/services/img/\(identifier)") }
    var pageURL: URL? { URL(string: "https://archive.org/details/\(identifier)") }
    var cleanDescription: String { (description ?? "").strippingHTML }

    init(identifier: String, title: String, year: String?, description: String?, downloads: Int?) {
        self.identifier = identifier
        self.title = title
        self.year = year
        self.description = description
        self.downloads = downloads
    }

    private enum CodingKeys: String, CodingKey { case identifier, title, year, description, downloads }

    /// L'Archive restituisce a volte stringhe, numeri o liste per lo stesso campo.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        title = Self.flexible(c, .title) ?? identifier
        year = Self.flexible(c, .year).map { String($0.prefix(4)) }
        description = Self.flexible(c, .description)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .downloads) {
            downloads = n
        } else if let s = Self.flexible(c, .downloads) {
            downloads = Int(s)
        } else {
            downloads = nil
        }
    }

    private static func flexible(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return String(n) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(Int(d)) }
        if let a = try? c.decodeIfPresent([String].self, forKey: key) { return a.joined(separator: "\n") }
        return nil
    }
}

struct ArchiveCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let query: String
}

enum Archive {
    static let base = "collection:(feature_films) AND mediatype:(movies)"

    static let categories: [ArchiveCategory] = [
        .init(id: "top", title: "I più visti", query: base),
        .init(id: "noir", title: "Noir", query: "collection:(film_noir) AND mediatype:(movies)"),
        .init(id: "scifi", title: "Fantascienza", query: base + " AND subject:(\"science fiction\")"),
        .init(id: "horror", title: "Horror", query: base + " AND subject:(horror)"),
        .init(id: "comedy", title: "Commedie", query: base + " AND subject:(comedy)"),
        .init(id: "western", title: "Western", query: base + " AND subject:(western)"),
        .init(id: "silent", title: "Cinema muto", query: "collection:(silent_films) AND mediatype:(movies)"),
        .init(id: "cartoons", title: "Cartoni d'epoca", query: "collection:(classic_cartoons) AND mediatype:(movies)"),
        .init(id: "italian", title: "In italiano", query: base + " AND language:(italian OR ita OR Italian)"),
    ]

    private struct SearchResponse: Decodable {
        struct Inner: Decodable { let docs: [ArchiveItem] }
        let response: Inner
    }

    static func search(_ query: String, rows: Int = 30, page: Int = 1) async throws -> [ArchiveItem] {
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        var items: [URLQueryItem] = [URLQueryItem(name: "q", value: query)]
        for f in ["identifier", "title", "year", "description", "downloads"] {
            items.append(URLQueryItem(name: "fl[]", value: f))
        }
        items.append(URLQueryItem(name: "sort[]", value: "downloads desc"))
        items.append(URLQueryItem(name: "rows", value: String(rows)))
        items.append(URLQueryItem(name: "page", value: String(page)))
        items.append(URLQueryItem(name: "output", value: "json"))
        c.queryItems = items
        guard let url = c.url else { return [] }
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        return try JSONDecoder().decode(SearchResponse.self, from: data).response.docs
    }

    static func searchTitle(_ text: String) async throws -> [ArchiveItem] {
        let clean = text.replacingOccurrences(of: "\"", with: "")
        return try await search("(\(base)) AND title:(\(clean))", rows: 20)
    }

    private struct Metadata: Decodable {
        struct File: Decodable {
            let name: String
            let format: String?
            let size: String?
        }
        let files: [File]?
    }

    /// Sceglie il file MP4 migliore tra quelli dell'elemento.
    static func videoURL(_ identifier: String) async throws -> URL {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)") else { throw AppError.noVideo }
        let (data, _) = try await URLSession.shared.data(from: url)
        let meta = try JSONDecoder().decode(Metadata.self, from: data)
        let files = meta.files ?? []
        func size(_ f: Metadata.File) -> Int { Int(f.size ?? "") ?? 0 }
        let mp4 = files.filter { f in
            let n = f.name.lowercased()
            return n.hasSuffix(".mp4") || n.hasSuffix(".m4v") || n.hasSuffix(".mov")
        }
        let preferred = mp4.filter { ($0.format ?? "").lowercased().contains("h.264") }
        let pool = preferred.isEmpty ? mp4 : preferred
        // Il più grande ha di solito la qualità migliore; sotto i 4 GB per non esagerare col traffico.
        let pick = pool.filter { size($0) < 4_000_000_000 }.max { size($0) < size($1) } ?? pool.first
        guard let file = pick else { throw AppError.noVideo }
        let encoded = file.name.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let out = URL(string: "https://archive.org/download/\(identifier)/\(encoded)") else { throw AppError.noVideo }
        return out
    }
}
