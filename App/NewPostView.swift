import SwiftUI
import OpenBookCore

struct NewPostView: View {
    @EnvironmentObject private var store: AppStore
    @Bindable var composer: PostComposer
    let published: (PostCreation) -> Void
    let checkTimeline: () -> Void
    let close: () -> Void
    @State private var confirmDiscard = false
    @State private var confirmRetry = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                Text("Che cosa vuoi condividere?").font(.headline)
                TextEditor(text: $composer.content)
                    .focused($editing)
                    .frame(height: 240)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)))
                    .accessibilityLabel("Testo del nuovo post")
                    .disabled(composer.isSubmitting)
                Picker("Visibilità", selection: $composer.visibility) {
                    ForEach(PostVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
                }
                .pickerStyle(.menu)
                .disabled(composer.isSubmitting)
                Text("Puoi usare Markdown, hashtag e menzioni. Il limite del testo è stabilito dalla tua istanza.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = composer.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
                if composer.uncertain {
                    Button("Chiudi e controlla la timeline", action: checkTimeline)
                    Button("Invia di nuovo") { confirmRetry = true }
                }
                if composer.isSubmitting {
                    ProgressView("Pubblicazione…").frame(maxWidth: .infinity)
                }
            }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Nuovo post")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        if composer.hasDraft { confirmDiscard = true }
                        else { composer.reset(); close() }
                    }.disabled(composer.isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pubblica") { publish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!composer.canSubmit)
                }
            }
            .confirmationDialog("Eliminare la bozza?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Elimina bozza", role: .destructive) { composer.reset(); close() }
                Button("Continua a scrivere", role: .cancel) { }
            }
            .confirmationDialog("Pubblicare di nuovo lo stesso testo?", isPresented: $confirmRetry, titleVisibility: .visible) {
                Button("Pubblica di nuovo") { composer.allowAnotherAttempt(); publish() }
            } message: { Text("Se il precedente invio è riuscito, verrà creato un post duplicato.") }
        }
        .interactiveDismissDisabled(composer.hasDraft || composer.isSubmitting)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .onAppear { editing = true }
    }

    private func publish() {
        editing = false
        Task {
            if let result = await composer.submit(credentials: { try await store.authorizedCredentials() }) {
                published(result)
            }
        }
    }
}
