import Foundation
import SwiftUI

// MARK: - Siti gratuiti e legali da aprire dentro Sipario

struct FreeSite: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let url: URL
    let symbol: String
    let color: Color

    static let all: [FreeSite] = [
        .init(id: "raiplay", name: "RaiPlay", subtitle: "Film, fiction, serie e programmi Rai",
              url: URL(string: "https://www.raiplay.it")!, symbol: "play.tv.fill", color: Color(red: 0.05, green: 0.35, blue: 0.75)),
        .init(id: "raidirette", name: "Rai in diretta", subtitle: "Rai 1, Rai 2, Rai 3 e gli altri canali",
              url: URL(string: "https://www.raiplay.it/dirette")!, symbol: "dot.radiowaves.left.and.right", color: Color(red: 0.10, green: 0.45, blue: 0.85)),
        .init(id: "mediaset", name: "Mediaset Infinity", subtitle: "Programmi e dirette Mediaset (parte gratuita)",
              url: URL(string: "https://mediasetinfinity.mediaset.it")!, symbol: "sparkles.tv.fill", color: Color(red: 0.12, green: 0.20, blue: 0.55)),
        .init(id: "la7", name: "La7", subtitle: "Diretta e programmi on demand",
              url: URL(string: "https://www.la7.it/dirette-tv")!, symbol: "7.square.fill", color: Color(red: 0.80, green: 0.15, blue: 0.20)),
        .init(id: "pluto", name: "Pluto TV", subtitle: "Canali e film gratis con pubblicità",
              url: URL(string: "https://pluto.tv/it/live-tv")!, symbol: "globe.europe.africa.fill", color: Color(red: 0.55, green: 0.25, blue: 0.75)),
        .init(id: "rakuten", name: "Rakuten TV", subtitle: "Sezione film gratuiti",
              url: URL(string: "https://www.rakuten.tv/it")!, symbol: "film.fill", color: Color(red: 0.75, green: 0.10, blue: 0.30)),
        .init(id: "plex", name: "Plex (gratis)", subtitle: "Film e canali gratuiti di Plex",
              url: URL(string: "https://watch.plex.tv")!, symbol: "chevron.right.2", color: Color(red: 0.85, green: 0.55, blue: 0.05)),
        .init(id: "arte", name: "Arte", subtitle: "Documentari, film e serie europee in italiano",
              url: URL(string: "https://www.arte.tv/it/")!, symbol: "paintpalette.fill", color: Color(red: 0.85, green: 0.35, blue: 0.10)),
        .init(id: "archive", name: "Internet Archive", subtitle: "Migliaia di film di pubblico dominio",
              url: URL(string: "https://archive.org/details/feature_films")!, symbol: "building.columns.fill", color: Color(red: 0.30, green: 0.32, blue: 0.38)),
    ]
}

/// Una pagina visitata o salvata dal browser integrato.
struct WebPage: Codable, Hashable, Identifiable {
    let title: String
    let url: URL
    var visited: Date = Date()
    var id: String { url.absoluteString }
}

// MARK: - I miei link

struct LinkItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
    var poster: URL? = nil
    var group: String? = nil
    var added: Date = Date()
}

@MainActor
final class LinkStore: ObservableObject {
    static let shared = LinkStore()

    struct Progress: Codable, Hashable {
        var seconds: Double
        var duration: Double
        var fraction: Double { duration > 0 ? min(1, seconds / duration) : 0 }
    }

    @Published private(set) var links: [LinkItem] = []
    @Published private(set) var recentPages: [WebPage] = []
    @Published private(set) var progress: [UUID: Progress] = [:]

    private let defaults = UserDefaults.standard

    private init() {
        links = load("myLinks") ?? []
        recentPages = load("recentPages") ?? []
        progress = load("linkProgress") ?? [:]
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let d = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let d = try? JSONEncoder().encode(value) { defaults.set(d, forKey: key) }
    }

    var groups: [String] {
        var seen: [String] = []
        for l in links {
            let g = l.group ?? "Senza gruppo"
            if !seen.contains(g) { seen.append(g) }
        }
        return seen
    }

    func add(_ link: LinkItem) {
        links.insert(link, at: 0)
        save(links, "myLinks")
    }

    func update(_ link: LinkItem) {
        if let i = links.firstIndex(where: { $0.id == link.id }) {
            links[i] = link
            save(links, "myLinks")
        }
    }

    func remove(_ link: LinkItem) {
        links.removeAll { $0.id == link.id }
        progress[link.id] = nil
        save(links, "myLinks")
        save(progress, "linkProgress")
    }

    func removeGroup(_ group: String) {
        links.removeAll { ($0.group ?? "Senza gruppo") == group }
        save(links, "myLinks")
    }

    /// Aggiunge le voci di una playlist M3U; restituisce quante ne sono state aggiunte.
    @discardableResult
    func importM3U(_ text: String, defaultGroup: String) -> Int {
        let known = Set(links.map(\.url))
        let items = M3U.parse(text, defaultGroup: defaultGroup).filter { !known.contains($0.url) }
        links.append(contentsOf: items)
        save(links, "myLinks")
        return items.count
    }

    func setProgress(_ id: UUID, seconds: Double, duration: Double) {
        // Le dirette non hanno durata: niente avanzamento da salvare.
        guard duration.isFinite, duration > 60, seconds.isFinite else { return }
        progress[id] = (seconds < 20 || seconds / duration > 0.95) ? nil : Progress(seconds: seconds, duration: duration)
        save(progress, "linkProgress")
    }

    func addRecent(_ page: WebPage) {
        guard page.url.scheme?.hasPrefix("http") == true else { return }
        recentPages.removeAll { $0.url.host == page.url.host }
        recentPages.insert(page, at: 0)
        if recentPages.count > 12 { recentPages = Array(recentPages.prefix(12)) }
        save(recentPages, "recentPages")
    }

    func clearRecent() {
        recentPages = []
        save(recentPages, "recentPages")
    }
}

// MARK: - Lettura delle playlist M3U

enum M3U {
    static func parse(_ text: String, defaultGroup: String) -> [LinkItem] {
        var out: [LinkItem] = []
        var pendingTitle: String?
        var pendingLogo: URL?
        var pendingGroup: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                pendingTitle = line.range(of: ",", options: .backwards).map {
                    String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                pendingLogo = attribute("tvg-logo", in: line).flatMap { URL(string: $0) }
                pendingGroup = attribute("group-title", in: line)
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let url = URL(string: line), let scheme = url.scheme, scheme.hasPrefix("http") else {
                pendingTitle = nil; pendingLogo = nil; pendingGroup = nil
                continue
            }
            let title = (pendingTitle?.isEmpty == false ? pendingTitle! : url.lastPathComponent)
            let group = (pendingGroup?.isEmpty == false ? pendingGroup! : defaultGroup)
            out.append(LinkItem(title: title, url: url, poster: pendingLogo, group: group))
            pendingTitle = nil; pendingLogo = nil; pendingGroup = nil
        }
        return out
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let v = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// Scarica una playlist da un indirizzo.
    static func download(_ url: URL) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AppError.http(code) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("#EXTM3U") || text.contains("#EXTINF") else {
            throw AppError.message("Il file non sembra una playlist M3U.")
        }
        return text
    }
}
