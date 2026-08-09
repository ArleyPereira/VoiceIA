import AppKit
import Foundation
import Observation

/// Idiomas disponíveis na tela de configurações.
enum TranscriptionLanguageOption: String, CaseIterable, Identifiable {
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .portuguese: return "Português (pt)"
        case .english: return "English (en)"
        case .spanish: return "Español (es)"
        case .auto: return "Detectar automaticamente"
        }
    }
}

/// Sub-abas dentro de Modelos.
enum ModelsPane: String, CaseIterable, Identifiable {
    case api
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .api: return "API"
        case .local: return "Local"
        }
    }

    var icon: String {
        switch self {
        case .api: return "key.fill"
        case .local: return "internaldrive.fill"
        }
    }
}

/// ViewModel da janela de configurações.
@Observable
@MainActor
final class SettingsViewModel {
    private let settings: AppSettings
    let localModelStore: LocalWhisperModelStore

    /// Notifica o AppState para liberar o Whisper da memória quando a política muda.
    var onTranscriptionPolicyChanged: () -> Void

    /// Texto digitado no campo (nunca logado).
    var apiKeyDraft: String = ""

    /// Mensagem de status da última ação de salvar/remover.
    var statusMessage: String?

    /// Indica se a última ação foi bem-sucedida.
    var didSucceedLastAction = false

    /// Permissões do sistema, relidas ao abrir/voltar para a janela.
    private(set) var isAccessibilityTrusted = false
    private(set) var isMicrophoneAuthorized = false

    /// Sub-aba ativa em Modelos.
    var selectedModelsPane: ModelsPane = .api

    init(
        settings: AppSettings,
        localModelStore: LocalWhisperModelStore? = nil,
        onTranscriptionPolicyChanged: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.localModelStore = localModelStore ?? .shared
        self.onTranscriptionPolicyChanged = onTranscriptionPolicyChanged
        settings.refreshAPIKeyStatus()
        refreshPermissions()
        self.localModelStore.refreshDiskState()
    }

    var hasAPIKey: Bool {
        settings.hasAPIKey
    }

    var isTestModeEnabled: Bool {
        get { settings.isTestModeEnabled }
        set {
            settings.isTestModeEnabled = newValue
            // Modo teste não usa Whisper: libera RAM/GPU imediatamente.
            if newValue {
                onTranscriptionPolicyChanged()
            }
        }
    }

    var keepRecordingsAfterTranscription: Bool {
        get { settings.keepRecordingsAfterTranscription }
        set { settings.keepRecordingsAfterTranscription = newValue }
    }

    var useLocalWhisperGPU: Bool {
        get { settings.useLocalWhisperGPU }
        set {
            guard settings.useLocalWhisperGPU != newValue else { return }
            settings.useLocalWhisperGPU = newValue
            // Troca CPU/GPU exige recarregar o contexto na próxima ditagem.
            onTranscriptionPolicyChanged()
        }
    }

    /// `true` quando o ditado usa Whisper local.
    var usesLocalTranscription: Bool {
        get { settings.transcriptionBackend == "local" }
        set {
            let backend = newValue ? "local" : "api"
            guard settings.transcriptionBackend != backend else { return }
            settings.transcriptionBackend = backend
            if !newValue {
                onTranscriptionPolicyChanged()
            }
        }
    }

    var selectedLocalModel: LocalWhisperModel {
        get {
            LocalWhisperModel(rawValue: settings.selectedLocalWhisperModel) ?? .largeV3
        }
        set {
            guard settings.selectedLocalWhisperModel != newValue.rawValue else { return }
            settings.selectedLocalWhisperModel = newValue.rawValue
            onTranscriptionPolicyChanged()
        }
    }

    var selectedLanguage: TranscriptionLanguageOption {
        get {
            TranscriptionLanguageOption(rawValue: settings.transcriptionLanguage) ?? .portuguese
        }
        set {
            settings.transcriptionLanguage = newValue.rawValue
        }
    }

    var apiKeyStatusLabel: String {
        hasAPIKey
            ? "Chave salva no Keychain"
            : "Nenhuma chave salva"
    }

    var modelLabel: String {
        TranscriptionConfiguration.model
    }

    var recordingsFolderPath: String {
        RecordingStorage.directoryURL.path
    }

    // MARK: - Modelos locais (UI)

    var localStatusBadge: String {
        localModelStore.downloadedCount > 0 ? "Pronto" : "Não configurado"
    }

    var localStatusIsReady: Bool {
        localModelStore.downloadedCount > 0
    }

    var selectedLocalModelDisplayName: String {
        guard localModelStore.isDownloaded(selectedLocalModel) else {
            return "Nenhum"
        }
        return selectedLocalModel.displayName
    }

    var gpuStatusLabel: String {
        useLocalWhisperGPU ? "GPU ligada" : "GPU desligada"
    }

    var storageSummaryLabel: String {
        localModelStore.totalOnDiskBytes.voiceIAByteCountLabel
    }

    var downloadsFooterLabel: String {
        let count = localModelStore.downloadedCount
        let size = storageSummaryLabel
        return "Downloads: \(size) · \(count) modelo\(count == 1 ? "" : "s")"
    }

    func isLocalModelDownloaded(_ model: LocalWhisperModel) -> Bool {
        localModelStore.isDownloaded(model)
    }

    func isLocalModelDownloading(_ model: LocalWhisperModel) -> Bool {
        localModelStore.downloading.contains(model)
    }

    func downloadProgress(for model: LocalWhisperModel) -> Double {
        localModelStore.fraction(for: model)
    }

    func detailedDownloadProgress(for model: LocalWhisperModel) -> ModelDownloadProgress? {
        localModelStore.progress(for: model)
    }

    func selectLocalModel(_ model: LocalWhisperModel) {
        guard localModelStore.isDownloaded(model) else { return }
        selectedLocalModel = model
    }

    func downloadLocalModel(_ model: LocalWhisperModel) {
        localModelStore.download(model)
        // Ao concluir, o store atualiza disco; selecionamos se ainda não há seleção baixada.
        Task { @MainActor in
            while localModelStore.downloading.contains(model) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if localModelStore.isDownloaded(model) {
                selectedLocalModel = model
                localModelStore.refreshDiskState()
            }
        }
    }

    func deleteLocalModel(_ model: LocalWhisperModel) {
        do {
            // Libera da RAM antes de apagar o arquivo do disco.
            onTranscriptionPolicyChanged()
            try localModelStore.delete(model)
            if selectedLocalModel == model {
                selectedLocalModel = localModelStore.downloadedModels.first ?? .largeV3
            }
        } catch {
            localModelStore.reportError(error.localizedDescription)
        }
    }

    func deleteUnusedLocalModels() {
        do {
            let keeping = localModelStore.isDownloaded(selectedLocalModel) ? selectedLocalModel : nil
            try localModelStore.deleteUnused(keeping: keeping)
        } catch {
            localModelStore.reportError(error.localizedDescription)
        }
    }

    // MARK: - Permissões e pastas

    func refreshPermissions() {
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
        isMicrophoneAuthorized = MicrophonePermission.isAuthorized
    }

    /// Pendente: pede confiança e abre Ajustes. Já autorizada: só abre Ajustes.
    func handleAccessibilityAction() {
        if isAccessibilityTrusted {
            AccessibilityPermission.openSystemSettings()
        } else {
            AccessibilityPermission.requestAccess()
            AccessibilityPermission.openSystemSettings()
        }
    }

    func openMicrophoneSettings() {
        MicrophonePermission.openSystemSettings()
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(RecordingStorage.directoryURL)
    }

    func openLocalModelsFolder() {
        NSWorkspace.shared.open(localModelStore.directoryURL)
    }

    /// Persiste a API key digitada.
    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Cole a API key da OpenAI antes de salvar."
            didSucceedLastAction = false
            return
        }

        do {
            try settings.saveOpenAIAPIKey(trimmed)
            apiKeyDraft = ""
            statusMessage = "API key salva com segurança no Keychain."
            didSucceedLastAction = true
        } catch {
            statusMessage = error.localizedDescription
            didSucceedLastAction = false
        }
    }

    /// Remove a API key do Keychain.
    func removeAPIKey() {
        do {
            try settings.deleteOpenAIAPIKey()
            apiKeyDraft = ""
            statusMessage = "API key removida."
            didSucceedLastAction = true
        } catch {
            statusMessage = error.localizedDescription
            didSucceedLastAction = false
        }
    }
}
