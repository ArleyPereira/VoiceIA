import Foundation
import Observation
import OSLog

/// Uma transcrição salva no histórico local.
struct TranscriptionHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let durationSeconds: TimeInterval?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        durationSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
    }
}

/// Persiste o histórico de transcrições em JSON (Application Support).
@Observable
@MainActor
final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()

    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "history")
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Entradas mais recentes primeiro.
    private(set) var entries: [TranscriptionHistoryEntry] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        loadFromDisk()
    }

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = base.appendingPathComponent("VoiceIA", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("transcription-history.json")
    }

    /// Adiciona uma entrada no topo. Ignora texto vazio.
    func append(text: String, durationSeconds: TimeInterval? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = TranscriptionHistoryEntry(
            text: trimmed,
            durationSeconds: durationSeconds
        )
        entries.insert(entry, at: 0)
        persist()
        logger.notice("Histórico: +1 entrada (total \(self.entries.count, privacy: .public)).")
    }

    func delete(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        persist()
    }

    func deleteAll() {
        guard !entries.isEmpty else { return }
        entries = []
        persist()
        logger.notice("Histórico limpo.")
    }

    private func loadFromDisk() {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let loaded = try decoder.decode([TranscriptionHistoryEntry].self, from: data)
            entries = loaded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            logger.error("Falha ao ler histórico: \(error.localizedDescription, privacy: .public)")
            entries = []
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Falha ao salvar histórico: \(error.localizedDescription, privacy: .public)")
        }
    }
}
