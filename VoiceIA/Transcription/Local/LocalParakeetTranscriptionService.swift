import AVFoundation
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
    /// Os mesmos `MLModel` que o manager está usando.
    ///
    /// O manager de streaming precisa receber um `AsrModels`, e é este: passar o
    /// objeto já carregado faz os dois caminhos compartilharem o Core ML em vez
    /// de manter ~1 GB duplicado na RAM.
    private var cachedModels: AsrModels?
    /// Carregamento em andamento — compartilhado entre aquecimento e ditagem
    /// para o modelo não ser carregado duas vezes em paralelo.
    private var loadTask: Task<AsrManager, Error>?
    /// Camadas do decoder do modelo carregado (evita um hop de actor por ditagem).
    private var cachedDecoderLayers: Int?
    /// CTC do boosting, quente entre ditagens como o TDT.
    private var cachedCtcModels: CtcModels?
    private var cachedCtcTokenizer: CtcTokenizer?
    private var ctcLoadTask: Task<CtcModels, Error>?
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
        let (languageCode, downloaded, replacements, ctcReady) = await MainActor.run {
            (
                settings.transcriptionLanguage,
                modelStore.isDownloaded,
                WordReplacementStore.shared.items,
                LocalCtcModelStore.shared.isDownloaded
            )
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

        let language = Self.mapLanguage(languageCode)

        // Só vale pagar o custo do boosting quando há substituição cadastrada e
        // o CTC está em disco. Sem uma das duas, o ditado segue no caminho batch
        // de sempre — a lista vazia não deve custar nada.
        let wantsBoosting = !replacements.isEmpty && ctcReady
        if !replacements.isEmpty && !ctcReady {
            logger.notice(
                "Substituições cadastradas (\(replacements.count)) mas CTC não baixado — transcrevendo sem boosting."
            )
        }

        let inferStart = Date()
        var boosted: String?
        if wantsBoosting {
            do {
                boosted = try await transcribeWithBoosting(samples: samples, replacements: replacements)
                if boosted == nil {
                    logger.error("Boosting devolveu texto vazio — repetindo no caminho batch.")
                }
            } catch {
                // Falha no boosting não pode custar a ditagem: o texto sem
                // correção é muito melhor que erro na cara do usuário.
                logger.error(
                    "Boosting falhou (\(error.localizedDescription, privacy: .public)) — caindo para o caminho batch."
                )
            }
        }

        let text: String
        if let boosted {
            text = boosted
        } else {
            var decoderState = TdtDecoderState.make(decoderLayers: await decoderLayerCount(of: manager))
            text = try await manager.transcribe(samples, decoderState: &decoderState, language: language).text
        }
        let inferMs = Date().timeIntervalSince(inferStart) * 1000
        let totalMs = Date().timeIntervalSince(pipelineStart) * 1000

        logger.notice(
            "Parakeet OK — load \(String(format: "%.0f", loadMs)) ms, infer \(String(format: "%.0f", inferMs)) ms, total \(String(format: "%.0f", totalMs)) ms, boosting \(boosted != nil ? "aplicado" : (wantsBoosting ? "recuado para batch" : "off"), privacy: .public)."
        )

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        cachedModels = nil
        cachedDecoderLayers = nil
        loadTask?.cancel()
        loadTask = nil
        // O CTC do boosting acompanha o TDT: manter só ele residente não faria
        // sentido, já que sozinho ele não transcreve nada.
        let hadCtc = cachedCtcModels != nil
        cachedCtcModels = nil
        cachedCtcTokenizer = nil
        ctcLoadTask?.cancel()
        ctcLoadTask = nil
        cacheLock.unlock()

        if hadCtc {
            logger.notice("CTC liberado da memória.")
        }

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
                self.cachedModels = models
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

    // MARK: - Substituição de palavras (vocabulary boosting)

    /// Piso de similaridade do "resgate acústico" do rescorer.
    ///
    /// Vem desligado no FluidAudio, e sem ele o CTC — que é um modelo inglês —
    /// troca trechos aleatórios de português por termos da lista. Medido num
    /// ditado de 36 s: cinco trocas destrutivas (`teste falhar` → `commit
    /// commit commit`) no padrão, zero com o piso, e a correção legítima
    /// (`branche` → `branch`, similaridade ~0,92) sobrevive nos dois.
    private static let spotterRescueFloor: Float = 0.60

    /// Piso de similaridade do caminho principal do rescorer (padrão 0,52).
    ///
    /// Em 0,52 ele troca palavras que só dividem o começo: `branch própria`
    /// virou `branch main`, e um `e` sumiu no meio da frase. Em 0,85 os dois
    /// estragos somem e nenhuma correção legítima é perdida — `brand main` →
    /// `branch main`, `brand nova` → `branch nova`, `branche` → `branch`. O
    /// preço é recall: `branch meio` deixa de virar `branch main`.
    private static let vocabularyMinSimilarity: Float = 0.85

    /// Contexto mínimo para o texto ser "confirmado" — e só texto confirmado é
    /// avaliado pelo rescorer.
    ///
    /// O padrão do FluidAudio é 10 s, pensado para streaming ao vivo, onde
    /// confirmar cedo demais faz o texto na tela mudar depois. Aqui o áudio
    /// chega inteiro e só lemos o resultado final, então esperar não protege
    /// nada — só faz **toda ditagem de menos de 10 s passar sem nenhuma
    /// substituição ser sequer considerada**, que é a maioria delas.
    private static let minContextForConfirmation: TimeInterval = 1.0

    /// Converte a lista do usuário no vocabulário do FluidAudio.
    ///
    /// O par vira **um termo com alias**: `text` é a grafia desejada e o alias é
    /// o que o modelo costuma escrever. Não é find-replace — o CTC confere no
    /// áudio se o trecho realmente soa como o termo antes de trocar.
    ///
    /// O `ctcTokenIds` não é opcional na prática: sem ele o rescorer descarta
    /// todo candidato em silêncio, e a lista inteira vira enfeite.
    private static func vocabularyTerms(
        from replacements: [WordReplacement],
        tokenizer: CtcTokenizer
    ) -> [CustomVocabularyTerm] {
        replacements.compactMap { item in
            let ids = tokenizer.encode(item.replacement)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: item.replacement,
                aliases: [item.original],
                ctcTokenIds: ids
            )
        }
    }

    /// Transcreve com boosting via `SlidingWindowAsrManager`.
    ///
    /// `configureVocabularyBoosting` só existe no manager de streaming — não há
    /// equivalente em `AsrManager`. Como o áudio inteiro já está em memória,
    /// entregamos tudo de uma vez: a janela padrão é a mesma 11+2+2 do caminho
    /// batch, então isto é streaming na forma e batch no efeito.
    ///
    /// O manager é descartável por ditagem: `finish()` encerra o `AsyncStream`
    /// de entrada, que é criado no `init` e não volta. O que se reaproveita são
    /// os modelos — o TDT e o CTC ficam quentes no cache.
    ///
    /// - Returns: o texto, ou `nil` quando o boosting devolve vazio. Com
    ///   vocabulário ligado, o `finish()` do FluidAudio remonta o texto a partir
    ///   de confirmado + volátil em vez dos tokens; se a última janela sai vazia
    ///   — silêncio no fim da fala, que é o normal ao soltar o atalho — ele
    ///   devolve string vazia e perde a ditagem inteira. Medido e reproduzível.
    private func transcribeWithBoosting(
        samples: [Float],
        replacements: [WordReplacement]
    ) async throws -> String? {
        let models = try await loadModelsForStreaming()
        let (ctcModels, tokenizer) = try await loadCtcModels()

        let terms = Self.vocabularyTerms(from: replacements, tokenizer: tokenizer)
        guard !terms.isEmpty else { return nil }

        // Mesma janela 11+2+2 do caminho batch; só o gatilho de confirmação muda.
        let windowConfig = SlidingWindowAsrConfig(
            chunkSeconds: 11.0,
            hypothesisChunkSeconds: 2.0,
            leftContextSeconds: 2.0,
            rightContextSeconds: 2.0,
            minContextForConfirmation: Self.minContextForConfirmation,
            confirmationThreshold: 0.85
        )
        let streaming = SlidingWindowAsrManager(config: windowConfig)
        try await streaming.loadModels(models)

        let vocabulary = CustomVocabularyContext(
            terms: terms,
            minSimilarity: Self.vocabularyMinSimilarity,
            minTermLength: WordReplacement.minimumLength
        )
        try await streaming.configureVocabularyBoosting(
            vocabulary: vocabulary,
            ctcModels: ctcModels,
            config: VocabularyRescorer.Config(
                spotterRescueMinSimilarity: Self.spotterRescueFloor,
                spotterRescueMultiWordMinSimilarity: Self.spotterRescueFloor
            )
        )

        // `.microphone` só descreve a origem do áudio para o manager; o PCM é o
        // mesmo que o caminho batch recebe.
        try await streaming.startStreaming(source: .microphone)
        await streaming.streamAudio(try Self.makeBuffer(from: samples))
        let text = try await streaming.finish()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self.restoreRegisteredSpelling(in: text, replacements: replacements)
    }

    /// Devolve ao termo a grafia exata que o usuário cadastrou.
    ///
    /// O FluidAudio copia a capitalização do que o **modelo** escreveu para o
    /// termo trocado (`preserveCapitalization`): como o Parakeet escreve `Brand`
    /// com maiúscula, `branch` voltava `Branch` mesmo sem nenhum cadastro assim.
    /// Numa substituição de palavras a grafia cadastrada é o contrato — quem
    /// escreveu `branch` quer `branch`.
    ///
    /// Vale para o texto todo do caminho com boosting: não dá para saber quais
    /// ocorrências vieram de uma troca, então qualquer aparição do termo é
    /// normalizada. O efeito colateral é que o termo fica minúsculo mesmo
    /// começando frase.
    private static func restoreRegisteredSpelling(
        in text: String,
        replacements: [WordReplacement]
    ) -> String {
        var result = text
        for item in replacements {
            let wanted = item.replacement
            guard let first = wanted.first, first.isLowercase else { continue }

            let capitalized = wanted.prefix(1).uppercased() + wanted.dropFirst()
            // `$` e `\` seriam lidos como referência de grupo no template.
            let template = wanted
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: capitalized))\\b",
                with: template,
                options: [.regularExpression]
            )
        }
        return result
    }

    /// PCM 16 kHz mono em `AVAudioPCMBuffer`, formato que o manager de streaming exige.
    private static func makeBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
        let channel = buffer.floatChannelData?[0] else {
            throw VoiceInputError.transcriptionFailed
        }

        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Os `AsrModels` que o manager quente está usando.
    ///
    /// Depende do `loadManager()` justamente para não abrir um segundo caminho
    /// de carregamento: quem chega primeiro carrega, os dois compartilham.
    private func loadModelsForStreaming() async throws -> AsrModels {
        _ = try await loadManager()
        cacheLock.lock()
        let models = cachedModels
        cacheLock.unlock()
        guard let models else {
            throw VoiceInputError.localModelMissing
        }
        return models
    }

    /// Carrega CTC e tokenizer uma vez só, com o mesmo single-flight do TDT.
    ///
    /// A primeira carga compila o Core ML e leva ~12 s; por isso ela fica no
    /// cache junto com o TDT e sai da RAM no mesmo idle unload.
    private func loadCtcModels() async throws -> (CtcModels, CtcTokenizer) {
        cacheLock.lock()
        if let cachedCtcModels, let cachedCtcTokenizer {
            let pair = (cachedCtcModels, cachedCtcTokenizer)
            cacheLock.unlock()
            return pair
        }

        let task: Task<CtcModels, Error>
        if let ctcLoadTask {
            task = ctcLoadTask
        } else {
            task = Task { [weak self] in
                let start = Date()
                let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
                let loaded = try await CtcModels.load(from: directory)
                let tokenizer = try await CtcTokenizer.load(from: directory)
                if let self {
                    self.cacheLock.lock()
                    self.cachedCtcModels = loaded
                    self.cachedCtcTokenizer = tokenizer
                    self.ctcLoadTask = nil
                    self.cacheLock.unlock()
                    self.logger.notice(
                        "CTC carregado em \(String(format: "%.1f", Date().timeIntervalSince(start))) s."
                    )
                }
                return loaded
            }
            ctcLoadTask = task
        }
        cacheLock.unlock()

        do {
            let models = try await task.value
            cacheLock.lock()
            let tokenizer = cachedCtcTokenizer
            cacheLock.unlock()
            guard let tokenizer else { throw VoiceInputError.transcriptionFailed }
            return (models, tokenizer)
        } catch {
            cacheLock.lock()
            if ctcLoadTask == task {
                ctcLoadTask = nil
            }
            cacheLock.unlock()
            throw error
        }
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
