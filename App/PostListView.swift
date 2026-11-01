import SwiftUI
import OpenBookCore

/// One List owns scrolling; profile presentation and feed rows are never nested lists.
struct PostListView<Header: View>: View {
    @EnvironmentObject private var store: AppStore
    @State private var feed: PostFeed
    let title: String
    let isRefreshingHeader: Bool
    let refreshHeader: (() async -> Bool)?
    let header: Header

    init(source: PostSource, api: APIClient, title: String, isRefreshingHeader: Bool = false,
         refreshHeader: (() async -> Bool)? = nil, @ViewBuilder header: () -> Header) {
        _feed = State(initialValue: PostFeed(source: source, api: api))
        self.title = title; self.isRefreshingHeader = isRefreshingHeader
        self.refreshHeader = refreshHeader; self.header = header()
    }

    var body: some View {
        List {
            header
            Section {
                ForEach(visiblePosts) { post in PostRow(post: post) }
            } header: { Text(title) } footer: {
                if case .person = feed.source {
                    Text("Per i profili remoti l’elenco può essere incompleto.")
                }
            }
            if let message = feed.errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Riprova") { Task { await load(reset: !feed.timeline.hasLoaded) } }
                    if feed.timeline.hasLoaded { Button("Ricarica dall’inizio") { Task { await refresh() } } }
                }.padding(.vertical, 8)
            } else if feed.timeline.hasLoaded && visiblePosts.isEmpty && !feed.timeline.hasNext {
                Text("Nessun post da mostrare.").foregroundStyle(.secondary)
            }
            if feed.timeline.hasNext && feed.errorMessage == nil {
                ProgressView("Altri post…").frame(maxWidth: .infinity)
                    .task(id: feed.timeline.nextPage) { await load(reset: false) }
            } else if feed.isLoading {
                HStack { Spacer(); ProgressView("Caricamento post…"); Spacer() }
            } else if feed.timeline.hasLoaded && !visiblePosts.isEmpty && feed.errorMessage == nil {
                Text("Hai raggiunto la fine dei post disponibili.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem {
                Button("Aggiorna", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(feed.isLoading || isRefreshingHeader)
            }
        }
        .task { if !feed.timeline.hasLoaded { await load(reset: true) } }
        .refreshable { await refresh() }
    }

    private var visiblePosts: [Post] { feed.timeline.posts.compactMap { store.management.current($0) } }

    private func refresh() async {
        guard !feed.isLoading, !isRefreshingHeader else { return }
        if let refreshHeader, (await refreshHeader()) == false { return }
        guard !Task.isCancelled else { return }
        await load(reset: true)
    }
    private func load(reset: Bool) async {
        let reactionRevision = store.likes.revision
        let announceRevision = store.announces.revision
        let managementRevision = store.management.revision
        if let page = await feed.load(reset: reset, credentials: { try await store.authorizedCredentials() }) {
            store.likes.ingest(page.posts, ifRevision: reactionRevision)
            store.announces.ingest(page.posts, ifRevision: announceRevision)
            store.management.ingest(page.posts, ifRevision: managementRevision)
        }
    }
}
