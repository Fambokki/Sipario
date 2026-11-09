import SwiftUI
import UIKit

// MARK: - Tema

enum Theme {
    static let accent = Color(red: 0.90, green: 0.17, blue: 0.24)
    static let gold = Color(red: 0.96, green: 0.76, blue: 0.36)
    static let card = Color(white: 0.11)
    static let background = Color(red: 0.04, green: 0.04, blue: 0.05)

    static let posterPalette: [Color] = [
        Color(red: 0.45, green: 0.10, blue: 0.16), Color(red: 0.12, green: 0.22, blue: 0.45),
        Color(red: 0.30, green: 0.14, blue: 0.42), Color(red: 0.08, green: 0.33, blue: 0.30),
        Color(red: 0.45, green: 0.26, blue: 0.08), Color(red: 0.20, green: 0.22, blue: 0.27),
    ]
}

// MARK: - Errori

enum AppError: LocalizedError {
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            if code == 404 { return "Indirizzo non trovato (errore 404)." }
            if code == 401 || code == 403 { return "Accesso negato dal server (errore \(code))." }
            return "Il server ha risposto con errore \(code)."
        case .message(let m): return m
        }
    }
}

// MARK: - Impostazioni

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var tmdbKey: String {
        didSet { defaults.set(tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "tmdbKey") }
    }
    @Published var autoplayNext: Bool { didSet { defaults.set(autoplayNext, forKey: "autoplayNext") } }

    private init() {
        tmdbKey = defaults.string(forKey: "tmdbKey") ?? ""
        autoplayNext = defaults.object(forKey: "autoplayNext") as? Bool ?? true
    }

    var hasTMDB: Bool { !tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Utilità

/// Identificativo breve e stabile (FNV-1a) ricavato da una stringa.
func stableID(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return String(h, radix: 36)
}

/// Chiave di confronto: minuscole, senza accenti, solo lettere e numeri.
func normalizeKey(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
}

func formatMinutes(_ minutes: Int) -> String {
    guard minutes > 0 else { return "" }
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m) min" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

func tmdbImage(_ path: String?, _ size: String) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { trimmed.isEmpty ? nil : trimmed }

    /// Numero stabile per scegliere un colore a partire da un titolo.
    var colorSeed: Int { unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 9973 } }
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

// MARK: - Regex

func regexMatches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
}

struct RegexHit {
    let range: Range<String.Index>
    let groups: [String?]
}

func regexHit(_ m: NSTextCheckingResult, in text: String) -> RegexHit? {
    guard let r = Range(m.range, in: text) else { return nil }
    var groups: [String?] = []
    if m.numberOfRanges > 1 {
        for i in 1..<m.numberOfRanges {
            groups.append(Range(m.range(at: i), in: text).map { String(text[$0]) })
        }
    }
    return RegexHit(range: r, groups: groups)
}

func firstHit(_ pattern: String, in text: String) -> RegexHit? {
    regexMatches(pattern, in: text).first.flatMap { regexHit($0, in: text) }
}

func lastHit(_ pattern: String, in text: String) -> RegexHit? {
    regexMatches(pattern, in: text).last.flatMap { regexHit($0, in: text) }
}
