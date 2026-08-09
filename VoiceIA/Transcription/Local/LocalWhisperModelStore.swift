import Foundation
import OSLog

/// Progresso detalhado de um download de modelo.
struct ModelDownloadProgress: Sendable, Equatable {
    var fractionCompleted: Double
    var bytesReceived: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double

    var percentLabel: String {
        "\(Int((fractionCompleted * 100).rounded()))%"
    }

    var speedLabel: String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(Int64(bytesPerSecond).voiceIAThroughputLabel)/s"
    }

    var sizeLabel: String {
        let received = bytesReceived.voiceIAByteCountLabel
        if totalBytes > 0 {
            return "\(received) / \(totalBytes.voiceIAByteCountLabel)"
        }
        return received
    }

    var summaryLabel: String {
        "\(percentLabel) · \(speedLabel) · \(sizeLabel)"
    }

    static let zero = ModelDownloadProgress(
        fractionCompleted: 0,
        bytesReceived: 0,
        totalBytes: 0,
        bytesPerSecond: 0
    )
}

/// Gerencia download e exclusão dos modelos Whisper em Application Support.
///
/// Usa `URLSessionDownloadTask` (rápido, nativo) e um marcador `.partial`
/// para limpar incompletos no cancelamento / saída do app.
@Observable
@MainActor
final class LocalWhisperModelStore {
    static let shared = LocalWhisperModelStore()

    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "local-models")
    private let fileManager: FileManager
    /// Mantém o delegate vivo junto com a session.
    private let coordinator: DownloadSessionCoordinator

    private var session: URLSession!
    private var delegates: [Int: ModelDownloadSession] = [:]
    private var tasksByModel: [LocalWhisperModel: URLSessionDownloadTask] = [:]

    private(set) var detailedProgress: [LocalWhisperModel: ModelDownloadProgress] = [:]
    private(set) var downloading: Set<LocalWhisperModel> = []
    private(set) var lastErrorMessage: String?
    private(set) var onDiskByteCounts: [LocalWhisperModel: Int64] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let coordinator = DownloadSessionCoordinator()
        self.coordinator = coordinator

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)
        coordinator.owner = self

        purgeIncompleteDownloads()
        refreshDiskState()
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func reportError(_ message: String) {
        lastErrorMessage = message
    }

    var directoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = base
            .appendingPathComponent("VoiceIA", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func fileURL(for model: LocalWhisperModel) -> URL {
        directoryURL.appendingPathComponent(model.fileName)
    }

    func partialURL(for model: LocalWhisperModel) -> URL {
        directoryURL.appendingPathComponent(model.fileName + ".partial")
    }

    func isDownloaded(_ model: LocalWhisperModel) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: model).path)
    }

    var downloadedModels: [LocalWhisperModel] {
        LocalWhisperModel.allCases.filter(isDownloaded)
    }

    var downloadedCount: Int {
        downloadedModels.count
    }

    var totalOnDiskBytes: Int64 {
        onDiskByteCounts.values.reduce(0, +)
    }

    func progress(for model: LocalWhisperModel) -> ModelDownloadProgress? {
        detailedProgress[model]
    }

    func fraction(for model: LocalWhisperModel) -> Double {
        detailedProgress[model]?.fractionCompleted ?? 0
    }

    func refreshDiskState() {
        var counts: [LocalWhisperModel: Int64] = [:]
        for model in LocalWhisperModel.allCases {
            let url = fileURL(for: model)
            guard fileManager.fileExists(atPath: url.path),
                  let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else {
                continue
            }
            counts[model] = size.int64Value
        }
        onDiskByteCounts = counts
    }

    func cancelAllDownloadsAndPurgePartials() {
        for model in Array(downloading) {
            cancelDownload(model)
        }
        purgeIncompleteDownloads()
    }

    func purgeIncompleteDownloads() {
        let folder = directoryURL
        guard let items = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in items {
            let name = url.lastPathComponent
            guard name.hasSuffix(".partial") || name.hasSuffix(".download") else { continue }
            do {
                try fileManager.removeItem(at: url)
                logger.notice("Parcial removido: \(name, privacy: .public)")
            } catch {
                logger.error("Falha ao apagar parcial \(name, privacy: .public)")
            }
        }
    }

    func download(_ model: LocalWhisperModel) {
        lastErrorMessage = nil
        guard !isDownloaded(model), !downloading.contains(model) else { return }

        downloading.insert(model)
        detailedProgress[model] = ModelDownloadProgress(
            fractionCompleted: 0,
            bytesReceived: 0,
            totalBytes: model.estimatedByteCount,
            bytesPerSecond: 0
        )

        // Marcador: indica download incompleto no disco (apagado no sucesso/cancel).
        let partial = partialURL(for: model)
        try? fileManager.removeItem(at: partial)
        fileManager.createFile(atPath: partial.path, contents: Data("downloading".utf8))

        logger.notice("Baixando \(model.displayName, privacy: .public)…")

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 60 * 60 * 6

        let task = session.downloadTask(with: request)
        let state = ModelDownloadSession(
            model: model,
            estimatedTotal: model.estimatedByteCount,
            startedAt: Date()
        )
        delegates[task.taskIdentifier] = state
        tasksByModel[model] = task
        task.resume()
    }

    func cancelDownload(_ model: LocalWhisperModel) {
        if let task = tasksByModel[model] {
            delegates[task.taskIdentifier] = nil
            task.cancel()
        }
        tasksByModel[model] = nil
        downloading.remove(model)
        detailedProgress[model] = nil
        try? fileManager.removeItem(at: partialURL(for: model))
        logger.notice("Download cancelado: \(model.displayName, privacy: .public)")
    }

    func delete(_ model: LocalWhisperModel) throws {
        cancelDownload(model)
        let url = fileURL(for: model)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            logger.notice("Modelo removido: \(model.displayName, privacy: .public)")
        }
        refreshDiskState()
    }

    func deleteUnused(keeping selected: LocalWhisperModel?) throws {
        for model in downloadedModels where model != selected {
            try delete(model)
        }
    }

    // MARK: - Callbacks da session (via coordinator)

    fileprivate func handleProgress(
        taskID: Int,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpected: Int64
    ) {
        guard let state = delegates[taskID] else { return }
        let total = totalBytesExpected > 0 ? totalBytesExpected : state.estimatedTotal
        let elapsed = Date().timeIntervalSince(state.startedAt)
        let speed = elapsed > 0.2 ? Double(totalBytesWritten) / elapsed : 0
        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0

        detailedProgress[state.model] = ModelDownloadProgress(
            fractionCompleted: fraction,
            bytesReceived: totalBytesWritten,
            totalBytes: total,
            bytesPerSecond: speed
        )
    }

    fileprivate func handleFinished(taskID: Int, location: URL) {
        guard let state = delegates[taskID] else { return }
        let model = state.model
        let destination = fileURL(for: model)
        let partial = partialURL(for: model)

        defer {
            delegates[taskID] = nil
            tasksByModel[model] = nil
            downloading.remove(model)
            detailedProgress[model] = nil
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            try? fileManager.removeItem(at: partial)
            refreshDiskState()
            logger.notice("Download concluído: \(model.displayName, privacy: .public)")
        } catch {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: location)
            lastErrorMessage = "Não foi possível salvar \(model.displayName)."
            logger.error("Falha ao mover modelo: \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate func handleFailed(taskID: Int, error: Error?) {
        guard let state = delegates[taskID] else { return }
        let model = state.model

        delegates[taskID] = nil
        tasksByModel[model] = nil
        downloading.remove(model)
        detailedProgress[model] = nil
        try? fileManager.removeItem(at: partialURL(for: model))

        if let error {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled {
                logger.notice("Download cancelado: \(model.displayName, privacy: .public)")
                return
            }
            lastErrorMessage = "Falha ao baixar \(model.displayName)."
            logger.error("Download falhou: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Session bridge

private final class ModelDownloadSession {
    let model: LocalWhisperModel
    let estimatedTotal: Int64
    let startedAt: Date

    init(model: LocalWhisperModel, estimatedTotal: Int64, startedAt: Date) {
        self.model = model
        self.estimatedTotal = estimatedTotal
        self.startedAt = startedAt
    }
}

/// Delegate da URLSession; encaminha para o store no MainActor.
private final class DownloadSessionCoordinator: NSObject, URLSessionDownloadDelegate {
    weak var owner: LocalWhisperModelStore?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            owner?.handleProgress(
                taskID: id,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let id = downloadTask.taskIdentifier
        // O arquivo temp some ao sair deste método — copiar/mover já no MainActor síncrono via semáforo não funciona bem.
        // Copiamos para um temp nosso imediatamente.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceia-\(id)-\(UUID().uuidString).bin")
        try? FileManager.default.copyItem(at: location, to: tempCopy)

        Task { @MainActor in
            owner?.handleFinished(taskID: id, location: tempCopy)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { @MainActor in
            owner?.handleFailed(taskID: id, error: error)
        }
    }
}

extension Int64 {
    var voiceIAByteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: self)
    }

    var voiceIAThroughputLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: self)
    }
}
