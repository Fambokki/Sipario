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
            ForEach(ExternalPlayer.allCases) { p in
                Button("Apri in \(p.name)") {
                    if let u = p.link(for: f.url) { openURL(u) }
                }
            }
            Button("Copia il link") { UIPasteboard.general.url = f.url }
            Button("Annulla", role: .cancel) {}
        } message: { f in
            Text(f.message)
        }
    }
}
