import Foundation
import OSLog
import WhisperMetalKit

/// Transcrição local via whisper.cpp (GGML) com Metal opcional.
final class LocalWhisperTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let settings: AppSettings
    private let modelStore: LocalWhisperModelStore
    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "local-whisper")
    private let cacheLock = NSLock()

    /// Cache do modelo carregado (path + flag GPU).
    private var cachedKey: String?
    private var cachedModel: WhisperModel?

    init(settings: AppSettings, modelStore: LocalWhisperModelStore = .shared) {
        self.settings = settings
        self.modelStore = modelStore
    }

    func transcribe(audioURL: URL, pcmSamples: [Float]? = nil) async throws -> String {
        let modelID = await MainActor.run { settings.selectedLocalWhisperModel }
        let useGPU = await MainActor.run { settings.useLocalWhisperGPU }
        let language = await MainActor.run { settings.transcriptionLanguage }

        guard let modelKind = LocalWhisperModel(rawValue: modelID) else {
            throw VoiceInputError.localModelMissing
        }

        let modelURL = await MainActor.run { modelStore.fileURL(for: modelKind) }
        let exists = await MainActor.run { modelStore.isDownloaded(modelKind) }
        guard exists else {
            throw VoiceInputError.localModelMissing
        }

        logger.notice("Transcrevendo localmente com \(modelKind.displayName, privacy: .public) (GPU=\(useGPU, privacy: .public)).")

        let samples: [Float]
        if let pcmSamples, !pcmSamples.isEmpty {
            samples = pcmSamples
        } else {
            samples = try WhisperAudio.samples(fromFile: audioURL)
        }
        guard SpeechPresenceAnalyzer.hasSpeechEnergy(in: samples) else {
            logger.notice("Áudio sem energia de fala — ignorando (evita alucinação do Whisper).")
            throw VoiceInputError.noSpeechDetected
        }

        let whisper = try await loadModel(at: modelURL, useGPU: useGPU)
        // Libera assim que a ditagem termina: manter ~GB em cache entre usos
        // deixa a RAM alta mesmo ocioso. A próxima ditagem recarrega sob demanda.
        defer { unloadCachedModel() }

        let options = WhisperOptions(
            language: language == "auto" ? nil : language,
            translate: false
        )
        let result = try await whisper.transcribe(samples: samples, options: options)
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceInputError.emptyTranscription
        }
        if SpeechPresenceAnalyzer.looksLikeSilenceHallucination(trimmed) {
            logger.notice("Transcrição descartada como alucinação de silêncio: \(trimmed, privacy: .public)")
            throw VoiceInputError.noSpeechDetected
        }
        return trimmed
    }

    /// Libera o modelo Whisper da memória (RAM/GPU).
    ///
    /// O `WhisperModel` faz `whisper_free` no `deinit`; basta soltar a referência
    /// forte para o runtime recuperar os ~GB do GGML.
    func unloadCachedModel() {
        cacheLock.lock()
        let hadModel = cachedModel != nil
        cachedModel = nil
        cachedKey = nil
        cacheLock.unlock()

        guard hadModel else { return }
        logger.notice("Modelo Whisper local liberado da memória.")
    }

    private func loadModel(at url: URL, useGPU: Bool) async throws -> WhisperModel {
        let key = "\(url.path)|gpu=\(useGPU)"

        cacheLock.lock()
        if let cachedModel, cachedKey == key {
            let reused = cachedModel
            cacheLock.unlock()
            return reused
        }
        cacheLock.unlock()

        let model = try await WhisperModel(modelPath: url, useGPU: useGPU)

        cacheLock.lock()
        cachedModel = model
        cachedKey = key
        cacheLock.unlock()
        return model
    }
}

/// Escolhe OpenAI, Whisper local ou Parakeet conforme as preferências.
final class CompositeTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let settings: AppSettings
    private let openAI: OpenAITranscriptionService
    private let localWhisper: LocalWhisperTranscriptionService
    private let localParakeet: LocalParakeetTranscriptionService

    init(settings: AppSettings) {
        self.settings = settings
        self.openAI = OpenAITranscriptionService(settings: settings)
        self.localWhisper = LocalWhisperTranscriptionService(settings: settings)
        self.localParakeet = LocalParakeetTranscriptionService(settings: settings)
    }

    func transcribe(audioURL: URL, pcmSamples: [Float]? = nil) async throws -> String {
        // Um hop só: três `MainActor.run` em série no caminho crítico eram três
        // idas e voltas de scheduler para ler três flags.
        let (testMode, backend, modelID) = await MainActor.run {
            (settings.isTestModeEnabled, settings.transcriptionBackend, settings.selectedLocalWhisperModel)
        }

        if testMode {
            // Mantém o mock no serviço OpenAI (sem rede).
            return try await openAI.transcribe(audioURL: audioURL, pcmSamples: nil)
        }

        if backend == "local" {
            let model = LocalTranscriptionModel(rawValue: modelID) ?? .default
            switch model.engine {
            case .whisper:
                return try await localWhisper.transcribe(audioURL: audioURL, pcmSamples: pcmSamples)
            case .parakeet:
                return try await localParakeet.transcribe(audioURL: audioURL, pcmSamples: pcmSamples)
            }
        }
        return try await openAI.transcribe(audioURL: audioURL, pcmSamples: nil)
    }

    /// Pré-carrega o Parakeet quando ele é o modelo local ativo.
    func warmLocalModelsIfNeeded() {
        Task { @MainActor in
            guard settings.transcriptionBackend == "local",
                  !settings.isTestModeEnabled else { return }
            let model = LocalTranscriptionModel(rawValue: settings.selectedLocalWhisperModel) ?? .default
            guard model.engine == .parakeet else { return }
            localParakeet.warmUpIfNeeded()
        }
    }

    /// Descarta Whisper e Parakeet em cache (modo teste, API ou troca de modelo/GPU).
    func unloadCachedLocalModel() {
        localWhisper.unloadCachedModel()
        localParakeet.unloadCachedModel()
    }
}
