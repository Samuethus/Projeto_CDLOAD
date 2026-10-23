-- =====================================================================
-- CDLoad · Estoque — nome dos produtos igual ao da nota fiscal (UMA ÚNICA VEZ)
-- Parte 1 de 2: PRÉVIA — só consulta, não altera nada.
--
-- Os produtos cadastrados à mão (antes do cadastro pela nota) podem ter um
-- nome diferente da descrição do produto na nota fiscal. Este ajuste troca o
-- nome do cadastro pela descrição da nota, para que a mesma mercadoria não
-- apareça com dois nomes. O produto (id, código de barras, saldo, preço e
-- lançamentos) continua o mesmo: só o nome muda.
--
-- Como o produto é ligado à linha da nota, nesta ordem de prioridade:
--   1. linha da nota ligada ao produto (entrada automática ou cadastro pela nota);
--   2. Código EAN Comercial da linha igual ao código de barras do produto;
--   3. entrada manual vinculada à nota: a única linha da nota com a mesma
--      quantidade (e o mesmo preço unitário, quando os dois existem).
-- Produto ligado a mais de uma linha: vale a regra de maior prioridade e,
-- nela, a nota mais recente.
--
-- Antes de rodar: notas gravadas antes da coluna "Código EAN Comercial" têm as
-- linhas sem EAN. Abra cada uma em "Editar" (o PDF guardado é relido e os EAN
-- são preenchidos), vá à etapa 3 e aprove — assim a regra 2 alcança essas notas.
--
-- Rode esta prévia, confira a lista e depois rode
-- ajuste_nomes_produtos_nf_2_aplicar.sql.
-- =====================================================================

with linhas as (
  select i.id as linha_id, i.nota_id, i.produto_id,
         nullif(regexp_replace(coalesce(i.ean, ''), '\D', '', 'g'), '') as ean,
         upper(regexp_replace(btrim(i.descricao), '\s+', ' ', 'g'))     as nome_nf,
         i.quantidade, i.valor_unitario,
         n.numero, n.fornecedor, n.data_emissao, coalesce(n.aprovada_em, n.created_at) as gravada_em
    from public.notas_fiscais_itens i
    join public.notas_fiscais n on n.id = i.nota_id
   where btrim(i.descricao) <> ''
),
manual as (
  select m.id as mov_id, m.produto_id, l.nome_nf, l.numero, l.fornecedor, l.data_emissao, l.gravada_em
    from public.movimentacoes_estoque m
    join linhas l on l.nota_id = m.nota_fiscal_id
                 and l.quantidade = m.quantidade
                 and (l.valor_unitario is null or m.preco_unitario is null
                      or round(l.valor_unitario, 2) = round(m.preco_unitario, 2))
                 and (l.produto_id is null or l.produto_id = m.produto_id)
   where m.tipo = 'entrada' and m.nota_fiscal_id is not null
),
candidatos as (
  select p.id as produto_id, 1 as regra, l.nome_nf, l.numero, l.fornecedor, l.data_emissao, l.gravada_em
    from public.cadastro_de_produtos p join linhas l on l.produto_id = p.id
  union all
  select p.id, 2, l.nome_nf, l.numero, l.fornecedor, l.data_emissao, l.gravada_em
    from public.cadastro_de_produtos p join linhas l on l.ean = regexp_replace(p.codigo_barras, '\D', '', 'g')
  union all
  select produto_id, 3, nome_nf, numero, fornecedor, data_emissao, gravada_em
    from (select mn.*, count(*) over (partition by mn.mov_id) as opcoes from manual mn) x
   where opcoes = 1
),
escolha as (
  select distinct on (produto_id) *
    from candidatos
   order by produto_id, regra, data_emissao desc, gravada_em desc
)
select p.codigo_barras,
       p.nome                                     as nome_atual,
       e.nome_nf                                  as nome_novo,
       case e.regra when 1 then 'linha ligada ao produto'
                    when 2 then 'mesmo EAN'
                    else 'entrada manual da nota (confira)' end as como_ligou,
       'NF ' || e.numero || ' · ' || e.fornecedor || ' · ' || to_char(e.data_emissao, 'DD/MM/YYYY') as nota,
       (count(*) over (partition by e.nome_nf) > 1
        or exists (select 1 from public.cadastro_de_produtos o
                    where o.id <> p.id and o.nome = e.nome_nf
                      and o.id not in (select produto_id from escolha))) as nome_repetido
  from escolha e
  join public.cadastro_de_produtos p on p.id = e.produto_id
 where p.nome is distinct from e.nome_nf
 order by nome_repetido desc, e.regra desc, p.nome;
-- nome_repetido = true: outro produto (outro código de barras) terá o mesmo nome — pode ser
-- a mesma mercadoria cadastrada duas vezes. Confira esses antes de aplicar.
