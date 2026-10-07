# Integração CDLoad × Survey Monkey

> **Status:** etapa 1 em andamento — **MCP Server oficial do Survey Monkey** configurado no projeto para uso no Claude Code (item 5) e seção **Survey Monkey** no app com um **retrato fixo** dos formulários (lido em 07/10/2026). A sincronização ao vivo (Edge Function + tabelas) ainda não está implementada.
> Este documento define **como o CDLoad vai ler as pastas e os formulários do Survey Monkey** e o passo a passo para implementar.

---

## 1. Objetivo

Trazer para o CDLoad, de forma automática e sem digitação manual:

- as **pastas** e os **formulários** (pesquisas) criados no Survey Monkey;
- a **estrutura** de cada formulário (páginas, perguntas e opções);
- as **respostas** coletadas.

Com isso, o Núcleo de Inteligência consulta as pesquisas na plataforma, cruza com os outros painéis (Dashboard) e gera relatórios, sem precisar abrir e exportar planilhas do Survey Monkey.

---

## 2. Como o Survey Monkey organiza os dados

A leitura segue a hierarquia da própria conta, de cima para baixo:

```
Conta (usuário do Survey Monkey)
└── Pastas ................ GET /v3/survey_folders
    └── Formulários ....... GET /v3/surveys?folder_id={pasta}
        ├── Estrutura ..... GET /v3/surveys/{formulário}/details   (páginas → perguntas → opções)
        ├── Coletores ..... GET /v3/surveys/{formulário}/collectors (links, e-mail, QR code)
        └── Respostas ..... GET /v3/surveys/{formulário}/responses/bulk
```

| Nível | O que é | Campos que interessam ao CDLoad |
|---|---|---|
| **Pasta** | Agrupador de formulários na conta | `id`, `title`, `num_surveys` |
| **Formulário** | A pesquisa em si | `id`, `title`, `folder_id`, `date_created`, `date_modified`, `response_count`, `question_count`, `preview` |
| **Página / Pergunta** | Estrutura do formulário | `family` (múltipla escolha, matriz, texto aberto…), `subtype`, `headings`, `answers.choices` |
| **Coletor** | Canal por onde a pesquisa é respondida | `id`, `type` (weblink, email…), `status` (open/closed), `date_created` |
| **Resposta** | Um respondente | `id`, `collector_id`, `response_status` (completed/partial), `date_created`, `date_modified`, `pages[].questions[].answers[]` |

Base da API: `https://api.surveymonkey.com/v3` (contas hospedadas na Europa usam `https://api.eu.surveymonkey.com/v3`).

---

## 3. Convenção de pastas e nomes no Survey Monkey

A integração lê **somente as pastas que seguem o padrão abaixo**. Pastas pessoais, rascunhos e testes ficam de fora automaticamente. **Combinar com toda a equipe antes de começar.**

### 3.1 Pastas

```
CDLOAD · <Categoria>
```

| Exemplo de pasta | Categoria no CDLoad |
|---|---|
| `CDLOAD · Pesquisas de Mercado` | Pesquisas de Mercado |
| `CDLOAD · Satisfação de Associados` | Satisfação de Associados |
| `CDLOAD · Eventos` | Eventos |
| `CDLOAD · Datas Comemorativas` | Datas Comemorativas |

- O texto depois de `CDLOAD · ` vira a **categoria** do formulário no CDLoad.
- Pasta sem o prefixo `CDLOAD` **não é lida**.
- Renomear a pasta muda a categoria na próxima sincronização (a ligação é pelo `id`, não pelo nome).

### 3.2 Formulários

```
AAAA-MM · <Tema> · <Público>
```

| Exemplo | Período | Tema | Público |
|---|---|---|---|
| `2026-10 · Dia das Crianças · Consumidores` | out/2026 | Dia das Crianças | Consumidores |
| `2026-11 · Black Friday · Lojistas` | nov/2026 | Black Friday | Lojistas |

- O **período** (`AAAA-MM`) permite filtrar por Mês/Ano no Dashboard, como nos outros painéis.
- Formulário fora do padrão continua sendo lido, mas entra com o período pela data de criação e o tema = título inteiro.
- Para tirar um formulário do CDLoad, mova-o para uma pasta sem o prefixo `CDLOAD`.

### 3.3 Perguntas (boas práticas para a análise)

- Prefira perguntas **fechadas** (múltipla escolha, escala, matriz) para tudo o que precisa virar gráfico.
- Use sempre **as mesmas opções** para a mesma pergunta em pesquisas diferentes (ex.: faixas de renda, bairros). Isso permite comparar uma edição com a outra.
- Perguntas de **contato** (nome, e-mail, telefone, CPF) devem ficar na **última página**. Ver item 8 (LGPD).

---

## 4. Arquitetura proposta

```
Survey Monkey (API v3)
        │  token de acesso (nunca no navegador)
        ▼
Supabase Edge Function  surveymonkey-sincronizar      ← agendada pelo pg_cron (a cada 1 h)
        │  grava/atualiza
        ▼
Tabelas survey_* (Postgres, RLS por seção)
        │  leitura com login (anon key + RLS)
        ▼
CDLoad (index.html): seção "Survey Monkey" e "Painel · Pesquisas" no Dashboard
```

**Por que não chamar a API direto do app:** o CDLoad é um site estático (GitHub Pages). Tudo o que está no navegador é público, e o token do Survey Monkey daria acesso a **todas** as pesquisas e respostas da conta. O token fica só no servidor (secret da Edge Function), o mesmo cuidado já usado na sincronização da agenda ([supabase/functions/sincronizar-agenda](../supabase/functions/sincronizar-agenda/index.ts)).

**Por que Edge Function e não SQL puro (como o Clipping):** a API do Survey Monkey é paginada e devolve JSON aninhado (páginas → perguntas → respostas). Em TypeScript isso fica mais simples e testável do que em PL/pgSQL.

---

## 5. MCP Server do Survey Monkey (Claude Code) — etapa atual

O Survey Monkey tem um **MCP Server oficial e hospedado** (lançado em mai/2026, verificado pela Anthropic). Com ele, o Claude Code lê as pastas, formulários, perguntas e respostas da conta direto na conversa, sem token manual e sem instalar nada.

| Item | Valor |
|---|---|
| Endereço | `https://mcp.surveymonkey.com/mcp` |
| Transporte | Streamable HTTP |
| Login | OAuth (janela do navegador na primeira conexão; a credencial fica guardada no Claude Code, **não no repositório**) |
| Plano | Basic ou superior |

### 5.1 Para que serve (e para que não serve)

| Serve para | Não serve para |
|---|---|
| Explorar a conta: listar formulários, ver estrutura e contagem de respostas | Alimentar o CDLoad: o login OAuth é pessoal e fica na máquina de quem conectou |
| Conferir se a convenção de nomes (item 3) está sendo seguida | Rodar sozinho/agendado (não tem gatilho de nova resposta) |
| Validar campos reais da API antes de escrever a sincronização (item 7) | Substituir a Edge Function: o app continua precisando dela + `SURVEYMONKEY_TOKEN` |
| Análises pontuais pedidas ao Claude ("resuma as respostas da pesquisa X") | |

### 5.2 O que já está no projeto

- [`.mcp.json`](../.mcp.json) (versionado): registra o servidor `surveymonkey`. Não contém token nem senha, só o endereço.
- `.claude/settings.json` (local, fora do Git pelo `.gitignore`): ativa o servidor e define permissões **somente leitura**:

  | Ferramentas liberadas (sem perguntar) | Ferramentas bloqueadas |
  |---|---|
  | `get_server_info`, `search_surveys`, `get_survey`, `get_pages`, `get_page`, `get_questions`, `get_question`, `get_question_types`, `get_response_count`, `get_responses` | `create_survey`, `update_survey`, `add_page`, `add_question`, `edit_question`, `delete_question`, `reorder_questions`, `create_weblink_collector` |

  Quem clonar o projeto em outra máquina deve criar o mesmo arquivo (conteúdo abaixo) para manter o bloqueio de escrita:

  ```json
  {
    "enabledMcpjsonServers": ["surveymonkey"],
    "permissions": {
      "allow": ["mcp__surveymonkey__get_server_info", "mcp__surveymonkey__search_surveys", "mcp__surveymonkey__get_survey",
                "mcp__surveymonkey__get_pages", "mcp__surveymonkey__get_page", "mcp__surveymonkey__get_questions",
                "mcp__surveymonkey__get_question", "mcp__surveymonkey__get_question_types",
                "mcp__surveymonkey__get_response_count", "mcp__surveymonkey__get_responses"],
      "deny":  ["mcp__surveymonkey__create_survey", "mcp__surveymonkey__update_survey", "mcp__surveymonkey__add_page",
                "mcp__surveymonkey__add_question", "mcp__surveymonkey__edit_question", "mcp__surveymonkey__delete_question",
                "mcp__surveymonkey__reorder_questions", "mcp__surveymonkey__create_weblink_collector"]
    }
  }
  ```

### 5.3 Passo a passo para conectar (cada pessoa, uma vez)

1. **Reabrir o Claude Code** na pasta do projeto (no VS Code: fechar e abrir o painel do Claude, ou *Developer: Reload Window*). Se perguntar se confia no servidor `surveymonkey` do `.mcp.json`, responder **sim**.
2. Na conversa, digitar **`/mcp`**, selecionar **surveymonkey** e escolher **Authenticate**.
3. O navegador abre a tela do Survey Monkey: entrar com a **conta da CDL dona das pesquisas** e clicar em **Authorize**.
4. Voltar ao Claude Code: em `/mcp` o servidor deve aparecer como **connected**.
5. **Testar** pedindo ao Claude, por exemplo:
   - "Liste os formulários da conta do Survey Monkey com nº de respostas."
   - "Mostre as perguntas e opções do formulário *2026-10 · Dia das Crianças · Consumidores*."
   - "Quais formulários estão fora do padrão `AAAA-MM · Tema · Público`?"

Sem Claude Code no VS Code? Pelo terminal o equivalente é `claude mcp add surveymonkey --transport http https://mcp.surveymonkey.com/mcp` e depois `/mcp` › Authenticate. Também dá para usar no claude.ai pelo diretório de conectores (*Settings › Connectors › SurveyMonkey*).

### 5.4 Cuidados

- O login dá ao Claude o acesso **da sua conta** no Survey Monkey. Conectar com a conta institucional, não com contas pessoais.
- **Respostas com dados pessoais** (nome, e-mail, telefone, CPF) aparecem na conversa ao usar `get_responses`. Pedir ao Claude números agregados e não colar respostas identificadas em relatórios, e-mails ou commits (LGPD, item 8).
- Para desconectar: `/mcp` › surveymonkey › **Clear authentication**. Para revogar de vez, remover o app autorizado nas configurações da conta do Survey Monkey.
- Erro **401** ou "needs authentication" no `/mcp`: refazer o passo 2. Erro de plano: conferir se a conta é Basic ou superior.

---

## 6. Pré-requisitos da sincronização (fazer uma vez)

1. **Plano da conta:** confirmar que o plano contratado (hoje *Plano individual*) permite acesso à API e leitura das respostas. Planos gratuitos têm limites de respostas visíveis e de chamadas.
2. **Criar o app privado** em <https://developer.surveymonkey.com/apps> (logado na conta da CDL que é dona das pesquisas):
   - tipo **Private App**;
   - escopos (somente leitura):

     | Escopo | Para quê |
     |---|---|
     | `View Surveys` (`surveys_read`) | pastas, formulários e estrutura |
     | `View Collectors` (`collectors_read`) | canais de coleta |
     | `View Responses` (`responses_read`) | lista de respostas |
     | `View Response Details` (`responses_read_detail`) | conteúdo de cada resposta |

   - **Não** marcar escopos de escrita (criar/editar pesquisas, enviar e-mails). A integração só lê.
3. **Gerar o Access Token** do app (botão *Generate* nas configurações do app).
4. **Guardar o token só no Supabase:**

   ```bash
   npx supabase secrets set SURVEYMONKEY_TOKEN="<token>"
   ```

   Nunca no `.env`, no `config.js`, nos secrets do GitHub Actions nem em mensagens/e-mails.
5. **Testar o acesso** (no terminal, com o token numa variável local):

   ```bash
   curl -H "Authorization: Bearer $SM_TOKEN" https://api.surveymonkey.com/v3/users/me
   curl -H "Authorization: Bearer $SM_TOKEN" "https://api.surveymonkey.com/v3/survey_folders?per_page=100"
   curl -H "Authorization: Bearer $SM_TOKEN" "https://api.surveymonkey.com/v3/surveys?folder_id=<ID_DA_PASTA>&per_page=50&include=response_count,date_modified,question_count"
   ```

   Se as pastas `CDLOAD · …` aparecerem, o token e os escopos estão certos.

---

## 7. Estrutura de leitura (o que a sincronização faz, em ordem)

Cada execução da `surveymonkey-sincronizar`:

| Passo | Chamada | Regra |
|---|---|---|
| 1. Pastas | `GET /v3/survey_folders?per_page=100` | Filtra as que começam com `CDLOAD`; grava/atualiza `survey_pastas` (categoria = texto após o prefixo). |
| 2. Formulários | `GET /v3/surveys?folder_id={pasta}&per_page=1000&include=response_count,date_created,date_modified,question_count,preview` | Grava/atualiza `survey_formularios`. Lê período, tema e público do título (padrão do item 3.2). Formulário que saiu das pastas `CDLOAD` fica **inativo** (não é apagado). |
| 3. Estrutura | `GET /v3/surveys/{id}/details` | **Só quando o `date_modified` mudou** desde a última leitura. Grava páginas, perguntas e opções em `survey_perguntas`. |
| 4. Coletores | `GET /v3/surveys/{id}/collectors?include=type,status,date_created` | Status do formulário no CDLoad: *Coletando* (algum coletor aberto) ou *Encerrado*. |
| 5. Respostas | `GET /v3/surveys/{id}/responses/bulk?per_page=100&sort_order=ASC&start_modified_at={última leitura}` | **Incremental:** só o que mudou desde a última sincronização. Grava em `survey_respostas` (respostas parciais também, marcadas como `partial`). |
| 6. Registro | — | Grava início, fim, contagens e erros em `survey_sincronizacoes` (o app mostra "Atualizado em …"). |

**Paginação:** toda listagem devolve `links.next` enquanto houver mais páginas; seguir até acabar.

**Limites de chamadas:** a API devolve nos cabeçalhos quantas chamadas restam (`X-Ratelimit-App-Global-Minute-Remaining` e `X-Ratelimit-App-Global-Day-Remaining`). Se faltar pouco, a função **para e continua na próxima execução** a partir do último ponto gravado. Os limites exatos dependem do plano e do status do app; conferir no portal do desenvolvedor.

**Primeira carga:** pode levar mais de uma execução (todas as respostas históricas). As seguintes são rápidas, porque só leem o que mudou.

---

## 8. Modelo de dados no Supabase (sugestão)

Arquivo a criar: `supabase/schema_surveymonkey.sql` (seguindo o prefixo `schema_` da pasta).

| Tabela | Uma linha por | Colunas principais |
|---|---|---|
| `survey_pastas` | pasta `CDLOAD · …` | `id` (do Survey Monkey), `titulo`, `categoria`, `qtd_formularios`, `atualizado_em` |
| `survey_formularios` | formulário | `id`, `pasta_id`, `titulo`, `periodo` (AAAA-MM), `tema`, `publico`, `status` (coletando/encerrado/inativo), `qtd_perguntas`, `qtd_respostas`, `link_preview`, `criado_em`, `modificado_em`, `estrutura_lida_em` |
| `survey_perguntas` | pergunta | `id`, `formulario_id`, `pagina`, `posicao`, `titulo`, `familia`, `subtipo`, `opcoes` (jsonb: id → texto), `dado_pessoal` (bool) |
| `survey_respostas` | respondente | `id`, `formulario_id`, `coletor_id`, `status` (completed/partial), `iniciada_em`, `concluida_em`, `modificada_em`, `respostas` (jsonb: pergunta → opção/texto) |
| `survey_sincronizacoes` | execução | `iniciado_em`, `finalizado_em`, `pastas`, `formularios`, `respostas_novas`, `erros` |

**Segurança (RLS):** mesmo padrão do resto do projeto ([schema_seguranca_rls.sql](../supabase/schema_seguranca_rls.sql)):

- leitura só com login **e** a seção `surveymonkey` liberada ao usuário (`public.cdl_secao('surveymonkey')`);
- escrita só pela Edge Function (`service_role`); ninguém grava pelo app;
- a seção `surveymonkey` já está em **Usuários › Permissões de Acesso** (lista `ALL_SECTIONS` do `index.html`; quem tinha a antiga `templates` passa a ter `surveymonkey`).

**LGPD (dados pessoais):**

- perguntas de contato (nome, e-mail, telefone, CPF) são marcadas como `dado_pessoal = true` e **não têm o conteúdo importado** (fica só "respondido / não respondido");
- os dashboards mostram apenas números agregados, nunca respostas individuais com identificação;
- se precisar do contato (ex.: retorno a um associado), consultar direto no Survey Monkey, com o acesso de quem é responsável pela pesquisa.

---

## 9. Como o CDLoad vai usar (fases)

| Fase | Entrega | Onde aparece |
|---|---|---|
| **1. Leitura** | Sincronização + seção **Survey Monkey**: pastas como abas/filtro, formulários com período, status, nº de respostas e link de pré-visualização | Menu lateral › Survey Monkey |
| **2. Análise** | **Painel · Pesquisas** no Dashboard, no mesmo layout dos demais (KPIs + 2 linhas de cards): respostas no período, taxa de conclusão, evolução diária, distribuição por pergunta fechada, comparação entre edições do mesmo tema | Dashboard › Painel · Pesquisas |
| **3. Tempo real e relatórios** | Webhook `response_completed` (resposta entra no CDLoad em segundos, sem esperar a sincronização) e modelo de relatório em PDF por pesquisa | Relatórios |

Filtros previstos no Painel · Pesquisas (mesma barra de filtros do Dashboard): **Busca** (formulário ou pergunta), **Pasta/Categoria**, **Formulário**, **Mês**, **Ano**, **Status**.

---

## 10. Checklist de implementação

**Organização (equipe)**
- [ ] Combinar e aplicar a convenção de pastas `CDLOAD · <Categoria>` (item 3.1).
- [ ] Renomear os formulários existentes no padrão `AAAA-MM · Tema · Público` (item 3.2).
- [ ] Mover as perguntas de contato para a última página.

**MCP Server (Claude Code)**
- [x] Registrar o servidor oficial em `.mcp.json` com permissões somente leitura (item 5.2).
- [ ] Cada pessoa: conectar com `/mcp` › Authenticate usando a conta da CDL (item 5.3).
- [ ] Usar o MCP para levantar pastas/formulários atuais e conferir a convenção (item 3).

**Acesso para a sincronização (administrador da conta)**
- [ ] Confirmar no plano que a API e as respostas estão liberadas.
- [ ] Criar o app privado com os 4 escopos de leitura (item 6).
- [ ] Gerar o token e gravar em `SURVEYMONKEY_TOKEN` (secret do Supabase).
- [ ] Testar com os `curl` do item 6.

**Desenvolvimento**
- [ ] `supabase/schema_surveymonkey.sql`: tabelas, RLS, seção `surveymonkey` e agendamento (pg_cron + pg_net a cada 1 h).
- [ ] `supabase/functions/surveymonkey-sincronizar/index.ts`: passos 1 a 6 do item 7, com paginação, leitura incremental e controle de limite.
- [x] Seção **Survey Monkey** criada no `index.html` (antiga "Templates", hoje só com o cabeçalho; os templates de WhatsApp continuam em WhatsApp › Templates).
- [x] Retrato fixo na seção **Survey Monkey** (`SM_RETRATO` no `index.html`, lido pelo MCP em 07/10/2026): filtros (busca, pasta, status, ano), KPIs, respostas por pasta, tabela de formulários e exportação CSV. Nomes das pastas provisórios (o MCP não informa o nome da pasta).
- [ ] Trocar o retrato pelos dados ao vivo (tabelas `survey_*` sincronizadas), mantendo o mesmo layout.
- [ ] **Painel · Pesquisas** no Dashboard (fase 2).
- [ ] Atualizar o [supabase/LEIA-ME.md](../supabase/LEIA-ME.md) com a ordem de execução do novo SQL e o deploy da função.

---

## 11. Erros comuns

| Erro | Causa provável | O que fazer |
|---|---|---|
| `401 Unauthorized` | Token errado, revogado ou de outra conta | Gerar outro token no app e atualizar o secret |
| `403 Forbidden` | Escopo faltando ou plano sem acesso ao recurso | Conferir os escopos (item 6) e o plano |
| `404 Not Found` | Formulário excluído ou movido para fora das pastas `CDLOAD` | Normal: a sincronização marca como inativo |
| `429 Too Many Requests` | Limite de chamadas atingido | Aguardar: a próxima execução continua de onde parou |
| Pasta não aparece no CDLoad | Nome fora do padrão `CDLOAD · …` | Renomear a pasta no Survey Monkey |

---

## 12. Referências

- Documentação da API v3: <https://api.surveymonkey.com/v3/docs>
- MCP Server oficial (conector do Claude): <https://claude.com/connectors/surveymonkey>
- Anúncio do conector: <https://www.surveymonkey.com/newsroom/surveymonkey-claude-ai-integration/>
- Apps e tokens (portal do desenvolvedor): <https://developer.surveymonkey.com/apps>
- Padrão de segurança do projeto: [SECURITY.md](../SECURITY.md) e [supabase/LEIA-ME.md](../supabase/LEIA-ME.md)

> Nomes de endpoints, escopos e cabeçalhos seguem a API v3 do Survey Monkey. Confira cada chamada na documentação oficial no momento da implementação, porque o fornecedor pode ajustar detalhes (limites, campos opcionais).
