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
    let parakeetModelStore: LocalParakeetModelStore
    let historyStore: TranscriptionHistoryStore

    /// Janela AppKit que hospeda as configurações (para centralizar diálogos filhos).
    weak var hostWindow: NSWindow?

    /// Notifica o AppState para liberar o modelo local quando a política muda.
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

    /// Aba ativa da janela de configurações.
    ///
    /// Fica aqui, e não em `@State` da view, para quem abre a janela poder
    /// escolher onde ela começa — o menu da barra de status abre no Histórico.
    var selectedTab: SettingsTab = .general

    /// Sub-aba ativa em Modelos.
    var selectedModelsPane: ModelsPane = .api

    init(
        settings: AppSettings,
        parakeetModelStore: LocalParakeetModelStore? = nil,
        historyStore: TranscriptionHistoryStore? = nil,
        onTranscriptionPolicyChanged: @escaping () -> Void = {},
        onAppearanceThemeChanged: @escaping () -> Void = {},
        onRecordingHUDStyleChanged: @escaping () -> Void = {},
        onDictationHotkeyChanged: @escaping () -> Void = {},
        onHotkeyCaptureSessionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.settings = settings
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
            // Modo teste não usa o modelo local: libera a RAM imediatamente.
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

    /// `true` quando o ditado usa o modelo local deste Mac.
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

    // MARK: - Modelo local (UI)

    var localStatusIsReady: Bool {
        parakeetModelStore.isDownloaded
    }

    var isLocalModelDownloaded: Bool {
        parakeetModelStore.isDownloaded
    }

    var isLocalModelDownloading: Bool {
        parakeetModelStore.isDownloading
    }

    var storageSummaryLabel: String {
        parakeetModelStore.onDiskByteCount.voiceIAByteCountLabel
    }

    var downloadsFooterLabel: String {
        isLocalModelDownloaded ? "Em disco: \(storageSummaryLabel)" : "Nenhum modelo baixado"
    }

    var detailedDownloadProgress: (fraction: Double, percentLabel: String, speedLabel: String, sizeLabel: String)? {
        guard let progress = parakeetModelStore.downloadProgress else { return nil }
        return (
            progress.fractionCompleted,
            progress.percentLabel,
            progress.speedLabel,
            progress.sizeLabel
        )
    }

    func downloadLocalModel() {
        parakeetModelStore.download()
        Task { @MainActor in
            while parakeetModelStore.isDownloading {
                try? await Task.sleep(for: .milliseconds(200))
            }
            parakeetModelStore.refreshDiskState()
        }
    }

    func cancelLocalModelDownload() {
        parakeetModelStore.cancelDownload()
    }

    func deleteLocalModel() {
        do {
            // Solta o modelo da RAM antes de apagar o que está em disco.
            onTranscriptionPolicyChanged()
            try parakeetModelStore.delete()
        } catch {
            parakeetModelStore.reportError(error.localizedDescription)
        }
    }

    func refreshLocalModelDiskState() {
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
        NSWorkspace.shared.open(parakeetModelStore.cacheDirectory)
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
