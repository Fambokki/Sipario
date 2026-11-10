import SwiftUI
import UIKit

@main
struct SiparioApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = LibraryStore.shared
    @StateObject private var playback = Playback.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 100 * 1024 * 1024, diskCapacity: 800 * 1024 * 1024)
        Playback.configureAudio()
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(white: 0.04, alpha: 0.85)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(playback)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

/// Le pagine raggiungibili dalla navigazione.
enum Route: Hashable {
    case item(String)
    case collection(String, CollectionFilter)
}

extension View {
    func siparioDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .item(let id): DetailView(id: id)
            case .collection(let title, let filter): CollectionView(title: title, filter: filter)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var playback: Playback
    @Environment(\.openURL) private var openURL

    var body: some View {
        TabView {
            NavigationStack { HomeView().siparioDestinations() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { BrowseView(kind: .movie).siparioDestinations() }
                .tabItem { Label("Film", systemImage: "film.fill") }
            NavigationStack { BrowseView(kind: .series).siparioDestinations() }
                .tabItem { Label("Serie TV", systemImage: "tv.fill") }
            NavigationStack { SearchView().siparioDestinations() }
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }
            NavigationStack { MyListView().siparioDestinations() }
                .tabItem { Label("La mia lista", systemImage: "plus.rectangle.on.rectangle") }
        }
        .task { await store.startup() }
        .confirmationDialog(
            playback.failure?.title ?? "",
            isPresented: Binding(get: { playback.failure != nil }, set: { if !$0 { playback.failure = nil } }),
            titleVisibility: .visible,
            presenting: playback.failure
        ) { f in
            if let url = f.url {
                ForEach(ExternalPlayer.allCases) { p in
                    Button("Apri in \(p.name)") {
                        if let u = p.link(for: url) { openURL(u) }
                    }
                }
                Button("Copia il link") { UIPasteboard.general.url = url }
            }
            Button(f.url == nil ? "OK" : "Annulla", role: .cancel) {}
        } message: { f in
            Text(f.message)
        }
        .background(
            Color.clear.confirmationDialog(
                "Scegli la fonte",
                isPresented: Binding(get: { playback.streamChoice != nil }, set: { if !$0 { playback.streamChoice = nil } }),
                titleVisibility: .visible,
                presenting: playback.streamChoice
            ) { c in
                ForEach(c.options.prefix(20)) { o in
                    Button(o.label) { playback.choose(o, item: c.item, episode: c.episode) }
                }
                Button("Annulla", role: .cancel) {}
            } message: { c in
                Text(c.episode.map { "\(c.item.displayTitle) · \($0.code)" } ?? c.item.displayTitle)
            }
        )
        .overlay {
            if playback.resolving {
                ProgressView("Cerco il video…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}
