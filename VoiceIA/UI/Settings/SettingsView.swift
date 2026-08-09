import AppKit
import SwiftUI

/// Abas da janela de configurações.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case transcription
    case recordings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Geral"
        case .models: return "Modelos"
        case .transcription: return "Transcrição"
        case .recordings: return "Gravações"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .models: return "sparkles"
        case .transcription: return "waveform"
        case .recordings: return "folder.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Atalho de ditado e permissões do macOS."
        case .models: return "API OpenAI e modelos locais Whisper."
        case .transcription: return "Idioma e modelo usados no ditado."
        case .recordings: return "O que fazer com os arquivos de áudio."
        }
    }
}

/// Janela de configurações: abas na lateral, conteúdo à direita.
struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            divider
            content
        }
        .background(SettingsBackground())
        .frame(minWidth: 780, minHeight: 540)
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.localModelStore.refreshDiskState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.localModelStore.refreshDiskState()
        }
    }

    // MARK: - Lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(SettingsTheme.accentGradient)

                VStack(alignment: .leading, spacing: 1) {
                    Text("VoiceIA")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Ditado por voz")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 28)
            .padding(.bottom, 22)

            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(for: tab)
            }

            Spacer(minLength: 0)

            Text(HotkeyConfiguration.displayName)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: SettingsTheme.hairline))
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 10)
        .frame(width: 208)
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        let isSelected = tab == selectedTab

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))

                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.65))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SettingsTheme.blue.opacity(0.38), SettingsTheme.purple.opacity(0.30)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: SettingsTheme.hairline)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1)
            .ignoresSafeArea()
    }

    // MARK: - Conteúdo

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedTab.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(selectedTab.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.bottom, 2)

                switch selectedTab {
                case .general:
                    generalTab
                case .models:
                    modelsTab
                case .transcription:
                    transcriptionTab
                case .recordings:
                    recordingsTab
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Aba Geral

    private var generalTab: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Atalho de ditado") {
                HStack(spacing: 14) {
                    Text(HotkeyConfiguration.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.07))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: SettingsTheme.hairline)
                        }

                    Text(HotkeyConfiguration.holdInstruction)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: "Permissões do macOS",
                subtitle: "As duas são necessárias: gravar o áudio e escrever no app em foco."
            ) {
                VStack(spacing: 14) {
                    SettingsRow(
                        title: "Microfone",
                        description: "Captura o áudio do ditado.",
                        icon: PermissionIndicator.symbol(isGranted: viewModel.isMicrophoneAuthorized),
                        iconColor: PermissionIndicator.color(isGranted: viewModel.isMicrophoneAuthorized)
                    ) {
                        Button("Ajustes") {
                            viewModel.openMicrophoneSettings()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Acessibilidade",
                        description: "Insere o texto transcrito no campo em foco.",
                        icon: PermissionIndicator.symbol(isGranted: viewModel.isAccessibilityTrusted),
                        iconColor: PermissionIndicator.color(isGranted: viewModel.isAccessibilityTrusted)
                    ) {
                        Button(viewModel.isAccessibilityTrusted ? "Ajustes" : "Autorizar") {
                            viewModel.handleAccessibilityAction()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - Aba Modelos

    private var modelsTab: some View {
        VStack(spacing: 16) {
            modelsPanePicker

            switch viewModel.selectedModelsPane {
            case .api:
                apiPane
            case .local:
                LocalModelsSettingsView(viewModel: viewModel)
            }
        }
    }

    private var modelsPanePicker: some View {
        HStack(spacing: 8) {
            ForEach(ModelsPane.allCases) { pane in
                let isSelected = viewModel.selectedModelsPane == pane
                Button {
                    viewModel.selectedModelsPane = pane
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(pane.title)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [SettingsTheme.blue.opacity(0.45), SettingsTheme.purple.opacity(0.35)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .overlay {
                                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: SettingsTheme.hairline)
                                }
                        } else {
                            Capsule()
                                .fill(.white.opacity(0.05))
                                .overlay {
                                    Capsule().strokeBorder(.white.opacity(0.10), lineWidth: SettingsTheme.hairline)
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var apiPane: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "API key",
                subtitle: "A chave fica só no Keychain deste Mac — não vai para o código nem para logs."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    SecureField("sk-…", text: $viewModel.apiKeyDraft)
                        .textFieldStyle(GlassFieldStyle())

                    HStack(spacing: 10) {
                        StatusPill(
                            text: viewModel.apiKeyStatusLabel,
                            isPositive: viewModel.hasAPIKey
                        )

                        Spacer(minLength: 0)

                        if viewModel.hasAPIKey {
                            Button("Remover") {
                                viewModel.removeAPIKey()
                            }
                            .buttonStyle(GhostButtonStyle())
                        }

                        Button("Salvar chave") {
                            viewModel.saveAPIKey()
                        }
                        .buttonStyle(GradientButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            viewModel.apiKeyDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }

                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(
                                viewModel.didSucceedLastAction
                                    ? Color(red: 0.40, green: 0.90, blue: 0.62)
                                    : Color(red: 1.00, green: 0.45, blue: 0.45)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard(title: "Créditos") {
                VStack(spacing: 14) {
                    SettingsRow(
                        title: "Modo teste",
                        description: viewModel.isTestModeEnabled
                            ? "Ativo: o ditado usa texto mock e não gasta crédito."
                            : "Desligado: cada ⇧ Tab bem-sucedido envia áudio à OpenAI e consome crédito."
                    ) {
                        Toggle("", isOn: $viewModel.isTestModeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(SettingsTheme.blue)
                    }
                }
            }
        }
    }

    // MARK: - Aba Transcrição

    private var transcriptionTab: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Idioma",
                subtitle: "Enviado à API, exceto em “Detectar automaticamente”, que omite o campo."
            ) {
                languageMenu
            }

            SettingsCard(title: "Modelo") {
                SettingsRow(
                    title: viewModel.modelLabel,
                    description: "Modelo econômico, adequado a ditados curtos."
                ) {
                    EmptyView()
                }
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(TranscriptionLanguageOption.allCases) { option in
                Button(option.displayName) {
                    viewModel.selectedLanguage = option
                }
            }
        } label: {
            HStack {
                Text(viewModel.selectedLanguage.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .fill(.white.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: SettingsTheme.hairline)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: 360, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aba Gravações

    private var recordingsTab: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Arquivos de áudio") {
                VStack(spacing: 14) {
                    SettingsRow(
                        title: "Manter após transcrever",
                        description: "Se desligado, o .m4a é apagado depois de uma transcrição bem-sucedida."
                    ) {
                        Toggle("", isOn: $viewModel.keepRecordingsAfterTranscription)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(SettingsTheme.blue)
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Pasta das gravações",
                        description: viewModel.recordingsFolderPath
                    ) {
                        Button("Abrir no Finder") {
                            viewModel.openRecordingsFolder()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel(settings: AppSettings()))
}
