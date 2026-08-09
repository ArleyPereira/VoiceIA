import AppKit
import Foundation
import Observation
import SwiftUI

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
    let parakeetModelStore: LocalParakeetModelStore
    let historyStore: TranscriptionHistoryStore

    /// Janela AppKit que hospeda as configurações (para centralizar diálogos filhos).
    weak var hostWindow: NSWindow?

    /// Notifica o AppState para liberar o Whisper da memória quando a política muda.
    var onTranscriptionPolicyChanged: () -> Void

    /// Notifica a janela para aplicar Sistema / Claro / Escuro.
    var onAppearanceThemeChanged: () -> Void

    /// Notifica o AppState para mostrar/esconder a barra conforme o estilo.
    var onRecordingHUDStyleChanged: () -> Void

    /// Notifica o AppState para re-registrar o atalho global.
    var onDictationHotkeyChanged: () -> Void

    /// `true` = captura ativa (pausar atalho global); `false` = retomou.
    var onHotkeyCaptureSessionChanged: (Bool) -> Void

    /// Incrementado quando o macOS muda claro/escuro — força o SwiftUI a
    /// reler `resolvedColorScheme` com a preferência em “Sistema”.
    private(set) var systemAppearanceEpoch = 0

    /// Texto digitado no campo (nunca logado).
    var apiKeyDraft: String = ""

    /// Mensagem de status da última ação de salvar/remover.
    var statusMessage: String?

    /// Indica se a última ação foi bem-sucedida.
    var didSucceedLastAction = false

    /// Permissões do sistema, relidas ao abrir/voltar para a janela.
    private(set) var isAccessibilityTrusted = false
    private(set) var isMicrophoneAuthorized = false

    /// Espelho de `SMAppService` — o VoiceIA abre no login do macOS.
    var opensAtLogin = false

    /// Aviso quando o macOS pede aprovação ou o app não está em Aplicativos.
    private(set) var launchAtLoginHint: String?

    /// Escutando teclas para definir um novo atalho.
    var isCapturingHotkey = false

    /// Dica durante/após a captura do atalho.
    var hotkeyCaptureHint: String?

    /// Monitor local de teclado durante a captura.
    private var hotkeyCaptureMonitor: Any?

    /// Sub-aba ativa em Modelos.
    var selectedModelsPane: ModelsPane = .api

    init(
        settings: AppSettings,
        localModelStore: LocalWhisperModelStore? = nil,
        parakeetModelStore: LocalParakeetModelStore? = nil,
        historyStore: TranscriptionHistoryStore? = nil,
        onTranscriptionPolicyChanged: @escaping () -> Void = {},
        onAppearanceThemeChanged: @escaping () -> Void = {},
        onRecordingHUDStyleChanged: @escaping () -> Void = {},
        onDictationHotkeyChanged: @escaping () -> Void = {},
        onHotkeyCaptureSessionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.settings = settings
        self.localModelStore = localModelStore ?? .shared
        self.parakeetModelStore = parakeetModelStore ?? .shared
        self.historyStore = historyStore ?? .shared
        self.onTranscriptionPolicyChanged = onTranscriptionPolicyChanged
        self.onAppearanceThemeChanged = onAppearanceThemeChanged
        self.onRecordingHUDStyleChanged = onRecordingHUDStyleChanged
        self.onDictationHotkeyChanged = onDictationHotkeyChanged
        self.onHotkeyCaptureSessionChanged = onHotkeyCaptureSessionChanged
        settings.refreshAPIKeyStatus()
        refreshPermissions()
        refreshLocalModelDiskState()
    }

    var hasAPIKey: Bool {
        settings.hasAPIKey
    }

    /// Tema da interface (Sistema / Claro / Escuro).
    var appearanceTheme: AppAppearanceTheme {
        get { AppAppearanceTheme(rawValue: settings.appearanceTheme) ?? .system }
        set {
            guard settings.appearanceTheme != newValue.rawValue else { return }
            settings.appearanceTheme = newValue.rawValue
            onAppearanceThemeChanged()
        }
    }

    /// Estilo da barra flutuante (Moderno / Clássico / Nenhuma).
    var recordingHUDStyle: RecordingHUDStyle {
        get { RecordingHUDStyle(rawValue: settings.recordingHUDStyle) ?? .moderno }
        set {
            guard settings.recordingHUDStyle != newValue.rawValue else { return }
            settings.recordingHUDStyle = newValue.rawValue
            onRecordingHUDStyleChanged()
        }
    }

    /// Atalho global de ditado escolhido pelo usuário.
    var dictationHotkey: DictationHotkey {
        settings.dictationHotkey
    }

    /// Inicia a escuta do novo atalho (Esc cancela).
    func beginHotkeyCapture() {
        guard !isCapturingHotkey else { return }
        isCapturingHotkey = true
        hotkeyCaptureHint = "Pressione o novo atalho… (Esc cancela)"
        onHotkeyCaptureSessionChanged(true)

        hotkeyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyCaptureEvent(event) ?? event
        }
    }

    /// Cancela a captura sem alterar o atalho atual.
    func cancelHotkeyCapture() {
        guard isCapturingHotkey else { return }
        endHotkeyCaptureSession(hint: nil)
    }

    /// Esconde a mensagem de feedback do atalho (sucesso / captura).
    func clearHotkeyCaptureHint() {
        hotkeyCaptureHint = nil
    }

    private func handleHotkeyCaptureEvent(_ event: NSEvent) -> NSEvent? {
        guard isCapturingHotkey else { return event }

        if event.keyCode == 53 { // Esc
            cancelHotkeyCapture()
            return nil
        }

        guard let hotkey = DictationHotkey.from(event: event) else {
            hotkeyCaptureHint = "Use um modificador (⌘ ⌥ ⇧ ⌃) + uma tecla."
            return nil
        }

        settings.dictationHotkey = hotkey
        onDictationHotkeyChanged()
        endHotkeyCaptureSession(hint: "Atalho atualizado para \(hotkey.displayName).")
        return nil
    }

    private func endHotkeyCaptureSession(hint: String?) {
        if let hotkeyCaptureMonitor {
            NSEvent.removeMonitor(hotkeyCaptureMonitor)
            self.hotkeyCaptureMonitor = nil
        }
        isCapturingHotkey = false
        hotkeyCaptureHint = hint
        onHotkeyCaptureSessionChanged(false)
    }

    /// Esquema SwiftUI correspondente (sempre concreto para atualizar na hora).
    var preferredColorScheme: ColorScheme {
        _ = systemAppearanceEpoch
        return appearanceTheme.resolvedColorScheme()
    }

    /// O macOS trocou claro/escuro — reaplica se a preferência for “Sistema”.
    func handleSystemAppearanceChanged() {
        systemAppearanceEpoch &+= 1
        guard appearanceTheme == .system else { return }
        onAppearanceThemeChanged()
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

    /// Quando `true`, ditagens reais entram no histórico local.
    var isTranscriptionHistoryEnabled: Bool {
        get { settings.isTranscriptionHistoryEnabled }
        set { settings.isTranscriptionHistoryEnabled = newValue }
    }

    var historyEntries: [TranscriptionHistoryEntry] {
        historyStore.entries
    }

    func deleteHistoryEntry(_ id: UUID) {
        historyStore.delete(id: id)
    }

    func deleteAllHistory() {
        historyStore.deleteAll()
    }

    func copyHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
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

    var selectedLocalModel: LocalTranscriptionModel {
        get {
            LocalTranscriptionModel(rawValue: settings.selectedLocalWhisperModel) ?? .default
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
        totalDownloadedLocalModels > 0 ? "Pronto" : "Não configurado"
    }

    var localStatusIsReady: Bool {
        totalDownloadedLocalModels > 0
    }

    private var totalDownloadedLocalModels: Int {
        localModelStore.downloadedCount + (parakeetModelStore.isDownloaded ? 1 : 0)
    }

    var selectedLocalModelDisplayName: String {
        guard isLocalModelDownloaded(selectedLocalModel) else {
            return "Nenhum"
        }
        return selectedLocalModel.displayName
    }

    var gpuStatusLabel: String {
        useLocalWhisperGPU ? "GPU ligada" : "GPU desligada"
    }

    var storageSummaryLabel: String {
        let total = localModelStore.totalOnDiskBytes + parakeetModelStore.onDiskByteCount
        return total.voiceIAByteCountLabel
    }

    var downloadsFooterLabel: String {
        let count = totalDownloadedLocalModels
        let size = storageSummaryLabel
        return "Downloads: \(size) · \(count) modelo\(count == 1 ? "" : "s")"
    }

    func isLocalModelDownloaded(_ model: LocalTranscriptionModel) -> Bool {
        switch model.engine {
        case .whisper:
            guard let whisper = model.whisperModel else { return false }
            return localModelStore.isDownloaded(whisper)
        case .parakeet:
            return parakeetModelStore.isDownloaded
        }
    }

    func isLocalModelDownloading(_ model: LocalTranscriptionModel) -> Bool {
        switch model.engine {
        case .whisper:
            guard let whisper = model.whisperModel else { return false }
            return localModelStore.downloading.contains(whisper)
        case .parakeet:
            return parakeetModelStore.isDownloading
        }
    }

    func detailedDownloadProgress(for model: LocalTranscriptionModel) -> (fraction: Double, percentLabel: String, speedLabel: String, sizeLabel: String)? {
        switch model.engine {
        case .whisper:
            guard let whisper = model.whisperModel,
                  let progress = localModelStore.progress(for: whisper) else {
                return nil
            }
            return (
                progress.fractionCompleted,
                progress.percentLabel,
                progress.speedLabel,
                progress.sizeLabel
            )
        case .parakeet:
            guard let progress = parakeetModelStore.downloadProgress else { return nil }
            return (
                progress.fractionCompleted,
                progress.percentLabel,
                progress.speedLabel,
                progress.sizeLabel
            )
        }
    }

    func selectLocalModel(_ model: LocalTranscriptionModel) {
        guard isLocalModelDownloaded(model) else { return }
        selectedLocalModel = model
    }

    func downloadLocalModel(_ model: LocalTranscriptionModel) {
        switch model.engine {
        case .whisper:
            guard let whisper = model.whisperModel else { return }
            localModelStore.download(whisper)
            Task { @MainActor in
                while localModelStore.downloading.contains(whisper) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if localModelStore.isDownloaded(whisper) {
                    selectedLocalModel = model
                    localModelStore.refreshDiskState()
                }
            }
        case .parakeet:
            parakeetModelStore.download()
            Task { @MainActor in
                while parakeetModelStore.isDownloading {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if parakeetModelStore.isDownloaded {
                    selectedLocalModel = model
                    parakeetModelStore.refreshDiskState()
                }
            }
        }
    }

    func cancelLocalModelDownload(_ model: LocalTranscriptionModel) {
        switch model.engine {
        case .whisper:
            guard let whisper = model.whisperModel else { return }
            localModelStore.cancelDownload(whisper)
        case .parakeet:
            parakeetModelStore.cancelDownload()
        }
    }

    func deleteLocalModel(_ model: LocalTranscriptionModel) {
        do {
            onTranscriptionPolicyChanged()
            switch model.engine {
            case .whisper:
                guard let whisper = model.whisperModel else { return }
                try localModelStore.delete(whisper)
            case .parakeet:
                try parakeetModelStore.delete()
            }
            if selectedLocalModel == model {
                selectedLocalModel = firstDownloadedLocalModel() ?? .default
            }
        } catch {
            switch model.engine {
            case .whisper:
                localModelStore.reportError(error.localizedDescription)
            case .parakeet:
                parakeetModelStore.reportError(error.localizedDescription)
            }
        }
    }

    func deleteUnusedLocalModels() {
        do {
            let keepingWhisper: LocalWhisperModel? = {
                guard selectedLocalModel.engine == .whisper else { return nil }
                return selectedLocalModel.whisperModel.flatMap {
                    localModelStore.isDownloaded($0) ? $0 : nil
                }
            }()
            try localModelStore.deleteUnused(keeping: keepingWhisper)

            if selectedLocalModel.engine != .parakeet, parakeetModelStore.isDownloaded {
                try parakeetModelStore.delete()
            }
        } catch {
            localModelStore.reportError(error.localizedDescription)
        }
    }

    private func firstDownloadedLocalModel() -> LocalTranscriptionModel? {
        LocalTranscriptionModel.allCases.first(where: isLocalModelDownloaded)
    }

    func refreshLocalModelDiskState() {
        localModelStore.refreshDiskState()
        parakeetModelStore.refreshDiskState()
    }

    // MARK: - Permissões e pastas

    func refreshPermissions() {
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
        isMicrophoneAuthorized = MicrophonePermission.isAuthorized
        refreshLaunchAtLogin()
    }

    /// Relê o status de início no login junto ao sistema.
    func refreshLaunchAtLogin() {
        opensAtLogin = LaunchAtLoginService.isEnabled
        launchAtLoginHint = LaunchAtLoginService.statusHint
    }

    /// Liga ou desliga a abertura automática no login.
    func setOpensAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginHint = nil
        } catch {
            launchAtLoginHint = error.localizedDescription
        }
        refreshLaunchAtLogin()
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
