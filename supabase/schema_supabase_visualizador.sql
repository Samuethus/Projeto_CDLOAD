-- =====================================================================================
-- CDLoad · Seção SUPABASE — lista das tabelas do banco (visualização, somente leitura)
-- =====================================================================================
--
-- COMO USAR
--   Supabase  >  SQL Editor  >  New query  >  cole este arquivo  >  RUN.   (pode rodar de novo: é idempotente)
--   Pré-requisito: supabase/schema_seguranca_rls.sql (usa a função cdl_secao).
--
-- O QUE FAZ
--   Cria a função public.cdl_tabelas(), usada pela seção "Supabase" do CDLoad para listar TODAS as tabelas do
--   esquema public: nome, descrição (comentário), quantidade de registros, colunas (nome e tipo), tamanho em disco
--   e se a tabela tem RLS (regras de acesso por linha) ligado.
--
-- SEGURANÇA
--   • Só responde para quem está logado e tem a seção "Supabase" liberada (chave interna "instancias") ou é
--     Administrador — os demais recebem erro de permissão.
--   • A função só informa a ESTRUTURA e a CONTAGEM de registros. Os dados em si são lidos pelo app com o login
--     do usuário, pela API normal: continuam valendo as regras de acesso (RLS) de cada tabela.
--   • Nada é alterado: a seção é somente leitura.
-- =====================================================================================

do $$
begin
  if to_regprocedure('public.cdl_secao(text)') is null then
    raise exception 'Rode supabase/schema_seguranca_rls.sql antes deste arquivo (falta a função cdl_secao).';
  end if;
end $$;

create or replace function public.cdl_tabelas()
returns table (
  nome       text,      -- nome da tabela (esquema public)
  descricao  text,      -- comentário da tabela (COMMENT ON TABLE), se houver
  registros  bigint,    -- quantidade exata de registros
  colunas    jsonb,     -- [{ "nome": ..., "tipo": ..., "nulo": true|false }] na ordem da tabela
  tamanho    bigint,    -- bytes em disco (tabela + índices)
  rls        boolean    -- RLS (row level security) ligado
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
  t record;
  n bigint;
begin
  if not public.cdl_secao('instancias') then
    raise exception 'Sem acesso à seção Supabase.' using errcode = '42501';
  end if;
  for t in
    select c.oid, c.relname::text as relname, obj_description(c.oid, 'pg_class') as descr, c.relrowsecurity
      from pg_class c join pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'public' and c.relkind in ('r', 'p')
     order by c.relname
  loop
    execute format('select count(*) from public.%I', t.relname) into n;
    return query
      select t.relname, t.descr, n,
             coalesce((select jsonb_agg(jsonb_build_object('nome', a.attname, 'tipo', format_type(a.atttypid, a.atttypmod), 'nulo', not a.attnotnull) order by a.attnum)
                         from pg_attribute a where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped), '[]'::jsonb),
             pg_total_relation_size(t.oid),
             t.relrowsecurity;
  end loop;
end $$;

revoke all on function public.cdl_tabelas() from public, anon;
grant execute on function public.cdl_tabelas() to authenticated;

-- Conferência (com o seu login, no app; no SQL Editor você é o dono do banco e a função pede o login do app):
-- select nome, registros, rls from public.cdl_tabelas();
