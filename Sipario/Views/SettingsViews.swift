import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Impostazioni

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Library?
    @State private var showAdd = false
    @State private var keyDraft = ""
    @State private var keyStatus: KeyStatus = .idle

    enum KeyStatus { case idle, checking, ok, bad }

    var body: some View {
        NavigationStack {
            Form {
                librariesSection
                tmdbSection
                Section {
                    Toggle("Episodio successivo in automatico", isOn: $settings.autoplayNext)
                } header: {
                    Text("Riproduzione")
                } footer: {
                    Text("Il player di iOS legge MP4, MOV, M4V e i flussi HLS (.m3u8). Per MKV, AVI e altri formati Sipario ti propone di aprire il video in VLC o Infuse (gratuiti sull'App Store).")
                }
                Section("Informazioni") {
                    LabeledContent("Versione", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("Sipario non contiene né fornisce contenuti: mostra e riproduce solo le librerie che aggiungi tu. Usa librerie di contenuti che hai il diritto di guardare.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .sheet(item: $editing) { LibraryEditorView(library: $0) }
            .sheet(isPresented: $showAdd) { LibraryEditorView(library: nil) }
            .onAppear { keyDraft = settings.tmdbKey }
        }
    }

    private var librariesSection: some View {
        Section {
            ForEach(store.libraries) { lib in
                Button { editing = lib } label: { LibraryRow(library: lib) }
            }
            .onDelete { offsets in
                for i in offsets { store.remove(store.libraries[i].id) }
            }
            Button { showAdd = true } label: { Label("Aggiungi libreria", systemImage: "plus.circle.fill") }
            NavigationLink { FormatsHelpView() } label: { Label("Formati supportati", systemImage: "questionmark.circle") }
            if !store.libraries.isEmpty {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    HStack {
                        Label("Aggiorna tutte", systemImage: "arrow.clockwise")
                        Spacer()
                        if !store.refreshing.isEmpty { ProgressView() }
                    }
                }
                .disabled(!store.refreshing.isEmpty)
            }
        } header: {
            Text("Le tue librerie")
        } footer: {
            Text("Le librerie si aggiornano da sole ogni 6 ore all'apertura dell'app; nella Home puoi anche tirare verso il basso.")
        }
    }

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
                .disabled(keyDraft.trimmed.isEmpty || keyStatus == .checking)
                Spacer()
                switch keyStatus {
                case .ok: Label("Funziona", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
                case .bad: Label("Non valida", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.footnote)
                case .checking: ProgressView()
                case .idle: EmptyView()
                }
            }
            if store.enrichTotal > 0 {
                LabeledContent("Schede preparate", value: "\(store.enrichDone) di \(store.enrichTotal)")
            }
            if settings.hasTMDB {
                Button("Cerca di nuovo le schede mancanti") {
                    Task { await store.enrich(force: true) }
                }
            }
            Link("Ottieni una chiave gratuita su TMDB", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
        } header: {
            Text("Copertine e schede (TMDB)")
        } footer: {
            Text("Facoltativo ma consigliato: con una chiave gratuita di themoviedb.org Sipario abbina i tuoi titoli alle schede ufficiali, con locandine, sfondi, loghi, trame in italiano, generi, cast e trailer.")
        }
    }

    private func checkKey() async {
        keyStatus = .checking
        let clean = keyDraft.trimmed
        if await TMDB.test(clean) {
            settings.tmdbKey = clean
            keyStatus = .ok
            Task { await store.enrich() }
        } else {
            keyStatus = .bad
        }
    }
}

struct LibraryRow: View {
    let library: Library
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: library.isFile ? "doc.fill" : "link")
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name).foregroundStyle(.primary)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let e = library.lastError {
                    Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            if store.refreshing.contains(library.id) { ProgressView() }
        }
    }

    private var summary: String {
        let c = store.counts(for: library.id)
        var parts: [String] = []
        if let n = c[.movie], n > 0 { parts.append(n == 1 ? "1 film" : "\(n) film") }
        if let n = c[.series], n > 0 { parts.append(n == 1 ? "1 serie" : "\(n) serie") }
        if let n = c[.live], n > 0 { parts.append(n == 1 ? "1 canale" : "\(n) canali") }
        if parts.isEmpty { parts.append("vuota") }
        return parts.joined(separator: " · ") + " — " + library.sourceLabel
    }
}

// MARK: - Aggiunta / modifica di una libreria

struct LibraryEditorView: View {
    let library: Library?

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var source = ""
    @State private var hint: KindHint = .auto
    @State private var pickedFile: (name: String, data: Data)?
    @State private var working = false
    @State private var message: String?
    @State private var success = false
    @State private var showFilePicker = false
    @State private var confirmDelete = false

    private var isNew: Bool { library == nil }
    private var usingFile: Bool { pickedFile != nil || (library?.isFile ?? false) }

    private var validURL: Bool {
        guard let u = URL(string: source.trimmed), let s = u.scheme?.lowercased() else { return false }
        return (s == "http" || s == "https") && u.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome (es. Film di casa)", text: $name)
                    if !usingFile {
                        TextField("Link della libreria (https://…)", text: $source, axis: .vertical)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...4)
                    }
                    Picker("Contenuto", selection: $hint) {
                        ForEach(KindHint.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Incolla il link di una playlist M3U, di un catalogo JSON, di una cartella web con file video (ad esempio il tuo NAS), di una pagina web con un video, di Internet Archive o PeerTube, o di un singolo video.")
                }

                if isNew {
                    Section {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label(pickedFile == nil ? "Oppure scegli un file dall'app File" : "Cambia file", systemImage: "folder")
                        }
                        if let f = pickedFile {
                            HStack {
                                Label(f.name, systemImage: "doc.fill")
                                Spacer()
                                Button("Togli") { pickedFile = nil }.font(.footnote)
                            }
                        }
                    } footer: {
                        Text("Playlist .m3u / .m3u8 o catalogo .json salvati sull'iPhone.")
                    }
                } else if let library {
                    Section {
                        Button {
                            Task { await store.refresh(library.id) }
                        } label: {
                            HStack {
                                Label("Aggiorna ora", systemImage: "arrow.clockwise")
                                Spacer()
                                if store.refreshing.contains(library.id) { ProgressView() }
                            }
                        }
                        if let d = library.lastUpdated {
                            LabeledContent("Ultimo aggiornamento", value: d.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Elimina libreria", role: .destructive) { confirmDelete = true }
                    }
                }

                if let message {
                    Section {
                        Label(message, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(success ? .green : .orange)
                            .font(.footnote)
                    }
                }

                Section {
                    NavigationLink("Che link posso usare?") { FormatsHelpView() }
                }
            }
            .navigationTitle(isNew ? "Nuova libreria" : "Libreria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(isNew ? "Importa" : "Salva") { Task { await save() } }
                            .disabled(!(usingFile || validURL))
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: false) { result in
                pick(result)
            }
            .confirmationDialog("Eliminare «\(library?.name ?? "")»? I file originali non vengono toccati.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let library { store.remove(library.id) }
                    dismiss()
                }
            }
            .onAppear(perform: setup)
        }
    }

    private static var fileTypes: [UTType] {
        var t: [UTType] = [.json, .plainText, .text, .data]
        if let m3u = UTType(filenameExtension: "m3u") { t.insert(m3u, at: 0) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { t.insert(m3u8, at: 0) }
        return t
    }

    private func setup() {
        if let library {
            name = library.name
            source = library.isFile ? "" : library.source
            hint = library.hint
        } else if source.isEmpty, let clip = UIPasteboard.general.url, ["http", "https"].contains(clip.scheme?.lowercased() ?? "") {
            source = clip.absoluteString
        }
    }

    private func pick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "Non riesco a leggere il file."
            success = false
            return
        }
        pickedFile = (url.lastPathComponent, data)
        if name.trimmed.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }

    private func defaultName() -> String {
        if let f = pickedFile { return (f.name as NSString).deletingPathExtension }
        if let u = URL(string: source.trimmed) {
            let last = u.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
            if !last.isEmpty && last != "/" { return last }
            return u.host ?? "Libreria"
        }
        return "Libreria"
    }

    private func save() async {
        working = true
        message = nil
        defer { working = false }
        let finalName = name.trimmed.isEmpty ? defaultName() : name.trimmed
        if var lib = library {
            lib.name = finalName
            lib.hint = hint
            if !lib.isFile { lib.source = source.trimmed }
            await store.update(lib)
            dismiss()
            return
        }
        do {
            let counts: [ItemKind: Int]
            if let f = pickedFile {
                counts = try await store.addLibrary(name: finalName, source: "file:" + f.name, hint: hint, fileData: f.data)
            } else {
                counts = try await store.addLibrary(name: finalName, source: source.trimmed, hint: hint)
            }
            var parts: [String] = []
            if let n = counts[.movie], n > 0 { parts.append("\(n) film") }
            if let n = counts[.series], n > 0 { parts.append("\(n) serie") }
            if let n = counts[.live], n > 0 { parts.append("\(n) canali") }
            message = "Trovati " + parts.joined(separator: ", ")
            success = true
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            message = error.localizedDescription
            success = false
        }
    }
}

// MARK: - Guida ai formati

struct FormatsHelpView: View {
    private let m3uExample = """
    #EXTM3U
    #EXTINF:-1 tvg-logo="https://…/poster.jpg" group-title="Azione",Inception (2010)
    https://mio-server.it/film/Inception.2010.mp4
    #EXTINF:-1 group-title="Serie TV",Dark S01E01 Segreti
    https://mio-server.it/serie/Dark/S01E01.mp4
    """

    private let jsonExample = """
    {
      "name": "La mia videoteca",
      "movies": [
        { "title": "Inception", "year": 2010,
          "poster": "https://…/poster.jpg",
          "genres": ["Azione"],
          "url": "https://…/inception.mp4" }
      ],
      "series": [
        { "title": "Dark", "year": 2017,
          "seasons": [
            { "season": 1, "episodes": [
              { "episode": 1, "title": "Segreti",
                "url": "https://…/dark-s01e01.mp4" }
            ] }
          ] }
      ]
    }
    """

    var body: some View {
        List {
            Section {
                Text("Una playlist con un video per voce. Sipario usa il nome, la copertina (tvg-logo) e la categoria (group-title). I nomi con S01E02 o 1x02 diventano episodi raggruppati per serie e stagione; l'anno tra parentesi aiuta a trovare la scheda giusta.")
                code(m3uExample)
            } header: { Text("Playlist M3U / M3U8") }

            Section {
                Text("Un elenco di film e serie con le loro stagioni. Campi facoltativi: year, poster, backdrop, overview, genres, tmdb (id della scheda). Va bene anche un semplice elenco [ … ] di elementi con \"type\": \"movie\", \"series\" o \"live\".")
                code(jsonExample)
            } header: { Text("Catalogo JSON") }

            Section {
                Text("Il link a una cartella condivisa via web che mostra l'elenco dei file (ad esempio il server web di un NAS Synology o QNAP, o una cartella condivisa con un server HTTP). Sipario esplora fino a 5 livelli di sottocartelle: le cartelle \"Serie\", \"Stagione 1\", \"Season 2\" vengono riconosciute come serie, e un'immagine poster.jpg o folder.jpg nella cartella diventa la copertina.")
            } header: { Text("Cartella web") }

            Section {
                Text("Il link diretto a un file video (.mp4, .mov, .m4v…) o a un flusso HLS (.m3u8).")
            } header: { Text("Singolo video") }
            Section {
                Text("Il link di un video, di una collezione o di una ricerca su archive.org (ad esempio archive.org/details/…): ogni titolo arriva con copertina, anno e trama. Ci sono migliaia di film di pubblico dominio.")
            } header: { Text("Internet Archive") }
            Section {
                Text("Il link di un video, di un canale (/c/…), di un account (/a/…) o di una playlist (/w/p/…) di un'istanza PeerTube. Le playlist con S01E02 nei titoli diventano serie.")
            } header: { Text("PeerTube") }
            Section {
                Text("Il link di una pagina che contiene un video in chiaro (MP4 o HLS). Sipario apre la pagina in un browser invisibile che blocca i circuiti pubblicitari, trova il flusso del video e importa solo quello, con titolo e copertina della pagina. Non funziona con i video protetti da DRM (RaiPlay, Netflix, Prime Video…) né con le pubblicità inserite dentro il flusso stesso.")
            } header: { Text("Pagina web") }

            Section {
                Text("Sipario non fornisce contenuti: usa solo librerie di video che possiedi o che hai il diritto di guardare.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Formati supportati")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func code(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
