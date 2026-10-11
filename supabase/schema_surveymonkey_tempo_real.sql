-- =====================================================================
-- CDLoad · Survey Monkey — correção da sincronização + respostas em tempo real
--
-- Execute em Supabase > SQL Editor DEPOIS de `schema_surveymonkey.sql`. É idempotente.
--
-- 1. Correção: a sincronização falhava em toda execução ("null value in column qtd_formularios of
--    relation survey_pastas") e as tabelas survey_* ficavam vazias — por isso a seção mostrava só o
--    retrato fixo, sem as respostas individuais. Só esta alteração já destrava a função publicada.
-- 2. Tempo real: as tabelas de respostas e formulários entram na publicação do Supabase Realtime,
--    para o app receber cada resposta gravada e atualizar a tela na hora (o RLS continua valendo:
--    só recebe quem tem a seção "surveymonkey").
-- 3. Dispara uma sincronização agora (a primeira carga traz todo o histórico em algumas execuções).
-- =====================================================================

-- 1. Correção da coluna que travava a sincronização
alter table public.survey_pastas alter column qtd_formularios set default 0;
alter table public.survey_pastas alter column qtd_formularios drop not null;

-- 2. Realtime (Supabase > Database > Publications > supabase_realtime)
do $$
declare t text;
begin
  foreach t in array array['survey_respostas', 'survey_formularios'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 3. Sincronização agora
select net.http_post(
  url     := 'https://xjexujpvnahaugizeyee.supabase.co/functions/v1/surveymonkey-sincronizar',
  headers := '{"Content-Type": "application/json"}'::jsonb,
  body    := '{}'::jsonb,
  timeout_milliseconds := 150000
);

-- Conferência (rode de novo depois de alguns minutos):
-- select id, iniciado_em, finalizado_em, formularios, atualizados, respostas_novas, pendentes, erros
--   from public.survey_sincronizacoes order by id desc limit 5;
-- select count(*) as respostas_gravadas from public.survey_respostas;
