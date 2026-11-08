import SwiftUI
import UIKit
import WebKit

/// Stato del browser integrato.
@MainActor
final class WebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress: Double = 0
    @Published var currentURL: URL?
    @Published var blockedPopups = 0
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.title = wv.title ?? "" }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.currentURL = wv.url }
            },
        ]
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    // I link che aprono una nuova finestra (target=_blank) restano nella stessa pagina;
    // le finestre che si aprono da sole (pubblicità) vengono bloccate.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated, let u = navigationAction.request.url {
            webView.load(URLRequest(url: u))
        } else {
            blockedPopups += 1
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        // Link verso altre app (es. "apri nell'app RaiPlay"): li apre il sistema.
        _ = await UIApplication.shared.open(url)
        return .cancel
    }
}

struct WebViewContainer: UIViewRepresentable {
    let model: WebModel
    let initial: URL

    func makeUIView(context: Context) -> WKWebView {
        if model.webView.url == nil { model.load(initial) }
        return model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebBrowserView: View {
    let url: URL
    let title: String

    @StateObject private var model = WebModel()
    @EnvironmentObject private var myList: MyList
    @EnvironmentObject private var links: LinkStore
    @Environment(\.openURL) private var openURL

    private var pageURL: URL { model.currentURL ?? url }
    private var pageTitle: String { model.title.isEmpty ? title : model.title }
    private var savedItem: SavedItem {
        SavedItem(source: .web, key: pageURL.absoluteString, title: pageTitle, imageURL: nil)
    }

    var body: some View {
        WebViewContainer(model: model, initial: url)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                if model.progress > 0 && model.progress < 1 {
                    ProgressView(value: model.progress)
                        .tint(Theme.accent)
                }
            }
            .navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack)
                    Button { model.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!model.canGoForward)
                    Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Spacer()
                    if model.blockedPopups > 0 {
                        Label("\(model.blockedPopups)", systemImage: "hand.raised.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Finestre bloccate: \(model.blockedPopups)")
                    }
                    Spacer()
                    Button {
                        withAnimation { myList.toggle(savedItem) }
                    } label: {
                        Image(systemName: myList.contains(savedItem.id) ? "bookmark.fill" : "bookmark")
                    }
                    ShareLink(item: pageURL) { Image(systemName: "square.and.arrow.up") }
                    Button { openURL(pageURL) } label: { Image(systemName: "safari") }
                }
            }
            .onDisappear {
                links.addRecent(WebPage(title: pageTitle, url: pageURL))
            }
    }
}
