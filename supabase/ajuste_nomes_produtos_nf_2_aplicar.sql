-- =====================================================================
-- CDLoad · Estoque — nome dos produtos igual ao da nota fiscal (UMA ÚNICA VEZ)
-- Parte 2 de 2: APLICA o ajuste conferido em ajuste_nomes_produtos_nf_1_previa.sql.
--
-- Troca o nome de cada produto ligado a uma linha de nota fiscal pela
-- descrição do produto na nota (mesmas regras e prioridade da prévia). Só o
-- nome muda: código de barras, saldo, preço, histórico de preços e
-- lançamentos ficam como estão.
--
-- O nome anterior de cada produto fica guardado em
-- public.estoque_ajuste_nomes_nf (sem acesso pelo app). Para desfazer:
--   update public.cadastro_de_produtos p set nome = a.nome_antigo
--     from public.estoque_ajuste_nomes_nf a where a.produto_id = p.id;
--
-- Depois de rodar, recarregue o CDLoad para ver os nomes novos.
-- Os novos cadastros já usam o nome da nota (cadastro pela nota na etapa 3).
-- =====================================================================

drop table if exists pg_temp._nomes_nf;
create temp table _nomes_nf as
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
  select m.id as mov_id, m.produto_id, l.*
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
select e.produto_id, p.nome as nome_antigo, e.nome_nf as nome_novo, e.regra,
       'NF ' || e.numero || ' · ' || e.fornecedor || ' · ' || to_char(e.data_emissao, 'DD/MM/YYYY') as nota
  from escolha e
  join public.cadastro_de_produtos p on p.id = e.produto_id
 where p.nome is distinct from e.nome_nf;

-- Guarda o nome anterior (tabela só para consulta/desfazer; o app não a lê).
create table if not exists public.estoque_ajuste_nomes_nf (
  produto_id   uuid primary key references public.cadastro_de_produtos(id) on delete cascade,
  nome_antigo  text not null,
  nome_novo    text not null,
  regra        int  not null,
  nota         text,
  ajustado_em  timestamptz not null default now()
);
alter table public.estoque_ajuste_nomes_nf enable row level security;
revoke all on public.estoque_ajuste_nomes_nf from anon, authenticated;

insert into public.estoque_ajuste_nomes_nf (produto_id, nome_antigo, nome_novo, regra, nota)
select produto_id, nome_antigo, nome_novo, regra, nota from _nomes_nf
on conflict (produto_id) do nothing;   -- rodado de novo: mantém o nome original da primeira vez

update public.cadastro_de_produtos p
   set nome = t.nome_novo
  from _nomes_nf t
 where t.produto_id = p.id;

-- Resultado: os produtos renomeados agora.
select p.codigo_barras, t.nome_antigo, p.nome as nome_atual,
       case t.regra when 1 then 'linha ligada ao produto'
                    when 2 then 'mesmo EAN'
                    else 'entrada manual da nota' end as como_ligou,
       t.nota
  from _nomes_nf t
  join public.cadastro_de_produtos p on p.id = t.produto_id
 order by p.nome;
