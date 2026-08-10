import CoreML
import FluidAudio
import Foundation
import OSLog

/// Transcrição local via NVIDIA Parakeet TDT 0.6B V3 (Core ML / FluidAudio).
final class LocalParakeetTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let settings: AppSettings
    private let modelStore: LocalParakeetModelStore
    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "local-parakeet")
    private let cacheLock = NSLock()

    /// Mantém o manager quente entre ditagens próximas.
    private var cachedManager: AsrManager?
    /// Carregamento em andamento — compartilhado entre aquecimento e ditagem
    /// para o modelo não ser carregado duas vezes em paralelo.
    private var loadTask: Task<AsrManager, Error>?
    /// Camadas do decoder do modelo carregado (evita um hop de actor por ditagem).
    private var cachedDecoderLayers: Int?
    private var warmTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?

    /// Após este tempo ocioso o Core ML sai da RAM (Spokenly também não fica
    /// com ~1 GB residente o tempo todo). Dez minutos cobrem uma sessão de
    /// trabalho contínua sem recarregar; a próxima ditagem reaquece no atalho.
    private static let idleUnloadDelay: Duration = .seconds(600)

    init(settings: AppSettings, modelStore: LocalParakeetModelStore? = nil) {
        self.settings = settings
        self.modelStore = modelStore ?? .shared
    }

    func transcribe(audioURL: URL, pcmSamples: [Float]? = nil) async throws -> String {
        cancelIdleUnload()

        let pipelineStart = Date()
        // Um hop só: cada `MainActor.run` é uma ida e volta de scheduler no
        // caminho crítico da ditagem.
        let (languageCode, downloaded) = await MainActor.run {
            (settings.transcriptionLanguage, modelStore.isDownloaded)
        }
        guard downloaded else {
            throw VoiceInputError.localModelMissing
        }

        // O ditado sempre entrega o PCM da captura; decodificar o `.m4a` seria
        // pagar de novo por algo que já está em memória.
        guard let samples = pcmSamples, !samples.isEmpty else {
            throw VoiceInputError.emptyRecording
        }
        logger.notice(
            "Parakeet: PCM em memória (\(samples.count) amostras, \(String(format: "%.2f", Double(samples.count) / 16_000.0))s)."
        )

        guard SpeechPresenceAnalyzer.hasSpeechEnergy(in: samples) else {
            logger.notice("Áudio sem energia de fala — ignorando.")
            scheduleIdleUnload()
            throw VoiceInputError.noSpeechDetected
        }

        let loadStart = Date()
        let manager = try await loadManager()
        // O aquecimento roda uma inferência de 1 s de silêncio dentro do mesmo
        // actor; com o modelo já carregado ela só faria a ditagem real esperar
        // na fila do actor.
        warmTask?.cancel()
        let loadMs = Date().timeIntervalSince(loadStart) * 1000

        var decoderState = TdtDecoderState.make(decoderLayers: await decoderLayerCount(of: manager))
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
                // Se uma ditagem real já chegou, ela cancela este Task: rodar o
                // silêncio agora só a colocaria na fila do actor.
                guard !Task.isCancelled else { return }
                var state = TdtDecoderState.make(decoderLayers: await self.decoderLayerCount(of: manager))
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
        cachedDecoderLayers = nil
        loadTask?.cancel()
        loadTask = nil
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

    /// Carrega o modelo uma vez só, mesmo com aquecimento e ditagem concorrendo.
    ///
    /// A versão anterior soltava o lock antes de `AsrModels.load`, então o warm
    /// do atalho e a transcrição podiam carregar ~1 GB de Core ML em duplicata.
    private func loadManager() async throws -> AsrManager {
        cacheLock.lock()
        if let cachedManager {
            let reused = cachedManager
            cacheLock.unlock()
            return reused
        }

        let task: Task<AsrManager, Error>
        if let loadTask {
            task = loadTask
        } else {
            task = makeLoadTask()
            loadTask = task
        }
        cacheLock.unlock()

        do {
            return try await task.value
        } catch {
            cacheLock.lock()
            if loadTask == task {
                loadTask = nil
            }
            cacheLock.unlock()
            throw error
        }
    }

    private func makeLoadTask() -> Task<AsrManager, Error> {
        Task { [weak self] in
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

            if let self {
                self.cacheLock.lock()
                let previous = self.cachedManager
                self.cachedManager = manager
                self.cachedDecoderLayers = nil
                self.loadTask = nil
                self.cacheLock.unlock()

                if let previous, previous !== manager {
                    Task { await previous.cleanup() }
                }
            }
            return manager
        }
    }

    /// `AsrManager` é um actor: ler `decoderLayerCount` a cada ditagem é um hop
    /// desnecessário, já que o valor só muda quando o modelo é recarregado.
    private func decoderLayerCount(of manager: AsrManager) async -> Int {
        cacheLock.lock()
        let cached = cachedDecoderLayers
        cacheLock.unlock()
        if let cached { return cached }

        let layers = await manager.decoderLayerCount
        cacheLock.lock()
        cachedDecoderLayers = layers
        cacheLock.unlock()
        return layers
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
