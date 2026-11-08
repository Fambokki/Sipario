import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: JellyfinLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var keyDraft = ""
    @State private var keyStatus: KeyStatus = .idle
    @State private var providers: [TMDBProvider] = []
    @State private var providerFilter = ""

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var loginError: String?
    @State private var kind: ServerKind = .jellyfin
    @State private var plexWaiting = false
    @State private var plexAuthURL: URL?
    @State private var plexServers: [PlexServer] = []
    @State private var plexAccountToken = ""
    @State private var plexUsername = ""
    @State private var connectingServer: String?
    @Environment(\.openURL) private var openURL

    enum KeyStatus: Equatable { case idle, checking, ok, bad }

    private let bitrates: [(String, Int)] = [
        ("Originale (fino a 120 Mbps)", 120_000_000),
        ("Alta (40 Mbps)", 40_000_000),
        ("Buona (20 Mbps)", 20_000_000),
        ("Media (8 Mbps)", 8_000_000),
        ("Risparmio dati (3 Mbps)", 3_000_000),
    ]

    var body: some View {
        NavigationStack {
            Form {
                tmdbSection
                if settings.hasTMDB { servicesSection }
                jellyfinSection
                aboutSection
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .onAppear {
                keyDraft = settings.tmdbKey
                server = settings.jellyfinServer
                username = settings.jellyfinUserName
                kind = settings.serverKind
            }
            .task(id: settings.cleanTMDBKey) {
                guard settings.hasTMDB else { providers = []; return }
                providers = (try? await TMDB.providers()) ?? []
            }
        }
    }

    // MARK: TMDB

    private var tmdbSection: some View {
        Section {
            TextField("Chiave API o token di lettura", text: $keyDraft, axis: .vertical)
                .lineLimit(1...3)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button(keyStatus == .checking ? "Verifico…" : "Salva e verifica") {
                    Task { await checkKey() }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyStatus == .checking)
                Spacer()
                switch keyStatus {
                case .ok: Label("Funziona", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
                case .bad: Label("Non valida", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.footnote)
                case .checking: ProgressView()
                case .idle: EmptyView()
                }
            }
            Link("Ottieni una chiave gratuita su TMDB", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
        } header: {
            Text("Catalogo film e serie")
        } footer: {
            Text("Registrati gratis su themoviedb.org, poi in Impostazioni → API crea una chiave (uso personale). Va bene sia la \"Chiave API\" sia il \"Token di lettura\".")
        }
    }

    private func checkKey() async {
        keyStatus = .checking
        let clean = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if await TMDB.test(key: clean) {
            settings.tmdbKey = clean
            keyStatus = .ok
        } else {
            keyStatus = .bad
        }
    }

    // MARK: Abbonamenti

    private var filteredProviders: [TMDBProvider] {
        let f = providerFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let base = f.isEmpty ? Array(providers.prefix(30)) : providers.filter { $0.providerName.lowercased().contains(f) }
        // I servizi già scelti in cima.
        let chosen = settings.serviceIds
        return base.filter { chosen.contains($0.providerId) } + base.filter { !chosen.contains($0.providerId) }
    }

    private var servicesSection: some View {
        Section {
            TextField("Cerca un servizio", text: $providerFilter)
                .textInputAutocapitalization(.never)
            if providers.isEmpty {
                ProgressView()
            }
            ForEach(filteredProviders) { p in
                Button {
                    settings.toggleService(p.saved)
                } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: p.logoURL)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(p.providerName).foregroundStyle(.primary)
                        Spacer()
                        if settings.serviceIds.contains(p.providerId) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        } header: {
            Text("I miei abbonamenti")
        } footer: {
            Text("Sipario evidenzia cosa è incluso nei tuoi servizi e crea una riga in Home per ognuno.")
        }
    }

    // MARK: Server personale

    private var jellyfinSection: some View {
        Section {
            if settings.hasJellyfin {
                LabeledContent("Tipo", value: settings.serverKind.name)
                if settings.serverKind == .plex && !settings.serverName.isEmpty {
                    LabeledContent("Server", value: settings.serverName)
                } else {
                    LabeledContent("Server", value: settings.jellyfinServer)
                }
                LabeledContent("Utente", value: settings.jellyfinUserName)
                Picker("Qualità streaming", selection: $settings.maxBitrate) {
                    ForEach(bitrates.indices, id: \.self) { i in Text(bitrates[i].0).tag(bitrates[i].1) }
                }
                Button("Aggiorna la libreria") {
                    Task { await library.refresh(force: true) }
                }
                Button("Esci", role: .destructive) {
                    settings.logoutJellyfin()
                    plexServers = []
                    Task { await library.refresh(force: true) }
                }
            } else {
                Picker("Tipo di server", selection: $kind) {
                    ForEach(ServerKind.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .plex {
                    plexLogin
                } else {
                    TextField("Indirizzo (es. http://192.168.1.10:8096)", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Nome utente", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button {
                        Task { await login() }
                    } label: {
                        if loggingIn { ProgressView() } else { Text("Accedi") }
                    }
                    .disabled(server.isEmpty || username.isEmpty || loggingIn)
                }
                if let loginError {
                    Text(loginError).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Il tuo server")
        } footer: {
            Text(serverFooter)
        }
    }

    private var serverFooter: String {
        switch settings.hasJellyfin ? settings.serverKind : kind {
        case .jellyfin:
            return "Jellyfin è gratuito e open source: installalo su un PC o NAS e aggiungi le cartelle con i tuoi film. Fuori casa serve un indirizzo raggiungibile da internet (es. Tailscale)."
        case .emby:
            return "Usa lo stesso indirizzo, utente e password che usi nell'app di Emby (di solito la porta è 8096)."
        case .plex:
            return "Accedi con il tuo account Plex: si apre la pagina ufficiale di Plex, poi torni qui. Plex chiede l'abbonamento Plex Pass per guardare i propri file fuori dalla rete di casa."
        }
    }

    @ViewBuilder
    private var plexLogin: some View {
        if plexServers.isEmpty {
            Button {
                Task { await startPlexLogin() }
            } label: {
                HStack {
                    Text(plexWaiting ? "In attesa dell'accesso su plex.tv…" : "Accedi con Plex")
                    Spacer()
                    if plexWaiting { ProgressView() } else { Image(systemName: "arrow.up.right.square") }
                }
            }
            .disabled(plexWaiting)
            if plexWaiting, let u = plexAuthURL {
                Link("Riapri la pagina di accesso", destination: u).font(.footnote)
            }
        } else {
            ForEach(plexServers) { srv in
                Button {
                    Task { await connectPlex(srv) }
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading) {
                            Text(srv.name).foregroundStyle(.primary)
                            Text(srv.owned == false ? "Condiviso con te" : "Tuo").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connectingServer == srv.id { ProgressView() }
                    }
                }
                .disabled(connectingServer != nil)
            }
        }
    }

    private func login() async {
        loggingIn = true
        loginError = nil
        defer { loggingIn = false }
        do {
            try await Jellyfin.login(kind: kind, server: server, username: username, password: password)
            password = ""
            await library.refresh(force: true)
        } catch {
            loginError = error.localizedDescription
        }
    }

    private func startPlexLogin() async {
        loginError = nil
        do {
            let pin = try await Plex.createPin()
            guard let u = Plex.authURL(pin) else { return }
            plexAuthURL = u
            plexWaiting = true
            openURL(u)
            defer { plexWaiting = false }
            // Controlla ogni 2 secondi per 5 minuti.
            for _ in 0..<150 {
                try await Task.sleep(for: .seconds(2))
                if let token = try? await Plex.checkPin(pin) {
                    plexAccountToken = token
                    plexUsername = await Plex.username(accountToken: token)
                    let list = try await Plex.servers(accountToken: token)
                    if list.isEmpty {
                        loginError = "Il tuo account Plex non ha server disponibili."
                    } else if list.count == 1 {
                        await connectPlex(list[0])
                    } else {
                        plexServers = list
                    }
                    return
                }
            }
            loginError = "Tempo scaduto: riprova l'accesso."
        } catch {
            plexWaiting = false
            loginError = error.localizedDescription
        }
    }

    private func connectPlex(_ srv: PlexServer) async {
        connectingServer = srv.id
        defer { connectingServer = nil }
        do {
            try await Plex.connect(srv, accountToken: plexAccountToken, username: plexUsername)
            plexServers = []
            await library.refresh(force: true)
        } catch {
            loginError = error.localizedDescription
        }
    }

    // MARK: Info

    private var aboutSection: some View {
        Section("Informazioni") {
            LabeledContent("Versione", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            Text("Sipario riproduce solo contenuti legali: il tuo server (Jellyfin, Emby o Plex) e i film di pubblico dominio dell'Internet Archive. Per i titoli dei servizi in abbonamento ti porta direttamente nella loro app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
