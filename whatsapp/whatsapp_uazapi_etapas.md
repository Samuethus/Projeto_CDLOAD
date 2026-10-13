# WhatsApp · Integração com a UAZAPI — esquema de etapas

> Planejamento de 12/10/2026 para a seção **WhatsApp** do CDLoad (abas Instâncias, Templates e Disparos). Os endpoints foram conferidos no contrato OpenAPI público da UAZAPI (docs.uazapi.com). Nada foi implementado ainda: este documento define a ordem de trabalho e as decisões a validar.

## 1. Em uma frase

O navegador nunca fala com a UAZAPI. Ele fala com **Edge Functions do Supabase**, que guardam os tokens, chamam a UAZAPI e recebem os eventos de volta (webhook). O **Supabase é a fonte da verdade** (instâncias, templates, campanhas, status de cada envio) e a tela acompanha tudo em **tempo real**, no mesmo padrão já usado no Survey Monkey.

## 2. Arquitetura

```
 Plataforma (index.html)                Supabase                           UAZAPI
 ───────────────────────     ───────────────────────────────     ─────────────────────
 Aba Instâncias    ──┐        Edge Function  whatsapp-api   ───►  /instance/create
 Aba Templates     ──┼──JWT──►  (valida login + seção)       ───►  /instance/connect, /status
 Aba Disparos      ──┘          · cria/conecta instância     ───►  /sender/advanced, /sender/edit
        ▲                       · dispara campanha
        │ Realtime              Banco (RLS)
        └──────────────────────  wa_instancias · wa_templates · wa_contatos · wa_listas
                                 wa_campanhas · wa_envios · wa_eventos · wa_optout
                                         ▲
                                Edge Function  whatsapp-webhook  ◄──  eventos: connection,
                                 (recebe, grava, responde 200)         messages_update, sender
```

**Pontos de decisão já tomados (sugestão):**

| Tema | Decisão | Por quê |
|---|---|---|
| Tokens | `admintoken` só como secret da Edge Function; token de cada instância só na tabela, sem leitura pelo navegador | Quem tem o token envia mensagens em nome do número |
| Templates | **Ficam no nosso banco**, com variáveis `{{nome}}` | A UAZAPI não tem aprovação de templates da Meta; é a API não oficial (WhatsApp Web) |
| Disparo | Usar `/sender/advanced` (texto já personalizado por destinatário) e `/sender/simple` quando o texto é igual para todos | A campanha tem fila, agendamento, pausa e retomada prontos |
| Status de cada envio | Webhook `messages_update` + `sender`, com rotina de conferência por `/sender/listmessages` | A UAZAPI avisa que "processado" não é "entregue" |
| Tempo real | Supabase Realtime nas tabelas `wa_*` | Mesmo padrão do Survey |

## 3. Endpoints da UAZAPI que vamos usar

Servidor: `https://{subdomain}.uazapi.com` (`free` ou `api`). Autenticação por cabeçalho: `admintoken` (administração) ou `token` (da instância).

| Etapa | Método e caminho | Auth | Observação |
|---|---|---|---|
| Criar instância | `POST /instance/create` `{name, systemName}` | admintoken | Retorna o `token` da instância |
| Listar instâncias | `GET /instance/all` | admintoken | Para conciliar com o banco |
| Conectar | `POST /instance/connect` `{phone?}` | token | Sem `phone` gera **QR code**; com `phone`, gera **código de pareamento** |
| Status | `GET /instance/status` | token | Conectada, QR pendente etc. |
| Desconectar / reiniciar | `POST /instance/disconnect` · `POST /instance/reset` | token | |
| Excluir | `DELETE /instance` | token | |
| Girar token | `POST /instance/token/rotate` | admintoken | Se o token vazar |
| Limites do número | `GET /instance/wa_messages_limits` | token | Teto de novas conversas |
| Webhook | `POST /webhook` `{url, events, excludeMessages}` | token | Eventos: `connection`, `messages_update`, `sender`, `messages` |
| Validar números | `POST /chat/check` | token | Antes do disparo |
| Envio avulso | `POST /send/text` · `/send/media` · `/send/menu` | token | Teste de template; `async` para fila |
| Campanha simples | `POST /sender/simple` | token | Mesmo conteúdo; `delayMin`, `delayMax`, `scheduled_for`, `folder` |
| Campanha avançada | `POST /sender/advanced` | token | Uma mensagem por destinatário |
| Controlar campanha | `POST /sender/edit` `{folder_id, action}` | token | `stop`, `continue`, `delete`, `reschedule`, `send_now` |
| Acompanhar | `GET /sender/listfolders` · `POST /sender/listmessages` · `GET /sender/stats` | token | Conferência e métricas |

## 4. Modelo de dados (Supabase)

| Tabela | Para quê | Campos principais |
|---|---|---|
| `wa_instancias` | Números conectados | `id`, `nome`, `uazapi_nome`, `token` (restrito), `telefone`, `status`, `ultimo_status_em`, `criado_por` |
| `wa_templates` | Modelos de mensagem | `id`, `nome`, `tipo` (texto, imagem, documento, botões…), `corpo` com `{{variáveis}}`, `midia_url`, `ativo` |
| `wa_contatos` | Destinatários | `id`, `nome`, `telefone` (E.164), `campos` (jsonb para variáveis), `origem` |
| `wa_listas` + `wa_listas_contatos` | Segmentações | nome, filtros, vínculo contato–lista |
| `wa_optout` | Quem pediu para sair | `telefone`, `motivo`, `em` — sempre excluído do disparo |
| `wa_campanhas` | Um disparo | `nome`, `instancia_id`, `template_id`, `lista_id`, `status` (rascunho, agendada, enviando, pausada, concluída), `agendada_para`, `delay_min`, `delay_max`, `uazapi_folder_id`, contadores |
| `wa_envios` | Um envio por destinatário | `campanha_id`, `contato_id`, `texto_final`, `status` (fila, enviado, entregue, lido, falhou), `erro`, `uazapi_msg_id`, tempos |
| `wa_eventos` | Log bruto do webhook | `tipo`, `payload`, `recebido_em` (auditoria e reprocesso) |

Segurança: RLS por `cdl_secao('whatsapp')`; escrita só pelas Edge Functions (service role); a coluna `token` fora de qualquer `select` do navegador (view sem o token).

## 5. Etapas

Cada etapa termina com algo que dá para testar. A ordem reduz risco: primeiro conectar um número, depois falar com ele, só então disparar em massa.

### Etapa 0 · Pré-requisitos (com você)
- Conta na UAZAPI, **servidor** (`free` ou `api`) e **admintoken**.
- 1 número de teste (chip próprio, nunca o da diretoria).
- Secrets no Supabase: `UAZAPI_URL`, `UAZAPI_ADMIN_TOKEN`, `WHATSAPP_WEBHOOK_SEGREDO` (valor longo e aleatório).
- **Pronto quando:** `curl` em `/instance/all` com o admintoken responde 200.

### Etapa 1 · Fundação
- SQL `schema_whatsapp.sql` com as tabelas, RLS e Realtime.
- Edge Function `whatsapp-api` (esqueleto): valida o login, checa a seção `whatsapp` e roteia por `acao`.
- **Pronto quando:** a plataforma chama a função logada e ela responde; sem login, recusa.

### Etapa 2 · Instâncias (aba Instâncias)
- Criar instância (nome) → grava em `wa_instancias`.
- Conectar: modal com **QR code** (ou código de pareamento por telefone), atualizando pelo status.
- Cartão de cada instância: nome, número, status (conectada, aguardando QR, desconectada), ações Reconectar, Desconectar, Excluir.
- **Pronto quando:** o chip de teste lê o QR e o cartão vira "Conectada" sozinho.

### Etapa 3 · Webhook de eventos
- Edge Function `whatsapp-webhook`: confere o segredo na URL, grava em `wa_eventos`, **responde 200 na hora** e processa depois.
- Configura `POST /webhook` ao criar a instância (eventos `connection`, `messages_update`, `sender`).
- Evento `connection` atualiza o status; `messages_update` atualiza `wa_envios`.
- **Pronto quando:** desligar o WhatsApp do celular muda o cartão para "Desconectada" em segundos.

### Etapa 4 · Templates (aba Templates)
- CRUD de templates com variáveis `{{nome}}`, prévia com dados fictícios e contador de caracteres.
- Tipos iniciais: texto e imagem/documento com legenda.
- Botão **Enviar teste** para um número informado (`/send/text` ou `/send/media`).
- **Pronto quando:** o teste chega ao celular com as variáveis preenchidas.

### Etapa 5 · Contatos, listas e opt-out
- Importar CSV/planilha (nome, telefone, campos extras); normalizar telefone para E.164 (`55` + DDD).
- Listas e segmentação simples; tabela `wa_optout` consultada em todo disparo.
- Resposta "SAIR" no webhook `messages` entra automaticamente no opt-out.
- **Pronto quando:** um contato em opt-out nunca aparece na fila.

### Etapa 6 · Disparos (aba Disparos)
Assistente em 4 passos: **instância → template → lista → agendamento**.
1. Rascunho em `wa_campanhas`; geração de `wa_envios` com o texto final de cada contato.
2. Validação: `/chat/check` (números sem WhatsApp saem), opt-out, duplicados, teto diário.
3. Envio: `/sender/advanced` com `folder`, `delayMin`/`delayMax` (intervalo aleatório) e `scheduled_for`; guarda o `folder_id`.
4. Controle na tela: **Pausar**, **Retomar**, **Enviar agora**, **Cancelar** (`/sender/edit`).
- **Pronto quando:** campanha de 10 contatos de teste, agendada, conclui com status individual de cada envio.

### Etapa 7 · Acompanhamento e relatórios
- Painel da campanha em tempo real: fila, enviados, entregues, lidos, falhas.
- Rotina de conferência (a cada poucos minutos) com `/sender/listmessages` e `/sender/stats` para corrigir o que o webhook perdeu.
- Filtros Mês/Ano/UF/Cidade já existentes passam a atuar sobre campanhas.
- **Pronto quando:** os números da tela batem com os da UAZAPI.

### Etapa 8 · Endurecimento e operação
- Aquecimento: limite diário crescente por número novo; distribuição entre mais de uma instância.
- Alerta (e-mail ou aviso na tela) quando uma instância cai ou há muita falha.
- Girar token (`/instance/token/rotate`), log de quem disparou o quê, retenção de payloads.
- Documento de operação (como reconectar, o que fazer em bloqueio).

## 6. Riscos e cuidados

| Risco | Cuidado |
|---|---|
| **API não oficial**: o WhatsApp pode banir o número | Conteúdo útil e esperado, intervalos aleatórios, volume crescente, opt-out visível, números reserva |
| **LGPD**: mensagem sem consentimento | Só contatos com base legal (associados, opt-in); registrar origem do contato; opt-out imediato |
| **Webhook sem assinatura** (a UAZAPI não assina) | Segredo na URL, validar o token da instância contra o banco, não confiar em `owner`/`instanceName` |
| **Webhook fora do ar** atrasa os eventos | Responder 200 rápido, fila interna, conferência periódica por API |
| **Token da instância vazar** | Fora do navegador e dos logs; rotação disponível |
| **Duplicar campanha** por resposta lenta | Antes de recriar, consultar `/sender/listfolders` |

## 7. O que preciso de você para começar

1. **Servidor e plano** da UAZAPI (subdomínio `free` ou `api`) e o `admintoken` (como secret, nunca no chat).
2. **Quantos números** vão operar e quem pode criar/disparar (todos com a seção ou só admin?).
3. **Origem dos contatos**: planilha, base de associados, Survey Monkey?
4. **Receber respostas** (caixa de entrada) entra agora ou depois? Sugestão: depois; só tratamos "SAIR" no início.
5. Preciso de **aprovação antes de disparar** (rascunho → aprovado por admin)? Sugestão: sim para listas grandes.

## 8. Ordem sugerida de entrega

`Etapa 0 → 1 → 2 → 3` (conectar e ver o status ao vivo) · `4 → 5` (conteúdo e contatos) · `6 → 7` (disparo e acompanhamento) · `8` (operação). As etapas 0 a 3 já entregam valor sozinhas: instâncias criadas e monitoradas pela plataforma.
