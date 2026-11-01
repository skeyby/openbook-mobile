import SwiftUI
import OpenBookCore

struct EditPostView: View {
    @EnvironmentObject private var store: AppStore
    @Bindable var editor: PostEditor
    let close: () -> Void
    @State private var confirmDiscard = false
    @State private var confirmReload = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if editor.isLoading { ProgressView("Caricamento del post…") }
                    if editor.original != nil {
                        TextEditor(text: $editor.content)
                            .focused($editing)
                            .frame(height: 240).padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)))
                            .accessibilityLabel("Testo del post da modificare")
                            .disabled(editor.isSaving || editor.isLoading)
                        Picker("Visibilità", selection: $editor.visibility) {
                            ForEach(PostVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
                        }
                        .pickerStyle(.menu).disabled(editor.isSaving || editor.isLoading)
                        Text("Puoi modificare testo e visibilità. Gli altri dati del post vengono conservati.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = editor.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                        Button("Rileggi post") {
                            if editor.hasChanges { confirmReload = true }
                            else { Task { await load() } }
                        }.disabled(editor.isSaving || editor.isLoading)
                    }
                    if editor.isSaving { ProgressView("Salvataggio…") }
                }.padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Modifica post")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        if editor.hasChanges { confirmDiscard = true } else { close() }
                    }.disabled(editor.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        editing = false
                        Task {
                            if await editor.save(using: store.management, credentials: { try await store.authorizedCredentials() }) { close() }
                        }
                    }.buttonStyle(.borderedProminent).disabled(!editor.canSave)
                }
            }
            .confirmationDialog("Scartare le modifiche?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Scarta modifiche", role: .destructive, action: close)
            }
            .confirmationDialog("Rileggere il post dal server?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Rileggi e scarta le modifiche", role: .destructive) { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(editor.hasChanges || editor.isSaving)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .task { await load() }
    }

    private func load() async {
        await editor.load { try await store.authorizedCredentials() }
        editing = editor.original != nil
    }
}
