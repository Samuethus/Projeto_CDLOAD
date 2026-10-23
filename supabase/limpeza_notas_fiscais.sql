-- =====================================================================
-- CDLoad · Estoque — APAGA TODAS AS NOTAS FISCAIS (rodar UMA ÚNICA VEZ)
--
-- Limpa o cadastro de notas para recomeçar com o novo fluxo (leitura do PDF).
-- NÃO mexe nos produtos nem nos lançamentos de origem, entrada e saída:
-- só desfaz o vínculo da entrada com a nota e apaga as notas e suas linhas.
-- Quantidades, saldos, preços, custos das saídas e datas de edição ficam
-- exatamente como estão (os gatilhos ficam desligados durante a limpeza).
--
-- Rode DEPOIS de schema_estoque_precos_nf.sql e schema_estoque_nf_itens.sql.
-- ATENÇÃO: não rode de novo depois de cadastrar notas novas — elas seriam
-- apagadas também.
--
-- Os arquivos (PDF) ficam no Storage: depois de rodar este script, apague-os
-- em Supabase > Storage > notas_fiscais > selecione tudo > Delete (ou "Empty
-- bucket"). O Supabase não permite apagar arquivos do Storage por SQL.
-- =====================================================================

-- Antes: quantas notas, linhas e entradas vinculadas existem.
select (select count(*) from public.notas_fiscais)        as notas,
       (select count(*) from public.notas_fiscais_itens)  as linhas_de_produto,
       (select count(*) from public.movimentacoes_estoque where nota_fiscal_id is not null) as entradas_vinculadas,
       (select count(*) from public.movimentacoes_estoque where nota_fiscal_path is not null) as anexos_antigos_nas_entradas;

-- Desfaz o vínculo das entradas (e limpa o anexo antigo, se ainda houver)
-- sem disparar os gatilhos de ajuste e de recálculo de custo.
alter table public.movimentacoes_estoque disable trigger user;
update public.movimentacoes_estoque
   set nota_fiscal_id = null, nota_fiscal_nome = null, nota_fiscal_path = null, nota_fiscal_bytes = null
 where nota_fiscal_id is not null or nota_fiscal_path is not null or nota_fiscal_nome is not null;
alter table public.movimentacoes_estoque enable trigger user;

-- Apaga as notas (as linhas de produto saem em cascata).
delete from public.notas_fiscais;

-- Depois: tudo deve voltar 0, e a quantidade de lançamentos não muda.
select (select count(*) from public.notas_fiscais)        as notas,
       (select count(*) from public.notas_fiscais_itens)  as linhas_de_produto,
       (select count(*) from public.movimentacoes_estoque where nota_fiscal_id is not null) as entradas_vinculadas,
       (select count(*) from public.movimentacoes_estoque) as lancamentos_mantidos;
