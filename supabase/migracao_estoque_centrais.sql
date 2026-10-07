-- =====================================================================
-- CDLoad · Módulo Estoque — migração para "estoques centrais + setor de
-- consumo"
--
-- Novo processo: a compra do mês abastece só os dois ESTOQUES CENTRAIS
-- (Escritório e Almoxarifado). O setor que usa o produto (Térreo, 1º Piso,
-- 2º Piso, Espaço CDL, Administrativo, Financeiro, Certificado, Comercial,
-- Diretoria, Recepção, RH, Jurídico) só é informado na SAÍDA, na coluna
-- nova `setor_consumo` — é ela que mapeia os setores que mais demandam.
--
-- Rode UMA VEZ, no Supabase > SQL Editor, se o seu banco já tinha o
-- Estoque em uso no modelo antigo (saldo em RH, Institucional, Espaço).
-- Banco novo: ignore este arquivo — schema_estoque.sql já cria tudo no
-- formato novo.
--
-- O que este script faz, em ordem:
--   1. Adiciona `setor_consumo` e `transferencia` em movimentacoes_estoque.
--   2. Marca como transferência os pares que o app gravou com a
--      observação "Transferência <origem> → <destino>" — assim eles deixam
--      de contar como compra/consumo no Dashboard e no Relatório.
--   3. Devolve ao estoque central o saldo que ainda estiver em RH,
--      Institucional ou Espaço: lança uma transferência (saída do setor
--      antigo + entrada na central de destino abaixo). Nada se perde: o
--      saldo total de cada produto continua o mesmo.
--      >>> Central de destino: troque 'Almoxarifado' por 'Escritório' na
--          linha marcada com "DESTINO" se preferir. <<<
--   4. Aplica as regras novas (NOT VALID: valem para todo lançamento novo,
--      sem reprovar o histórico antigo):
--        • setor (estoque) só pode ser Escritório ou Almoxarifado;
--        • toda saída que não seja transferência exige setor_consumo.
--
-- As saídas antigas não têm setor de consumo — aparecem como "Não
-- informado" nos gráficos de consumo por setor. Se souber o setor de
-- alguma delas, preencha depois, por exemplo:
--   update public.movimentacoes_estoque set setor_consumo = 'Comercial'
--    where id = '<id da saída>';
--
-- Faça um backup/export de movimentacoes_estoque antes de rodar.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Colunas novas (as regras saem do caminho até o passo 4: UPDATE em
--    linha antiga também é checado por constraint NOT VALID).
-- ---------------------------------------------------------------------
alter table public.movimentacoes_estoque add column if not exists setor_consumo text;
alter table public.movimentacoes_estoque add column if not exists transferencia boolean not null default false;
alter table public.movimentacoes_estoque drop constraint if exists movimentacoes_estoque_setor_valido;
alter table public.movimentacoes_estoque drop constraint if exists movimentacoes_estoque_consumo_valido;

-- ---------------------------------------------------------------------
-- 2. Transferências antigas (o app gravava "... Transferência X → Y").
-- ---------------------------------------------------------------------
update public.movimentacoes_estoque
   set transferencia = true, setor_consumo = null
 where tipo in ('entrada', 'saida')
   and observacao like '%Transferência % → %';

-- ---------------------------------------------------------------------
-- 3. Saldo em setor antigo volta para o estoque central.
-- ---------------------------------------------------------------------
with saldos as (
  select produto_id, setor,
         sum(case when tipo = 'saida' then -quantidade else quantidade end) as saldo
    from public.movimentacoes_estoque
   where setor not in ('Escritório', 'Almoxarifado')
   group by produto_id, setor
  having sum(case when tipo = 'saida' then -quantidade else quantidade end) > 0
),
destino as (
  select 'Almoxarifado'::text as central   -- DESTINO
)
insert into public.movimentacoes_estoque (produto_id, tipo, setor, setor_consumo, transferencia, quantidade, observacao, usuario_email)
select s.produto_id, x.tipo, case when x.tipo = 'saida' then s.setor else d.central end, null, true, s.saldo,
       format('Migração para estoques centrais · Transferência %s → %s', s.setor, d.central), null
  from saldos s
 cross join destino d
 cross join (values ('saida'), ('entrada')) as x(tipo)
 order by s.produto_id, x.tipo desc;   -- saída antes da entrada

-- ---------------------------------------------------------------------
-- 4. Regras novas (iguais às de schema_estoque.sql).
-- ---------------------------------------------------------------------
alter table public.movimentacoes_estoque
  add constraint movimentacoes_estoque_setor_valido
  check (setor in ('Escritório', 'Almoxarifado')) not valid;

alter table public.movimentacoes_estoque
  add constraint movimentacoes_estoque_consumo_valido
  check (
    (tipo = 'saida' or setor_consumo is null)
    and (tipo <> 'saida' or transferencia or nullif(btrim(setor_consumo), '') is not null)
    and (not transferencia or (tipo <> 'origem' and setor_consumo is null))
  ) not valid;

create index if not exists movimentacoes_estoque_consumo_idx
  on public.movimentacoes_estoque (setor_consumo, created_at desc) where tipo = 'saida';

commit;

-- A API (PostgREST) passa a enxergar setor_consumo/transferencia na hora.
notify pgrst, 'reload schema';

-- Conferência: nenhum produto deve ter saldo fora das centrais.
select p.nome, v.setor, v.saldo
  from public.vw_estoque_saldo v
  join public.cadastro_de_produtos p on p.id = v.produto_id
 where v.setor not in ('Escritório', 'Almoxarifado') and v.saldo <> 0;
