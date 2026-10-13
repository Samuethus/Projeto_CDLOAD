-- ============================================================================
-- CDLoad · WhatsApp (UAZAPI) — Etapa 1: tabelas, RLS e tempo real
--
-- Rode em Supabase > SQL Editor (idempotente).
-- Pré-requisito: schema_seguranca_rls.sql (funções cdl_secao / cdl_admin).
--
-- Regras de segurança:
--   • O navegador só LÊ (select) e só quem tem a seção "whatsapp" liberada.
--   • Toda escrita passa pelas Edge Functions (service role ignora o RLS).
--   • O token de cada instância fica em tabela própria, com RLS ligado e
--     nenhuma policy: o navegador nunca consegue ler.
-- ============================================================================

do $$
begin
  if to_regprocedure('public.cdl_secao(text)') is null then
    raise exception 'Rode supabase/schema_seguranca_rls.sql antes deste arquivo (falta a função cdl_secao).';
  end if;
end $$;

-- ---------- Instâncias (números conectados) ----------

create table if not exists public.wa_instancias (
  id               uuid primary key default gen_random_uuid(),
  nome             text not null,
  uazapi_nome      text not null unique,
  telefone         text,
  status           text not null default 'desconectada'
                   check (status in ('desconectada','aguardando_qr','conectando','conectada')),
  ultimo_status_em timestamptz,
  criado_por       uuid references auth.users(id) on delete set null,
  criado_em        timestamptz not null default now()
);

-- Token da instância: sem policy = invisível para o navegador.
create table if not exists public.wa_instancia_tokens (
  instancia_id uuid primary key references public.wa_instancias(id) on delete cascade,
  token        text not null
);

-- ---------- Templates ----------

create table if not exists public.wa_templates (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  tipo       text not null default 'texto' check (tipo in ('texto','imagem','documento','botoes')),
  corpo      text not null,
  midia_url  text,
  ativo      boolean not null default true,
  criado_por uuid references auth.users(id) on delete set null,
  criado_em  timestamptz not null default now()
);

-- ---------- Contatos, listas e opt-out ----------

create table if not exists public.wa_contatos (
  id        uuid primary key default gen_random_uuid(),
  nome      text,
  telefone  text not null unique,          -- E.164 sem "+", ex.: 5565999990000
  campos    jsonb not null default '{}'::jsonb,
  origem    text,
  criado_em timestamptz not null default now()
);

create table if not exists public.wa_listas (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null,
  filtros   jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);

create table if not exists public.wa_listas_contatos (
  lista_id   uuid not null references public.wa_listas(id) on delete cascade,
  contato_id uuid not null references public.wa_contatos(id) on delete cascade,
  primary key (lista_id, contato_id)
);

create table if not exists public.wa_optout (
  telefone text primary key,
  motivo   text,
  em       timestamptz not null default now()
);

-- ---------- Campanhas e envios ----------

create table if not exists public.wa_campanhas (
  id               uuid primary key default gen_random_uuid(),
  nome             text not null,
  instancia_id     uuid references public.wa_instancias(id) on delete set null,
  template_id      uuid references public.wa_templates(id) on delete set null,
  lista_id         uuid references public.wa_listas(id) on delete set null,
  status           text not null default 'rascunho'
                   check (status in ('rascunho','agendada','enviando','pausada','concluida','cancelada')),
  agendada_para    timestamptz,
  delay_min        integer not null default 10,
  delay_max        integer not null default 30,
  uazapi_folder_id text,
  total            integer not null default 0,
  criado_por       uuid references auth.users(id) on delete set null,
  criado_em        timestamptz not null default now()
);

create table if not exists public.wa_envios (
  id            uuid primary key default gen_random_uuid(),
  campanha_id   uuid not null references public.wa_campanhas(id) on delete cascade,
  contato_id    uuid references public.wa_contatos(id) on delete set null,
  telefone      text not null,
  texto_final   text,
  status        text not null default 'fila'
                check (status in ('fila','enviado','entregue','lido','falhou')),
  erro          text,
  uazapi_msg_id text,
  enviado_em    timestamptz,
  entregue_em   timestamptz,
  lido_em       timestamptz,
  criado_em     timestamptz not null default now()
);
create index if not exists wa_envios_campanha_idx on public.wa_envios (campanha_id, status);
create index if not exists wa_envios_msg_idx      on public.wa_envios (uazapi_msg_id);

-- ---------- Log bruto do webhook ----------

create table if not exists public.wa_eventos (
  id          bigint generated always as identity primary key,
  tipo        text,
  payload     jsonb,
  recebido_em timestamptz not null default now()
);

-- ---------- RLS: leitura só com a seção "whatsapp"; escrita só pelas Edge Functions ----------

do $$
declare t text;
begin
  foreach t in array array[
    'wa_instancias','wa_templates','wa_contatos','wa_listas','wa_listas_contatos',
    'wa_optout','wa_campanhas','wa_envios','wa_eventos'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.cdl_secao(''whatsapp''))',
      t || '_select', t);
  end loop;
end $$;

alter table public.wa_instancia_tokens enable row level security;  -- sem policy de propósito
revoke all on public.wa_instancia_tokens from anon, authenticated;

-- ---------- Tempo real ----------

do $$
declare t text;
begin
  foreach t in array array['wa_instancias','wa_campanhas','wa_envios'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Conferência: deve listar as 9 tabelas wa_* + wa_instancia_tokens
-- select tablename, rowsecurity from pg_tables where schemaname = 'public' and tablename like 'wa\_%' order by 1;
