import Foundation
import FluidAudio
import Observation
import OSLog

/// Download, estado em disco e exclusão do CTC 110M usado na substituição de palavras.
///
/// É um modelo **auxiliar**, separado do Parakeet TDT: o 0.6B não tem head CTC,
/// e é o CTC que confere no áudio se a palavra falada corresponde ao termo
/// cadastrado. Sem ele o ditado funciona igual — só não corrige vocabulário.
///
/// Por isso o download é opcional e fica num card próprio: quem não usa
/// substituições não paga os ~60–70 MB de RAM nem o espaço em disco.
@Observable
@MainActor
final class LocalCtcModelStore {
    static let shared = LocalCtcModelStore()

    /// Tamanho aproximado, para o rótulo antes de conhecer o repo.
    static let estimatedByteCount: Int64 = 120_000_000

    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "ctc-store")
    private let variant: CtcModelVariant = .ctc110m

    private(set) var isDownloading = false
    private(set) var onDiskByteCount: Int64 = 0
    private(set) var lastErrorMessage: String?
    private var downloadTask: Task<Void, Never>?

    private init() {
        refreshDiskState()
    }

    var cacheDirectory: URL {
        CtcModels.defaultCacheDirectory(for: variant)
    }

    var isDownloaded: Bool {
        CtcModels.modelsExist(at: cacheDirectory)
    }

    func refreshDiskState() {
        onDiskByteCount = directoryByteCount(at: cacheDirectory)
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func reportError(_ message: String) {
        lastErrorMessage = message
    }

    /// Baixa o pacote CTC pelo downloader do FluidAudio.
    ///
    /// Diferente do Parakeet, aqui não usamos o downloader paralelo próprio: são
    /// dois arquivos e ~120 MB, então a serialidade do `ModelHub` não incomoda
    /// como incomodava nos 460 MB do TDT.
    func download() {
        guard !isDownloading else { return }
        lastErrorMessage = nil
        isDownloading = true

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await CtcModels.download(variant: self.variant)
                try Task.checkCancellation()
                await MainActor.run {
                    self.isDownloading = false
                    self.refreshDiskState()
                    self.logger.notice("CTC 110M baixado (compile ocorre no 1º uso).")
                }
            } catch is CancellationError {
                await MainActor.run { self.isDownloading = false }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.lastErrorMessage = error.localizedDescription
                    self.logger.error("Download do CTC falhou: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    func delete() throws {
        cancelDownload()
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDirectory.path) {
            try fm.removeItem(at: cacheDirectory)
        }
        refreshDiskState()
        logger.notice("CTC removido do disco.")
    }

    private func directoryByteCount(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !["partial", "etag"].contains(fileURL.pathExtension) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
