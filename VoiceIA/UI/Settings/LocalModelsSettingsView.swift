import SwiftUI

/// Conteúdo da sub-aba Local: backend, Whisper/Parakeet, download e exclusão.
struct LocalModelsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showMissingModelAlert = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            backendCard
            modelsList
            footerBar
        }
        .onAppear {
            viewModel.refreshLocalModelDiskState()
            // GPU permanece ligada por padrão (sem toggle na UI).
            if !viewModel.useLocalWhisperGPU {
                viewModel.useLocalWhisperGPU = true
            }
        }
        .alert("Modelo local necessário", isPresented: $showMissingModelAlert) {
            Button("Entendi", role: .cancel) {}
        } message: {
            Text("Baixe pelo menos um modelo local (Whisper ou Parakeet) antes de ativar “Usar no ditado”. Enquanto isso, o atalho continua com a API OpenAI ou o modo teste.")
        }
    }

    // MARK: - Backend

    private var backendCard: some View {
        SettingsCard {
            SettingsRow(
                title: "Usar no ditado",
                description: viewModel.usesLocalTranscription
                    ? "Com o atalho, a transcrição roda no modelo local deste Mac (sem enviar áudio à OpenAI)."
                    : "Com o atalho, a transcrição usa a API OpenAI na nuvem. Ligue este interruptor para usar o modelo local baixado."
            ) {
                Toggle("", isOn: Binding(
                    get: { viewModel.usesLocalTranscription },
                    set: { newValue in
                        if newValue, !viewModel.localStatusIsReady {
                            showMissingModelAlert = true
                            return
                        }
                        viewModel.usesLocalTranscription = newValue
                        viewModel.localModelStore.clearError()
                        viewModel.parakeetModelStore.clearError()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SettingsTheme.accent)
            }
        }
    }

    // MARK: - Lista

    private var modelsList: some View {
        VStack(spacing: 12) {
            ForEach(LocalTranscriptionModel.allCases) { model in
                modelCard(model)
            }
        }
    }

    private func modelCard(_ model: LocalTranscriptionModel) -> some View {
        let downloaded = viewModel.isLocalModelDownloaded(model)
        let downloading = viewModel.isLocalModelDownloading(model)
        let selected = viewModel.selectedLocalModel == model && downloaded
        let progress = viewModel.detailedDownloadProgress(for: model)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.systemImageName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.08)))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(model.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)

                            if let badge = model.badgeTitle {
                                Text(badge)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(
                                        model.badgeIsAccent
                                            ? SettingsTheme.accent
                                            : Color(red: 1.0, green: 0.84, blue: 0.40)
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(
                                            (model.badgeIsAccent
                                                ? SettingsTheme.accent
                                                : Color(red: 1.0, green: 0.84, blue: 0.40)
                                            ).opacity(0.14)
                                        )
                                    )
                            }

                            if selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0.40, green: 0.90, blue: 0.62))
                            }
                        }

                        Text(model.shortDescription)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(model.estimatedSizeLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !downloading else { return }
                    viewModel.selectLocalModel(model)
                }

                modelActionButton(model, downloaded: downloaded, downloading: downloading)
            }

            if downloading, let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .tint(SettingsTheme.accent)
                    HStack {
                        HStack(spacing: 8) {
                            Text(progress.percentLabel)
                            Text("·")
                                .foregroundStyle(.white.opacity(0.35))
                            Text(progress.speedLabel)
                        }
                        Spacer(minLength: 8)
                        Text(progress.sizeLabel)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(selected ? SettingsTheme.sidebarSelection(colorScheme) : SettingsTheme.cardFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    selected ? SettingsTheme.accent.opacity(0.55) : SettingsTheme.cardStroke(colorScheme),
                    lineWidth: SettingsTheme.hairline
                )
        }
    }

    @ViewBuilder
    private func modelActionButton(
        _ model: LocalTranscriptionModel,
        downloaded: Bool,
        downloading: Bool
    ) -> some View {
        if downloading {
            Button("Cancelar") {
                viewModel.cancelLocalModelDownload(model)
            }
            .buttonStyle(GhostButtonStyle())
        } else if downloaded {
            Button("Excluir") {
                viewModel.deleteLocalModel(model)
            }
            .buttonStyle(GhostButtonStyle())
        } else {
            Button {
                viewModel.downloadLocalModel(model)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    // MARK: - Rodapé

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = viewModel.localModelStore.lastErrorMessage ?? viewModel.parakeetModelStore.lastErrorMessage {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.downloadsFooterLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Exclua modelos não usados para liberar espaço em disco.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer(minLength: 12)

                Button {
                    viewModel.openLocalModelsFolder()
                } label: {
                    Label("Pasta", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())

                Button {
                    viewModel.deleteUnusedLocalModels()
                } label: {
                    Label("Excluir não usados", systemImage: "trash")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(viewModel.localModelStore.downloadedCount + (viewModel.parakeetModelStore.isDownloaded ? 1 : 0) <= 1)
            }
        }
        .padding(.top, 4)
    }
}
