import CoreML
import FluidAudio
import Foundation
import OSLog
import WhisperMetalKit

/// Transcrição local via NVIDIA Parakeet TDT 0.6B V3 (Core ML / FluidAudio).
final class LocalParakeetTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let settings: AppSettings
    private let modelStore: LocalParakeetModelStore
    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "local-parakeet")
    private let cacheLock = NSLock()

    /// Mantém o manager quente entre ditagens próximas.
    private var cachedManager: AsrManager?
    private var warmTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?

    /// Após este tempo ocioso o Core ML sai da RAM (Spokenly também não fica
    /// com ~1 GB residente o tempo todo). A próxima ditagem reaquece no atalho.
    private static let idleUnloadDelay: Duration = .seconds(120)

    init(settings: AppSettings, modelStore: LocalParakeetModelStore? = nil) {
        self.settings = settings
        self.modelStore = modelStore ?? .shared
    }

    func transcribe(audioURL: URL, pcmSamples: [Float]? = nil) async throws -> String {
        cancelIdleUnload()

        let pipelineStart = Date()
        let languageCode = await MainActor.run { settings.transcriptionLanguage }
        let downloaded = await MainActor.run { modelStore.isDownloaded }
        guard downloaded else {
            throw VoiceInputError.localModelMissing
        }

        let samples: [Float]
        if let pcmSamples, !pcmSamples.isEmpty {
            samples = pcmSamples
            logger.notice(
                "Parakeet: PCM em memória (\(samples.count) amostras, \(String(format: "%.2f", Double(samples.count) / 16_000.0))s)."
            )
        } else {
            let decodeStart = Date()
            samples = try WhisperAudio.samples(fromFile: audioURL)
            logger.notice(
                "Parakeet: decode do arquivo em \(String(format: "%.0f", Date().timeIntervalSince(decodeStart) * 1000)) ms."
            )
        }

        guard SpeechPresenceAnalyzer.hasSpeechEnergy(in: samples) else {
            logger.notice("Áudio sem energia de fala — ignorando.")
            scheduleIdleUnload()
            throw VoiceInputError.noSpeechDetected
        }

        let loadStart = Date()
        let manager = try await loadManager()
        let loadMs = Date().timeIntervalSince(loadStart) * 1000

        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language = Self.mapLanguage(languageCode)

        let inferStart = Date()
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: language)
        let inferMs = Date().timeIntervalSince(inferStart) * 1000
        let totalMs = Date().timeIntervalSince(pipelineStart) * 1000

        logger.notice(
            "Parakeet OK — load \(String(format: "%.0f", loadMs)) ms, infer \(String(format: "%.0f", inferMs)) ms, total \(String(format: "%.0f", totalMs)) ms."
        )

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleIdleUnload()
        guard !trimmed.isEmpty else {
            throw VoiceInputError.emptyTranscription
        }
        return trimmed
    }

    /// Carrega o Core ML (e especializa o ANE) sem bloquear a UI.
    ///
    /// Chamado no launch e no início da ditagem: enquanto você fala, o modelo
    /// já está quente quando soltar o atalho.
    func warmUpIfNeeded() {
        cancelIdleUnload()
        cacheLock.lock()
        let alreadyWarm = cachedManager != nil
        cacheLock.unlock()
        if alreadyWarm { return }

        warmTask?.cancel()
        warmTask = Task { [weak self] in
            guard let self else { return }
            let downloaded = await MainActor.run { self.modelStore.isDownloaded }
            guard downloaded else { return }
            do {
                let start = Date()
                let manager = try await self.loadManager()
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let silence = [Float](repeating: 0, count: 16_000)
                _ = try? await manager.transcribe(silence, decoderState: &state, language: .portuguese)
                self.logger.notice(
                    "Parakeet aquecido em \(String(format: "%.1f", Date().timeIntervalSince(start))) s."
                )
                self.scheduleIdleUnload()
            } catch {
                self.logger.error(
                    "Falha ao aquecer Parakeet: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Libera o Parakeet da memória (troca de modelo / política / ocioso).
    func unloadCachedModel() {
        warmTask?.cancel()
        warmTask = nil
        cancelIdleUnload()

        cacheLock.lock()
        let manager = cachedManager
        cachedManager = nil
        cacheLock.unlock()

        guard let manager else { return }
        Task {
            await manager.cleanup()
        }
        logger.notice("Modelo Parakeet liberado da memória.")
    }

    private func scheduleIdleUnload() {
        cancelIdleUnload()
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.idleUnloadDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.unloadCachedModel()
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func loadManager() async throws -> AsrManager {
        cacheLock.lock()
        if let cachedManager {
            let reused = cachedManager
            cacheLock.unlock()
            return reused
        }
        cacheLock.unlock()

        // Spokenly / FluidAudio: tudo no ANE. GPU no encoder gasta bem mais
        // RAM unificada por ~8% de RTFx — não vale para ditado.
        let configuration = AsrModels.defaultConfiguration()
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        let models = try await AsrModels.load(
            from: cacheDir,
            configuration: configuration,
            version: .v3,
            encoderComputeUnits: .cpuAndNeuralEngine
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        cacheLock.lock()
        if let previous = cachedManager, previous !== manager {
            Task { await previous.cleanup() }
        }
        cachedManager = manager
        cacheLock.unlock()
        return manager
    }

    private static func mapLanguage(_ code: String) -> Language? {
        switch code {
        case "pt": return .portuguese
        case "en": return .english
        case "es": return .spanish
        case "auto": return nil
        default: return Language(rawValue: code)
        }
    }
}
