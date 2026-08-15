import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Modal de CRUD das substituições de palavras.
///
/// Estrutura das telas de referência do Spokenly, com o visual do VoiceIA:
/// cabeçalho com título e fechar, corpo (vazio, lista ou formulário) e rodapé
/// com a ação principal.
struct WordReplacementsModal: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// O que o corpo está mostrando agora.
    private enum Mode: Equatable {
        case list
        case creating
        case editing(UUID)
    }

    @State private var mode: Mode = .list
    @State private var original = ""
    @State private var replacement = ""
    @State private var errorMessage: String?
    /// Item que está sendo arrastado agora (`nil` fora do gesto).
    @State private var draggingID: UUID?

    private var store: WordReplacementStore { viewModel.wordReplacementStore }

    var body: some View {
        VStack(spacing: 0) {
            header
            SettingsDivider()
            body(for: mode)
            SettingsDivider()
            footer
        }
        .frame(width: 520, height: 460)
        .background(SettingsBackground())
        .preferredColorScheme(viewModel.preferredColorScheme)
        // Fechar o modal gravando descarta: transcrever para um formulário que
        // saiu da tela só gastaria bateria e sujaria a pasta de gravações.
        .onDisappear {
            if viewModel.dictatingField != nil {
                viewModel.cancelFieldDictation()
            }
        }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Substituição de palavras")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

                Text("Troca automaticamente palavras e frases em cada nova transcrição.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                viewModel.isShowingWordReplacements = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(SettingsTheme.cardFill(colorScheme)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Fechar")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Corpo

    @ViewBuilder
    private func body(for mode: Mode) -> some View {
        switch mode {
        case .list:
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        case .creating, .editing:
            editor
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "character.book.closed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(SettingsTheme.accent)

            Text("Nenhuma substituição ainda")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

            Text("Crie a primeira para corrigir vocabulário, grafia ou variantes de nome nas próximas transcrições.")
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            Button {
                beginCreating()
            } label: {
                Label("Nova substituição", systemImage: "plus.circle.fill")
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.top, 4)

            Button("Importar") {
                importFromFile()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.items) { item in
                    row(for: item)
                        .opacity(draggingID == item.id ? 0.35 : 1)
                        .onDrag {
                            draggingID = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ReorderDropDelegate(
                                target: item,
                                store: store,
                                draggingID: $draggingID
                            )
                        )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .animation(.easeInOut(duration: 0.18), value: store.items.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for item: WordReplacement) -> some View {
        HStack(spacing: 8) {
            Text(item.original)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

            Text(item.replacement)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))

            Spacer(minLength: 8)

            Menu {
                Button("Mover para o início") { store.moveToTop(id: item.id) }
                    .disabled(item.id == store.items.first?.id)
                Button("Mover para o fim") { store.moveToBottom(id: item.id) }
                    .disabled(item.id == store.items.last?.id)
                Divider()
                Button("Editar") { beginEditing(item) }
                // Sem alerta de confirmação, igual ao histórico: exclusão imediata.
                Button("Excluir", role: .destructive) { store.delete(id: item.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                .fill(SettingsTheme.cardFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardStroke(colorScheme), lineWidth: SettingsTheme.hairline)
        }
    }

    /// Formulário de criar e de editar — os dois têm os mesmos campos e a mesma
    /// validação, então mudam só o título e o rótulo do botão.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)

            HStack(spacing: 10) {
                micButton(for: .original)

                TextField("Original", text: $original)
                    .textFieldStyle(GlassFieldStyle())

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

                TextField("Substituição", text: $replacement)
                    .textFieldStyle(GlassFieldStyle())
            }

            Text(viewModel.dictatingField == .original
                 ? "Fale a palavra como você costuma falar. O texto vem sem correção, que é o ponto: aqui entra o que o modelo erra."
                 : "O original é o que o modelo costuma escrever; a substituição é a grafia correta.")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.15), value: viewModel.dictatingField)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    /// Microfone que preenche o campo falando, em vez de digitar.
    ///
    /// Reaproveita o ditado inteiro — a mesma barra flutuante aparece, com
    /// duração, ondas e o ✕ para descartar. O texto não é inserido em lugar
    /// nenhum: volta direto para este campo.
    private func micButton(for field: SettingsViewModel.WordReplacementField) -> some View {
        let isRecording = viewModel.dictatingField == field
        let isBusyElsewhere = viewModel.dictatingField != nil && !isRecording

        return Button {
            viewModel.dictate(into: field) { text in
                switch field {
                case .original: original = text
                case .replacement: replacement = text
                }
                errorMessage = nil
            }
        } label: {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isRecording ? Color.white : SettingsTheme.secondaryLabel(colorScheme))
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                        .fill(isRecording ? SettingsTheme.accent : SettingsTheme.cardFill(colorScheme))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                        .strokeBorder(SettingsTheme.cardStroke(colorScheme), lineWidth: SettingsTheme.hairline)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusyElsewhere)
        .opacity(isBusyElsewhere ? 0.4 : 1)
        .help(isRecording ? "Encerrar e preencher" : "Preencher falando")
        .animation(.easeInOut(duration: 0.15), value: isRecording)
    }

    // MARK: - Rodapé

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch mode {
            case .list:
                Text(countLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

                Spacer(minLength: 8)

                if !store.items.isEmpty {
                    Button("Importar") { importFromFile() }
                        .buttonStyle(GhostButtonStyle())

                    Button {
                        beginCreating()
                    } label: {
                        Label("Adicionar", systemImage: "plus")
                    }
                    .buttonStyle(GradientButtonStyle())
                }

            case .creating, .editing:
                Spacer(minLength: 8)

                Button("Cancelar") { returnToList() }
                    .buttonStyle(GhostButtonStyle())

                Button(mode == .creating ? "Criar" : "Concluir") { commit() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isFormFilled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var countLabel: String {
        let count = store.items.count
        guard count > 0 else { return "" }
        return count == 1 ? "1 substituição" : "\(count) substituições"
    }

    /// Só desabilita o botão com campo vazio. Tamanho mínimo e duplicata viram
    /// mensagem no `commit`, para o usuário saber **por que** foi recusado em
    /// vez de encarar um botão inerte.
    private var isFormFilled: Bool {
        !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Ações

    private func beginCreating() {
        original = ""
        replacement = ""
        errorMessage = nil
        mode = .creating
    }

    private func beginEditing(_ item: WordReplacement) {
        original = item.original
        replacement = item.replacement
        errorMessage = nil
        mode = .editing(item.id)
    }

    private func returnToList() {
        // Sair do formulário gravando descarta a captura junto.
        viewModel.cancelFieldDictation()
        errorMessage = nil
        mode = .list
    }

    private func commit() {
        let failure: WordReplacementValidationError?
        switch mode {
        case .creating:
            failure = store.add(original: original, replacement: replacement)
        case .editing(let id):
            failure = store.update(id: id, original: original, replacement: replacement)
        case .list:
            return
        }

        if let failure {
            errorMessage = failure.message
        } else {
            returnToList()
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Importar"
        panel.message = "Escolha um JSON de substituições."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try store.importFrom(url: url)
            errorMessage = nil
            viewModel.reportWordReplacementImport(count: count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Reordena a lista enquanto o item arrastado passa por cima das outras linhas.
///
/// A troca acontece no `dropEntered`, não no soltar: é o que faz a lista abrir
/// espaço embaixo do cursor, em vez de o usuário soltar às cegas e só então
/// descobrir onde o item caiu.
private struct ReorderDropDelegate: DropDelegate {
    let target: WordReplacement
    let store: WordReplacementStore
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let draggingID, draggingID != target.id else { return }
            store.reorder(id: draggingID, toIndexOf: target.id)
        }
    }

    /// Sem isto o cursor mostra o "+" de cópia — aqui nada é copiado.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            // A ordem já está na tela; só falta gravá-la.
            store.commitReorder()
            draggingID = nil
        }
        return true
    }
}
