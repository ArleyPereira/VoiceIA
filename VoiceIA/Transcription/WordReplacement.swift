import Foundation

/// Um par "o que o modelo escreveu" → "o que deveria sair".
///
/// No motor local, cada par vira um termo de vocabulário do FluidAudio, onde a
/// substituição é a grafia canônica e o original entra como *alias*. Não é
/// find-replace no texto pronto: o reconhecimento usa o áudio como evidência,
/// então "brand" só vira "branch" quando o som combina.
struct WordReplacement: Identifiable, Codable, Equatable {
    let id: UUID
    /// O que o modelo costuma escrever (`brand`, `gridle`, `anroid`).
    var original: String
    /// A grafia desejada (`branch`, `Gradle`, `Android`).
    var replacement: String
    /// Posição na lista. A ordem importa: é a ordem enviada ao motor, e é ela
    /// que desempata conflitos raros (`git` contra `GitHub`).
    var sortIndex: Int

    init(id: UUID = UUID(), original: String, replacement: String, sortIndex: Int) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.sortIndex = sortIndex
    }
}

/// Por que um par foi recusado, com a mensagem que a UI mostra.
enum WordReplacementValidationError: Equatable {
    case emptyField
    case tooShort(minimum: Int)
    case duplicated(original: String)

    var message: String {
        switch self {
        case .emptyField:
            return "Preencha os dois campos."
        case .tooShort(let minimum):
            return "Use pelo menos \(minimum) caracteres — termos curtos geram troca errada."
        case .duplicated(let original):
            return "Já existe uma substituição para “\(original)”."
        }
    }
}

extension WordReplacement {
    /// Mínimo de caracteres aceito nos dois lados.
    ///
    /// O FluidAudio ignora termo com menos de 3 caracteres justamente porque
    /// pedaço curto casa com qualquer coisa (o exemplo do paper é `or` → `VR`).
    /// Recusamos aqui para o usuário receber o motivo em vez de cadastrar um
    /// par que o motor vai descartar em silêncio.
    static let minimumLength = 3
}
