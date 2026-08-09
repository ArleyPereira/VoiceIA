import Foundation

/// Contrato para serviços de transcrição de áudio.
protocol TranscriptionService {
    /// Transcreve o áudio. Quando `pcmSamples` vem preenchido (captura local em
    /// 16 kHz mono), a ASR local usa essas amostras e não decodifica o arquivo.
    func transcribe(audioURL: URL, pcmSamples: [Float]?) async throws -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL) async throws -> String {
        try await transcribe(audioURL: audioURL, pcmSamples: nil)
    }
}
