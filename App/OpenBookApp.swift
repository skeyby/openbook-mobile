import SwiftUI

@main
struct OpenBookApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(.indigo)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if let credentials = store.credentials {
                TimelineView(instanceHost: credentials.instance.origin.host ?? "OpenBook")
                    .id(credentials.instance.origin)
            } else {
                ConnectView()
            }
        }
        .alert("OpenBook", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct ConnectView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("lastInstance") private var instance = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 52)).foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Il tuo OpenBook,\nsempre con te.").font(.largeTitle.bold())
                        Text("Collega la tua istanza per leggere i post ed esplorare persone e connessioni.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Indirizzo dell’istanza").font(.headline)
                        TextField("https://social.example.org", text: $instance)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onSubmit { connect() }
                            .disabled(store.isConnecting)
                        Button(action: connect) {
                            HStack {
                                if store.isConnecting { ProgressView().controlSize(.small) }
                                Text(store.isConnecting ? "Collegamento…" : "Accedi con OpenBook")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }.padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(instance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isConnecting)
                    }
                    Label("L’accesso avviene nel browser di sistema. Le credenziali della sessione sono conservate nel Portachiavi.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Prima versione · Le API sono sperimentali e consentono di interagire con timeline, profili e richieste di follow. L’istanza deve essere raggiungibile da questo dispositivo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("OpenBook")
        }
    }

    private func connect() { Task { await store.connect(to: instance) } }
}
