-- =====================================================================
-- CDLoad · Seção "Roadmap" — interações do Núcleo de Inteligência com
-- os setores da CDL (flags por setor × dia)
--
-- Rode em Supabase > SQL Editor DEPOIS de schema_seguranca_rls.sql e
-- schema_usuarios_edicao.sql (usa cdl_secao e cdl_pode_editar).
-- É idempotente: pode rodar de novo sem apagar dados.
--
--   roadmap_interacoes → uma linha por setor e dia em que houve
--                        interação/reunião (no máximo uma por dia)
--
-- Métrica exibida no app: janela de 7 dias que termina hoje;
-- índice = setores distintos com interação ÷ 11 setores (100% = todos).
--
-- Acesso (seção "roadmap" em Usuários › Permissões de Acesso):
--   ler e marcar ......... quem tem a seção liberada
--   desmarcar ............ quem registrou a flag, usuário com Edição
--                          ou Administrador
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists public.roadmap_interacoes (
  id          uuid primary key default gen_random_uuid(),
  setor       text not null check (setor in (
                'Marketing', 'Certificado Digital / Espaço CDL', 'Institucional',
                'Superintendência', 'Financeiro', 'TI', 'Relações Humanas', 'CNDL',
                'Departamento Pessoal', 'SPC Brasil', 'Produtos CDL')),
  data        date not null,
  tipo        text not null default 'reuniao' check (tipo in ('reuniao', 'alinhamento', 'demanda')),
  criado_por  text,
  criado_em   timestamptz not null default now(),
  constraint roadmap_interacoes_setor_data_key unique (setor, data)
);

create index if not exists roadmap_interacoes_data_idx on public.roadmap_interacoes (data desc);

-- Quem registrou vem do login (não do que o navegador enviar).
create or replace function public.cdl_roadmap_autor()
returns trigger
language plpgsql security definer
set search_path = public, auth
as $$
begin
  new.criado_por := lower(coalesce(auth.jwt() ->> 'email', new.criado_por));
  new.criado_em := now();
  return new;
end;
$$;

drop trigger if exists roadmap_interacoes_autor on public.roadmap_interacoes;
create trigger roadmap_interacoes_autor
  before insert on public.roadmap_interacoes
  for each row execute function public.cdl_roadmap_autor();

-- ---------- RLS ----------
alter table public.roadmap_interacoes enable row level security;
revoke all on public.roadmap_interacoes from anon, authenticated;
grant select, insert, delete on public.roadmap_interacoes to authenticated;

drop policy if exists roadmap_select on public.roadmap_interacoes;
drop policy if exists roadmap_insert on public.roadmap_interacoes;
drop policy if exists roadmap_delete on public.roadmap_interacoes;

create policy roadmap_select on public.roadmap_interacoes for select to authenticated
  using (public.cdl_secao('roadmap'));
create policy roadmap_insert on public.roadmap_interacoes for insert to authenticated
  with check (public.cdl_secao('roadmap') and data <= current_date + 1);
create policy roadmap_delete on public.roadmap_interacoes for delete to authenticated
  using (
    public.cdl_pode_editar('roadmap')
    or (public.cdl_secao('roadmap') and lower(criado_por) = lower(auth.jwt() ->> 'email'))
  );

-- ---------- Conferência ----------
select policyname, cmd from pg_policies
where schemaname = 'public' and tablename = 'roadmap_interacoes'
order by cmd;
