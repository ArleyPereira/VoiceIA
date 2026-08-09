# VoiceIA — Falha de inserção no Cursor após Whisper local

Documento de handoff para outro modelo/agente continuar o diagnóstico.  
Criado em: **2026-08-09**  
Idioma: português  

---

## 0. CAUSA RAIZ ENCONTRADA em 2026-08-09 (terceira rodada)

**O Cursor não publicava nenhuma árvore de acessibilidade.** Não era o campo
que estava "errado": a API não devolvia *nada*.

Log do teste que falhou:

```
[accessibility] Nenhum elemento focado encontrado   (x9)
[insertion]     Sem alvo de inserção (nenhum candidato).
[dialog]        Diálogo de resgate visível (Sem campo em foco)
```

No Notas, no mesmo build: `Foco capturado: Notas · AXTextArea` → inserção OK.

### Por quê

Chromium/Electron só constrói a árvore de acessibilidade quando detecta um
cliente assistivo. Sem esse sinal, `kAXFocusedUIElement` do app é `nil` —
não existe elemento focado do ponto de vista da API.

Isso ficou fatal porque, numa rodada anterior, o fallback "usar o app inteiro
como alvo" foi removido de `AccessibilityService.focusedElement()` (para evitar
`⌘V` no vazio). Sem árvore **e** sem fallback, não sobrava candidato algum —
por isso até o modo teste, que antes funcionava no Cursor, parou.

### Comprovação empírica

Sonda executada contra o processo do Cursor:

```
antes  -> focusedUIElement: nil
AXManualAccessibility status: 0        (sucesso)
depois -> focusedUIElement: AXGroup    (árvore sendo montada)
depois -> focusedUIElement: AXTextArea settableValue=true settableSelected=true
          value="Send follow-up\n"
```

Ou seja: basta pedir a árvore que o input do chat aparece, editável.

### Correção

Em `AccessibilityService`:

1. Quando o lookup system-wide falha, pedir a árvore ao app antes de desistir:
   `AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)`.
   Em dois estágios por processo — `AXManualAccessibility` e, se ainda faltar,
   `AXEnhancedUserInterface` (o sinal clássico do VoiceOver, deixado para
   segundo porque pode mexer no tamanho das janelas).
2. Se mesmo assim não houver UI focada, usar a **janela focada** como alvo
   (a digitação sintética não exige papel de texto). Sem janela focada —
   Mesa/Finder — continua lançando `.noFocusedElement`, então o diálogo só
   aparece quando realmente não há onde escrever.

Em `DefaultTextInsertionService.resolveTargetWithRetry`: insistir enquanto o
alvo não for editável, em vez de aceitar a primeira resposta. O Chromium leva
algumas centenas de milissegundos para montar a árvore depois do pedido; parar
na primeira resposta devolveria só a janela.

O pedido acontece na captura de foco (início da gravação), então a árvore já
está pronta quando a transcrição termina.

---

## 0.1. SOLUÇÃO APLICADA em 2026-08-09 (segunda rodada)

**Causa raiz:** a inserção dependia de dois caminhos que o Cursor (Electron)
rejeita ou aceita de forma não confiável — escrita AX direta e `⌘V` sintético.
Quando ambos falhavam, o app concluía "não há campo em foco" e abria o diálogo,
mesmo com o input do Cursor focado.

**Correção:** foi adicionado um terceiro caminho, que virou o principal para
Electron/Chromium — **digitação Unicode sintética**:

```swift
CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
event.keyboardSetUnicodeString(stringLength:unicodeString:)
```

Por que funciona:

- `keyboardSetUnicodeString` entrega os caracteres direto ao cliente de entrada
  de texto do app (o mesmo canal usado por IMEs), sem depender de layout de
  teclado nem da área de transferência.
- `virtualKey: 0` impede que o app interprete o evento como atalho. Isso vale
  inclusive para `\n`, que entra como quebra de linha em vez de disparar o
  Enter (e enviar a mensagem do chat).
- `CGEventSource(stateID: .privateState)` isola o estado de modificadores: um
  Shift residual do ⇧ Tab deixa de contaminar a digitação.
- O texto é enviado em blocos de até 16 unidades UTF-16, cortando em fronteira
  de `Character` (não quebra emoji nem acento composto). Payload longo demais é
  truncado por alguns apps.

**Ordem final das estratégias** (`DefaultTextInsertionService`):

1. Accessibility verificado — apps nativos (Notas, TextEdit, Safari).
2. **Digitação Unicode** — Electron/Chromium. Não encosta no clipboard.
3. Clipboard + ⌘V — último recurso, com o clipboard do usuário **sempre
   restaurado** via `defer`.

**Verificação real de sucesso.** Todo caminho relê `kAXValue` antes e depois e
classifica em `confirmed` / `rejected` / `unknown`. Só cai para a estratégia
seguinte quando o campo comprovadamente não mudou — nada de falso sucesso.

**Clipboard deixou de ser sobrescrito em silêncio** (pedido explícito do
usuário):

- `insertViaClipboardPaste` restaura o snapshot em `defer`, inclusive em falha.
- O diálogo de resgate **não copia nada** ao abrir; só o botão "Copiar" escreve
  no `NSPasteboard`.
- `AppState` distingue `.noFocusedElement` de `.textInsertionFailed` e mostra
  títulos/textos diferentes (`InsertionRescueReason`).

**Diagnóstico.** Cada inserção registra em `logger.notice` o alvo, o pid, se o
papel era editável, o app frontmost e os candidatos capturado/ao-vivo.

Status: implementado, compilado e instalado em `/Applications/VoiceIA.app`.
Falta a validação do usuário no fluxo real.

O conteúdo abaixo é o histórico do diagnóstico.

---

**Projeto:** `/Users/arley/Developer/VoiceIA`  
**Bundle ID:** `dev.arley.santana.VoiceIA`  
**App de teste:** `/Applications/VoiceIA.app` (única cópia registrada; rebuild via `scripts/install-dev-app.sh`)

Documentos relacionados (histórico):

- `docs/Cursor_Insercao_Texto_Handoff.md` — inserção no Cursor em geral (parcialmente resolvida em 2026-08-08)
- `docs/Dialogo_Clipboard_Sem_Foco_Handoff.md` — diálogo quando realmente não há campo em foco

---

## 1. Problema atual (reproduzido em 2026-08-09)

### Sintoma

1. Usuário coloca o **input do Cursor** em foco (chat / follow-up).
2. Usa **⇧ Tab**, grava áudio, finaliza a gravação.
3. A transcrição roda (Whisper **local** ou outro backend).
4. Ao terminar, aparece o diálogo **“Sem campo em foco”** dizendo que não havia input focado e que o texto foi para a área de transferência.
5. Na prática o input do Cursor **ainda estava focado** (visualmente). O texto **não** foi inserido no campo.

### Expectativa do produto

- Com o input do Cursor focado no início da gravação, o texto transcrito deve **aparecer nesse campo** ao final.
- O diálogo “Sem campo em foco” só deve aparecer quando **de fato** não houver campo de texto utilizável.
- **Não** se deve sobrescrever o clipboard do usuário de forma silenciosa / automática só para tentar colar (ver §5).

### Ambiente do teste

- macOS (Darwin 25.x)
- Cursor (Electron/Chromium)
- VoiceIA menu bar, hotkey **⇧ Tab**
- Transcrição local via WhisperMetalKit + modelos GGML em  
  `~/Library/Application Support/VoiceIA/Models/`
- Toggle **Usar no ditado** (backend `local`) e/ou modo teste na aba API

---

## 2. Pipeline relevante

```
⇧ Tab pressionado
  → AppState.beginDictationSession()
  → captureFocusBeforeRecordingBestEffort()   // guarda FocusedElement
  → grava áudio
⇧ Tab / stop
  → finishDictationPipeline()
  → transcriptionService.transcribe(...)       // pode demorar (Whisper local)
  → insertTranscribedText(texto)
       → recordingState = .idle (esconde HUD)
       → sleep ~280 ms
       → textInsertionService.insert(text, into: captured)
            → tenta Accessibility verificado
            → se falhar, tenta clipboard + ⌘V sintético
       → se qualquer erro (exceto Acessibilidade negada):
            → presentClipboardFallback()  // limpa clipboard + diálogo
```

Arquivos-chave:

| Arquivo | Papel |
|---|---|
| `VoiceIA/App/AppState.swift` | Captura de foco, pipeline, fallback do diálogo |
| `VoiceIA/Input/DefaultTextInsertionService.swift` | AX + clipboard/⌘V |
| `VoiceIA/Accessibility/AccessibilityService.swift` | Resolve elemento focado |
| `VoiceIA/Accessibility/FocusedElement.swift` | Snapshot do alvo (AXUIElement + pid + role) |
| `VoiceIA/UI/ClipboardFallbackDialogController.swift` | Diálogo “Sem campo em foco” |
| `VoiceIA/Input/ClipboardSnapshot.swift` | Snapshot/restauração do pasteboard |
| `VoiceIA/UI/Recording/RecordingOverlayController.swift` | HUD (não deve roubar foco; `nonactivatingPanel`) |

Logs:

```bash
log show --predicate 'subsystem == "dev.arley.santana.VoiceIA"' --last 15m --style compact
```

Categorias úteis: `accessibility`, `insertion`, `local-whisper`.  
Usar `logger.notice` (não só `info`) — `info` não aparece no `log show` padrão.

---

## 3. Contexto técnico (o que já se sabe do Cursor)

Do handoff anterior (`Cursor_Insercao_Texto_Handoff.md`), validado em 2026-08-08:

1. **AX mente sucesso.**  
   `AXUIElementSetAttributeValue` em `kAXSelectedText` / `kAXValue` pode retornar `.success` **sem** alterar o contenteditable do Cursor. Por isso toda escrita AX é **verificada por releitura** (`didInsertSucceed`).

2. **⌘V precisa de sequência completa de modificadores.**  
   Chromium reconstrói modifiers via `flagsChanged`. Só key down/up de V com `flags = .maskCommand` é ignorado. A sequência correta é:  
   Command down (`flagsChanged`) → V down → V up → Command up, com ~18 ms entre eventos.

3. **HUD não deve ativar o app.**  
   Overlay usa `NSPanel` + `.nonactivatingPanel`.

4. Em testes antigos (modo teste / texto fixo), a inserção no Cursor **já funcionou** com log típico:

```
Foco capturado: Cursor · AXTextArea
Alvo: Cursor · AXTextArea pid=…
Accessibility não alterou o campo; usando clipboard + ⌘V.
Paste enviado via HID tap.
```

O regresso atual parece ligado a **demora da transcrição local** e/ou ao estado do foco AX **depois** dessa espera — não necessariamente à gravação em si.

---

## 4. O que já foi tentado (2026-08-09) — ainda falhou no teste do usuário

### 4.1 Hipótese

Após Whisper local (segundos/minutos), o Cursor deixa de expor um `kAXFocusedUIElement` com papel editável (`AXTextArea` etc.), mesmo com o caret visível. O código antigo exigia alvo “editável”; sem isso lançava `.noFocusedElement` → diálogo enganoso.

### 4.2 Mudanças feitas em `DefaultTextInsertionService`

1. **Reativar o app capturado** (`activateAndWait(pid:)`) antes de reler o foco.
2. **Preferir o `captured` do início da gravação** sobre o foco “live”.
3. **`resolveEditableTarget`**: se o nó for `AXApplication` / `AXWindow` / `AXGroup`, tenta descer via `kAXFocusedUIElement`.
4. Se **nenhum** papel editável for encontrado, mas ainda houver app alvo → **tenta ⌘V mesmo assim** (para evitar falso “sem foco”).
5. Em `AppState.insertTranscribedText`: sleep de 150 ms → **280 ms** após idle.

Trecho atual (resumo):

```swift
if let captured {
    try? await activateAndWait(pid: captured.processID)
}
let ordered = [captured, liveTarget].compactMap { $0 }
let editable = ordered.compactMap { resolveEditableTarget(from: $0) }.first
if let target = editable {
    // AX verificado → senão clipboard+⌘V
} else if let appTarget = ordered.first {
    // ⌘V “cego” no app
} else {
    throw VoiceInputError.noFocusedElement
}
```

### 4.3 Resultado

**Usuário reportou que ainda não funcionou** (diálogo / texto não entra no Cursor).

Não há logs recentes anexados a este handoff; o próximo agente **deve** pedir/coletar `log show` logo após um teste falho.

### 4.4 Outras mudanças recentes (não são a causa, mas mudam o contexto)

- Download de modelos: `URLSessionDownloadTask` (antes era byte-a-byte e ficava ~140 KB/s).
- Toggle **Usar no ditado** + alerta se não há modelo baixado.
- Roteamento: **modo teste > local > OpenAI**. Com modo teste ligado, Whisper local **não** roda.

---

## 5. Feedback explícito do usuário sobre o clipboard (importante)

O usuário **não gostou** da abordagem de colocar o texto automaticamente na área de transferência (⌘V / Ctrl+V):

> Pode ser que o usuário já tenha conteúdo no clipboard e a gente acabe **substituindo**, gerando insatisfação.

### Implicações de produto (requisito novo / reforçado)

1. **Não sobrescrever o clipboard automaticamente** no caminho “feliz” nem no fallback sem consentimento claro, se possível.
2. Preferir inserção que **não dependa** de clobber do pasteboard geral:
   - Accessibility real (difícil no Electron),
   - ou outro mecanismo que preserve o clipboard do usuário,
   - ou, se clipboard for inevitável: **só após confirmação** no diálogo (“Copiar ditagem”), nunca em silêncio.
3. O diálogo atual (`presentClipboardFallback`) **já faz** `pasteboard.clearContents()` + `setString` — isso **viola** a preferência do usuário se disparar em falso positivo.
4. `insertViaClipboardPaste` também escreve no pasteboard geral (com snapshot/restore só em sucesso após ~0,4 s). Em falha, a ditagem fica no clipboard de propósito — de novo, sobrescreve o conteúdo anterior.

### Direção sugerida para o próximo agente

- Separar “mostrar ditagem ao usuário” de “escrever no NSPasteboard”.
- Diálogo poderia exibir o texto + botão **opcional** “Copiar”, sem copiar no `present`.
- Explorar se existe caminho de inserção no Cursor **sem** pasteboard (AX tree mais profundo, `AXPress`, IPCs, etc.) — historicamente AX sozinho falhou no Cursor.

---

## 6. Comportamento esperado (aceite)

| Cenário | Esperado |
|---|---|
| Input Cursor focado → ⇧ Tab → gravar → transcrever → inserir | Texto aparece no input; **sem** diálogo de “sem foco” |
| Nenhum campo de texto real em foco | Texto **não se perde**; UI clara; **clipboard do usuário não é sobrescrito sem ação explícita** |
| Notas / TextEdit (apps nativos) | Continua inserindo via Accessibility quando possível |
| Modo teste ligado | Mock, sem rede; inserção ainda deve respeitar as regras acima |

---

## 7. Hipóteses ainda abertas (para investigar)

1. **`capturedFocusedElement` está nil ou com role não utilizável** no momento do ⇧ Tab (captura falhou).
2. **Transcrição local longa**: o AXUIElement capturado fica inválido; `activate` não restaura o contenteditable focado.
3. **Janela de Settings do VoiceIA** aberta durante o teste interfere no frontmost / foco.
4. **⌘V está sendo postado**, mas o Cursor ignora (foco em webview errada, agent chat vs composer, etc.).
5. O diálogo abre por **outro erro** (não só `.noFocusedElement`): hoje **qualquer** `catch` em `insertTranscribedText` chama `presentClipboardFallback` — inclusive `.textInsertionFailed`. Isso mascara a causa real.
6. **Modo teste vs local**: confirmar qual backend estava ativo no teste que falhou.
7. Permissão de Acessibilidade apontando para binário errado (DerivedData vs `/Applications`) — no passado já quebrou TCC.

---

## 8. Como reproduzir / diagnosticar

1. Instalar build atual em `/Applications/VoiceIA.app` com `scripts/install-dev-app.sh`.
2. Em Ajustes do macOS → Privacidade → Acessibilidade: garantir **VoiceIA** de `/Applications`.
3. Abrir Cursor, focar o input do chat.
4. **Não** abrir Settings do VoiceIA (ou fechar antes), para reduzir interferência.
5. ⇧ Tab → falar → finalizar.
6. Observar se o texto entra ou se o diálogo abre.
7. Imediatamente:

```bash
log show --predicate 'subsystem == "dev.arley.santana.VoiceIA"' --last 5m --style compact \
  | rg -i 'foco|Alvo|inser|clipboard|Paste|Fallback|Sem campo|local-whisper|candidatos'
```

Logs que se espera ver em sucesso:

```
Foco capturado: Cursor · …
Alvo: Cursor · … pid=…
Accessibility não alterou o campo; usando clipboard + ⌘V.   # ou Inserido via Accessibility
Paste enviado via HID tap.
```

Logs típicos de falha atual (a confirmar):

```
Sem campo editável em foco (candidatos: …)
Inserção falhou (…); indo para o clipboard.
Fallback de clipboard acionado (copiado=true)
Diálogo de clipboard visível.
```

ou:

```
Campo AX não editável (…); tentando ⌘V no app …
Paste enviado via HID tap.
```

(e mesmo assim o texto não aparece — paste “cego”.)

---

## 9. Estado do código no momento deste handoff

- Build Debug assinado (Apple Development), instalado em `/Applications`.
- Inserção: preferência por `captured` + tentativa de ⌘V mesmo sem role editável (**ainda falha no teste do usuário**).
- Fallback: qualquer erro de inserção (exceto permissão AX) → **copia para clipboard + diálogo**.
- Usuário pediu explicitamente para **parar de confiar / abusar do clipboard automático** e documentar tudo para outro modelo.

### O que **não** fazer às cegas

- Não “resolver” só mostrando o diálogo de novo.
- Não assumir que HID paste = texto inserido (já houve falso sucesso no Desktop/Finder).
- Não limpar o pasteboard do usuário sem UX explícita.

### O que priorizar

1. Coletar logs do teste falho (obrigatório).
2. Distinguir no `AppState` os erros (`.noFocusedElement` vs `.textInsertionFailed` vs outros) com mensagens/diálogos diferentes.
3. Remover / tornar **opt-in** a escrita automática no `NSPasteboard`.
4. Revalidar inserção no Cursor com **modo teste** (rápido) vs **Whisper local** (lento) para isolar o fator tempo/foco.
5. Se necessário, instrumentar: role AX no capture, role no insert, frontmost app, se `postPasteShortcut` retornou true, e se o valor AX mudou depois do paste.

---

## 10. Resumo executivo

| Item | Status |
|---|---|
| Inserção no Cursor (histórico, texto curto/teste) | Já funcionou (2026-08-08) via clipboard+⌘V |
| Inserção após Whisper local com input focado | **Quebrado** (2026-08-09) — diálogo falso / texto não entra |
| Patch “reativar app + preferir captured + ⌘V cego” | **Não resolveu** no teste do usuário |
| Clipboard automático | **Rejeitado pelo usuário** — não sobrescrever sem consentimento |
| Próximo passo | Novo agente com logs + nova estratégia sem clobber silencioso do pasteboard |

---

*Fim do handoff.*
