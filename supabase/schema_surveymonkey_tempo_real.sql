-- =====================================================================================
-- CDLoad · Survey Monkey — CORREÇÃO DA SINCRONIZAÇÃO + RESPOSTAS EM TEMPO REAL
-- =====================================================================================
--
-- COMO USAR
--   1. Abra o Supabase  >  seu projeto  >  SQL Editor  >  New query.
--   2. Cole este arquivo inteiro e clique em RUN.
--   3. Pode rodar quantas vezes quiser: nada é apagado nem duplicado (é "idempotente").
--   Pré-requisito: o arquivo schema_surveymonkey.sql já ter sido rodado antes (ele cria as tabelas survey_*).
--
-- POR QUE ESTE ARQUIVO EXISTE
--   A seção Survey do CDLoad mostra os dados que a Edge Function "surveymonkey-sincronizar" copia do
--   Survey Monkey para o Supabase (tabelas survey_*). Essa cópia FALHAVA EM TODA EXECUÇÃO com o erro:
--       null value in column "qtd_formularios" of relation "survey_pastas" violates not-null constraint
--   Resultado: as tabelas ficavam vazias, a seção mostrava só o "retrato fixo" de 09/10/2026 e a tabela
--   de respostas individuais (uma linha por resposta) aparecia vazia.
--
-- O QUE ESTE ARQUIVO FAZ (3 PASSOS, EXPLICADOS ABAIXO)
--   Passo 1 — Corrige a coluna que travava a cópia      → as respostas passam a ser gravadas.
--   Passo 2 — Liga o "tempo real" (Supabase Realtime)    → a tela do CDLoad se atualiza sozinha.
--   Passo 3 — Dispara uma cópia agora                    → não precisa esperar o próximo ciclo de 15 min.
--   No fim há consultas de CONFERÊNCIA para ver se deu certo.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- PASSO 1 — Corrigir a coluna que travava a sincronização
-- -------------------------------------------------------------------------------------
-- A tabela survey_pastas guarda as pastas do Survey Monkey. A coluna qtd_formularios (quantos
-- formulários há na pasta) era obrigatória, mas a pasta especial "Sem pasta" era gravada sem esse
-- número — e o banco recusava a gravação inteira. Aqui a coluna passa a:
--   • ter 0 como valor padrão;
--   • aceitar ficar vazia.
-- Só este passo já destrava a função que está publicada hoje (não precisa republicar nada).
alter table public.survey_pastas alter column qtd_formularios set default 0;
alter table public.survey_pastas alter column qtd_formularios drop not null;


-- -------------------------------------------------------------------------------------
-- PASSO 2 — Ligar o tempo real (Supabase Realtime)
-- -------------------------------------------------------------------------------------
-- O Realtime é o recurso do Supabase que AVISA o navegador quando uma linha muda no banco.
-- Aqui as tabelas de respostas e de formulários passam a enviar esses avisos. Assim, com a seção
-- Survey aberta, cada resposta nova gravada aparece na tela na hora (lista, painel e tabela de
-- respostas), sem recarregar a página.
-- Segurança: o aviso só chega para quem já pode ver os dados (login + seção "surveymonkey"
-- liberada) — as mesmas regras de acesso (RLS) das tabelas continuam valendo.
-- O "if not exists" evita erro se a tabela já estiver ligada.
do $$
declare t text;
begin
  foreach t in array array['survey_respostas', 'survey_formularios'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- -------------------------------------------------------------------------------------
-- PASSO 3 — Disparar uma sincronização agora
-- -------------------------------------------------------------------------------------
-- Normalmente o próprio banco chama a Edge Function a cada 15 minutos (agendamento criado no
-- schema_surveymonkey.sql). Esta chamada só adianta a primeira cópia depois da correção.
-- O resultado aparece como um número (id do pedido) — isso é normal: a cópia roda em segundo plano.
-- A PRIMEIRA cópia traz todo o histórico de respostas e pode levar algumas execuções (cada uma tem
-- ~2 minutos); as seguintes trazem só o que é novo.
select net.http_post(
  url     := 'https://xjexujpvnahaugizeyee.supabase.co/functions/v1/surveymonkey-sincronizar',
  headers := '{"Content-Type": "application/json"}'::jsonb,
  body    := '{}'::jsonb,
  timeout_milliseconds := 150000
);


-- =====================================================================================
-- CONFERÊNCIA — rode as consultas abaixo (selecione a linha e clique em RUN) após ~3 minutos
-- =====================================================================================
--
-- A) Histórico das cópias (a mais recente primeiro):
--    select id, iniciado_em, finalizado_em, formularios, atualizados, respostas_novas, pendentes, erros
--      from public.survey_sincronizacoes order by id desc limit 5;
--    Deu certo quando:  "erros" está vazio  e  "formularios" é maior que 0.
--    "pendentes" > 0 = ainda falta copiar formulários; a próxima execução (15 min) continua de onde parou.
--
-- B) Quantas respostas já foram copiadas:
--    select count(*) as respostas_gravadas from public.survey_respostas;
--
-- C) Tempo real ligado (deve listar survey_formularios e survey_respostas):
--    select tablename from pg_publication_tables where pubname = 'supabase_realtime' and tablename like 'survey_%';
--
-- Depois disso, abra a seção Survey no CDLoad (com login): a contagem mostra "ao vivo" e, ao abrir um
-- formulário › "Resposta individual", aparece uma linha por resposta (a mais recente no topo).
--
-- =====================================================================================
-- PRÓXIMO PASSO (OPCIONAL) — avisos do Survey Monkey na hora em que a resposta é enviada
-- =====================================================================================
-- Sem este passo, as respostas novas chegam a cada 15 minutos (pela cópia agendada) e, a partir daí,
-- a tela atualiza sozinha. Para chegarem NO MESMO INSTANTE do envio (webhook), siga o
-- surveymonkey/LEIA-ME.md, seção "Atualização (11/10/2026)":
--   1. Survey Monkey (developer.surveymonkey.com › My Apps › Scopes): habilitar "View Webhooks" e
--      "Create/Modify Webhooks".
--   2. Supabase (Edge Functions › Secrets): criar SURVEYMONKEY_WEBHOOK_CHAVE com um texto aleatório
--      (é a senha que impede terceiros de chamarem a função se passando pelo Survey Monkey).
--   3. Republicar a função: npx supabase functions deploy surveymonkey-sincronizar --no-verify-jwt
--   A função cadastra o webhook no Survey Monkey sozinha na cópia seguinte.
