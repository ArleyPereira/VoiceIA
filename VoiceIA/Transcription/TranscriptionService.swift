import Foundation

/// Contrato para serviços de transcrição de áudio.
protocol TranscriptionService {
    /// Transcreve o áudio no URL informado e retorna o texto.
    func transcribe(audioURL: URL) async throws -> String
}
