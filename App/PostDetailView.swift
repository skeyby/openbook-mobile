import SwiftUI
import OpenBookCore

struct PostDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var detail: PostDetail
    @State private var comments: CommentFeed
    @State private var editor: CommentEditor?
    @State private var showEditor = false
    @State private var pendingMode: CommentEditor.Mode?
    @State private var confirmSwitch = false
    @State private var deleting: Comment?
    @State private var deletionError: String?
    @State private var deletionBlocked = false
    @State private var revealedComments = false
    @State private var notice: String?

    init(postID: String, api: APIClient) {
        _detail = State(initialValue: PostDetail(postID: postID, api: api))
        _comments = State(initialValue: CommentFeed(postID: postID, api: api))
    }
    private var currentPost: Post? { detail.post.flatMap { store.management.current($0) } }
    private var commentsAllowed: Bool { currentPost.map { !$0.postCW || revealedComments } ?? false }
    private var visibleComments: [Comment] { comments.comments.compactMap { store.comments.current($0) } }
    private var threadRows: [CommentThread.Row] { CommentThread.rows(in: visibleComments) }

    var body: some View {
        Group {
            if let post = detail.post {
                if let current = store.management.current(post) {
                    List {
                        Section {
                            PostRow(post: current, opensDetails: false)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                        Section {
                            if commentsAllowed { commentContent }
                            else {
                                Button("Mostra i commenti di questo contenuto") { revealedComments = true }
                                Text("I commenti possono riferirsi al contenuto protetto dall’avviso.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } header: {
                            commentHeader
                        } footer: {
                            if commentsAllowed && comments.hasLoaded {
                                Text("Le conversazioni remote possono essere incomplete.").font(.caption)
                            }
                        }
                    }
                    .listStyle(.plain)
                    #if os(iOS)
                    .listSectionSpacing(8)
                    #endif
                    .refreshable { await load() }
                } else {
                    ContentUnavailableView("Post eliminato", systemImage: "trash", description: Text("Questo post è stato eliminato. Puoi tornare alla timeline."))
                }
            } else if detail.isLoading {
                ProgressView("Caricamento post…")
            } else {
                ContentUnavailableView {
                    Label("Post non disponibile", systemImage: "text.bubble")
                } description: { Text(detail.errorMessage ?? "Impossibile caricare il post.") } actions: {
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
                .disabled(detail.isLoading || comments.isLoading || store.management.deleted.contains(detail.postID))
        }
        .task { await load() }
        .task(id: commentsAllowed) {
            if commentsAllowed && !comments.hasLoaded { await loadComments(reset: true) }
        }
        .sheet(isPresented: $showEditor) {
            if let editor {
                CommentEditorView(editor: editor, allowsSaving: comments.canWrite, saved: {
                    notice = editor.isEditing ? "Commento modificato." : "Commento pubblicato."
                    showEditor = false; self.editor = nil
                    requestCommentRefresh()
                    Task { await store.comments.refreshCount(postID: detail.postID) { try await store.authorizedCredentials() } }
                }, close: {
                    showEditor = false; self.editor = nil
                }, checkComments: {
                    showEditor = false
                    notice = "Controlla se il commento è presente. La bozza resta disponibile con Riprendi bozza."
                    Task { await load() }
                })
            }
        }
        .confirmationDialog("Hai già una bozza. Vuoi scartarla?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Scarta e continua", role: .destructive) {
                if let pendingMode { openEditor(pendingMode) }
                pendingMode = nil
            }
            Button("Riprendi bozza") { pendingMode = nil; showEditor = true }
            Button("Annulla", role: .cancel) { pendingMode = nil }
        }
        .confirmationDialog("Eliminare questo commento?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting {
                Button("Elimina commento", role: .destructive) { Task { await delete(deleting) } }
            }
        } message: { Text("Il commento verrà eliminato. Le sue risposte pubblicate resteranno disponibili.") }
    }

    private var commentHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Commenti").font(.headline).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if commentsAllowed && comments.canWrite {
                    Button("Commenta", systemImage: "square.and.pencil") {
                        requestEditor(.create(parentID: nil, parentName: nil))
                    }
                    .font(.subheadline).buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Scrivi un commento")
                    .disabled(currentPost?.postVisibility == "direct")
                }
            }
            if commentsAllowed && comments.canWrite {
                if editor != nil {
                    Button("Riprendi bozza") { showEditor = true }
                        .font(.subheadline).buttonStyle(.borderless)
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if currentPost?.postVisibility == "direct" {
                    Text("Non è possibile aggiungere commenti a un post diretto.").font(.caption)
                }
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }

    @ViewBuilder private var commentContent: some View {
        if let message = comments.unavailableMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "bubble.left").foregroundStyle(.secondary)
                Button("Verifica di nuovo") { Task { await loadComments(reset: true) } }
                    .disabled(comments.isLoading)
            }.padding(.vertical, 8)
        }
        ForEach(threadRows) { row in
            let comment = row.comment
            CommentRow(comment: comment,
                       parent: visibleComments.first { $0.id.lowercased() == comment.commentParentId?.lowercased() },
                       depth: row.depth, parentUnavailable: row.parentUnavailable,
                       canReply: comments.canWrite && currentPost?.postVisibility != "direct",
                       reply: { requestEditor(.create(parentID: comment.id, parentName: comment.commentAuthor.personName)) },
                       edit: { requestEditor(.edit(commentID: comment.id)) },
                       delete: { deleting = comment })
                .disabled(deletionBlocked)
        }
        if let deletionError {
            Text(deletionError).font(.footnote).foregroundStyle(.red)
            Button("Ricarica commenti") { Task { await loadComments(reset: true) } }
        }
        if let message = comments.errorMessage {
            Text(message).foregroundStyle(.red)
            Button(comments.needsRestart || !comments.hasLoaded ? "Ricarica dall’inizio" : "Riprova") {
                Task { await loadComments(reset: comments.needsRestart || !comments.hasLoaded, retry: true) }
            }
            if comments.hasLoaded && !comments.needsRestart {
                Button("Ricarica dall’inizio") { Task { await loadComments(reset: true) } }
            }
        } else if comments.hasLoaded && visibleComments.isEmpty && !comments.hasNext {
            Text("Nessun commento disponibile su questa istanza.").foregroundStyle(.secondary)
        }
        if comments.hasNext && comments.errorMessage == nil {
            ProgressView("Altri commenti…").frame(maxWidth: .infinity)
                .task(id: comments.nextPage) { await loadComments(reset: false) }
        } else if comments.isLoading { ProgressView("Caricamento commenti…") }
    }

    private func requestEditor(_ mode: CommentEditor.Mode) {
        guard comments.canWrite else { return }
        if editor?.hasDraft == true {
            pendingMode = mode; confirmSwitch = true
        } else { openEditor(mode) }
    }
    private func openEditor(_ mode: CommentEditor.Mode) {
        guard comments.canWrite else { return }
        editor = CommentEditor(postID: detail.postID, mode: mode, currentPersonID: store.currentPersonID, api: store.api)
        showEditor = true
    }
    private func requestCommentRefresh() {
        Task { await loadComments(reset: true) }
    }
    private func delete(_ comment: Comment) async {
        deleting = nil
        do {
            try await store.comments.delete(comment, currentPersonID: store.currentPersonID) { try await store.authorizedCredentials() }
            notice = "Commento eliminato."
            requestCommentRefresh()
            await store.comments.refreshCount(postID: detail.postID) { try await store.authorizedCredentials() }
        } catch {
            deletionBlocked = true
            deletionError = "Cancellazione non confermata. \(error.localizedDescription) Ricarica i commenti prima di riprovare."
        }
    }
    private func loadComments(reset: Bool, retry: Bool = false) async {
        guard commentsAllowed else { return }
        let revision = store.comments.revision
        if let page = await comments.load(reset: reset, retry: retry, credentials: { try await store.authorizedCredentials() }) {
            store.comments.ingest(page, ifRevision: revision)
            if reset { deletionError = nil; deletionBlocked = false }
        }
    }
    private func load() async {
        guard !comments.isLoading else { return }
        let reactionRevision = store.likes.revision
        let announceRevision = store.announces.revision
        let managementRevision = store.management.revision
        let commentRevision = store.comments.revision
        if let fresh = await detail.load(credentials: { try await store.authorizedCredentials() }) {
            store.likes.ingest([fresh], ifRevision: reactionRevision)
            store.announces.ingest([fresh], ifRevision: announceRevision)
            store.management.ingest([fresh], ifRevision: managementRevision)
            store.comments.ingestPosts([fresh], ifRevision: commentRevision)
            await loadComments(reset: true)
        }
    }
}
