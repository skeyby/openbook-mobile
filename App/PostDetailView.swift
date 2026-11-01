import SwiftUI
import OpenBookCore

struct PostDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var detail: PostDetail

    init(postID: String, api: APIClient) {
        _detail = State(initialValue: PostDetail(postID: postID, api: api))
    }

    var body: some View {
        Group {
            if let post = detail.post {
                if let current = store.management.current(post) {
                    List {
                        Section {
                            PostRow(post: current, opensDetails: false)
                        }
                        Section("Commenti") {
                            Text("I commenti saranno disponibili in un prossimo aggiornamento.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load() }
                } else {
                    ContentUnavailableView("Post eliminato", systemImage: "trash", description: Text("Questo post è stato eliminato. Puoi tornare alla timeline."))
                }
            } else if detail.isLoading {
                ProgressView("Caricamento post…")
            } else {
                ContentUnavailableView {
                    Label("Post non disponibile", systemImage: "text.bubble")
                } description: {
                    Text(detail.errorMessage ?? "Impossibile caricare il post.")
                } actions: {
                    Button("Riprova") { Task { await load() } }
                }
            }
        }
        .navigationTitle("Post")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .modifier(BackNavigation())
        .toolbar {
            Button("Aggiorna post", systemImage: "arrow.clockwise") { Task { await load() } }
                .disabled(detail.isLoading || store.management.deleted.contains(detail.postID))
        }
        .task { await load() }
    }

    private func load() async {
        let reactionRevision = store.likes.revision
        let announceRevision = store.announces.revision
        let managementRevision = store.management.revision
        if let fresh = await detail.load(credentials: { try await store.authorizedCredentials() }) {
            store.likes.ingest([fresh], ifRevision: reactionRevision)
            store.announces.ingest([fresh], ifRevision: announceRevision)
            store.management.ingest([fresh], ifRevision: managementRevision)
        }
    }
}
