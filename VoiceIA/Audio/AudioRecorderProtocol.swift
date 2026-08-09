import Foundation

/// Contrato para captura de áudio do microfone.
protocol AudioRecorderProtocol: AnyObject {
    /// Indica se há sessão de gravação aberta (ativa ou pausada).
    var isRecording: Bool { get }

    /// Indica se a captura está pausada (sessão ainda aberta).
    var isPaused: Bool { get }

    /// Nível de áudio normalizado (0...1).
    var audioLevel: Float { get }

    /// Métricas da última captura concluída.
    var lastDiagnostics: CaptureDiagnostics { get }

    /// Inicia a gravação em um arquivo temporário.
    func startRecording() async throws

    /// Pausa a captura sem fechar o arquivo.
    func pauseRecording() async throws

    /// Retoma a captura no mesmo arquivo.
    func resumeRecording() async throws

    /// Encerra a gravação e devolve o URL do arquivo gerado.
    func stopRecording() async throws -> URL

    /// Consome o PCM 16 kHz mono acumulado durante a última captura.
    ///
    /// Evita o roundtrip AAC→PCM na transcrição local (Parakeet/Whisper).
    /// Devolve `nil` se não houver amostras.
    func consumePCMSamples() -> [Float]?

    /// Remove um arquivo de gravação temporário.
    func deleteRecording(at url: URL) throws
}
