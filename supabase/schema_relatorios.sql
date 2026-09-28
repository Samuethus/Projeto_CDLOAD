-- =====================================================================
-- CDLoad · Módulo Relatórios — schema (tabela + bucket de Storage)
--
-- Execute uma vez em Supabase > SQL Editor. É idempotente: pode ser
-- rodado de novo sem apagar dados.
--
-- IMPORTANTE — este script NÃO abre acesso a nenhuma tabela/bucket: só
-- cria a estrutura e habilita RLS sem nenhuma policy (ou seja, ninguém
-- lê ou grava nada ainda, nem o dono). O acesso real (login + seção
-- "relatorios" liberada) é concedido por `supabase/seguranca_rls.sql`,
-- que deve ser executado LOGO DEPOIS deste.
--
--   relatorios_arquivos  → metadados de cada material enviado (título,
--                          categoria, competência, tamanho, quem enviou)
--   bucket "relatorios"  → o arquivo em si (PDF, planilha, etc.), privado
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Metadados dos arquivos
-- ---------------------------------------------------------------------
create table if not exists public.relatorios_arquivos (
  id             uuid primary key default gen_random_uuid(),
  titulo         text not null,
  categoria      text,
  competencia    text,
  arquivo_nome   text not null,
  arquivo_path   text not null unique,
  tamanho_bytes  bigint not null check (tamanho_bytes >= 0),
  usuario_email  text,
  created_at     timestamptz not null default now()
);

create index if not exists relatorios_arquivos_created_idx
  on public.relatorios_arquivos (created_at desc);

-- ---------------------------------------------------------------------
-- 2. Bucket de Storage para os arquivos. Privado: o app só gera links
--    de download assinados e temporários (createSignedUrl), depois de
--    o RLS de storage.objects confirmar a seção do usuário.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('relatorios', 'relatorios', false)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3. RLS ligado, SEM policies — bloqueia geral até seguranca_rls.sql
--    conceder acesso a `authenticated` conforme a seção "relatorios".
-- ---------------------------------------------------------------------
alter table public.relatorios_arquivos enable row level security;
revoke all on public.relatorios_arquivos from anon, authenticated;

-- Próximo passo obrigatório: supabase/seguranca_rls.sql
