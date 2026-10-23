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
-- quem aprovou e quando. As linhas da nota NÃO são ligadas aos produtos do
-- estoque: a Entrada continua escolhendo a nota manualmente.
--
--   notas_fiscais_itens  → linhas de produto da nota (descrição, código,
--                          NCM, CFOP, unidade, quantidade e valores)
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

-- ---------------------------------------------------------------------
-- Grava a nota e as linhas numa única transação (aprovação da etapa 3).
--   p_id    null = nota nova; senão, a nota a alterar (as linhas são trocadas)
--   p_nota  campos da nota (arquivo_* só são trocados quando vêm no JSON)
--   p_itens [{ ordem, codigo, descricao, ncm, cfop, unidade, quantidade,
--             valor_unitario, valor_total }]
-- Roda com as permissões de quem chama (RLS das duas tabelas vale).
-- ---------------------------------------------------------------------
create or replace function public.estoque_nf_salvar(p_id uuid, p_nota jsonb, p_itens jsonb)
returns uuid language plpgsql as $$
declare
  v_id uuid;
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

  insert into public.notas_fiscais_itens (nota_id, ordem, codigo, descricao, ncm, cfop, unidade, quantidade, valor_unitario, valor_total)
  select v_id, coalesce(x.ordem, row_number() over ())::int, nullif(btrim(x.codigo), ''), btrim(x.descricao), nullif(btrim(x.ncm), ''),
         nullif(btrim(x.cfop), ''), nullif(btrim(x.unidade), ''), x.quantidade, x.valor_unitario, x.valor_total
    from jsonb_to_recordset(coalesce(p_itens, '[]'::jsonb))
         as x(ordem int, codigo text, descricao text, ncm text, cfop text, unidade text, quantidade numeric, valor_unitario numeric, valor_total numeric)
   where nullif(btrim(x.descricao), '') is not null;

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

-- O cadastro novo exige o PDF: o bucket volta a aceitar só PDF.
update storage.buckets set allowed_mime_types = array['application/pdf'] where id = 'notas_fiscais';

notify pgrst, 'reload schema';

-- Conferência: as 4 regras das linhas da nota e a função de gravação.
select policyname, cmd from pg_policies where schemaname = 'public' and tablename = 'notas_fiscais_itens' order by cmd;
select proname from pg_proc where proname = 'estoque_nf_salvar';
