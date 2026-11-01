import SwiftUI
import OpenBookCore

struct PeopleView: View {
    @EnvironmentObject private var store: AppStore
    let personID: String
    let relationship: Relationship
    @State private var people: [PersonReference] = []
    @State private var cursor: String?
    @State private var seenCursors: Set<String> = []
    @State private var hasNext = false
    @State private var loaded = false
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(people) { person in
                    NavigationLink(value: AppRoute.person(person.personId)) {
                        HStack(spacing: 12) {
                            Avatar(url: person.personAvatar)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.personName).font(.headline)
                                Text(person.handle).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } footer: { Text("Le liste remote possono essere incomplete: mostrano solo persone note a questa istanza.") }
            if loading && !hasNext { ProgressView("Caricamento…") }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Riprova") { Task { await load(reset: !loaded) } }
            } else if loaded && people.isEmpty {
                Text("Nessuna persona da mostrare.").foregroundStyle(.secondary)
            }
            if hasNext && errorMessage == nil {
                ProgressView("Altre persone…")
                    .frame(maxWidth: .infinity)
                    .task(id: cursor) { await load(reset: false) }
            }
        }
        .navigationTitle(relationship.title)
        .modifier(BackNavigation())
        .task { if !loaded { await load(reset: true) } }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            try Task.checkCancellation()
            let credentials = try await store.authorizedCredentials()
            try Task.checkCancellation()
            let page = try await store.api.people(id: personID, relationship: relationship, after: reset ? nil : cursor, credentials: credentials)
            try Task.checkCancellation()
            if reset { people = []; seenCursors = [] }
            var existingIDs = Set(people.map(\.id))
            people.append(contentsOf: page.people.filter { existingIDs.insert($0.id).inserted })
            cursor = page.people.last?.id
            if let cursor {
                hasNext = page.hasNext && seenCursors.insert(cursor).inserted
            } else {
                hasNext = false
            }
            loaded = true
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            if reset { people = []; loaded = false; hasNext = false; cursor = nil }
            if case OpenBookError.http(let status, _) = error, [401, 403, 404].contains(status) {
                people = []; loaded = false; hasNext = false; cursor = nil
            }
            errorMessage = error.localizedDescription
        }
    }
}
