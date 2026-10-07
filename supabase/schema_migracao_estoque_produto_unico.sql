-- =====================================================================
-- CDLoad · Módulo Estoque — migração para catálogo único por setor
--
-- Só é necessário rodar este script UMA VEZ, se o seu banco já tinha o
-- Estoque em uso no modelo antigo (produto preso a um setor, com o mesmo
-- código de barras podendo existir como cadastros separados em setores
-- diferentes). Depois de rodá-lo, `supabase/schema_estoque.sql` já
-- reflete o novo formato e pode ser reexecutado normalmente (idempotente).
--
-- Se o Estoque está sendo criado do zero, IGNORE este arquivo — basta
-- rodar schema_estoque.sql e schema_seguranca_rls.sql, que já criam tudo no
-- formato novo.
--
-- O que este script faz, em ordem:
--   0. Em alguns bancos a coluna de setor do cadastro foi criada
--      fisicamente como `categoria` (o app já lia essa coluna via um
--      "apelido" no JS — ver STOCK_SETOR_COL em index.html). Se for o
--      caso, ela é renomeada para `setor` antes de tudo, pra alinhar com
--      o restante do script e com schema_estoque.sql.
--   1. Adiciona a coluna `setor` em movimentacoes_estoque e preenche
--      cada lançamento com o setor do produto ao qual ele pertencia.
--   2. Mescla cadastros duplicados do mesmo código de barras (que hoje
--      existem um por setor) num único produto por código — mantém o
--      cadastro mais antigo como "canônico" e reaponta o histórico de
--      movimentações dos demais para ele. Como só pode haver um
--      lançamento de tipo 'origem' por produto, a 'origem' dos
--      cadastros mesclados vira 'entrada' (o setor de cada lançamento
--      já foi gravado no passo 1, então nada se perde).
--   3. Remove os cadastros duplicados, agora órfãos.
--   4. Aplica as restrições novas (setor obrigatório e válido em
--      movimentacoes_estoque, código de barras único no catálogo).
--   5. Substitui a trigger de validação de saldo e a view
--      vw_estoque_saldo pelas versões que calculam saldo por
--      produto + setor (mesmo código de schema_estoque.sql).
--
-- Faça um backup/export das tabelas cadastro_de_produtos e
-- movimentacoes_estoque antes de rodar, por precaução.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Alinha o nome da coluna, se o cadastro foi criado com `categoria`
--    em vez de `setor`.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'cadastro_de_produtos' and column_name = 'setor'
  ) and exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'cadastro_de_produtos' and column_name = 'categoria'
  ) then
    alter table public.cadastro_de_produtos rename column categoria to setor;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Coluna setor em movimentacoes_estoque + backfill a partir do
--    produto (antes de mexer nos cadastros, enquanto produto_id ainda
--    aponta pro cadastro específico daquele setor).
-- ---------------------------------------------------------------------
alter table public.movimentacoes_estoque add column if not exists setor text;

update public.movimentacoes_estoque m
   set setor = p.setor
  from public.cadastro_de_produtos p
 where p.id = m.produto_id
   and m.setor is null;

-- ---------------------------------------------------------------------
-- 2. Mescla cadastros duplicados (mesmo código de barras) num só,
--    mantendo o mais antigo como canônico.
-- ---------------------------------------------------------------------
with duplicados as (
  select
    id,
    codigo_barras,
    first_value(id) over (partition by codigo_barras order by created_at asc, id asc) as canonico_id
  from public.cadastro_de_produtos
)
update public.movimentacoes_estoque m
   set produto_id = d.canonico_id
  from duplicados d
 where m.produto_id = d.id
   and d.id <> d.canonico_id;

-- Só pode haver uma 'origem' por produto: nos cadastros que deixaram de
-- ser canônicos, a origem vira uma entrada comum (o setor dela já está
-- preservado na coluna setor).
with duplicados as (
  select
    id,
    codigo_barras,
    first_value(id) over (partition by codigo_barras order by created_at asc, id asc) as canonico_id
  from public.cadastro_de_produtos
)
update public.movimentacoes_estoque m
   set tipo = 'entrada'
  from duplicados d
 where m.produto_id = d.canonico_id
   and m.tipo = 'origem'
   and m.id not in (
     select id from public.movimentacoes_estoque
      where produto_id = d.canonico_id and tipo = 'origem'
      order by created_at asc limit 1
   )
   and d.id <> d.canonico_id;

-- Remove os cadastros que deixaram de ser canônicos (já sem movimentações
-- apontando pra eles).
with duplicados as (
  select
    id,
    codigo_barras,
    first_value(id) over (partition by codigo_barras order by created_at asc, id asc) as canonico_id
  from public.cadastro_de_produtos
)
delete from public.cadastro_de_produtos p
 using duplicados d
 where p.id = d.id
   and d.id <> d.canonico_id;

-- ---------------------------------------------------------------------
-- 3. Restrições novas.
-- ---------------------------------------------------------------------
alter table public.movimentacoes_estoque alter column setor set not null;

do $$
declare
  r record;
begin
  -- Remove qualquer unique constraint antiga em (setor, codigo_barras) —
  -- não confiamos no nome exato, pode ter sido criada com outro nome
  -- (ex: quando a coluna ainda se chamava `categoria`).
  for r in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'cadastro_de_produtos'
       and con.contype = 'u'
       and (
         select array_agg(attname::text order by attname::text)
           from unnest(con.conkey) k
           join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k
       ) = array['codigo_barras', 'setor']::text[]
  loop
    execute format('alter table public.cadastro_de_produtos drop constraint %I', r.conname);
  end loop;

  if not exists (select 1 from pg_constraint where conname = 'cadastro_de_produtos_codigo_key') then
    alter table public.cadastro_de_produtos add constraint cadastro_de_produtos_codigo_key unique (codigo_barras);
  end if;

  -- Como a coluna pode ter vindo de `categoria` (campo livre, sem essa
  -- restrição), só adiciona o check se todo o histórico já usa um dos 5
  -- setores. Se houver valor fora da lista, avisa e pula — corrija os
  -- dados (ex: `update movimentacoes_estoque set setor = 'Escritório'
  -- where setor = '...'`) e rode este bloco de novo depois.
  if exists (select 1 from public.movimentacoes_estoque where setor not in ('Escritório', 'Almoxarifado', 'RH', 'Institucional', 'Espaço')) then
    raise notice 'movimentacoes_estoque tem setor(es) fora da lista padrão — restrição movimentacoes_estoque_setor_valido NÃO foi criada. Valores encontrados: %',
      (select string_agg(distinct setor, ', ') from public.movimentacoes_estoque where setor not in ('Escritório', 'Almoxarifado', 'RH', 'Institucional', 'Espaço'));
  elsif not exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_setor_valido') then
    alter table public.movimentacoes_estoque
      add constraint movimentacoes_estoque_setor_valido
      check (setor in ('Escritório', 'Almoxarifado', 'RH', 'Institucional', 'Espaço'));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Trigger de saldo e view, agora por produto + setor (igual a
--    schema_estoque.sql — reaplicado aqui para o banco já ficar
--    consistente antes de você rodar aquele script de novo).
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

-- CREATE OR REPLACE VIEW não deixa mudar a ordem/nome de colunas
-- existentes (só permite adicionar no final) — a view antiga tinha
-- `setor` como última coluna e a nova tem como a 2ª, então precisa
-- dropar e recriar. Isso também apaga os grants da view, por isso eles
-- são refeitos logo abaixo (mesmo trecho de supabase/schema_seguranca_rls.sql).
drop view if exists public.vw_estoque_saldo;

create view public.vw_estoque_saldo
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

revoke all on public.vw_estoque_saldo from anon;
grant select on public.vw_estoque_saldo to authenticated;

commit;

-- Depois de rodar isto, rode supabase/schema_estoque.sql de novo (é
-- idempotente) para garantir que tudo — nomes de constraint, comentários,
-- índices — fica exatamente igual ao que um banco novo teria.
