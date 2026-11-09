import SwiftUI
import OpenBookCore

struct NewPostView: View {
    @EnvironmentObject private var store: AppStore
    @Bindable var composer: PostComposer
    let published: (PostCreation) -> Void
    let checkTimeline: () -> Void
    let close: () -> Void
    @State private var submitTask: Task<Void, Never>?
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
                        .disabled(composer.isBusy)
                    Picker("Visibilità", selection: $composer.visibility) {
                        ForEach(PostVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
                    }
                    .pickerStyle(.menu)
                    .disabled(composer.isBusy)
                    #if os(iOS)
                    PostMediaPickerView(composer: composer)
                    #endif
                    Text("Puoi usare Markdown, hashtag e menzioni. Il limite del testo è stabilito dalla tua istanza.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = composer.preflightError {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                    if let message = composer.errorMessage, message != composer.preflightError {
                        Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if composer.uncertain {
                        Button("Chiudi e controlla la timeline", action: checkTimeline)
                        Button("Invia di nuovo") { confirmRetry = true }
                    }
                    if composer.isSubmitting {
                        ProgressView(composer.attachments.isEmpty ? "Pubblicazione…" : "Caricamento allegati e invio…").frame(maxWidth: .infinity)
                        Button("Interrompi invio") { submitTask?.cancel() }
                            .font(.footnote)
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
                    }.disabled(composer.isBusy)
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
        .interactiveDismissDisabled(composer.hasDraft || composer.isBusy)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .onAppear { editing = true }
        .onChange(of: store.instanceMetadata?.instanceUploadLimits, initial: true) { _, limits in
            composer.setUploadLimits(limits)
        }
        .task { await store.loadInstanceMetadata() }
        .onDisappear { submitTask?.cancel() }
    }

    private func publish() {
        editing = false
        let session = store.sessionRevision
        submitTask = Task {
            defer { submitTask = nil }
            if let result = await composer.submit(refreshLimits: { try await store.refreshUploadLimits() }, credentials: { try await store.authorizedCredentials() }) {
                guard store.sessionRevision == session else { return }
                published(result)
            }
        }
    }
}
