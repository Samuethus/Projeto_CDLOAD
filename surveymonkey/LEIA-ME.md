# Integração CDLoad × Survey Monkey

> **Status:** planejamento (próxima etapa). Nada desta integração está implementado ainda.
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
- Perguntas de **contato** (nome, e-mail, telefone, CPF) devem ficar na **última página**. Ver item 7 (LGPD).

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
CDLoad (index.html): seção "Pesquisas" e "Painel · Pesquisas" no Dashboard
```

**Por que não chamar a API direto do app:** o CDLoad é um site estático (GitHub Pages). Tudo o que está no navegador é público, e o token do Survey Monkey daria acesso a **todas** as pesquisas e respostas da conta. O token fica só no servidor (secret da Edge Function), o mesmo cuidado já usado na sincronização da agenda ([supabase/functions/sincronizar-agenda](../supabase/functions/sincronizar-agenda/index.ts)).

**Por que Edge Function e não SQL puro (como o Clipping):** a API do Survey Monkey é paginada e devolve JSON aninhado (páginas → perguntas → respostas). Em TypeScript isso fica mais simples e testável do que em PL/pgSQL.

---

## 5. Pré-requisitos (fazer uma vez)

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

## 6. Estrutura de leitura (o que a sincronização faz, em ordem)

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

## 7. Modelo de dados no Supabase (sugestão)

Arquivo a criar: `supabase/schema_surveymonkey.sql` (seguindo o prefixo `schema_` da pasta).

| Tabela | Uma linha por | Colunas principais |
|---|---|---|
| `survey_pastas` | pasta `CDLOAD · …` | `id` (do Survey Monkey), `titulo`, `categoria`, `qtd_formularios`, `atualizado_em` |
| `survey_formularios` | formulário | `id`, `pasta_id`, `titulo`, `periodo` (AAAA-MM), `tema`, `publico`, `status` (coletando/encerrado/inativo), `qtd_perguntas`, `qtd_respostas`, `link_preview`, `criado_em`, `modificado_em`, `estrutura_lida_em` |
| `survey_perguntas` | pergunta | `id`, `formulario_id`, `pagina`, `posicao`, `titulo`, `familia`, `subtipo`, `opcoes` (jsonb: id → texto), `dado_pessoal` (bool) |
| `survey_respostas` | respondente | `id`, `formulario_id`, `coletor_id`, `status` (completed/partial), `iniciada_em`, `concluida_em`, `modificada_em`, `respostas` (jsonb: pergunta → opção/texto) |
| `survey_sincronizacoes` | execução | `iniciado_em`, `finalizado_em`, `pastas`, `formularios`, `respostas_novas`, `erros` |

**Segurança (RLS):** mesmo padrão do resto do projeto ([schema_seguranca_rls.sql](../supabase/schema_seguranca_rls.sql)):

- leitura só com login **e** a nova seção `pesquisas` liberada ao usuário (`public.cdl_secao('pesquisas')`);
- escrita só pela Edge Function (`service_role`); ninguém grava pelo app;
- incluir a seção `pesquisas` em **Usuários › Permissões de Acesso** (lista `ALL_SECTIONS` do `index.html`).

**LGPD (dados pessoais):**

- perguntas de contato (nome, e-mail, telefone, CPF) são marcadas como `dado_pessoal = true` e **não têm o conteúdo importado** (fica só "respondido / não respondido");
- os dashboards mostram apenas números agregados, nunca respostas individuais com identificação;
- se precisar do contato (ex.: retorno a um associado), consultar direto no Survey Monkey, com o acesso de quem é responsável pela pesquisa.

---

## 8. Como o CDLoad vai usar (fases)

| Fase | Entrega | Onde aparece |
|---|---|---|
| **1. Leitura** | Sincronização + seção **Pesquisas**: pastas como abas/filtro, formulários com período, status, nº de respostas e link de pré-visualização | Menu lateral › Pesquisas |
| **2. Análise** | **Painel · Pesquisas** no Dashboard, no mesmo layout dos demais (KPIs + 2 linhas de cards): respostas no período, taxa de conclusão, evolução diária, distribuição por pergunta fechada, comparação entre edições do mesmo tema | Dashboard › Painel · Pesquisas |
| **3. Tempo real e relatórios** | Webhook `response_completed` (resposta entra no CDLoad em segundos, sem esperar a sincronização) e modelo de relatório em PDF por pesquisa | Relatórios |

Filtros previstos no Painel · Pesquisas (mesma barra de filtros do Dashboard): **Busca** (formulário ou pergunta), **Pasta/Categoria**, **Formulário**, **Mês**, **Ano**, **Status**.

---

## 9. Checklist de implementação

**Organização (equipe)**
- [ ] Combinar e aplicar a convenção de pastas `CDLOAD · <Categoria>` (item 3.1).
- [ ] Renomear os formulários existentes no padrão `AAAA-MM · Tema · Público` (item 3.2).
- [ ] Mover as perguntas de contato para a última página.

**Acesso (administrador da conta)**
- [ ] Confirmar no plano que a API e as respostas estão liberadas.
- [ ] Criar o app privado com os 4 escopos de leitura (item 5).
- [ ] Gerar o token e gravar em `SURVEYMONKEY_TOKEN` (secret do Supabase).
- [ ] Testar com os `curl` do item 5.

**Desenvolvimento**
- [ ] `supabase/schema_surveymonkey.sql`: tabelas, RLS, seção `pesquisas` e agendamento (pg_cron + pg_net a cada 1 h).
- [ ] `supabase/functions/surveymonkey-sincronizar/index.ts`: passos 1 a 6 do item 6, com paginação, leitura incremental e controle de limite.
- [ ] Seção **Pesquisas** no `index.html` (fase 1).
- [ ] **Painel · Pesquisas** no Dashboard (fase 2).
- [ ] Atualizar o [supabase/LEIA-ME.md](../supabase/LEIA-ME.md) com a ordem de execução do novo SQL e o deploy da função.

---

## 10. Erros comuns

| Erro | Causa provável | O que fazer |
|---|---|---|
| `401 Unauthorized` | Token errado, revogado ou de outra conta | Gerar outro token no app e atualizar o secret |
| `403 Forbidden` | Escopo faltando ou plano sem acesso ao recurso | Conferir os escopos (item 5) e o plano |
| `404 Not Found` | Formulário excluído ou movido para fora das pastas `CDLOAD` | Normal: a sincronização marca como inativo |
| `429 Too Many Requests` | Limite de chamadas atingido | Aguardar: a próxima execução continua de onde parou |
| Pasta não aparece no CDLoad | Nome fora do padrão `CDLOAD · …` | Renomear a pasta no Survey Monkey |

---

## 11. Referências

- Documentação da API v3: <https://api.surveymonkey.com/v3/docs>
- Apps e tokens (portal do desenvolvedor): <https://developer.surveymonkey.com/apps>
- Padrão de segurança do projeto: [SECURITY.md](../SECURITY.md) e [supabase/LEIA-ME.md](../supabase/LEIA-ME.md)

> Nomes de endpoints, escopos e cabeçalhos seguem a API v3 do Survey Monkey. Confira cada chamada na documentação oficial no momento da implementação, porque o fornecedor pode ajustar detalhes (limites, campos opcionais).
