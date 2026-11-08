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

    // MARK: Jellyfin

    private var jellyfinSection: some View {
        Section {
            if settings.hasJellyfin {
                LabeledContent("Server", value: settings.jellyfinServer)
                LabeledContent("Utente", value: settings.jellyfinUserName)
                Picker("Qualità streaming", selection: $settings.maxBitrate) {
                    ForEach(bitrates.indices, id: \.self) { i in Text(bitrates[i].0).tag(bitrates[i].1) }
                }
                Button("Aggiorna la libreria") {
                    Task { await library.refresh(force: true) }
                }
                Button("Esci", role: .destructive) {
                    settings.logoutJellyfin()
                    Task { await library.refresh(force: true) }
                }
            } else {
                TextField("Indirizzo (es. http://192.168.1.10:8096)", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Nome utente", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                if let loginError {
                    Text(loginError).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    Task { await login() }
                } label: {
                    if loggingIn { ProgressView() } else { Text("Accedi") }
                }
                .disabled(server.isEmpty || username.isEmpty || loggingIn)
            }
        } header: {
            Text("Il tuo server Jellyfin")
        } footer: {
            Text("Jellyfin è gratuito e open source: installalo su un PC o NAS e aggiungi le cartelle con i tuoi film. Fuori casa serve un indirizzo raggiungibile da internet (es. Tailscale).")
        }
    }

    private func login() async {
        loggingIn = true
        loginError = nil
        defer { loggingIn = false }
        do {
            try await Jellyfin.login(server: server, username: username, password: password)
            password = ""
            await library.refresh(force: true)
        } catch {
            loginError = error.localizedDescription
        }
    }

    // MARK: Info

    private var aboutSection: some View {
        Section("Informazioni") {
            LabeledContent("Versione", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            Text("Sipario riproduce solo contenuti legali: il tuo server Jellyfin e i film di pubblico dominio dell'Internet Archive. Per i titoli dei servizi in abbonamento ti porta direttamente nella loro app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
