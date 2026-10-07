-- =====================================================================
-- CDLoad · Módulo Estoque — schema (tabelas, triggers, view)
--
-- Execute uma vez em Supabase > SQL Editor. É idempotente: pode ser
-- rodado de novo sem apagar dados.
--
-- IMPORTANTE — este script NÃO abre acesso a nenhuma tabela: ele só cria
-- a estrutura e habilita RLS sem nenhuma policy (ou seja, ninguém lê ou
-- grava nada ainda, nem o dono). O acesso real (login + seção liberada)
-- é concedido por `supabase/seguranca_rls.sql`, que deve ser executado
-- LOGO DEPOIS deste. Rodar só este arquivo deixa o Estoque inutilizável
-- (e é proposital: nunca deixamos o `anon` com acesso, nem por um instante).
--
--   cadastro_de_produtos   → catálogo único (código de barras único no
--                            catálogo inteiro), sem setor — o produto é
--                            global; `estoque_minimo` é um total único
--                            (soma dos dois estoques centrais)
--   movimentacoes_estoque  → origem (1º lançamento, único por produto),
--                            entradas e saídas. `setor` é sempre um dos dois
--                            ESTOQUES CENTRAIS (Escritório | Almoxarifado):
--                            a compra do mês abastece as centrais e toda
--                            retirada sai de uma delas. Na saída,
--                            `setor_consumo` informa o setor que consome o
--                            produto (Térreo, 1º Piso, Comercial, ...) — é
--                            ele que mapeia os setores que mais demandam.
--                            `transferencia` marca as duas pontas de uma
--                            transferência entre as centrais (não é compra
--                            nem consumo).
--   vw_estoque_saldo       → saldo por produto + estoque central = origem +
--                            entradas − saídas daquela central
--
-- Banco que já usava o modelo antigo (entradas/saídas em RH, Institucional,
-- Espaço): rode supabase/migracao_estoque_centrais.sql uma vez.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Cadastro de produtos (catálogo único, sem setor — produto é global)
-- ---------------------------------------------------------------------
create table if not exists public.cadastro_de_produtos (
  id              uuid primary key default gen_random_uuid(),
  codigo_barras   text not null,
  nome            text not null,
  descricao       text,
  unidade         text not null default 'UN',
  estoque_minimo  numeric(14,3) not null default 0 check (estoque_minimo >= 0),
  preco_custo     numeric(14,2) check (preco_custo is null or preco_custo >= 0),
  ativo           boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

do $$
begin
  -- Migração de bancos antigos: `setor` era o "setor de origem" do
  -- produto, mas o produto é global (só as movimentações têm setor) —
  -- remove a coluna, sua checagem de valor válido e o gatilho que travava
  -- a edição dela.
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'cadastro_de_produtos' and column_name = 'setor') then
    drop trigger if exists trg_cadastro_de_produtos_setor_fixo on public.cadastro_de_produtos;
    alter table public.cadastro_de_produtos drop constraint if exists cadastro_de_produtos_setor_valido;
    alter table public.cadastro_de_produtos drop column setor;
  end if;
  -- Substitui a unicidade antiga (setor, código) — hoje o código de
  -- barras é único no catálogo inteiro, não mais por setor.
  if exists (select 1 from pg_constraint where conname = 'cadastro_de_produtos_setor_codigo_key') then
    alter table public.cadastro_de_produtos drop constraint cadastro_de_produtos_setor_codigo_key;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cadastro_de_produtos_codigo_key') then
    alter table public.cadastro_de_produtos
      add constraint cadastro_de_produtos_codigo_key unique (codigo_barras);
  end if;
end $$;

drop function if exists public.estoque_bloqueia_troca_setor();

-- ---------------------------------------------------------------------
-- 2. Movimentações: origem / entrada / saída
--    setor          → estoque central onde o saldo mexe (Escritório | Almoxarifado)
--    setor_consumo  → só na saída: setor que consome o produto
--    transferencia  → par saída+entrada entre as duas centrais
-- ---------------------------------------------------------------------
create table if not exists public.movimentacoes_estoque (
  id             uuid primary key default gen_random_uuid(),
  produto_id     uuid not null references public.cadastro_de_produtos(id) on delete cascade,
  tipo           text not null check (tipo in ('origem', 'entrada', 'saida')),
  setor          text not null,
  setor_consumo  text,
  transferencia  boolean not null default false,
  quantidade     numeric(14,3) not null,
  observacao     text,
  usuario_email  text,
  created_at     timestamptz not null default now(),
  editado_em     timestamptz,   -- último ajuste (só Administrador edita)
  editado_por    text,
  constraint movimentacoes_estoque_quantidade_valida check (
    (tipo = 'origem' and quantidade >= 0) or (tipo <> 'origem' and quantidade > 0)
  )
);

alter table public.movimentacoes_estoque add column if not exists setor_consumo text;
alter table public.movimentacoes_estoque add column if not exists transferencia boolean not null default false;
alter table public.movimentacoes_estoque add column if not exists editado_em timestamptz;
alter table public.movimentacoes_estoque add column if not exists editado_por text;

do $$
begin
  -- Troca a regra antiga (5 setores com estoque) pela nova (só as 2 centrais).
  if exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_setor_valido'
              and pg_get_constraintdef(oid) like '%Institucional%') then
    alter table public.movimentacoes_estoque drop constraint movimentacoes_estoque_setor_valido;
  end if;
  -- NOT VALID: vale para todo lançamento novo sem reprovar o histórico do
  -- modelo antigo (RH, Institucional, Espaço).
  if not exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_setor_valido') then
    alter table public.movimentacoes_estoque
      add constraint movimentacoes_estoque_setor_valido
      check (setor in ('Escritório', 'Almoxarifado')) not valid;
  end if;
  -- Setor de consumo: só existe na saída e é obrigatório em toda saída que
  -- não seja transferência entre centrais. A lista de setores fica no app
  -- (STOCK_SETORES_CONSUMO em index.html), para crescer sem mexer no banco.
  if not exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_consumo_valido') then
    alter table public.movimentacoes_estoque
      add constraint movimentacoes_estoque_consumo_valido
      check (
        (tipo = 'saida' or setor_consumo is null)
        and (tipo <> 'saida' or transferencia or nullif(btrim(setor_consumo), '') is not null)
        and (not transferencia or (tipo <> 'origem' and setor_consumo is null))
      ) not valid;
  end if;
end $$;

create index if not exists movimentacoes_estoque_produto_idx
  on public.movimentacoes_estoque (produto_id, created_at desc);

create index if not exists movimentacoes_estoque_consumo_idx
  on public.movimentacoes_estoque (setor_consumo, created_at desc) where tipo = 'saida';

-- Um único lançamento de origem por produto
create unique index if not exists movimentacoes_estoque_origem_unica
  on public.movimentacoes_estoque (produto_id) where tipo = 'origem';

-- ---------------------------------------------------------------------
-- 3. updated_at automático no cadastro
-- ---------------------------------------------------------------------
create or replace function public.estoque_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_cadastro_de_produtos_updated_at on public.cadastro_de_produtos;
create trigger trg_cadastro_de_produtos_updated_at
  before update on public.cadastro_de_produtos
  for each row execute function public.estoque_set_updated_at();

-- ---------------------------------------------------------------------
-- 4. Integridade do saldo (por produto + estoque central)
--    • saída maior que o saldo disponível NAQUELA CENTRAL → bloqueada
--    • remoção de entrada que deixaria o saldo da central negativo → bloqueada
--    • origem só é removida junto com o produto (cascade)
-- ---------------------------------------------------------------------
create or replace function public.estoque_valida_saldo()
returns trigger language plpgsql as $$
declare
  v_produto uuid;
  v_setor   text;
  v_saldo   numeric;
begin
  if tg_op = 'INSERT' then
    if new.tipo <> 'saida' then return new; end if;
    v_produto := new.produto_id;
    v_setor := new.setor;
  else
    if old.tipo = 'saida' then return old; end if;
    v_produto := old.produto_id;
    v_setor := old.setor;
  end if;

  -- Serializa movimentações concorrentes do mesmo produto.
  -- Se o produto não existe mais, é um DELETE em cascata: libera.
  perform 1 from public.cadastro_de_produtos where id = v_produto for update;
  if not found then
    return case when tg_op = 'INSERT' then new else old end;
  end if;

  if tg_op = 'DELETE' and old.tipo = 'origem' then
    raise exception 'O lançamento de origem só pode ser removido junto com o produto.';
  end if;

  select coalesce(sum(case when tipo = 'saida' then -quantidade else quantidade end), 0)
    into v_saldo
    from public.movimentacoes_estoque
   where produto_id = v_produto and setor = v_setor;

  if tg_op = 'INSERT' and v_saldo - new.quantidade < 0 then
    raise exception 'Saldo insuficiente em %: saldo atual %, saída solicitada %', v_setor, v_saldo, new.quantidade
      using errcode = 'check_violation';
  end if;

  if tg_op = 'DELETE' and v_saldo - old.quantidade < 0 then
    raise exception 'Remover esta entrada deixaria o saldo de % negativo (saldo atual %).', v_setor, v_saldo
      using errcode = 'check_violation';
  end if;

  return case when tg_op = 'INSERT' then new else old end;
end;
$$;

drop trigger if exists trg_movimentacoes_estoque_valida_saldo on public.movimentacoes_estoque;
create trigger trg_movimentacoes_estoque_valida_saldo
  before insert or delete on public.movimentacoes_estoque
  for each row execute function public.estoque_valida_saldo();

-- ---------------------------------------------------------------------
-- 4b. Ajuste de lançamento (UPDATE — só Administrador, pelo RLS)
--    • nenhum estoque central afetado pode ficar com saldo negativo
--    • origem não muda de tipo nem de produto
--    • transferência: só quantidade e observação (o app ajusta as duas
--      pontas em sequência, numa ordem que nunca negativa o saldo)
--    • grava quem e quando ajustou (editado_por / editado_em)
-- ---------------------------------------------------------------------
create or replace function public.estoque_valida_ajuste()
returns trigger language plpgsql as $$
declare
  k       record;
  v_saldo numeric;
begin
  if old.transferencia or new.transferencia then
    if new.transferencia is distinct from old.transferencia or new.tipo <> old.tipo
       or new.produto_id <> old.produto_id or new.setor <> old.setor then
      raise exception 'Numa transferência só a quantidade e a observação podem ser ajustadas.';
    end if;
  end if;
  if (old.tipo = 'origem') <> (new.tipo = 'origem') or (old.tipo = 'origem' and new.produto_id <> old.produto_id) then
    raise exception 'O lançamento de origem não muda de tipo nem de produto.';
  end if;

  -- Serializa com as demais movimentações dos produtos envolvidos.
  perform 1 from public.cadastro_de_produtos where id in (old.produto_id, new.produto_id) order by id for update;

  -- Saldo final de cada central afetada (a antiga e a nova), já com o ajuste.
  for k in select distinct t.produto_id, t.setor
             from (values (old.produto_id, old.setor), (new.produto_id, new.setor)) as t(produto_id, setor) loop
    select coalesce(sum(case when tipo = 'saida' then -quantidade else quantidade end), 0)
      into v_saldo
      from public.movimentacoes_estoque
     where produto_id = k.produto_id and setor = k.setor and id <> old.id;
    if new.produto_id = k.produto_id and new.setor = k.setor then
      v_saldo := v_saldo + case when new.tipo = 'saida' then -new.quantidade else new.quantidade end;
    end if;
    if v_saldo < 0 then
      raise exception 'Este ajuste deixaria o saldo de % negativo (ficaria %).', k.setor, v_saldo
        using errcode = 'check_violation';
    end if;
  end loop;

  new.editado_em := now();
  new.editado_por := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', current_user);
  return new;
end;
$$;

drop trigger if exists trg_movimentacoes_estoque_valida_ajuste on public.movimentacoes_estoque;
create trigger trg_movimentacoes_estoque_valida_ajuste
  before update on public.movimentacoes_estoque
  for each row execute function public.estoque_valida_ajuste();

-- ---------------------------------------------------------------------
-- 5. Saldo por produto + estoque central (security_invoker: respeita o
--    RLS de quem consulta). Um produto pode ter uma linha por central
--    onde já teve alguma movimentação.
-- ---------------------------------------------------------------------
create or replace view public.vw_estoque_saldo
with (security_invoker = true) as
select
  m.produto_id,
  m.setor,
  coalesce(sum(case when m.tipo = 'saida' then -m.quantidade else m.quantidade end), 0) as saldo,
  coalesce(sum(m.quantidade) filter (where m.tipo = 'origem'), 0)  as quantidade_origem,
  coalesce(sum(m.quantidade) filter (where m.tipo = 'entrada'), 0) as total_entradas,
  coalesce(sum(m.quantidade) filter (where m.tipo = 'saida'), 0)   as total_saidas,
  max(m.created_at) as ultima_movimentacao
from public.movimentacoes_estoque m
group by m.produto_id, m.setor;

-- ---------------------------------------------------------------------
-- 6. RLS ligado, SEM policies — bloqueia geral até seguranca_rls.sql
--    conceder acesso a `authenticated` conforme seção/perfil.
-- ---------------------------------------------------------------------
alter table public.cadastro_de_produtos  enable row level security;
alter table public.movimentacoes_estoque enable row level security;
revoke all on public.cadastro_de_produtos, public.movimentacoes_estoque, public.vw_estoque_saldo from anon, authenticated;

-- A API (PostgREST) passa a enxergar colunas novas na hora.
notify pgrst, 'reload schema';

-- Próximo passo obrigatório: supabase/seguranca_rls.sql
