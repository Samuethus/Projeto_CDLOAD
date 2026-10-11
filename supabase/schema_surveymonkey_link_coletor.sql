-- =====================================================================================
-- CDLoad · Survey Monkey — LINK DE RESPOSTA DE CADA FORMULÁRIO (coluna "Link de resposta")
-- =====================================================================================
--
-- COMO USAR
--   Supabase  >  SQL Editor  >  New query  >  cole este arquivo  >  RUN.
--   Pode rodar mais de uma vez (idempotente).
--   ORDEM IMPORTANTE: rode ESTE arquivo ANTES de publicar a versão nova da Edge Function
--   surveymonkey-sincronizar (ela passa a gravar a coluna "url"; sem a coluna, a gravação falha).
--
-- O QUE FAZ
--   Passo 1 — Cria a coluna "url" nos coletores: o link que o respondente abre (ex.: https://pt.surveymonkey.com/r/ABC123).
--   Passo 2 — Cria o controle "coletores_lidos_em": a função relê os coletores dos formulários ABERTOS a cada
--             hora, para um coletor novo (link novo) aparecer sem precisar mexer no formulário.
--   Passo 3 — Marca todos os formulários para a próxima sincronização reler os coletores e trazer os links
--             (as respostas não são baixadas de novo: a leitura continua de onde parou).
--
-- DEPOIS
--   Publique a função nova e aguarde a próxima sincronização (até 15 min). Na seção Survey, a coluna
--   "Link de resposta" mostra o link do coletor aberto (ou do último criado, nos formulários encerrados).
-- =====================================================================================

-- Passo 1
alter table public.survey_coletores add column if not exists url text;

-- Passo 2
alter table public.survey_formularios add column if not exists coletores_lidos_em timestamptz;

-- Passo 3
update public.survey_formularios set pendente = true where ativo;

-- Conferência (depois da próxima sincronização):
-- select f.titulo, c.status, c.url, c.criado_em
--   from public.survey_coletores c join public.survey_formularios f on f.id = c.formulario_id
--  order by c.criado_em desc limit 20;
