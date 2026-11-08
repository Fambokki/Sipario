import SwiftUI

@main
struct SiparioApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var library = JellyfinLibrary.shared
    @StateObject private var myList = MyList.shared
    @StateObject private var playback = Playback.shared
    @StateObject private var matcher = ClassicMatcher.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 80 * 1024 * 1024, diskCapacity: 600 * 1024 * 1024)
        Playback.configureAudio()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(myList)
                .environmentObject(playback)
                .environmentObject(matcher)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

/// Le pagine raggiungibili dalla navigazione.
enum Route: Hashable {
    case tmdb(MediaKind, Int)
    case jellyfin(String)
    case archive(ArchiveItem)
    case discover(title: String, kind: MediaKind, params: [String: String])
}

extension View {
    func siparioDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .tmdb(let kind, let id): TMDBDetailView(kind: kind, id: id)
            case .jellyfin(let id): JellyfinDetailView(id: id)
            case .archive(let item): ArchiveDetailView(item: item)
            case .discover(let title, let kind, let params): DiscoverGridView(title: title, kind: kind, params: params)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var playback: Playback
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView().siparioDestinations() }
                .tabItem { Label("Home", systemImage: "play.tv.fill") }
                .tag(0)
            NavigationStack { SearchView().siparioDestinations() }
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }
                .tag(1)
            NavigationStack { LibraryView().siparioDestinations() }
                .tabItem { Label("Libreria", systemImage: "externaldrive.fill") }
                .tag(2)
            NavigationStack { ClassicsView().siparioDestinations() }
                .tabItem { Label("Classici", systemImage: "film.stack") }
                .tag(3)
            NavigationStack { MyListView().siparioDestinations() }
                .tabItem { Label("La mia lista", systemImage: "bookmark.fill") }
                .tag(4)
        }
        .overlay {
            if playback.isPreparing {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    ProgressView("Preparo il video…")
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Qualcosa non va", isPresented: Binding(
            get: { playback.errorMessage != nil },
            set: { if !$0 { playback.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playback.errorMessage ?? "")
        }
    }
}
