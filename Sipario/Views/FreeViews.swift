import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Scheda "Gratis": classici, siti gratuiti, i miei link

struct GratisView: View {
    enum Part: String, CaseIterable, Identifiable {
        case classics = "Classici", sites = "Siti gratuiti", links = "I miei link"
        var id: String { rawValue }
    }

    @State private var part: Part = .classics

    var body: some View {
        Group {
            switch part {
            case .classics: ClassicsView()
            case .sites: FreeSitesView()
            case .links: MyLinksView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Sezione", selection: $part) {
                ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .background(Theme.background)
        .navigationTitle("Gratis")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Siti gratuiti

struct FreeSitesView: View {
    @EnvironmentObject private var links: LinkStore
    @EnvironmentObject private var myList: MyList

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var savedPages: [SavedItem] { myList.items.filter { $0.source == .web } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Servizi gratuiti e legali, da guardare senza uscire da Sipario. Le finestre pubblicitarie che si aprono da sole vengono bloccate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(FreeSite.all) { site in
                        NavigationLink(value: Route.web(site.url, site.name)) { tile(site) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                if !savedPages.isEmpty {
                    pageList(title: "Pagine salvate", pages: savedPages.compactMap { s in
                        URL(string: s.key).map { WebPage(title: s.title, url: $0) }
                    })
                }
                if !links.recentPages.isEmpty {
                    pageList(title: "Visitati di recente", pages: links.recentPages, clearable: true)
                }
            }
            .padding(.vertical)
        }
    }

    private func tile(_ site: FreeSite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: site.symbol)
                .font(.title2)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Text(site.name).font(.headline).foregroundStyle(.white)
            Text(site.subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(
            LinearGradient(colors: [site.color, site.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pageList(title: String, pages: [WebPage], clearable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if clearable {
                    Button("Cancella") { links.clearRecent() }.font(.subheadline)
                }
            }
            .padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(pages) { page in
                    NavigationLink(value: Route.web(page.url, page.title)) {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .foregroundStyle(Theme.gold)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(page.url.host ?? page.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 56)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
        }
    }
}

// MARK: - I miei link

struct MyLinksView: View {
    @EnvironmentObject private var links: LinkStore
    @EnvironmentObject private var playback: Playback

    @State private var editing: LinkItem?
    @State private var showAdd = false
    @State private var showImport = false

    var body: some View {
        ScrollView {
            if links.links.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.gold)
                        .padding(.top, 50)
                    Text("I tuoi video, in un posto solo").font(.title3.bold())
                    Text("Aggiungi indirizzi video diretti (.mp4, .m3u8) o importa una playlist M3U: Sipario li riproduce col suo player, con Picture in Picture e ripresa da dove eri rimasto.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 28)
                    HStack {
                        Button("Aggiungi un link") { showAdd = true }.buttonStyle(.borderedProminent)
                        Button("Importa playlist") { showImport = true }.buttonStyle(.bordered)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                    ForEach(links.groups, id: \.self) { group in
                        groupSection(group)
                    }
                }
                .padding(.vertical)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAdd = true } label: { Label("Aggiungi un link", systemImage: "plus") }
                    Button { showImport = true } label: { Label("Importa playlist M3U", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showAdd) { LinkEditorView(link: nil) }
        .sheet(item: $editing) { LinkEditorView(link: $0) }
        .sheet(isPresented: $showImport) { ImportPlaylistView() }
    }

    private func groupSection(_ group: String) -> some View {
        let items = links.links.filter { ($0.group ?? "Senza gruppo") == group }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group).font(.title3.bold())
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Elimina il gruppo", role: .destructive) { links.removeGroup(group) }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(items) { link in
                    Button { playback.play(link) } label: { row(link) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { editing = link } label: { Label("Modifica", systemImage: "pencil") }
                            Button { UIPasteboard.general.url = link.url } label: { Label("Copia indirizzo", systemImage: "doc.on.doc") }
                            Button(role: .destructive) { links.remove(link) } label: { Label("Elimina", systemImage: "trash") }
                        }
                    Divider().padding(.leading, 84)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
        }
    }

    private func row(_ link: LinkItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.background
                if let poster = link.poster {
                    RemoteImage(url: poster, contentMode: .fit, placeholderIcon: "play.rectangle.fill")
                        .padding(4)
                } else {
                    Image(systemName: link.url.pathExtension.lowercased() == "m3u8" ? "dot.radiowaves.left.and.right" : "play.rectangle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 60, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(link.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(link.url.host ?? link.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = links.progress[link.id] {
                    ProgressBar(value: p.fraction).frame(width: 120)
                }
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Aggiunta / modifica di un link

struct LinkEditorView: View {
    let link: LinkItem?

    @EnvironmentObject private var links: LinkStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""
    @State private var poster = ""
    @State private var group = ""

    private var parsedURL: URL? {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        return u
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Indirizzo del video (https://…/video.mp4)", text: $address, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Titolo", text: $title)
                    TextField("Gruppo (facoltativo)", text: $group)
                } footer: {
                    Text("Funzionano i link diretti a file video (.mp4, .mov, .m4v) e i flussi HLS (.m3u8). Usa solo contenuti tuoi o diffusi legalmente.")
                }
                Section("Copertina (facoltativa)") {
                    TextField("Indirizzo di un'immagine", text: $poster)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let link {
                    Section {
                        Button("Elimina", role: .destructive) {
                            links.remove(link)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(link == nil ? "Nuovo link" : "Modifica link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }.disabled(parsedURL == nil)
                }
            }
            .onAppear {
                if let link {
                    title = link.title
                    address = link.url.absoluteString
                    poster = link.poster?.absoluteString ?? ""
                    group = link.group ?? ""
                } else if let clip = UIPasteboard.general.url, ["http", "https"].contains(clip.scheme?.lowercased() ?? "") {
                    address = clip.absoluteString
                }
            }
        }
    }

    private func save() {
        guard let url = parsedURL else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let cleanGroup = group.trimmingCharacters(in: .whitespaces)
        let posterURL = URL(string: poster.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.scheme == nil ? nil : $0 }
        var item = link ?? LinkItem(title: "", url: url)
        item.title = cleanTitle.isEmpty ? (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) : cleanTitle
        item.url = url
        item.poster = posterURL
        item.group = cleanGroup.isEmpty ? nil : cleanGroup
        if link == nil { links.add(item) } else { links.update(item) }
        dismiss()
    }
}

// MARK: - Importazione di una playlist M3U

struct ImportPlaylistView: View {
    @EnvironmentObject private var links: LinkStore
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var group = ""
    @State private var working = false
    @State private var message: String?
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Indirizzo della playlist (.m3u / .m3u8)", text: $address, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Nome del gruppo (facoltativo)", text: $group)
                    Button {
                        Task { await importFromURL() }
                    } label: {
                        if working { ProgressView() } else { Text("Importa dall'indirizzo") }
                    }
                    .disabled(working || URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == nil)
                }
                Section {
                    Button("Scegli un file dall'app File") { showFilePicker = true }
                } footer: {
                    Text("Le voci della playlist compaiono in \"I miei link\", divise per gruppo. Importa solo playlist di contenuti legali.")
                }
                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Importa playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [UTType(filenameExtension: "m3u") ?? .plainText,
                                                UTType(filenameExtension: "m3u8") ?? .plainText, .plainText],
                          allowsMultipleSelection: false) { result in
                importFile(result)
            }
        }
    }

    private var groupName: String {
        let g = group.trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? "Playlist" : g
    }

    private func importFromURL() async {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        working = true
        defer { working = false }
        do {
            let text = try await M3U.download(url)
            report(links.importM3U(text, defaultGroup: groupName))
        } catch {
            message = error.localizedDescription
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                message = "Non riesco a leggere il file."
                return
            }
            let name = group.trimmingCharacters(in: .whitespaces).isEmpty ? url.deletingPathExtension().lastPathComponent : groupName
            report(links.importM3U(text, defaultGroup: name))
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func report(_ count: Int) {
        message = count == 0 ? "Nessuna voce nuova trovata nella playlist." :
            (count == 1 ? "Aggiunto 1 video." : "Aggiunti \(count) video.")
    }
}
