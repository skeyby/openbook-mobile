import SwiftUI
import OpenBookCore

struct CommentRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(AppNavigation.self) private var navigation
    let comment: Comment
    let parent: Comment?
    let depth: Int
    let parentUnavailable: Bool
    let canReply: Bool
    let reply: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var activeImage: PostImageSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if parentUnavailable || depth > 3 {
                Text(parent.map { "In risposta a \($0.commentAuthor.personName)" } ?? "Risposta a un commento non caricato o non disponibile")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                Button { navigation.path.append(.person(comment.commentAuthor.personId)) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Avatar(url: comment.commentAuthor.personAvatar)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.commentAuthor.personName).font(.headline)
                            Text(comment.commentAuthor.handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(comment.commentAuthor.personName)
                .accessibilityValue(comment.commentAuthor.handle)
                .accessibilityHint("Apre il profilo dell’autore")
                if comment.isOwned(by: store.currentPersonID) {
                    Menu {
                        Button("Modifica", systemImage: "pencil", action: edit)
                        Button("Elimina commento", systemImage: "trash", role: .destructive, action: delete)
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Azioni sul tuo commento")
                    .disabled(store.comments.pending.contains(comment.id.lowercased()))
                }
            }
            HStack {
                if let date = comment.publishedDate { PostDateText(date: date) }
                if comment.commentEditedAt != nil { Text("Modificato") }
                if depth > 0 {
                    Text("Risposta").accessibilityLabel(parent.map { "Risposta a \($0.commentAuthor.personName), livello \(depth)" } ?? "Risposta, livello \(depth)")
                }
            }.font(.caption).foregroundStyle(.secondary)
            MarkdownPostView(comment.commentContent, baseURL: comment.commentUri, emojis: comment.commentCustomEmojis)
            PostAttachmentsView(attachments: comment.commentAttachments ?? [], selection: $activeImage)
            HStack(spacing: 20) {
                Label("\(comment.commentCounters.commentLikesCount)", systemImage: comment.commentMyInteractions.commentLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .accessibilityLabel("\(comment.commentCounters.commentLikesCount) Mi piace\(comment.commentMyInteractions.commentLiked ? ", incluso il tuo" : "")")
                Label("\(comment.commentCounters.commentRepliesCount)", systemImage: "bubble")
                    .accessibilityLabel("\(comment.commentCounters.commentRepliesCount) risposte dirette note")
                Spacer(minLength: 0)
                Button("Rispondi", systemImage: "arrowshape.turn.up.left", action: reply)
                    .buttonStyle(.borderless)
                    .disabled(!canReply || store.comments.pending.contains(comment.id.lowercased()))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.leading, CGFloat(min(depth, 3)) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle().fill(.secondary.opacity(0.3))
                    .frame(width: 2)
                    .padding(.vertical, 8)
                    .padding(.leading, CGFloat(min(depth, 3) - 1) * 14)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .imageViewer(selection: $activeImage)
    }
}

struct CommentEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Bindable var editor: CommentEditor
    let allowsSaving: Bool
    let saved: () -> Void
    let close: () -> Void
    let checkComments: () -> Void
    @State private var confirmDiscard = false
    @State private var confirmRetry = false
    @State private var confirmReload = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .create(let parentID, let name) = editor.mode {
                        Text(parentID == nil ? "Commenta questo post" : "Risposta a \(name ?? "un commento")").font(.headline)
                        Text("La visibilità è quella del post originale.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !allowsSaving {
                        Text("I commenti non sono attualmente disponibili su questa istanza. La bozza è conservata.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if editor.isLoading { ProgressView("Caricamento commento…") }
                    if !editor.isEditing || editor.original != nil {
                        TextEditor(text: $editor.content)
                            .frame(height: 240).padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)))
                            .accessibilityLabel("Testo del commento")
                            .disabled(editor.isSaving || editor.isLoading)
                        Text("Puoi usare Markdown e menzioni. Il limite del testo è stabilito dall’istanza.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = editor.errorMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    if editor.uncertain {
                        Button("Chiudi e controlla i commenti", action: checkComments)
                        Button("Invia di nuovo") { confirmRetry = true }.disabled(!allowsSaving)
                    }
                    if editor.requiresReload {
                        Button("Rileggi commento") {
                            if editor.hasDraft { confirmReload = true }
                            else { Task { await load() } }
                        }.disabled(editor.isLoading || editor.isSaving)
                    }
                    if editor.isSaving { ProgressView(editor.isEditing ? "Salvataggio…" : "Pubblicazione…") }
                }.padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editor.isEditing ? "Modifica commento" : "Nuovo commento")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        if editor.hasDraft { confirmDiscard = true } else { close() }
                    }.disabled(editor.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.isEditing ? "Salva" : "Pubblica") { save() }
                        .disabled(!allowsSaving || !editor.canSave)
                }
            }
            .confirmationDialog("Eliminare la bozza?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Elimina bozza", role: .destructive, action: close)
            }
            .confirmationDialog("Inviare di nuovo il commento?", isPresented: $confirmRetry, titleVisibility: .visible) {
                Button("Pubblica di nuovo") { editor.allowAnotherAttempt(); save() }
            } message: { Text("Se il primo invio è riuscito, verrà creato un commento duplicato.") }
            .confirmationDialog("Rileggere e scartare le modifiche?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Rileggi e scarta", role: .destructive) { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(editor.hasDraft || editor.isSaving)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .task { if editor.original == nil && editor.errorMessage == nil { await load() } }
    }

    private func load() async { await editor.load { try await store.authorizedCredentials() } }
    private func save() {
        guard allowsSaving else { return }
        Task { if await editor.save(using: store.comments, credentials: { try await store.authorizedCredentials() }) { saved() } }
    }
}
