import SwiftUI
import OpenBookCore

struct FollowRequestsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let requests = store.incomingFollowRequests
        List {
            Section {
                ForEach(requests.people) { person in
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink(value: AppRoute.person(person.id)) {
                            HStack(spacing: 12) {
                                Avatar(url: person.personAvatar)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.personName).font(.headline)
                                    Text(person.handle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Approva", systemImage: "checkmark") {
                                Task { await requests.decide(personID: person.id, accept: true) { try await store.authorizedCredentials() } }
                            }
                            Button("Rifiuta", systemImage: "xmark", role: .destructive) {
                                Task { await requests.decide(personID: person.id, accept: false) { try await store.authorizedCredentials() } }
                            }
                            if requests.changingID == person.id.lowercased() { ProgressView().controlSize(.small) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(requests.isLoading || requests.isChanging || requests.requiresReload)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Richiesta di \(person.personName)")
                    }.padding(.vertical, 6)
                }
            } footer: { Text("Richieste ricevute dal tuo account, in attesa di approvazione.") }
            if let message = requests.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                    Button(requests.requiresReload ? "Ricarica richieste" : "Riprova") {
                        Task { await load(reset: requests.requiresReload || !requests.hasLoaded) }
                    }
                    if requests.hasLoaded && !requests.requiresReload {
                        Button("Ricarica dall’inizio") { Task { await load(reset: true) } }
                    }
                }
            } else if requests.hasLoaded && requests.people.isEmpty && !requests.hasNext {
                Text("Nessuna richiesta in attesa.").foregroundStyle(.secondary)
            }
            if requests.hasNext && requests.errorMessage == nil {
                ProgressView("Altre richieste…").frame(maxWidth: .infinity)
                    .task(id: "\(requests.cursor ?? "")-\(requests.isChanging)-\(requests.pageRevision)") { await load(reset: false) }
            } else if requests.isLoading {
                ProgressView("Caricamento richieste…")
            }
        }
        .navigationTitle("Richieste di follow")
        .modifier(BackNavigation())
        .toolbar {
            Button("Aggiorna richieste", systemImage: "arrow.clockwise") { Task { await load(reset: true) } }
                .disabled(requests.isLoading || requests.isChanging)
        }
        .task { if !requests.hasLoaded { await load(reset: true) } }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        await store.incomingFollowRequests.load(reset: reset) { try await store.authorizedCredentials() }
    }
}
