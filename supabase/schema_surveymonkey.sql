-- =====================================================================
-- CDLoad · Survey Monkey — dados ao vivo (pastas, formulários, perguntas, coletores e respostas)
--
-- Execute em Supabase > SQL Editor DEPOIS de `schema_seguranca_rls.sql` (usa a função `cdl_secao`)
-- e DEPOIS de publicar a Edge Function `surveymonkey-sincronizar` (ver surveymonkey/LEIA-ME.md, item 6).
-- É idempotente: pode ser rodado de novo sem apagar dados.
--
-- O que faz:
--   1. Cria as tabelas survey_* que a Edge Function preenche a partir da API v3 do Survey Monkey.
--   2. RLS: só lê quem está logado e tem a seção "surveymonkey" liberada (ou é Administrador).
--      Ninguém grava pelo app: só a Edge Function (service_role, que ignora o RLS).
--   3. Agenda a sincronização a cada 15 minutos (pg_cron + pg_net) e dispara a primeira agora.
--
-- LGPD: perguntas de contato (nome, e-mail, telefone, CPF, endereço...) ficam com dado_pessoal = true
-- e a resposta delas NÃO é importada (só "respondida"). O IP do respondente nunca é gravado.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.cdl_secao(text)') is null then
    raise exception 'Rode supabase/schema_seguranca_rls.sql antes deste arquivo (falta a função cdl_secao).';
  end if;
end $$;

create extension if not exists pg_cron;   -- agendamento
create extension if not exists pg_net;    -- chamada HTTP da Edge Function a partir do banco

-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.survey_pastas (
  id               text primary key,               -- id da pasta no Survey Monkey ('0' = sem pasta)
  titulo           text not null,
  qtd_formularios  integer not null default 0,
  atualizado_em    timestamptz not null default now()
);

create table if not exists public.survey_formularios (
  id                    text primary key,          -- id do formulário no Survey Monkey
  pasta_id              text not null default '0',
  titulo                text not null,
  status                text,                      -- 'OPEN' (algum coletor aberto) | 'CLOSED'
  qtd_perguntas         integer,
  qtd_respostas         integer not null default 0,
  link_preview          text,
  criado_em             timestamptz,
  modificado_em         timestamptz,
  ativo                 boolean not null default true,   -- false = excluído no Survey Monkey (os dados ficam)
  -- Controle da sincronização incremental:
  pendente              boolean not null default true,   -- mudou: falta reler estrutura/coletores/respostas
  estrutura_lida_em     timestamptz,                     -- modificado_em da última leitura da estrutura
  respostas_lidas_ate   timestamptz,                     -- maior date_modified de resposta já gravada
  atualizado_em         timestamptz not null default now()
);
create index if not exists survey_formularios_pasta_idx on public.survey_formularios (pasta_id);

create table if not exists public.survey_perguntas (
  id             text primary key,                 -- id da pergunta no Survey Monkey
  formulario_id  text not null references public.survey_formularios (id) on delete cascade,
  pagina         integer not null,
  posicao        integer not null,
  titulo         text not null,
  familia        text not null,                    -- single_choice | multiple_choice | matrix | open_ended | demographic | datetime | presentation...
  subtipo        text,
  -- { "choices": [{id, text}], "rows": [{id, text}], "cols": [...], "other": {id, text} }
  opcoes         jsonb not null default '{}'::jsonb,
  dado_pessoal   boolean not null default false
);
create index if not exists survey_perguntas_form_idx on public.survey_perguntas (formulario_id, pagina, posicao);

create table if not exists public.survey_coletores (
  id             text primary key,
  formulario_id  text not null references public.survey_formularios (id) on delete cascade,
  nome           text,
  tipo           text,                             -- weblink | email | sms | popup...
  status         text,                             -- open | closed | new
  qtd_respostas  integer,
  criado_em      timestamptz
);
create index if not exists survey_coletores_form_idx on public.survey_coletores (formulario_id);

create table if not exists public.survey_respostas (
  id             text primary key,                 -- id da resposta no Survey Monkey
  formulario_id  text not null references public.survey_formularios (id) on delete cascade,
  coletor_id     text,
  status         text,                             -- completed | partial | overquota | disqualified
  iniciada_em    timestamptz,
  modificada_em  timestamptz,
  -- { "<pergunta_id>": [ {"c": choice_id, "r": row_id, "o": other_id, "t": texto} ... ] }
  -- Pergunta com dado_pessoal: [ {"p": 1} ] (só "respondida", sem o conteúdo).
  respostas      jsonb not null default '{}'::jsonb
);
create index if not exists survey_respostas_form_idx on public.survey_respostas (formulario_id, modificada_em);

-- Histórico das execuções (o app mostra "Atualizado em ...").
create table if not exists public.survey_sincronizacoes (
  id               bigint generated always as identity primary key,
  iniciado_em      timestamptz not null default now(),
  finalizado_em    timestamptz,
  formularios      integer,                        -- formulários na conta
  atualizados      integer,                        -- formulários relidos nesta execução
  respostas_novas  integer,
  pendentes        integer,                        -- formulários que ficaram para a próxima execução
  chamadas_api     integer,
  erros            text
);

-- ---------------------------------------------------------------------
-- 2. Segurança (RLS): leitura com a seção "surveymonkey"; escrita só pela Edge Function
-- ---------------------------------------------------------------------
do $$
declare
  t   text;
  pol record;
begin
  foreach t in array array['survey_pastas','survey_formularios','survey_perguntas','survey_coletores','survey_respostas','survey_sincronizacoes']
  loop
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.cdl_secao(''surveymonkey''))', t || '_select', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. Agendamento: a cada 15 minutos o banco chama a Edge Function.
--    Troque SEU_PROJECT_REF pelo id do projeto (Project Settings > General > Project ID).
--    A função é publicada com --no-verify-jwt e se protege sozinha: ignora chamadas a menos de
--    5 minutos da anterior, então ninguém consegue esgotar o limite de chamadas da API.
-- ---------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'cdload-surveymonkey';
select cron.schedule('cdload-surveymonkey', '*/15 * * * *', $$
  select net.http_post(
    url     := 'https://SEU_PROJECT_REF.supabase.co/functions/v1/surveymonkey-sincronizar',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  )
$$);

-- Primeira execução agora (a primeira carga traz todo o histórico e pode levar algumas execuções;
-- acompanhe com a consulta abaixo).
select net.http_post(
  url     := 'https://SEU_PROJECT_REF.supabase.co/functions/v1/surveymonkey-sincronizar',
  headers := '{"Content-Type": "application/json"}'::jsonb,
  body    := '{}'::jsonb,
  timeout_milliseconds := 150000
);

-- ---------------------------------------------------------------------
-- 4. Conferência (rode de novo depois de alguns minutos)
-- ---------------------------------------------------------------------
-- select * from public.survey_sincronizacoes order by id desc limit 5;
-- select count(*) as formularios, sum(qtd_respostas) as respostas_na_conta,
--        count(*) filter (where pendente) as pendentes from public.survey_formularios where ativo;
-- select count(*) as respostas_gravadas from public.survey_respostas;
