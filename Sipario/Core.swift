import SwiftUI
import UIKit

// MARK: - Tema

enum Theme {
    static let accent = Color(red: 0.90, green: 0.17, blue: 0.24)
    static let gold = Color(red: 0.96, green: 0.76, blue: 0.36)
    static let card = Color(white: 0.11)
    static let background = Color(red: 0.04, green: 0.04, blue: 0.05)
}

// MARK: - Errori

enum AppError: LocalizedError {
    case missingKey
    case badKey
    case notLoggedIn
    case http(Int)
    case noVideo
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Manca la chiave TMDB. Aggiungila nelle Impostazioni."
        case .badKey: return "La chiave TMDB non è valida."
        case .notLoggedIn: return "Non sei collegato a Jellyfin."
        case .http(let code): return "Il server ha risposto con errore \(code)."
        case .noVideo: return "Non ho trovato un file video riproducibile."
        case .message(let m): return m
        }
    }
}

// MARK: - Servizio di streaming scelto dall'utente

struct SavedProvider: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let logoPath: String?
}

// MARK: - Impostazioni

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var tmdbKey: String { didSet { defaults.set(tmdbKey, forKey: "tmdbKey") } }
    @Published var services: [SavedProvider] { didSet { saveServices() } }
    @Published var jellyfinServer: String { didSet { defaults.set(jellyfinServer, forKey: "jfServer") } }
    @Published var jellyfinToken: String { didSet { defaults.set(jellyfinToken, forKey: "jfToken") } }
    @Published var jellyfinUserId: String { didSet { defaults.set(jellyfinUserId, forKey: "jfUserId") } }
    @Published var jellyfinUserName: String { didSet { defaults.set(jellyfinUserName, forKey: "jfUserName") } }
    /// Bitrate massimo per lo streaming da Jellyfin (bit/s).
    @Published var maxBitrate: Int { didSet { defaults.set(maxBitrate, forKey: "jfBitrate") } }

    let region = "IT"
    let deviceId: String

    private init() {
        tmdbKey = defaults.string(forKey: "tmdbKey") ?? ""
        jellyfinServer = defaults.string(forKey: "jfServer") ?? ""
        jellyfinToken = defaults.string(forKey: "jfToken") ?? ""
        jellyfinUserId = defaults.string(forKey: "jfUserId") ?? ""
        jellyfinUserName = defaults.string(forKey: "jfUserName") ?? ""
        let bitrate = defaults.integer(forKey: "jfBitrate")
        maxBitrate = bitrate > 0 ? bitrate : 20_000_000
        if let data = defaults.data(forKey: "services"),
           let list = try? JSONDecoder().decode([SavedProvider].self, from: data) {
            services = list
        } else {
            services = []
        }
        if let id = defaults.string(forKey: "deviceId") {
            deviceId = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "deviceId")
            deviceId = id
        }
    }

    private func saveServices() {
        if let data = try? JSONEncoder().encode(services) {
            defaults.set(data, forKey: "services")
        }
    }

    var cleanTMDBKey: String { tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasTMDB: Bool { !cleanTMDBKey.isEmpty }
    var hasJellyfin: Bool { !jellyfinToken.isEmpty && !jellyfinServer.isEmpty && !jellyfinUserId.isEmpty }
    var serviceIds: Set<Int> { Set(services.map(\.id)) }

    func toggleService(_ p: SavedProvider) {
        if let i = services.firstIndex(where: { $0.id == p.id }) {
            services.remove(at: i)
        } else {
            services.append(p)
        }
    }

    func logoutJellyfin() {
        jellyfinToken = ""
        jellyfinUserId = ""
        jellyfinUserName = ""
    }
}

// MARK: - Utilità

extension String {
    /// Rimuove i tag HTML e comprime gli spazi.
    var strippingHTML: String {
        var s = replacingOccurrences(of: "<br ?/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var yearPrefix: String? {
        count >= 4 ? String(prefix(4)) : nil
    }
}

func formatMinutes(_ minutes: Int) -> String {
    guard minutes > 0 else { return "" }
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m) min" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

/// Il view controller in cima, per presentare il player da qualsiasi punto.
@MainActor
func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

/// Chiave di decodifica: trasforma "PascalCase" (Jellyfin) in "camelCase".
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension Dictionary where Key == String {
    /// Ricerca della chiave senza distinzione tra maiuscole e minuscole.
    func value(forInsensitive key: String) -> Value? {
        let k = key.lowercased()
        return first { $0.key.lowercased() == k }?.value
    }
}
