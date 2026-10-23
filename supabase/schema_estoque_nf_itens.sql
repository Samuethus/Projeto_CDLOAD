-- =====================================================================
-- CDLoad · Estoque — notas fiscais lidas do PDF, com as linhas de produto
--
-- Rode em Supabase > SQL Editor DEPOIS de schema_estoque_precos_nf.sql
-- (passo 23 do LEIA-ME). É idempotente.
--
-- O cadastro da nota ("+ Nota Fiscal") passa a ser em 3 etapas:
--   1. escolher o tipo do PDF (DANFE ou NF-e da consulta do portal) e anexá-lo
--      — o app lê o texto do PDF no navegador;
--   2. conferir os dados da nota, já preenchidos pela leitura;
--   3. conferir e aprovar as linhas de produto da nota.
-- A aprovação grava a nota e as linhas juntas (estoque_nf_salvar) e registra
-- quem aprovou e quando. Na etapa 3, a coluna "Entrada" marca as linhas que
-- viram entrada no estoque ao aprovar (escolhendo o produto do estoque de
-- cada uma); as demais linhas não são ligadas a produto. A entrada manual
-- (escolhendo a nota na Entrada) continua.
--
--   notas_fiscais_itens  → linhas de produto da nota (descrição, código EAN
--                          comercial, código do fornecedor, NCM, CFOP,
--                          unidade, quantidade e valores) — os dados oficiais,
--                          exatamente como estão na nota
--   notas_fiscais_itens_ajuste → ajuste de lançamento da linha (Un. UN1 +
--                          Rateio: quantidade e valor unitário por unidade),
--                          usado na entrada no estoque; não altera a linha oficial
--   notas_fiscais        → + tipo_arquivo, lida_do_pdf, aprovada_em, aprovada_por
--
-- Acesso: igual ao da nota — quem tem a seção Estoque lê e cadastra (o
-- restrito não); editar e excluir é de quem pode editar o Estoque.
-- =====================================================================

alter table public.notas_fiscais add column if not exists lida_do_pdf  boolean not null default false;
alter table public.notas_fiscais add column if not exists aprovada_em  timestamptz;
alter table public.notas_fiscais add column if not exists aprovada_por text;
-- Tipo do PDF escolhido na etapa 1: 'danfe' (documento do fornecedor) ou 'nfe' (consulta do portal da NF-e).
alter table public.notas_fiscais add column if not exists tipo_arquivo text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'notas_fiscais_tipo_arquivo_valido') then
    alter table public.notas_fiscais
      add constraint notas_fiscais_tipo_arquivo_valido check (tipo_arquivo is null or tipo_arquivo in ('danfe', 'nfe'));
  end if;
end $$;
comment on column public.notas_fiscais.tipo_arquivo is 'Tipo do PDF: danfe (documento do fornecedor) ou nfe (consulta do portal da NF-e).';

comment on column public.notas_fiscais.lida_do_pdf is 'Dados preenchidos pela leitura automática do PDF (conferidos pelo usuário).';
comment on column public.notas_fiscais.aprovada_em is 'Quando o usuário conferiu e aprovou a nota e as linhas de produto.';

create table if not exists public.notas_fiscais_itens (
  id              uuid primary key default gen_random_uuid(),
  nota_id         uuid not null references public.notas_fiscais(id) on delete cascade,
  ordem           integer not null,
  codigo          text,
  descricao       text not null,
  ncm             text,
  cfop            text,
  unidade         text,
  quantidade      numeric(14,4) check (quantidade is null or quantidade >= 0),
  valor_unitario  numeric(14,4) check (valor_unitario is null or valor_unitario >= 0),
  valor_total     numeric(14,2) check (valor_total is null or valor_total >= 0),
  created_at      timestamptz not null default now()
);
create index if not exists notas_fiscais_itens_nota_idx on public.notas_fiscais_itens (nota_id, ordem);

-- Entrada automática pela nota (coluna "Entrada" da etapa 3): a linha marcada aponta para o produto do
-- estoque e, depois de aprovada, para a entrada lançada. A entrada manual continua existindo.
alter table public.notas_fiscais_itens add column if not exists produto_id uuid
  references public.cadastro_de_produtos(id) on delete set null;
alter table public.notas_fiscais_itens add column if not exists entrada_aprovada boolean not null default false;
alter table public.notas_fiscais_itens add column if not exists movimentacao_id uuid
  references public.movimentacoes_estoque(id) on delete set null;
comment on column public.notas_fiscais_itens.entrada_aprovada is 'Linha aprovada para entrada automática no estoque (coluna Entrada da etapa 3).';
comment on column public.notas_fiscais_itens.movimentacao_id is 'Entrada lançada automaticamente por esta linha.';
-- Código EAN Comercial (GTIN) do produto na nota — a coluna "Código EAN Comercial" da etapa 3.
-- `codigo` continua guardando o código do produto no fornecedor.
alter table public.notas_fiscais_itens add column if not exists ean text;
comment on column public.notas_fiscais_itens.ean is 'Código EAN Comercial (GTIN) do produto na nota.';
-- Coluna "Cadastro" da etapa 3: produto que não existia no estoque (nenhum código de barras igual ao EAN)
-- e foi cadastrado pela linha ao aprovar a nota.
alter table public.notas_fiscais_itens add column if not exists cadastro_pela_nota boolean not null default false;
comment on column public.notas_fiscais_itens.cadastro_pela_nota is 'Produto cadastrado no estoque por esta linha (coluna Cadastro da etapa 3).';
-- ---------------------------------------------------------------------
-- Ajustes de lançamento (colunas Un. e Rateio da etapa 3), separados dos
-- dados oficiais da nota. notas_fiscais_itens guarda a linha exatamente como
-- está na nota fiscal (unidade, quantidade, valor unitário e total); o ajuste
-- fica em notas_fiscais_itens_ajuste e é o que vai para a entrada no estoque.
-- Assim as análises das notas usam sempre os valores oficiais.
--   UN1 com rateio N: quantidade = quantidade da nota × N;
--                     valor unitário = valor total da linha ÷ quantidade.
-- Linha sem ajuste = lançada como veio na nota (PC1).
-- ---------------------------------------------------------------------
create table if not exists public.notas_fiscais_itens_ajuste (
  item_id         uuid primary key references public.notas_fiscais_itens(id) on delete cascade,
  nota_id         uuid not null references public.notas_fiscais(id) on delete cascade,
  unidade         text not null default 'UN1' check (unidade in ('PC1', 'UN1')),
  rateio          numeric(14,4) not null check (rateio > 0),
  quantidade      numeric(14,4) not null check (quantidade >= 0),
  valor_unitario  numeric(14,4) check (valor_unitario is null or valor_unitario >= 0),
  ajustado_em     timestamptz not null default now(),
  ajustado_por    text default public.estoque_email_sessao()
);
create index if not exists notas_fiscais_itens_ajuste_nota_idx on public.notas_fiscais_itens_ajuste (nota_id);
comment on table public.notas_fiscais_itens_ajuste is 'Ajuste de lançamento da linha da nota (Un. UN1 + Rateio). A linha oficial fica intacta em notas_fiscais_itens.';

-- Migração: a primeira versão do Rateio gravava o ajuste na própria linha (coluna rateio, com a quantidade e o
-- valor unitário já por unidade). O ajuste passa para a tabela acima e a linha volta aos valores da nota.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'notas_fiscais_itens' and column_name = 'rateio') then
    insert into public.notas_fiscais_itens_ajuste (item_id, nota_id, unidade, rateio, quantidade, valor_unitario)
    select i.id, i.nota_id, 'UN1', i.rateio, i.quantidade, i.valor_unitario
      from public.notas_fiscais_itens i
     where i.rateio > 0
    on conflict (item_id) do nothing;
    update public.notas_fiscais_itens i
       set quantidade     = round(i.quantidade / i.rateio, 4),
           valor_unitario = case when i.quantidade > 0
                                 then round(coalesce(i.valor_total, i.valor_unitario * i.quantidade) / (i.quantidade / i.rateio), 4) end,
           unidade        = case when i.unidade = 'UN1' then 'PC1' else i.unidade end
     where i.rateio > 0;
    alter table public.notas_fiscais_itens drop column rateio;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Grava a nota e as linhas numa única transação (aprovação da etapa 3).
--   p_id    null = nota nova; senão, a nota a alterar (as linhas são trocadas)
--   p_nota  campos da nota (arquivo_* só são trocados quando vêm no JSON)
--   p_itens [{ ordem, codigo, ean, descricao, ncm, cfop, unidade, quantidade,
--             valor_unitario, valor_total, produto_id, lancar_entrada,
--             movimentacao_id, setor, cadastrar_produto, unidade_cadastro,
--             cadastro_pela_nota, lanc_unidade, lanc_rateio, lanc_quantidade,
--             lanc_valor_unitario }]
-- unidade/quantidade/valor_unitario/valor_total = dados oficiais da nota.
-- lanc_* = ajuste de lançamento (UN1 + Rateio): gravado em
-- notas_fiscais_itens_ajuste e usado na entrada e no cadastro do produto.
-- Linha com cadastrar_produto e EAN: se nenhum produto tem esse código de
-- barras, cadastra o produto (EAN, descrição, unidade_cadastro e preço da
-- linha); se já existe, usa o existente. A entrada da linha vai para ele.
-- Linha com lancar_entrada e ainda sem movimentacao_id vira uma ENTRADA no
-- estoque (produto_id, quantidade da linha, preço = valor unitário da linha,
-- vinculada à nota), lançada agora — na data do cadastro da nota. O preço
-- praticado segue a regra de sempre: preço diferente do cadastro atualiza o
-- produto e o saldo existente fica no preço anterior (gatilhos de
-- schema_estoque_precos_nf.sql). Linha já lançada mantém a entrada (não
-- duplica ao editar a nota).
-- Roda com as permissões de quem chama (RLS das tabelas vale).
-- ---------------------------------------------------------------------
create or replace function public.estoque_nf_salvar(p_id uuid, p_nota jsonb, p_itens jsonb)
returns uuid language plpgsql as $$
declare
  v_id   uuid;
  v_mov  uuid;
  v_prod uuid;
  v_cad  boolean;
  v_item uuid;
  v_qtd  numeric;   -- quantidade e preço do lançamento: os do ajuste (UN1 + Rateio) ou os da nota
  v_vu   numeric;
  x      record;
begin
  if p_id is null then
    insert into public.notas_fiscais (numero, serie, chave_acesso, fornecedor, fornecedor_cnpj, data_emissao, valor_total, observacao,
                                      arquivo_nome, arquivo_path, arquivo_bytes, tipo_arquivo, lida_do_pdf, usuario_email, aprovada_em, aprovada_por)
    values (p_nota->>'numero', nullif(p_nota->>'serie', ''), nullif(p_nota->>'chave_acesso', ''), p_nota->>'fornecedor',
            nullif(p_nota->>'fornecedor_cnpj', ''), (p_nota->>'data_emissao')::date, (p_nota->>'valor_total')::numeric,
            nullif(p_nota->>'observacao', ''), p_nota->>'arquivo_nome', p_nota->>'arquivo_path', (p_nota->>'arquivo_bytes')::bigint,
            nullif(p_nota->>'tipo_arquivo', ''), coalesce((p_nota->>'lida_do_pdf')::boolean, false), p_nota->>'usuario_email', now(), public.estoque_email_sessao())
    returning id into v_id;
  else
    update public.notas_fiscais set
           numero          = p_nota->>'numero',
           serie           = nullif(p_nota->>'serie', ''),
           chave_acesso    = nullif(p_nota->>'chave_acesso', ''),
           fornecedor      = p_nota->>'fornecedor',
           fornecedor_cnpj = nullif(p_nota->>'fornecedor_cnpj', ''),
           data_emissao    = (p_nota->>'data_emissao')::date,
           valor_total     = (p_nota->>'valor_total')::numeric,
           observacao      = nullif(p_nota->>'observacao', ''),
           arquivo_nome    = case when p_nota ? 'arquivo_path' then p_nota->>'arquivo_nome' else arquivo_nome end,
           arquivo_path    = case when p_nota ? 'arquivo_path' then p_nota->>'arquivo_path' else arquivo_path end,
           arquivo_bytes   = case when p_nota ? 'arquivo_path' then (p_nota->>'arquivo_bytes')::bigint else arquivo_bytes end,
           tipo_arquivo    = coalesce(nullif(p_nota->>'tipo_arquivo', ''), tipo_arquivo),
           lida_do_pdf     = coalesce((p_nota->>'lida_do_pdf')::boolean, lida_do_pdf),
           aprovada_em     = now(),
           aprovada_por    = public.estoque_email_sessao()
     where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Nota fiscal não encontrada ou sem permissão de edição.' using errcode = '42501';
    end if;
    delete from public.notas_fiscais_itens where nota_id = v_id;
  end if;

  for x in select *
             from jsonb_to_recordset(coalesce(p_itens, '[]'::jsonb))
                  as r(ordem int, codigo text, ean text, descricao text, ncm text, cfop text, unidade text, quantidade numeric, valor_unitario numeric,
                       valor_total numeric, produto_id uuid, lancar_entrada boolean, movimentacao_id uuid, setor text,
                       cadastrar_produto boolean, unidade_cadastro text, cadastro_pela_nota boolean,
                       lanc_unidade text, lanc_rateio numeric, lanc_quantidade numeric, lanc_valor_unitario numeric)
            where nullif(btrim(r.descricao), '') is not null
  loop
    v_mov  := x.movimentacao_id;
    v_prod := x.produto_id;
    v_cad  := coalesce(x.cadastro_pela_nota, false);
    v_qtd  := case when x.lanc_rateio > 0 then x.lanc_quantidade else x.quantidade end;
    v_vu   := case when x.lanc_rateio > 0 then x.lanc_valor_unitario else x.valor_unitario end;
    -- Cadastro pela nota: o produto com este EAN (já existente ou cadastrado agora).
    if coalesce(x.cadastrar_produto, false) and nullif(btrim(x.ean), '') is not null then
      select id into v_prod from public.cadastro_de_produtos where codigo_barras = btrim(x.ean);
      if v_prod is null then
        insert into public.cadastro_de_produtos (codigo_barras, nome, unidade, estoque_minimo, preco_custo, descricao, ativo)
        values (btrim(x.ean), btrim(x.descricao), coalesce(nullif(btrim(x.unidade_cadastro), ''), 'UN'), 0, round(v_vu, 2),
                left(format('Cadastrado pela NF %s (%s)', p_nota->>'numero', p_nota->>'fornecedor'), 300), true)
        returning id into v_prod;
        v_cad := true;
      end if;
    end if;
    if v_mov is null and coalesce(x.lancar_entrada, false) then
      if v_prod is null then
        raise exception 'Linha % (%): escolha o produto do estoque para lançar a entrada.', x.ordem, btrim(x.descricao) using errcode = 'check_violation';
      end if;
      if coalesce(v_qtd, 0) <= 0 then
        raise exception 'Linha % (%): a quantidade da entrada precisa ser maior que zero.', x.ordem, btrim(x.descricao) using errcode = 'check_violation';
      end if;
      insert into public.movimentacoes_estoque (produto_id, tipo, setor, quantidade, preco_unitario, nota_fiscal_id, observacao, usuario_email)
      values (v_prod, 'entrada', coalesce(nullif(btrim(x.setor), ''), 'Almoxarifado'), v_qtd, v_vu, v_id,
              left(format('Entrada automática · NF %s · linha %s: %s%s', p_nota->>'numero', x.ordem, btrim(x.descricao),
                          case when x.lanc_rateio > 0 then format(' (UN1 · rateio %s por pacote)', rtrim(rtrim(to_char(x.lanc_rateio, 'FM9999999990.9999'), '0'), '.')) else '' end), 300),
              auth.jwt() ->> 'email')
      returning id into v_mov;
    end if;
    -- Linha oficial: exatamente como está na nota.
    insert into public.notas_fiscais_itens (nota_id, ordem, codigo, ean, descricao, ncm, cfop, unidade, quantidade, valor_unitario, valor_total,
                                            produto_id, entrada_aprovada, movimentacao_id, cadastro_pela_nota)
    values (v_id, coalesce(x.ordem, 0), nullif(btrim(x.codigo), ''), nullif(btrim(x.ean), ''), btrim(x.descricao), nullif(btrim(x.ncm), ''), nullif(btrim(x.cfop), ''),
            nullif(btrim(x.unidade), ''), x.quantidade, x.valor_unitario, x.valor_total,
            v_prod, coalesce(x.lancar_entrada, false) or v_mov is not null, v_mov, v_cad)
    returning id into v_item;
    -- Ajuste de lançamento (UN1 + Rateio), à parte.
    if x.lanc_rateio > 0 then
      insert into public.notas_fiscais_itens_ajuste (item_id, nota_id, unidade, rateio, quantidade, valor_unitario)
      values (v_item, v_id, coalesce(nullif(btrim(x.lanc_unidade), ''), 'UN1'), x.lanc_rateio, coalesce(x.lanc_quantidade, 0), x.lanc_valor_unitario);
    end if;
  end loop;

  return v_id;
end;
$$;

revoke all on function public.estoque_nf_salvar(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.estoque_nf_salvar(uuid, jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Acesso (RLS)
-- ---------------------------------------------------------------------
alter table public.notas_fiscais_itens enable row level security;
revoke all on public.notas_fiscais_itens from anon;
grant select, insert, update, delete on public.notas_fiscais_itens to authenticated;

drop policy if exists nf_itens_select on public.notas_fiscais_itens;
drop policy if exists nf_itens_insert on public.notas_fiscais_itens;
drop policy if exists nf_itens_update on public.notas_fiscais_itens;
drop policy if exists nf_itens_delete on public.notas_fiscais_itens;
create policy nf_itens_select on public.notas_fiscais_itens for select to authenticated using (public.cdl_secao('estoque'));
create policy nf_itens_insert on public.notas_fiscais_itens for insert to authenticated
  with check (public.cdl_secao('estoque') and not public.cdl_restrito());
create policy nf_itens_update on public.notas_fiscais_itens for update to authenticated
  using (public.cdl_pode_editar('estoque')) with check (public.cdl_pode_editar('estoque'));
create policy nf_itens_delete on public.notas_fiscais_itens for delete to authenticated
  using (public.cdl_pode_editar('estoque'));

-- Ajustes de lançamento: mesmo acesso das linhas da nota.
alter table public.notas_fiscais_itens_ajuste enable row level security;
revoke all on public.notas_fiscais_itens_ajuste from anon;
grant select, insert, update, delete on public.notas_fiscais_itens_ajuste to authenticated;
drop policy if exists nf_ajuste_select on public.notas_fiscais_itens_ajuste;
drop policy if exists nf_ajuste_insert on public.notas_fiscais_itens_ajuste;
drop policy if exists nf_ajuste_update on public.notas_fiscais_itens_ajuste;
drop policy if exists nf_ajuste_delete on public.notas_fiscais_itens_ajuste;
create policy nf_ajuste_select on public.notas_fiscais_itens_ajuste for select to authenticated using (public.cdl_secao('estoque'));
create policy nf_ajuste_insert on public.notas_fiscais_itens_ajuste for insert to authenticated
  with check (public.cdl_secao('estoque') and not public.cdl_restrito());
create policy nf_ajuste_update on public.notas_fiscais_itens_ajuste for update to authenticated
  using (public.cdl_pode_editar('estoque')) with check (public.cdl_pode_editar('estoque'));
create policy nf_ajuste_delete on public.notas_fiscais_itens_ajuste for delete to authenticated
  using (public.cdl_pode_editar('estoque'));

-- O cadastro novo exige o PDF: o bucket volta a aceitar só PDF.
update storage.buckets set allowed_mime_types = array['application/pdf'] where id = 'notas_fiscais';

notify pgrst, 'reload schema';

-- Conferência: as 4 regras das linhas da nota, as 4 dos ajustes e a função de gravação; e, por linha ajustada,
-- os dados oficiais da nota ao lado do ajuste de lançamento.
select tablename, policyname, cmd from pg_policies where schemaname = 'public' and tablename in ('notas_fiscais_itens', 'notas_fiscais_itens_ajuste') order by tablename, cmd;
select proname from pg_proc where proname = 'estoque_nf_salvar';
select n.numero as nf, i.ordem as linha, i.descricao, i.unidade as un_nota, i.quantidade as qtd_nota, i.valor_unitario as vu_nota, i.valor_total,
       a.unidade as un_lancamento, a.rateio, a.quantidade as qtd_lancamento, a.valor_unitario as vu_lancamento
  from public.notas_fiscais_itens_ajuste a
  join public.notas_fiscais_itens i on i.id = a.item_id
  join public.notas_fiscais n on n.id = i.nota_id
 order by n.numero, i.ordem;
