import SwiftUI
import OpenBookCore

struct ProfileExplorer: View {
    @State private var personID = ""
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        Form {
            Section {
                TextField("UUID della persona", text: $personID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { openProfile() }
                Button("Apri profilo", systemImage: "person.crop.circle") { openProfile() }
                    .disabled(UUID(uuidString: personID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            } header: { Text("Cerca un profilo") } footer: {
                Text("Inserisci l’identificativo della persona nella tua istanza. La ricerca per nome non è ancora disponibile.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cerca profilo")
        .modifier(BackNavigation())
    }

    private func openProfile() {
        let id = personID.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: id) != nil { navigation.path.append(.person(id)) }
    }
}

struct PersonView: View {
    @EnvironmentObject private var store: AppStore
    var personID: String? = nil
    @State private var person: Person?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var activeImage: PostImageSelection?

    var body: some View {
        Group {
            if let person {
                PostListView(source: postSource(for: person), api: store.api, title: "Post", isRefreshingHeader: isLoading,
                             refreshHeader: { await load() }) {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            if let cover = safeImageURL(person.personProfile.personCoverImage) {
                                // Size from the List row before aspect-fill: a wide image must
                                // not widen the entire profile presentation and shift its text.
                                GeometryReader { geometry in
                                    AsyncImage(url: cover) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.indigo.opacity(0.08) }
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .clipped()
                                }
                                .frame(height: 140)
                                .clipped()
                                .accessibilityHidden(true)
                            }
                            if let avatarURL = safeImageURL(person.personProfile.personAvatar) {
                                Button {
                                    activeImage = PostImageSelection(id: "avatar-\(person.id)", url: avatarURL,
                                                                     description: "Foto profilo di \(person.personProfile.personName)")
                                } label: {
                                    Avatar(url: avatarURL, size: 72)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Apri foto profilo di \(person.personProfile.personName)")
                                .accessibilityHint("Apre la foto a tutto schermo con zoom")
                            } else {
                                Avatar(url: nil, size: 72)
                            }
                            CustomEmojiText(person.personProfile.personName, emojis: person.personAttributes.personCustomEmojis,
                                            textStyle: .title, weight: .bold)
                            Text(person.handle).foregroundStyle(.secondary).textSelection(.enabled)
                            if personID != nil { followControl(for: person) }
                            if person.personType == "application" { Label("Applicazione", systemImage: "app.badge") }
                            if person.personType == "feed" { Label("Feed", systemImage: "dot.radiowaves.left.and.right") }
                            if person.personType == "group" { Label("Comunità", systemImage: "person.3") }
                            if person.personStatus == "inactive" { Label("Account inattivo", systemImage: "pause.circle") }
                            if person.personAttributes.personMemorial { Label("Account commemorativo", systemImage: "heart") }
                            if person.personAttributes.personFollowApproval { Label("Richieste di seguito soggette ad approvazione", systemImage: "lock") }
                            if let summary = person.personProfile.personSummary, !summary.isEmpty {
                                CustomEmojiText(summary, emojis: person.personAttributes.personCustomEmojis).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                    Section("Connessioni") {
                        if postSource(for: person) == .mine {
                            NavigationLink("Richieste di follow", value: AppRoute.followRequests)
                        }
                        NavigationLink(value: AppRoute.people(person.personId, .followers)) { CountRow(title: "Follower", count: person.personFollowersCount) }
                        NavigationLink(value: AppRoute.people(person.personId, .following)) { CountRow(title: "Seguiti", count: person.personFollowingCount) }
                    }
                    if let destination = person.personAttributes.personMovedTo {
                        Section("Account trasferito") {
                            NavigationLink("Apri il nuovo profilo", value: AppRoute.person(destination.personId))
                        }
                    }
                    if let fields = person.personProfile.personFields, !fields.isEmpty {
                        Section("Informazioni") {
                            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                                VStack(alignment: .leading, spacing: 4) {
                                    CustomEmojiText(field.label, emojis: person.personAttributes.personCustomEmojis, textStyle: .caption)
                                        .foregroundStyle(.secondary)
                                    CustomEmojiText(field.value, emojis: person.personAttributes.personCustomEmojis).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                }
                .id(postSource(for: person))
            } else if isLoading {
                ProgressView("Caricamento profilo…")
            } else {
                ContentUnavailableView {
                    Label("Profilo non disponibile", systemImage: "person.crop.circle.badge.questionmark")
                } description: { Text(errorMessage ?? "Impossibile caricare il profilo.") } actions: {
                    Button("Riprova") { Task { await load() } }
                }
            }
        }
        .navigationTitle(personID == nil ? "Il mio profilo" : "Profilo")
        .modifier(BackNavigation())
        .imageViewer(selection: $activeImage)
        .task(id: personID) { _ = await load() }
    }

    @ViewBuilder
    private func followControl(for person: Person) -> some View {
        if let ownID = store.currentPersonID {
            if ownID.lowercased() != person.id.lowercased() {
                let id = person.id.lowercased()
                VStack(alignment: .leading, spacing: 8) {
                    if store.follows.pending.contains(id) {
                        ProgressView("Aggiornamento segui…")
                    }
                    if let status = store.follows.states[id]?.status {
                        Button {
                            Task {
                                if await store.follows.toggle(personID: id, currentPersonID: store.currentPersonID,
                                                              credentials: { try await store.authorizedCredentials() }) {
                                    _ = await load()
                                }
                            }
                        } label: {
                            switch status {
                            case .none: Label("Segui", systemImage: "person.badge.plus")
                            case .pending: Label("Richiesta inviata · Annulla", systemImage: "clock")
                            case .accepted: Label("Segui già · Non seguire più", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.follows.pending.contains(id) || isLoading)
                        .accessibilityIdentifier("profile-follow-button")
                    } else if !store.follows.pending.contains(id) {
                        Text("Stato del segui non disponibile").font(.caption).foregroundStyle(.secondary)
                        Button("Aggiorna stato segui") {
                            Task { await store.follows.load(personID: id) { try await store.authorizedCredentials() } }
                        }.disabled(isLoading)
                    }
                    if let message = store.follows.errors[id] {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        } else {
            Text("Identità dell’account non disponibile").font(.caption).foregroundStyle(.secondary)
            Button("Ricarica account") { Task { _ = await load() } }.disabled(isLoading)
        }
    }

    private func postSource(for person: Person) -> PostSource {
        if personID == nil || person.personId.lowercased() == store.currentPersonID?.lowercased() { return .mine }
        return .person(person.personId)
    }

    @discardableResult
    private func load() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let credentials = try await store.authorizedCredentials()
            let result: Person
            if let personID { result = try await store.api.person(id: personID, credentials: credentials) }
            else { result = try await store.api.me(credentials: credentials).myPerson }
            try Task.checkCancellation()
            person = result
            if personID != nil {
                await store.loadCurrentPerson()
                try Task.checkCancellation()
                if let ownID = store.currentPersonID, ownID.lowercased() != result.id.lowercased() {
                    await store.follows.load(personID: result.id) { try await store.authorizedCredentials() }
                }
            }
            return true
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            // Do not keep previously visible data after access has been denied.
            person = nil
            errorMessage = error.localizedDescription
        }
        return false
    }
}

struct CountRow: View {
    let title: String
    let count: Int?
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.map { String($0) } ?? "Non disponibile").foregroundStyle(.secondary)
        }
    }
}

func safeImageURL(_ url: URL?) -> URL? {
    guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
    return url
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 44
    var body: some View {
        AsyncImage(url: safeImageURL(url)) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

// iOS supplies the native back button. macOS gets an explicit toolbar action.
struct BackNavigation: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(macOS)
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Indietro", systemImage: "chevron.left") { dismiss() }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        #else
        content
        #endif
    }
}
