import SwiftUI

/// "Stasera cosa guardo?": scegli l'umore, Sipario pesca un titolo a caso.
struct SurpriseView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: JellyfinLibrary
    @EnvironmentObject private var playback: Playback
    @Environment(\.dismiss) private var dismiss

    enum Mood: String, CaseIterable, Identifiable {
        case any = "Qualsiasi", laugh = "Ridere", chills = "Brividi", feel = "Emozionarmi"
        case rush = "Adrenalina", dream = "Sognare", family = "In famiglia"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .any: return "sparkles"
            case .laugh: return "face.smiling"
            case .chills: return "eye.trianglebadge.exclamationmark"
            case .feel: return "heart.fill"
            case .rush: return "bolt.fill"
            case .dream: return "moon.stars.fill"
            case .family: return "figure.2.and.child.holdinghands"
            }
        }
        func genres(_ kind: MediaKind) -> [Int] {
            switch (self, kind) {
            case (.any, _): return []
            case (.laugh, _): return [35]
            case (.chills, .movie): return [27, 53]
            case (.chills, .tv): return [9648, 80]
            case (.feel, .movie): return [18, 10749]
            case (.feel, .tv): return [18]
            case (.rush, .movie): return [28, 12]
            case (.rush, .tv): return [10759]
            case (.dream, .movie): return [878, 14]
            case (.dream, .tv): return [10765]
            case (.family, _): return [16, 10751]
            }
        }
    }

    enum Pool: String, CaseIterable, Identifiable {
        case services = "I miei servizi", library = "Il mio server", everything = "Tutto"
        var id: String { rawValue }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case both = "Entrambi", movie = "Film", tv = "Serie"
        var id: String { rawValue }
    }

    struct Candidate: Hashable {
        let title: String
        let year: String?
        let overview: String?
        let rating: Double?
        let poster: URL?
        let tmdb: TMDBItem?
        let jellyfin: JFItem?
    }

    @State private var mood: Mood = .any
    @State private var pool: Pool = .everything
    @State private var kind: Kind = .both
    @State private var flashing: Candidate?
    @State private var result: Candidate?
    @State private var rolling = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    stage
                    controls
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Stasera cosa guardo?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
            .siparioDestinations()
        }
    }

    // MARK: Il "palco"

    private var stage: some View {
        let shown = result ?? flashing
        return VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.card], startPoint: .top, endPoint: .bottom))
                if let shown {
                    RemoteImage(url: shown.poster)
                        .frame(width: 190, height: 285)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Theme.accent.opacity(result != nil ? 0.6 : 0), radius: 30)
                        .scaleEffect(result != nil ? 1.0 : 0.92)
                        .id(shown)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "theatermasks.fill").font(.system(size: 64)).foregroundStyle(Theme.gold)
                        Text("Scegli l'umore e lascia fare a me")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 320)
            .clipped()

            if let r = result {
                VStack(spacing: 8) {
                    Text(r.title)
                        .font(.system(size: 24, weight: .black, design: .serif))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        if let y = r.year { Text(y) }
                        if let v = r.rating, v > 0 { Label(String(format: "%.1f", v), systemImage: "star.fill").foregroundStyle(Theme.gold) }
                        if r.jellyfin != nil { Text("· Sul tuo server").foregroundStyle(Theme.gold) }
                    }
                    .font(.caption.weight(.semibold))
                    if let o = r.overview, !o.isEmpty {
                        Text(o).font(.footnote).foregroundStyle(.secondary).lineLimit(4).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 10) {
                        if let j = r.jellyfin, j.isPlayable {
                            PillButton(title: "Guarda", systemImage: "play.fill", prominent: true) {
                                dismiss()
                                playback.play(j)
                            }
                        }
                        if let t = r.tmdb {
                            NavigationLink(value: Route.tmdb(t.kind, t.id)) { detailLabel }
                                .buttonStyle(.plain)
                        } else if let j = r.jellyfin {
                            NavigationLink(value: Route.jellyfin(j.id)) { detailLabel }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
    }

    private var detailLabel: some View {
        Label("Scheda", systemImage: "info.circle")
            .font(.subheadline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Controlli

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ho voglia di…").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Mood.allCases) { m in
                    Button { mood = m } label: {
                        Label(m.rawValue, systemImage: m.icon)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(mood == m ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Cosa", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Da dove", selection: $pool) {
                ForEach(availablePools) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                Task { await roll() }
            } label: {
                Label(result == nil ? "Sorprendimi" : "Un altro!", systemImage: "dice.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LinearGradient(colors: [Theme.accent, Color(red: 0.65, green: 0.08, blue: 0.2)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(rolling)
            .sensoryFeedback(.impact(weight: .heavy), trigger: result)
        }
    }

    private var availablePools: [Pool] {
        var out: [Pool] = []
        if settings.hasTMDB && !settings.services.isEmpty { out.append(.services) }
        if settings.hasJellyfin { out.append(.library) }
        out.append(.everything)
        return out
    }

    // MARK: Estrazione

    private func candidates() async throws -> [Candidate] {
        var out: [Candidate] = []
        let kinds: [MediaKind] = kind == .both ? [.movie, .tv] : (kind == .movie ? [.movie] : [.tv])
        let effectivePool = availablePools.contains(pool) ? pool : .everything

        if effectivePool != .library && settings.hasTMDB {
            for k in kinds {
                var p: [String: String] = [
                    "vote_average.gte": "6.8",
                    "vote_count.gte": k == .movie ? "400" : "150",
                    "page": String(Int.random(in: 1...6)),
                ]
                let g = mood.genres(k)
                if !g.isEmpty { p["with_genres"] = g.map(String.init).joined(separator: "|") }
                if effectivePool == .services {
                    p["with_watch_providers"] = settings.services.map { String($0.id) }.joined(separator: "|")
                    p["with_watch_monetization_types"] = "flatrate|free|ads"
                }
                let items = (try? await TMDB.discover(k, p)) ?? []
                out += items.map { t in
                    Candidate(title: t.displayTitle, year: t.year, overview: t.overview, rating: t.voteAverage,
                              poster: t.posterURL, tmdb: t, jellyfin: library.match(t.kind, t.id))
                }
            }
        }

        if effectivePool != .services && settings.hasJellyfin && (mood == .any || effectivePool == .library) {
            let types = kinds.map { $0 == .movie ? "Movie" : "Series" }.joined(separator: ",")
            let items = (try? await Jellyfin.items(types: types, sortBy: "Random", filters: "IsUnplayed", limit: 30)) ?? []
            out += items.map { j in
                Candidate(title: j.name ?? "", year: j.productionYear.map(String.init), overview: j.overview,
                          rating: j.communityRating, poster: j.posterURL, tmdb: nil, jellyfin: j)
            }
        }
        return out
    }

    private func roll() async {
        rolling = true
        errorText = nil
        defer { rolling = false }
        withAnimation { result = nil }

        let pool = (try? await candidates()) ?? []
        guard let winner = pool.randomElement() else {
            errorText = settings.hasTMDB || settings.hasJellyfin
                ? "Non ho trovato nulla con questi filtri: prova un altro umore."
                : "Configura TMDB o Jellyfin nelle Impostazioni per usare questa funzione."
            return
        }
        // Effetto "slot machine": scorre qualche locandina rallentando.
        let spins = min(14, max(4, pool.count))
        for i in 0..<spins {
            withAnimation(.easeInOut(duration: 0.12)) { flashing = pool.randomElement() }
            try? await Task.sleep(for: .milliseconds(70 + i * 18))
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            flashing = nil
            result = winner
        }
    }
}
