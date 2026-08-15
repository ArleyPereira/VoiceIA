# VoiceIA — Ligar a substituição de palavras ao motor Parakeet

Documento de referência para retomar e decidir depois.
Criado em: **2026-08-13**
Idioma: português
Projeto: `/Users/arley/Developer/VoiceIA`

---

## 0. Resumo em uma frase

A lista de substituições existe, persiste e tem CRUD completo, mas **ainda não
chega ao motor**: a API de vocabulário do FluidAudio só existe no manager de
*streaming*, e nós transcrevemos em *batch*.

---

## 1. O que já está pronto

| Peça | Arquivo |
|---|---|
| Modelo | `VoiceIA/Transcription/WordReplacement.swift` |
| Persistência (JSON em Application Support) | `VoiceIA/Transcription/WordReplacementStore.swift` |
| Modal de CRUD | `VoiceIA/UI/Settings/WordReplacementsModal.swift` |
| Card na aba Transcrição | `VoiceIA/UI/Settings/SettingsView.swift` |

O usuário cadastra, edita, exclui, reordena e importa. Nada disso influencia a
transcrição hoje.

---

## 2. Por que a ligação não foi feita

O plano previa passar `CustomVocabularyContext` ao `AsrManager.transcribe`. Essa
API **não existe** ali.

Verificado no checkout do FluidAudio 0.15.5:

```
SlidingWindowAsrManager.swift:91
    public func configureVocabularyBoosting(
        vocabulary: CustomVocabularyContext,
        ctcModels: CtcModels,
        config: VocabularyRescorer.Config? = nil
    ) async throws
```

`configureVocabularyBoosting` é o **único** ponto de entrada do vocabulário, e
pertence ao `SlidingWindowAsrManager` — o manager de streaming. O `AsrManager`
que usamos em `LocalParakeetTranscriptionService` não tem parâmetro equivalente
em nenhuma das quatro sobrecargas de `transcribe`.

Confirmado também no CLI do próprio FluidAudio: quando recebe `--custom-vocab`,
ele instancia o streaming e chama `startStreaming()`, mesmo transcrevendo um
arquivo (`TranscribeCommand.swift:691-704`). Não há caminho batch.

---

## 3. O que a ligação exigiria

Trocar o motor de batch para streaming em `LocalParakeetTranscriptionService`:

| Hoje | Com vocabulário |
|---|---|
| `AsrManager.transcribe(samples, decoderState:, language:)` | `SlidingWindowAsrManager` |
| uma chamada, resultado direto | `startStreaming()` → `streamAudio(buffer)` → `finish()` |
| PCM `[Float]` em memória | `AVAudioPCMBuffer` |

Isso mexe no trecho mais sensível do app. A ASR responde hoje em ~200 ms com o
modelo quente (51 s de áudio em 276 ms), número obtido no PR de latência (#4)
depois de trabalho considerável. O manager de streaming tem outro perfil — foi
desenhado para emitir parciais durante a fala, não para transcrever de uma vez
no fim.

Some-se o custo do CTC: o Parakeet 0.6B não tem *head* CTC, então o boosting
exige baixar e carregar um modelo auxiliar de ~110M (~60–70 MB de RAM), com
cache e idle unload próprios, espelhando o que já fazemos com o TDT.

---

## 4. Opções (nenhuma implementada)

### A — Migrar para o streaming manager

- **A favor:** é o único caminho que entrega o recurso como planejado.
- **Contra:** reescreve o núcleo da transcrição, com risco real de regressão de
  latência. Precisa de medição antes e depois, nos mesmos cenários do PR #4.

### B — Manter batch e aplicar find-replace no texto

- **A favor:** trivial, sem custo de RAM nem de latência.
- **Contra:** o plano descarta isso explicitamente, e com razão: `brand` viraria
  `branch` também quando a pessoa falasse "brand" de verdade. Sem evidência no
  áudio, é troca cega.

### C — Deixar como está e reavaliar

- A lista fica cadastrada, pronta para quando a decisão for tomada. O card
  informa o usuário; hoje ele não promete correção que não acontece.

---

## 5. Como validar quando for implementado

1. Cadastrar `brand → branch`, `gridle → Gradle`, `anroid → Android`.
2. Ditar as três palavras em frases naturais, com o modelo quente.
3. Conferir no log `local-parakeet` que a ASR continua na casa dos ~200 ms —
   comparar com os números do PR #4 antes de aceitar.
4. Ditar com a lista **vazia** e confirmar que o CTC nem é carregado.
5. Ditar "brand" no sentido de marca e confirmar que **não** vira "branch" —
   é o teste que separa boosting por áudio de find-replace cego.
