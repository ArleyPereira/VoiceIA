import AppKit
import Foundation
import Observation
import OSLog

/// Fonte de verdade compartilhada do estado da aplicação.
@Observable
@MainActor
final class AppState {
    var recordingState: RecordingState = .idle {
        didSet { overlayController.sync(with: self) }
    }

    var lastRecordingURL: URL?
    var lastRecordingByteCount: Int?
    var lastCaptureDiagnostics: CaptureDiagnostics?
    var lastFocusedElementSummary: String?
    var lastInsertionMessage: String?
    var lastTranscriptionText: String?
    var permissionDeniedMessage: String?
    var lastHotkeyResultMessage: String?
    var isHotkeyMonitoringEnabled = false
    var isAccessibilityTrusted = AccessibilityPermission.isTrusted

    /// Configurações (API key no Keychain + idioma + guards de crédito).
    let settings: AppSettings

    /// Nível de áudio espelhado no MainActor para animar a waveform.
    var displayedAudioLevel: Float = 0

    /// Duração da gravação atual formatada (m:ss).
    var recordingDurationText: String = "0:00"

    private let audioRecorder: any AudioRecorderProtocol
    private let hotkeyService: any GlobalHotkeyServiceProtocol
    private let accessibilityService: any AccessibilityServiceProtocol
    private let textInsertionService: any TextInsertionService
    private let transcriptionService: any TranscriptionService
    private let overlayController = RecordingOverlayController()
    private let settingsWindowController = SettingsWindowController()
    private let clipboardFallbackDialog = ClipboardFallbackDialogController()
    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "pipeline")

    private var successResetTask: Task<Void, Never>?
    private var levelPollingTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    /// Tempo ativo já acumulado (exclui pausas).
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var capturedFocusedElement: FocusedElement?
    /// Distingue gravação de menu (só mic) do push-to-talk (transcreve).
    private var isMicrophoneOnlyTest = false

    /// Texto local só para o botão “Inserir texto de teste”.
    static let localInsertionTestText = "Olá, este é um teste do VoiceIA."

    init(
        audioRecorder: any AudioRecorderProtocol = AudioRecorder(),
        hotkeyService: any GlobalHotkeyServiceProtocol = GlobalHotkeyService(),
        accessibilityService: any AccessibilityServiceProtocol = AccessibilityService(),
        textInsertionService: (any TextInsertionService)? = nil,
        settings: AppSettings? = nil,
        transcriptionService: (any TranscriptionService)? = nil
    ) {
        self.audioRecorder = audioRecorder
        self.hotkeyService = hotkeyService
        self.accessibilityService = accessibilityService
        self.textInsertionService = textInsertionService
            ?? DefaultTextInsertionService(accessibilityService: accessibilityService)
        let resolvedSettings = settings ?? AppSettings()
        self.settings = resolvedSettings
        self.transcriptionService = transcriptionService
            ?? CompositeTranscriptionService(settings: resolvedSettings)
        refreshAccessibilityStatus()
        startHotkeyMonitoring()
    }

    /// Abre a janela de Configurações (API key + idioma).
    func openSettingsWindow() {
        settingsWindowController.show(settings: settings) { [weak self] in
            self?.releaseLocalWhisperResources()
        }
    }

    /// Libera o Whisper local da RAM/GPU quando o ditado não vai usá-lo.
    ///
    /// O modelo fica em cache depois da primeira transcrição local (~GB). Ao
    /// ligar o modo teste, voltar para a API ou trocar modelo/GPU, soltamos a
    /// referência para o `deinit` liberar o contexto GGML.
    func releaseLocalWhisperResources() {
        guard let composite = transcriptionService as? CompositeTranscriptionService else { return }
        composite.unloadCachedLocalModel()
    }

    var audioLevel: Float {
        audioRecorder.audioLevel
    }

    /// Relê o status de Acessibilidade (útil depois de o usuário autorizar nos Ajustes).
    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = accessibilityService.isTrusted()
    }

    /// Encerra e reabre o app para o macOS reavaliar a confiança de Acessibilidade.
    func relaunchForAccessibility() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
        }
    }

    /// Solicita a permissão de Acessibilidade (diálogo nativo + Ajustes).
    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        let granted = accessibilityService.requestAccess()
        isAccessibilityTrusted = granted
        if !granted {
            AccessibilityPermission.openSystemSettings()
        }
        return granted
    }

    /// Liga o monitoramento global de ⇧ Tab.
    func startHotkeyMonitoring() {
        guard !isHotkeyMonitoringEnabled else { return }

        hotkeyService.onPressed = { [weak self] in
            Task { @MainActor in
                await self?.handleHotkeyPressed()
            }
        }

        hotkeyService.onReleased = { [weak self] in
            // Release não finaliza — permite pause/continua no HUD.
            self?.hotkeyService.resetHoldState()
        }

        hotkeyService.start()
        isHotkeyMonitoringEnabled = true
    }

    func stopHotkeyMonitoring() {
        hotkeyService.stop()
        isHotkeyMonitoringEnabled = false
    }

    /// ⇧ Tab: inicia se idle; se já gravando/pausado, envia para transcrição.
    func handleHotkeyPressed() async {
        switch recordingState {
        case .recording, .paused:
            guard !isMicrophoneOnlyTest else { return }
            await finishDictationPipeline()
        case .idle, .error, .success:
            await beginDictationSession()
        case .transcribing, .inserting:
            break
        }
    }

    /// Inicia sessão de ditado (continua até pause/stop ou novo ⇧ Tab).
    func beginDictationSession() async {
        guard canStartRecording else { return }

        isMicrophoneOnlyTest = false
        successResetTask?.cancel()
        permissionDeniedMessage = nil
        lastHotkeyResultMessage = nil
        lastInsertionMessage = nil
        lastTranscriptionText = nil
        displayedAudioLevel = 0
        recordingDurationText = "0:00"
        accumulatedRecordingDuration = 0
        LiveAudioMeter.shared.reset()
        refreshAccessibilityStatus()
        settings.refreshAPIKeyStatus()

        if let gateError = dictationReadinessError() {
            failWithPermission(gateError)
            return
        }

        do {
            captureFocusBeforeRecordingBestEffort()
            try await audioRecorder.startRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            lastRecordingURL = nil
            lastRecordingByteCount = nil
            startLevelPolling()
            startDurationTicker()
        } catch let error as VoiceInputError where error == .microphonePermissionDenied {
            failWithPermission(error)
        } catch let error as VoiceInputError {
            failRecording(message: error.localizedDescription)
        } catch {
            failRecording(message: VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Pausa a captura (mesmo arquivo; dá para continuar depois).
    func pauseDictation() async {
        guard recordingState == .recording, !isMicrophoneOnlyTest else { return }
        do {
            try await audioRecorder.pauseRecording()
            if let startedAt = recordingStartedAt {
                accumulatedRecordingDuration += Date().timeIntervalSince(startedAt)
            }
            recordingStartedAt = nil
            recordingState = .paused
            stopLevelPolling()
            LiveAudioMeter.shared.reset()
            displayedAudioLevel = 0
            recordingDurationText = Self.formatDuration(accumulatedRecordingDuration)
        } catch {
            failRecording(message: (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Retoma a captura após pause.
    func resumeDictation() async {
        guard recordingState == .paused, !isMicrophoneOnlyTest else { return }
        do {
            try await audioRecorder.resumeRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            startLevelPolling()
            startDurationTicker()
        } catch {
            failRecording(message: (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Encerra e envia para transcrição (botão ■ do HUD).
    func stopDictationAndTranscribe() async {
        guard recordingState == .recording || recordingState == .paused else { return }
        guard !isMicrophoneOnlyTest else { return }
        await finishDictationPipeline()
    }

    /// Inicia gravação de teste do microfone (menu) — **nunca** chama OpenAI.
    func startTestRecording() async {
        guard canStartRecording else { return }
        isMicrophoneOnlyTest = true
        successResetTask?.cancel()
        permissionDeniedMessage = nil
        lastHotkeyResultMessage = nil
        lastInsertionMessage = nil
        displayedAudioLevel = 0
        recordingDurationText = "0:00"
        accumulatedRecordingDuration = 0
        LiveAudioMeter.shared.reset()
        refreshAccessibilityStatus()

        do {
            try await audioRecorder.startRecording()
            recordingStartedAt = Date()
            recordingState = .recording
            lastRecordingURL = nil
            lastRecordingByteCount = nil
            startLevelPolling()
            startDurationTicker()
        } catch let error as VoiceInputError where error == .microphonePermissionDenied {
            isMicrophoneOnlyTest = false
            failWithPermission(error)
        } catch let error as VoiceInputError {
            isMicrophoneOnlyTest = false
            failRecording(message: error.localizedDescription)
        } catch {
            isMicrophoneOnlyTest = false
            failRecording(message: VoiceInputError.recordingFailed.localizedDescription)
        }
    }

    /// Encerra teste de microfone: só valida arquivo local, sem OpenAI e sem inserção.
    func stopTestRecording(deleteAfterValidation: Bool = false) async -> String {
        guard (recordingState == .recording || recordingState == .paused), isMicrophoneOnlyTest else {
            return VoiceInputError.recordingNotInProgress.localizedDescription
        }

        stopLevelPolling()
        stopDurationTicker()
        let message = await stopRecordingInternal(deleteAfterValidation: deleteAfterValidation)
        lastHotkeyResultMessage = message
        isMicrophoneOnlyTest = false
        hotkeyService.resetHoldState()

        if recordingState != .error {
            lastInsertionMessage = "Teste de microfone OK (sem OpenAI)."
            recordingState = .idle
        } else {
            scheduleReturnToIdle(afterMilliseconds: 2_000)
        }

        return message
    }

    /// Insere texto local de teste (sem OpenAI).
    func insertTestTextNow() async -> String {
        refreshAccessibilityStatus()
        guard isAccessibilityTrusted else {
            permissionDeniedMessage = VoiceInputError.accessibilityPermissionDenied.localizedDescription
            recordingState = .error
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return permissionDeniedMessage ?? ""
        }

        recordingState = .idle
        do {
            try await textInsertionService.insert(text: Self.localInsertionTestText)
            let method = textInsertionService.lastMethod?.rawValue ?? "desconhecido"
            lastInsertionMessage = "Texto local inserido via \(method)."
            recordingState = .idle
            return lastInsertionMessage ?? ""
        } catch let error as VoiceInputError {
            recordingState = .error
            lastInsertionMessage = error.localizedDescription
            permissionDeniedMessage = error == .accessibilityPermissionDenied ? error.localizedDescription : nil
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return error.localizedDescription
        } catch {
            recordingState = .error
            lastInsertionMessage = VoiceInputError.textInsertionFailed.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return lastInsertionMessage ?? ""
        }
    }

    func resetErrorState() {
        if recordingState == .error {
            recordingState = .idle
        }
        permissionDeniedMessage = nil
    }

    /// Abre no Finder a pasta das gravações, já selecionando a mais recente.
    func openRecordingsFolder() {
        if let lastRecordingURL, FileManager.default.fileExists(atPath: lastRecordingURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
            return
        }
        NSWorkspace.shared.open(RecordingStorage.directoryURL)
    }

    // MARK: - Privado

    /// Single-flight: só inicia se estiver livre.
    private var canStartRecording: Bool {
        switch recordingState {
        case .idle, .error, .success:
            return true
        case .recording, .paused, .transcribing, .inserting:
            return false
        }
    }

    private var currentActiveDuration: TimeInterval {
        var total = accumulatedRecordingDuration
        if recordingState == .recording, let startedAt = recordingStartedAt {
            total += Date().timeIntervalSince(startedAt)
        }
        return total
    }

    private func finishDictationPipeline() async {
        stopLevelPolling()
        stopDurationTicker()

        if recordingState == .recording, let startedAt = recordingStartedAt {
            accumulatedRecordingDuration += Date().timeIntervalSince(startedAt)
            recordingStartedAt = nil
        }

        let message = await stopRecordingInternal(deleteAfterValidation: false)
        lastHotkeyResultMessage = message
        hotkeyService.resetHoldState()

        guard recordingState != .error, let audioURL = lastRecordingURL else {
            scheduleReturnToIdle(afterMilliseconds: 2_000)
            return
        }

        // Gate novamente (modo teste, API ou modelo local).
        settings.refreshAPIKeyStatus()
        if let gateError = dictationReadinessError() {
            recordingState = .error
            permissionDeniedMessage = gateError.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_500)
            return
        }

        recordingState = .transcribing

        let transcribed: String
        do {
            transcribed = try await transcriptionService.transcribe(audioURL: audioURL)
            lastTranscriptionText = transcribed
        } catch let error as VoiceInputError {
            recordingState = .error
            lastInsertionMessage = error.localizedDescription
            if error == .missingAPIKey || error == .localModelMissing {
                permissionDeniedMessage = error.localizedDescription
            }
            scheduleReturnToIdle(afterMilliseconds: 2_500)
            return
        } catch {
            recordingState = .error
            lastInsertionMessage = VoiceInputError.transcriptionFailed.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_500)
            return
        }

        await insertTranscribedText(transcribed)

        if !settings.keepRecordingsAfterTranscription {
            try? audioRecorder.deleteRecording(at: audioURL)
            if lastRecordingURL == audioURL {
                lastRecordingURL = nil
            }
        }
    }

    private func insertTranscribedText(_ text: String) async {
        // Esconde o HUD antes de digitar (Electron/Cursor).
        recordingState = .idle
        // Tempo extra: após Whisper local o Cursor precisa reassumir o foco AX.
        try? await Task.sleep(for: .milliseconds(280))

        do {
            if let captured = capturedFocusedElement {
                try await textInsertionService.insert(text: text, into: captured)
            } else {
                try await textInsertionService.insert(text: text)
            }
            let method = textInsertionService.lastMethod?.rawValue ?? "desconhecido"
            lastInsertionMessage = "Inserido via \(method)."
            recordingState = .idle
        } catch let error as VoiceInputError where error == .accessibilityPermissionDenied {
            recordingState = .error
            lastInsertionMessage = error.localizedDescription
            permissionDeniedMessage = error.localizedDescription
            scheduleReturnToIdle(afterMilliseconds: 2_000)
        } catch let error as VoiceInputError where error == .noFocusedElement {
            logger.notice("Nenhum alvo de inserção; oferecendo o texto ao usuário.")
            presentInsertionRescue(for: text, reason: .noFocusedField)
        } catch {
            // Qualquer outra falha: o texto não pode se perder.
            logger.notice("Inserção falhou (\(String(describing: error), privacy: .public)); oferecendo o texto ao usuário.")
            presentInsertionRescue(for: text, reason: .insertionRefused)
        }

        capturedFocusedElement = nil
    }

    /// Mostra a ditagem para o usuário quando a inserção automática falhou.
    ///
    /// Não escreve na área de transferência: sobrescrever o que o usuário
    /// copiou seria perda de dado. A cópia só acontece se ele clicar em "Copiar".
    private func presentInsertionRescue(for text: String, reason: InsertionRescueReason) {
        lastInsertionMessage = reason.statusMessage
        recordingState = .idle
        permissionDeniedMessage = nil

        // Adia um tick para o HUD idle fechar antes do diálogo aparecer.
        DispatchQueue.main.async { [weak self] in
            self?.clipboardFallbackDialog.present(transcribedText: text, reason: reason)
        }
    }

    /// Pré-condições do ditado conforme backend (teste ignora tudo).
    private func dictationReadinessError() -> VoiceInputError? {
        if settings.isTestModeEnabled { return nil }
        if settings.transcriptionBackend == "local" {
            let model = LocalWhisperModel(rawValue: settings.selectedLocalWhisperModel) ?? .largeV3
            if !LocalWhisperModelStore.shared.isDownloaded(model) {
                return .localModelMissing
            }
            return nil
        }
        if !settings.hasAPIKey {
            return .missingAPIKey
        }
        return nil
    }

    private func captureFocusBeforeRecordingBestEffort() {
        refreshAccessibilityStatus()
        guard isAccessibilityTrusted else {
            capturedFocusedElement = nil
            lastFocusedElementSummary = "sem Acessibilidade"
            return
        }

        do {
            let focused = try accessibilityService.focusedElement()
            capturedFocusedElement = focused
            lastFocusedElementSummary = focused.summary
        } catch {
            capturedFocusedElement = nil
            lastFocusedElementSummary = "foco indisponível"
        }
    }

    private func stopRecordingInternal(deleteAfterValidation: Bool) async -> String {
        do {
            let url = try await audioRecorder.stopRecording()
            let diagnostics = audioRecorder.lastDiagnostics

            lastRecordingURL = url
            lastRecordingByteCount = diagnostics.byteCount
            lastCaptureDiagnostics = diagnostics

            let message = "Áudio salvo:\n\(diagnostics.summary)"

            if deleteAfterValidation {
                try audioRecorder.deleteRecording(at: url)
                lastRecordingURL = nil
            }

            return message
        } catch {
            let diagnostics = audioRecorder.lastDiagnostics
            lastCaptureDiagnostics = diagnostics
            lastRecordingURL = diagnostics.fileURL
            lastRecordingByteCount = diagnostics.byteCount
            recordingState = .error

            let description = (error as? VoiceInputError)?.localizedDescription
                ?? VoiceInputError.recordingFailed.localizedDescription
            return "\(description)\n\(diagnostics.summary)"
        }
    }

    private func failWithPermission(_ error: VoiceInputError) {
        stopLevelPolling()
        stopDurationTicker()
        hotkeyService.resetHoldState()
        capturedFocusedElement = nil
        isMicrophoneOnlyTest = false
        recordingState = .error
        permissionDeniedMessage = error.localizedDescription
        scheduleReturnToIdle(afterMilliseconds: 2_500)
    }

    private func failRecording(message: String) {
        stopLevelPolling()
        stopDurationTicker()
        hotkeyService.resetHoldState()
        capturedFocusedElement = nil
        isMicrophoneOnlyTest = false
        recordingState = .error
        permissionDeniedMessage = message
        scheduleReturnToIdle(afterMilliseconds: 2_000)
    }

    private func startLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = Task { @MainActor in
            while !Task.isCancelled && recordingState == .recording {
                let level: Float
                if let recorder = audioRecorder as? AudioRecorder {
                    level = recorder.pollMeterLevel()
                } else {
                    level = audioRecorder.audioLevel
                    LiveAudioMeter.shared.setLevel(level)
                }
                displayedAudioLevel = level
                try? await Task.sleep(for: .milliseconds(33))
            }
            displayedAudioLevel = 0
        }
    }

    private func stopLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = nil
        displayedAudioLevel = 0
    }

    private func startDurationTicker() {
        durationTask?.cancel()
        durationTask = Task { @MainActor in
            while !Task.isCancelled && (recordingState == .recording || recordingState == .paused) {
                recordingDurationText = Self.formatDuration(currentActiveDuration)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stopDurationTicker() {
        durationTask?.cancel()
        durationTask = nil
        recordingDurationText = Self.formatDuration(currentActiveDuration)
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func scheduleReturnToIdle(afterMilliseconds: UInt64) {
        successResetTask?.cancel()
        successResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(afterMilliseconds))
            guard !Task.isCancelled else { return }
            if recordingState == .success || recordingState == .error {
                recordingState = .idle
                hotkeyService.resetHoldState()
            }
        }
    }
}
