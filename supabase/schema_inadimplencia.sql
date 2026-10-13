-- =====================================================================================
-- CDLoad · Seção INADIMPLÊNCIA — documentação do SPC Brasil (tabela + bucket de Storage)
-- =====================================================================================
--
-- COMO USAR
--   Supabase  >  SQL Editor  >  New query  >  cole este arquivo  >  RUN.
--   Pode rodar mais de uma vez (idempotente). Rode DEPOIS de schema_usuarios_edicao.sql
--   (usa cdl_secao e cdl_pode_editar).
--
-- O QUE FAZ
--   A antiga seção "Configurações" passa a ser "Inadimplência" (a chave da seção continua
--   "configuracoes": quem já tinha a seção liberada continua com acesso).
--   Passo 1 — inadimplencia_arquivos: metadados de cada documento enviado
--             (abrangência Cuiabá | Mato Grosso | Brasil, data de publicação — define a pasta Ano > Mês —,
--             arquivo, quem enviou).
--   Passo 2 — bucket privado "inadimplencia" com o arquivo (o app só abre por link assinado e temporário).
--   Passo 3 — Acesso (mesma regra da seção Relatórios):
--               ler e enviar ......... quem tem a seção liberada (o autor não pode ser forjado)
--               remover .............. Administrador ou usuário com "Edição" e a seção liberada
--   Esses documentos são a base do indicador "Inadimplência" do Dashboard › Panorama Econômico.
-- =====================================================================================

create extension if not exists pgcrypto;

-- Passo 1
create table if not exists public.inadimplencia_arquivos (
  id               uuid primary key default gen_random_uuid(),
  titulo           text not null,
  abrangencia      text not null check (abrangencia in ('Cuiabá', 'Mato Grosso', 'Brasil')),
  referencia       date not null,                 -- mês de referência (sempre o dia 1): pasta Ano > Mês
  arquivo_nome     text not null,
  arquivo_path     text not null unique,
  tamanho_bytes    bigint not null check (tamanho_bytes >= 0),
  usuario_email    text,
  created_at       timestamptz not null default now()
);
create index if not exists inadimplencia_arquivos_ref_idx on public.inadimplencia_arquivos (referencia desc, abrangencia);

-- Data de publicação (campo do cadastro): define a pasta Ano > Mês do documento.
-- Documentos enviados antes deste campo ficam com o mês de referência.
alter table public.inadimplencia_arquivos add column if not exists data_publicacao date;
update public.inadimplencia_arquivos set data_publicacao = referencia where data_publicacao is null;
create index if not exists inadimplencia_arquivos_pub_idx on public.inadimplencia_arquivos (data_publicacao desc);

comment on table public.inadimplencia_arquivos is
  'Inadimplência: documentos do SPC Brasil por abrangência (Cuiabá, Mato Grosso, Brasil) e mês de referência.';

-- Passo 2
insert into storage.buckets (id, name, public)
values ('inadimplencia', 'inadimplencia', false)
on conflict (id) do nothing;

-- Passo 3
alter table public.inadimplencia_arquivos enable row level security;
revoke all on public.inadimplencia_arquivos from anon, authenticated;
grant select, insert, delete on public.inadimplencia_arquivos to authenticated;

drop policy if exists inad_select on public.inadimplencia_arquivos;
drop policy if exists inad_insert on public.inadimplencia_arquivos;
drop policy if exists inad_delete on public.inadimplencia_arquivos;
create policy inad_select on public.inadimplencia_arquivos for select to authenticated
  using (public.cdl_secao('configuracoes'));
create policy inad_insert on public.inadimplencia_arquivos for insert to authenticated
  with check (public.cdl_secao('configuracoes')
              and (usuario_email is null or lower(usuario_email) = lower(auth.jwt() ->> 'email')));
create policy inad_delete on public.inadimplencia_arquivos for delete to authenticated
  using (public.cdl_pode_editar('configuracoes'));

drop policy if exists inad_storage_select on storage.objects;
drop policy if exists inad_storage_insert on storage.objects;
drop policy if exists inad_storage_delete on storage.objects;
create policy inad_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'inadimplencia' and public.cdl_secao('configuracoes'));
create policy inad_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'inadimplencia' and public.cdl_secao('configuracoes'));
create policy inad_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'inadimplencia' and public.cdl_pode_editar('configuracoes'));

notify pgrst, 'reload schema';

-- Conferência: bucket e regras criados.
select id, public from storage.buckets where id = 'inadimplencia';
select policyname, cmd from pg_policies where tablename in ('inadimplencia_arquivos') or policyname like 'inad_storage_%' order by policyname;
