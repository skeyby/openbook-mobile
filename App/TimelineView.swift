import SwiftUI
import OpenBookCore

struct TimelineView: View {
    @EnvironmentObject private var store: AppStore
    let instanceHost: String
    @State private var engine: PostEngine = .timeline
    @State private var confirmDisconnect = false
    @State private var navigation = AppNavigation()
    @State private var composer = PostComposer()
    @State private var isComposing = false
    @State private var feedRevision = UUID()
    @State private var publicationMessage: String?

    var body: some View {
        NavigationStack(path: $navigation.path) {
            PostListView(source: .feed(engine), api: store.api, title: nil, refreshHeader: {
                await store.loadInstanceMetadata()
                return true
            }) {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.instanceMetadata?.displayName ?? instanceHost)
                        Text(engine.summary).font(.caption).foregroundStyle(.secondary)
                        if store.requiresReauthentication {
                            Text("Sessione scaduta. Usa Accedi di nuovo nel menu account per ricollegare l’istanza.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                PostPublicationsView { feedRevision = UUID() }
            }
                .id("\(engine.rawValue)-\(feedRevision.uuidString)")
                .navigationTitle(store.instanceMetadata?.displayName ?? instanceHost)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .myProfile: PersonView()
                    case .followRequests: FollowRequestsView()
                    case .search: ProfileExplorer()
                    case .person(let id): PersonView(personID: id)
                    case .post(let id): PostDetailView(postID: id, api: store.api)
                    case .people(let id, let relationship): PeopleView(personID: id, relationship: relationship)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Picker("Sorgente dei post", selection: $engine) {
                                ForEach(PostEngine.allCases) { source in Text(source.title).tag(source) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(engine.title).font(.headline)
                                Image(systemName: "chevron.down").font(.caption.bold())
                            }
                        }
                        .accessibilityLabel("Sorgente dei post: \(engine.title)")
                        .accessibilityIdentifier("feed-source-menu")
                    }
                    ToolbarItem {
                        Button(composer.hasDraft ? "Riprendi bozza" : "Nuovo post", systemImage: "square.and.pencil") { publicationMessage = nil; isComposing = true }
                            .accessibilityIdentifier("new-post-button")
                    }
                    ToolbarItem {
                        Menu {
                            Button("Il mio profilo", systemImage: "person.crop.circle") { navigation.path.append(.myProfile) }
                            Button("Cerca profilo per UUID", systemImage: "magnifyingglass") { navigation.path.append(.search) }
                            if store.identityError != nil {
                                Button("Ricarica account", systemImage: "arrow.clockwise") { Task { await store.loadCurrentPerson() } }
                            }
                            if store.instanceMetadataError != nil {
                                Button("Ricarica nome istanza", systemImage: "arrow.clockwise") {
                                    Task { await store.loadInstanceMetadata() }
                                }
                            }
                            Divider()
                            Button(store.requiresReauthentication ? "Accedi di nuovo" : "Scollega istanza", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmDisconnect = true }
                        } label: { Label("Menu account", systemImage: "line.3.horizontal") }
                    }
                }
                .confirmationDialog("Scollegare l’istanza da questo dispositivo?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Scollega", role: .destructive) { store.disconnect() }
                } message: {
                    Text("La sessione viene rimossa da questo dispositivo; il token non viene revocato sul server.")
                }
        }
        .environment(navigation)
        .task { await store.loadCurrentPerson() }
        .task { await store.loadInstanceMetadata() }
        .sheet(isPresented: $isComposing) {
            NewPostView(composer: composer) { result in
                store.publications.register(result)
                if result.wasDeferred {
                    publicationMessage = result.monitorID == nil
                        ? "Invio ricevuto, ma lo stato non è leggibile. Controlla la timeline prima di creare un altro post."
                        : "File ricevuti. Il post verrà pubblicato dopo l’elaborazione del video."
                } else {
                    publicationMessage = result.post == nil
                        ? "Post pubblicato. La risposta non è leggibile: controlla la timeline."
                        : "Post pubblicato."
                }
                composer.reset()
                returnToTimeline()
            } checkTimeline: { returnToTimeline() } close: { isComposing = false }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = publicationMessage {
                HStack {
                    Label(message, systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("Chiudi", systemImage: "xmark") { publicationMessage = nil }
                        .labelStyle(.iconOnly)
                }
                .font(.subheadline).padding().background(.regularMaterial)
            }
        }
    }

    private func returnToTimeline() {
        isComposing = false
        engine = .timeline
        navigation.path = []
        feedRevision = UUID()
    }
}

struct PostRow: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @Environment(AppNavigation.self) private var navigation
    var opensDetails = true
    @State private var revealed = false
    @State private var activeEditor: PostEditor?
    @State private var activeImage: PostImageSelection?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let announce = post.postAnnounce {
                Button { navigation.path.append(.person(announce.announceAuthor.personId)) } label: {
                    Label("Rilanciato da \(announce.announceAuthor.personName)", systemImage: "arrow.2.squarepath")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Button { navigation.path.append(.person(post.postAuthor.personId)) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Avatar(url: post.postAuthor.personAvatar)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(post.postAuthor.personName).font(.headline).foregroundStyle(.primary)
                                Text(post.postAuthor.handle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(post.postAuthor.personName)
                    .accessibilityValue(post.postAuthor.handle)
                    .accessibilityHint("Apre il profilo dell’autore")
                    VStack(alignment: .leading, spacing: 3) {
                        if post.postEditedAt != nil { Text("Modificato") }
                        if let date = post.publishedDate { PostDateText(date: date) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 56)
                }
                if post.isOwned(by: store.currentPersonID) {
                    Menu {
                        Button("Modifica", systemImage: "pencil") {
                            guard let userID = store.currentPersonID else { return }
                            activeEditor = PostEditor(postID: post.id, currentPersonID: userID, api: store.api)
                        }.disabled(!post.supportsBasicEditing)
                        Button("Elimina post", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Azioni sul tuo post")
                    .disabled(store.management.pending.contains(post.id))
                }
            }

            if post.postCW && !revealed {
                Button { revealed = true } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "eye.slash").font(.title2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(post.postCWText.flatMap { $0.isEmpty ? nil : $0 } ?? "Avviso sul contenuto")
                                .font(.subheadline.bold())
                            Text("Clicca per visualizzare comunque")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Avviso sul contenuto: \(post.postCWText.flatMap { $0.isEmpty ? nil : $0 } ?? "Contenuto nascosto")")
                .accessibilityHint("Mostra il testo e gli allegati del post")
            } else if post.postCW {
                Button("Nascondi contenuto", systemImage: "eye.slash") { revealed = false }
                    .font(.caption).buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
            if !post.postCW || revealed { postBody }
            if let error = store.management.errors[post.id] { Text(error).font(.footnote).foregroundStyle(.red) }
            if store.management.pending.contains(post.id) { ProgressView("Aggiornamento post…") }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $activeEditor) { model in
            EditPostView(editor: model) { activeEditor = nil }
        }
        .imageViewer(selection: $activeImage)
        .confirmationDialog("Eliminare questo post?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina post", role: .destructive) {
                Task {
                    _ = await store.management.delete(post: post, currentPersonID: store.currentPersonID) { try await store.authorizedCredentials() }
                }
            }
        } message: { Text("Il post verrà eliminato. L’operazione non può essere annullata.") }
    }

    private var postBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = post.postName, !title.isEmpty {
                CustomEmojiText(title, emojis: post.postCustomEmojis, textStyle: .title3, weight: .bold)
            }
            if !post.postContent.isEmpty { MarkdownPostView(post.postContent, baseURL: post.postUri, emojis: post.postCustomEmojis) }
            PostAttachmentsView(attachments: post.postAttachments ?? [], selection: $activeImage)
            if let source = post.postSourceUri, let url = safeImageURL(URL(string: source)) {
                Link("Apri la fonte", destination: url).font(.subheadline)
            }
            if let location = post.postAttributes.postLocation, !location.displayName.isEmpty {
                Label(location.displayName, systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                Button {
                    Task { await store.likes.toggle(post: post) { try await store.authorizedCredentials() } }
                } label: {
                    HStack(spacing: 6) {
                        if store.likes.pending.contains(post.id) { ProgressView().controlSize(.mini) }
                        Label(store.likes.state(for: post).count.map(String.init) ?? "—",
                              systemImage: store.likes.state(for: post).liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.likes.state(for: post).liked ? Color.indigo : Color.secondary)
                .disabled(store.likes.pending.contains(post.id) || store.management.pending.contains(post.id))
                .accessibilityLabel(store.likes.state(for: post).liked ? "Togli Mi piace" : "Metti Mi piace")
                .accessibilityValue(store.likes.state(for: post).count.map { "\($0) Mi piace" } ?? "Contatore da aggiornare")
                if opensDetails {
                    Button { navigation.path.append(.post(post.id)) } label: {
                        Label(store.comments.count(for: post).map(String.init) ?? "—", systemImage: "bubble")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apri dettaglio del post")
                    .accessibilityValue(store.comments.count(for: post).map { "\($0) commenti" } ?? "Contatore commenti da aggiornare")
                } else {
                    Label(store.comments.count(for: post).map(String.init) ?? "—", systemImage: "bubble")
                        .accessibilityLabel(store.comments.count(for: post).map { "\($0) commenti" } ?? "Contatore commenti da aggiornare")
                }
                Button {
                    Task { await store.announces.toggle(post: post) { try await store.authorizedCredentials() } }
                } label: {
                    HStack(spacing: 6) {
                        if store.announces.pending.contains(post.id) { ProgressView().controlSize(.mini) }
                        Label(store.announces.state(for: post).count.map(String.init) ?? "—", systemImage: "arrow.2.squarepath")
                        if store.announces.state(for: post).announced { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.announces.state(for: post).announced ? Color.indigo : Color.secondary)
                .disabled(!store.announces.canToggle(post: post) || store.announces.pending.contains(post.id) || store.management.pending.contains(post.id))
                .accessibilityLabel(store.announces.state(for: post).announced ? "Annulla rilancio" : "Rilancia post")
                .accessibilityValue(store.announces.state(for: post).count.map { "\($0) condivisioni" } ?? "Contatore da aggiornare")
            }
            .font(.caption).foregroundStyle(.secondary)
            if store.comments.unknownCounts.contains(post.id.lowercased()) {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = store.comments.countErrors[post.id.lowercased()] { Text(message).font(.footnote) }
                    Button("Aggiorna contatore commenti") {
                        Task { await store.comments.refreshCount(postID: post.id) { try await store.authorizedCredentials() } }
                    }.disabled(store.comments.countPending.contains(post.id.lowercased()))
                }
            }
            if let message = store.announces.errors[post.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                    if store.announces.needsRefresh.contains(post.id) {
                        Button("Aggiorna rilancio") {
                            Task { await store.announces.refresh(post: post) { try await store.authorizedCredentials() } }
                        }.disabled(store.announces.pending.contains(post.id) || store.management.pending.contains(post.id))
                    }
                }
            }
            if let message = store.likes.errors[post.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                    if store.likes.needsRefresh.contains(post.id) {
                        Button("Aggiorna Mi piace") {
                            Task { await store.likes.refresh(post: post) { try await store.authorizedCredentials() } }
                        }.disabled(store.likes.pending.contains(post.id) || store.management.pending.contains(post.id))
                    }
                }
            }
        }
    }
}

struct PostDateText: View {
    let date: Date

    var body: some View {
        SwiftUI.TimelineView(PostDateSchedule(published: date)) { context in
            Text(PostTimestamp.text(for: date, now: context.date))
                .help(date.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

private struct PostDateSchedule: TimelineSchedule {
    let published: Date

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(published: published, nextDate: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let published: Date
        var nextDate: Date?

        mutating func next() -> Date? {
            guard let current = nextDate else { return nil }
            nextDate = PostTimestamp.nextUpdate(for: published, after: current)
            return current
        }
    }
}
