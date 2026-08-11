import Foundation

/// Contrato para inserção de texto no aplicativo focado.
protocol TextInsertionService: AnyObject {
    /// Estratégia usada na última inserção (diagnóstico na interface).
    var lastMethod: InsertionMethod? { get }

    /// Chamado quando a ditagem comprovadamente não chegou ao campo.
    ///
    /// A entrega é assíncrona: o evento sai, mas só segundos depois dá para
    /// afirmar que o texto não apareceu. Como `insert` já retornou, a falha
    /// chega por aqui — é o que garante a barra de resgate mesmo quando o
    /// ⌘V é aceito pelo sistema e ainda assim se perde no app alvo.
    var onInsertionLost: ((String) -> Void)? { get set }

    /// Insere o texto no alvo apropriado (foco atual).
    func insert(text: String) async throws

    /// Insere o texto usando o elemento capturado no início da gravação.
    func insert(text: String, into captured: FocusedElement) async throws
}
