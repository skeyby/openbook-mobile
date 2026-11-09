import SwiftUI
import OpenBookCore

struct PostPublicationsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    let published: () -> Void
    @State private var cancelID: String?
    private var pollKey: String { scenePhase == .active ? store.publications.pollingIDs.joined(separator: ",") : "" }
    var body: some View {
        Group {
            if !store.publications.jobs.isEmpty {
                Section("Invii multimediali") {
                    ForEach(store.publications.jobs) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if job.value?.status == .pending || job.value?.status == .processing { ProgressView().controlSize(.small) }
                                Text(statusText(job)).font(.subheadline)
                                Spacer()
                                Button("Aggiorna stato", systemImage: "arrow.clockwise") { Task { await refresh(job.id) } }
                                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    .disabled(store.publications.pending.contains(job.id))
                            }
                            if let error = store.publications.errors[job.id] { Text(error).font(.footnote).foregroundStyle(.red) }
                            if job.value?.status == .published, let id = job.value?.postId {
                                Button("Apri post") { navigation.path.append(.post(id)) }
                            }
                            if store.publications.canCancel(job) {
                                Button(job.value?.status == .failed ? "Elimina invio fallito" : "Annulla invio", role: .destructive) { cancelID = job.id }
                            }
                            if job.value?.status == .published || store.publications.errors[job.id] != nil {
                                Button("Nascondi avviso") { store.publications.dismiss(id: job.id) }
                                    .accessibilityHint("Nasconde solo questo avviso. Non annulla l’invio sul server.")
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .confirmationDialog("Annullare questo invio?", isPresented: Binding(get: { cancelID != nil }, set: { if !$0 { cancelID = nil } }), titleVisibility: .visible) {
            if let id = cancelID {
                Button("Annulla invio", role: .destructive) {
                    cancelID = nil
                    Task { await store.publications.cancel(id: id) { try await store.authorizedCredentials() } }
                }
            }
        } message: { Text("L’annullamento è possibile solo prima che inizi l’elaborazione o dopo un errore. Un post già pubblicato non verrà eliminato.") }
        .task(id: pollKey) {
            guard !pollKey.isEmpty else { return }
            while !Task.isCancelled && !store.publications.pollingIDs.isEmpty {
                for id in store.publications.pollingIDs {
                    if Task.isCancelled { return }
                    await refresh(id)
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func refresh(_ id: String) async {
        if await store.publications.refresh(id: id, credentials: { try await store.authorizedCredentials() }) { published() }
    }
    private func statusText(_ job: PostPublications.Job) -> String {
        switch job.value?.status {
        case .pending: "Video ricevuto, in attesa di elaborazione."
        case .processing: "Video in elaborazione. Il post non è ancora pubblicato."
        case .failed: "Elaborazione non riuscita. Il post non è stato pubblicato."
        case .published: job.value?.postId == nil ? "Elaborazione completata. Il post non è disponibile." : "Post pubblicato."
        case nil: job.value == nil ? "Invio ricevuto. Verifica dello stato…" : "Stato dell’invio non riconosciuto. Aggiorna per verificarlo."
        }
    }
}
