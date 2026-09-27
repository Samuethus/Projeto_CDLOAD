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
--   cadastro_de_produtos   → cadastro por setor (código de barras único
--                            dentro de cada setor; cada setor tem o seu
--                            próprio estoque do mesmo produto)
--   movimentacoes_estoque  → origem (1º lançamento, único por produto),
--                            entradas e saídas
--   vw_estoque_saldo       → saldo por produto = origem + entradas − saídas
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Cadastro de produtos
-- ---------------------------------------------------------------------
create table if not exists public.cadastro_de_produtos (
  id              uuid primary key default gen_random_uuid(),
  setor           text not null,
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
  if not exists (select 1 from pg_constraint where conname = 'cadastro_de_produtos_setor_valido') then
    alter table public.cadastro_de_produtos
      add constraint cadastro_de_produtos_setor_valido
      check (setor in ('Escritório', 'Almoxarifado', 'RH', 'Institucional', 'Espaço'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cadastro_de_produtos_setor_codigo_key') then
    alter table public.cadastro_de_produtos
      add constraint cadastro_de_produtos_setor_codigo_key unique (setor, codigo_barras);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Movimentações: origem / entrada / saída
-- ---------------------------------------------------------------------
create table if not exists public.movimentacoes_estoque (
  id             uuid primary key default gen_random_uuid(),
  produto_id     uuid not null references public.cadastro_de_produtos(id) on delete cascade,
  tipo           text not null check (tipo in ('origem', 'entrada', 'saida')),
  quantidade     numeric(14,3) not null,
  observacao     text,
  usuario_email  text,
  created_at     timestamptz not null default now(),
  constraint movimentacoes_estoque_quantidade_valida check (
    (tipo = 'origem' and quantidade >= 0) or (tipo <> 'origem' and quantidade > 0)
  )
);

create index if not exists movimentacoes_estoque_produto_idx
  on public.movimentacoes_estoque (produto_id, created_at desc);

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

-- O setor é fixo após o cadastro: o estoque (e o histórico) pertence a ele.
create or replace function public.estoque_bloqueia_troca_setor()
returns trigger language plpgsql as $$
begin
  if new.setor is distinct from old.setor then
    raise exception 'O setor de um produto não pode ser alterado após o cadastro.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_cadastro_de_produtos_setor_fixo on public.cadastro_de_produtos;
create trigger trg_cadastro_de_produtos_setor_fixo
  before update on public.cadastro_de_produtos
  for each row execute function public.estoque_bloqueia_troca_setor();

-- ---------------------------------------------------------------------
-- 4. Integridade do saldo
--    • saída maior que o saldo disponível → bloqueada
--    • remoção de entrada que deixaria o saldo negativo → bloqueada
--    • origem só é removida junto com o produto (cascade)
-- ---------------------------------------------------------------------
create or replace function public.estoque_valida_saldo()
returns trigger language plpgsql as $$
declare
  v_produto uuid;
  v_saldo   numeric;
begin
  if tg_op = 'INSERT' then
    if new.tipo <> 'saida' then return new; end if;
    v_produto := new.produto_id;
  else
    if old.tipo = 'saida' then return old; end if;
    v_produto := old.produto_id;
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
   where produto_id = v_produto;

  if tg_op = 'INSERT' and v_saldo - new.quantidade < 0 then
    raise exception 'Saldo insuficiente: saldo atual %, saída solicitada %', v_saldo, new.quantidade
      using errcode = 'check_violation';
  end if;

  if tg_op = 'DELETE' and v_saldo - old.quantidade < 0 then
    raise exception 'Remover esta entrada deixaria o saldo negativo (saldo atual %).', v_saldo
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
-- 5. Saldo por produto (security_invoker: respeita o RLS de quem consulta)
-- ---------------------------------------------------------------------
create or replace view public.vw_estoque_saldo
with (security_invoker = true) as
select
  p.id as produto_id,
  coalesce(sum(case when m.tipo = 'saida' then -m.quantidade else m.quantidade end), 0) as saldo,
  coalesce(sum(m.quantidade) filter (where m.tipo = 'origem'), 0)  as quantidade_origem,
  coalesce(sum(m.quantidade) filter (where m.tipo = 'entrada'), 0) as total_entradas,
  coalesce(sum(m.quantidade) filter (where m.tipo = 'saida'), 0)   as total_saidas,
  max(m.created_at) as ultima_movimentacao,
  p.setor
from public.cadastro_de_produtos p
left join public.movimentacoes_estoque m on m.produto_id = p.id
group by p.id;

-- ---------------------------------------------------------------------
-- 6. RLS ligado, SEM policies — bloqueia geral até seguranca_rls.sql
--    conceder acesso a `authenticated` conforme seção/perfil.
-- ---------------------------------------------------------------------
alter table public.cadastro_de_produtos  enable row level security;
alter table public.movimentacoes_estoque enable row level security;
revoke all on public.cadastro_de_produtos, public.movimentacoes_estoque, public.vw_estoque_saldo from anon, authenticated;

-- Próximo passo obrigatório: supabase/seguranca_rls.sql
