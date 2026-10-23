-- =====================================================================
-- CDLoad · Estoque — preço praticado, histórico de preços e notas fiscais
--
-- Rode uma vez em Supabase > SQL Editor, num banco que já tem o Estoque,
-- DEPOIS de schema_usuarios_restricao.sql e schema_usuarios_edicao.sql
-- (usa cdl_restrito() e cdl_pode_editar()). É idempotente. Se
-- schema_estoque_editar_movimentacao.sql for rodado de novo, rode este outra vez.
--
-- 1. PREÇO PRATICADO (camadas, a mais antiga sai primeiro)
--    • Cada entrada/origem grava o preço da compra em `preco_unitario`: o
--      digitado na Entrada ou, sem ele, o preço atual do cadastro.
--    • Preço digitado na Entrada diferente do cadastro atualiza o produto
--      (`preco_custo` + `preco_atualizado_em` = data da entrada).
--    • Mudar o preço (no cadastro ou na Entrada) NÃO revaloriza o saldo que
--      já existe: ele continua com o preço anterior, e o histórico
--      (`estoque_precos`) registra o saldo restante e o valor dele nesse preço.
--      O preço novo só vale para o estoque que entrar a partir dali.
--    • Cada saída grava em `preco_unitario` o custo médio das camadas que
--      consumiu (as mais antigas primeiro). Dashboard e relatório usam esse
--      valor, então a variação de preço não distorce compras nem consumo.
--    • Ajustar ou remover um lançamento recalcula o custo das saídas do produto.
--
-- 2. NOME DO PRODUTO SEMPRE EM MAIÚSCULAS (gatilho no cadastro, vale para
--    qualquer usuário e qualquer caminho de gravação).
--
-- 3. NOTAS FISCAIS (`notas_fiscais`): cadastro próprio, com o arquivo
--    (PDF ou XML) no bucket privado "notas_fiscais". A Entrada deixa de
--    anexar arquivo e passa a apontar para uma nota (`nota_fiscal_id`).
--    Os PDFs já anexados às entradas viram notas fiscais aqui (fornecedor
--    "Não informado") e continuam vinculados à mesma entrada.
--
-- Acesso: quem tem a seção Estoque lê e cadastra nota; editar e excluir nota
-- é de quem pode editar o Estoque (Administrador ou usuário com Edição). O
-- usuário restrito não cadastra nota. O histórico de preços é só leitura
-- (gravado pelos gatilhos).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Colunas novas
-- ---------------------------------------------------------------------
alter table public.cadastro_de_produtos  add column if not exists preco_atualizado_em timestamptz;
alter table public.movimentacoes_estoque add column if not exists preco_unitario numeric(14,4)
  check (preco_unitario is null or preco_unitario >= 0);

comment on column public.cadastro_de_produtos.preco_atualizado_em is
  'Data da última mudança do preço de custo (no cadastro ou numa Entrada).';
comment on column public.movimentacoes_estoque.preco_unitario is
  'Entrada/origem: preço da compra. Saída: custo médio das camadas consumidas (as mais antigas primeiro), gravado pelo banco.';

-- ---------------------------------------------------------------------
-- 2. Notas fiscais
-- ---------------------------------------------------------------------
create table if not exists public.notas_fiscais (
  id               uuid primary key default gen_random_uuid(),
  numero           text not null,
  serie            text,
  chave_acesso     text,             -- 44 dígitos da NF-e (opcional)
  fornecedor       text not null,
  fornecedor_cnpj  text,             -- só dígitos (14)
  data_emissao     date not null,
  valor_total      numeric(14,2) check (valor_total is null or valor_total >= 0),
  observacao       text,
  arquivo_nome     text,
  arquivo_path     text unique,      -- caminho no bucket "notas_fiscais"
  arquivo_bytes    bigint,
  usuario_email    text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint notas_fiscais_chave_valida check (chave_acesso is null or chave_acesso ~ '^[0-9]{44}$'),
  constraint notas_fiscais_cnpj_valido  check (fornecedor_cnpj is null or fornecedor_cnpj ~ '^[0-9]{14}$'),
  constraint notas_fiscais_arquivo_valido check (arquivo_path is null or arquivo_nome is not null)
);

-- Uma NF é única pela chave de acesso e por emitente (CNPJ) + série + número.
create unique index if not exists notas_fiscais_chave_unica on public.notas_fiscais (chave_acesso) where chave_acesso is not null;
create unique index if not exists notas_fiscais_emitente_unica
  on public.notas_fiscais (fornecedor_cnpj, numero, coalesce(serie, '')) where fornecedor_cnpj is not null;
create index if not exists notas_fiscais_emissao_idx on public.notas_fiscais (data_emissao desc);

drop trigger if exists trg_notas_fiscais_updated_at on public.notas_fiscais;
create trigger trg_notas_fiscais_updated_at
  before update on public.notas_fiscais
  for each row execute function public.estoque_set_updated_at();

-- Vínculo da Entrada com a nota (só entrada de compra). Nota com entrada
-- vinculada não é excluída: desvincule ou ajuste a entrada antes.
alter table public.movimentacoes_estoque add column if not exists nota_fiscal_id uuid
  references public.notas_fiscais(id) on delete restrict;
create index if not exists movimentacoes_estoque_nf_idx on public.movimentacoes_estoque (nota_fiscal_id) where nota_fiscal_id is not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_nf_vinculo_valido') then
    alter table public.movimentacoes_estoque
      add constraint movimentacoes_estoque_nf_vinculo_valido
      check (nota_fiscal_id is null or (tipo = 'entrada' and not transferencia));
  end if;
end $$;

-- O bucket passa a aceitar também o XML da NF-e.
update storage.buckets
   set allowed_mime_types = array['application/pdf', 'application/xml', 'text/xml']
 where id = 'notas_fiscais';

-- ---------------------------------------------------------------------
-- 3. Histórico de preços
--    saldo_na_data × preco_anterior = valor do estoque que ficou no preço
--    anterior quando o preço mudou.
-- ---------------------------------------------------------------------
create table if not exists public.estoque_precos (
  id                   uuid primary key default gen_random_uuid(),
  produto_id           uuid not null references public.cadastro_de_produtos(id) on delete cascade,
  preco_anterior       numeric(14,2),
  preco_novo           numeric(14,2),
  origem               text not null check (origem in ('cadastro', 'entrada')),
  movimentacao_id      uuid references public.movimentacoes_estoque(id) on delete set null,
  saldo_na_data        numeric(14,3) not null default 0,
  valor_saldo_anterior numeric(14,2) generated always as (round(saldo_na_data * coalesce(preco_anterior, 0), 2)) stored,
  usuario_email        text,
  created_at           timestamptz not null default now()
);
create index if not exists estoque_precos_produto_idx on public.estoque_precos (produto_id, created_at desc);

-- ---------------------------------------------------------------------
-- 4. Funções e gatilhos
-- ---------------------------------------------------------------------
-- E-mail de quem está gravando (mesma leitura do estoque_valida_ajuste).
create or replace function public.estoque_email_sessao()
returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', current_user::text);
$$;

-- 4a. Cadastro: nome em maiúsculas e data da última mudança de preço.
--     Mudança vinda de uma Entrada usa a data da entrada (cdl.preco_data).
create or replace function public.estoque_produto_normaliza()
returns trigger language plpgsql as $$
begin
  new.nome := upper(btrim(new.nome));
  if tg_op = 'INSERT' then
    if new.preco_custo is not null then new.preco_atualizado_em := coalesce(new.preco_atualizado_em, now()); end if;
  elsif new.preco_custo is distinct from old.preco_custo then
    new.preco_atualizado_em := coalesce(nullif(current_setting('cdl.preco_data', true), '')::timestamptz, now());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_cadastro_de_produtos_normaliza on public.cadastro_de_produtos;
create trigger trg_cadastro_de_produtos_normaliza
  before insert or update on public.cadastro_de_produtos
  for each row execute function public.estoque_produto_normaliza();

-- 4b. Histórico: cada mudança de preço registra o saldo que ficou no preço anterior.
--     security definer: grava no histórico (sem policy de escrita) para qualquer usuário.
create or replace function public.estoque_produto_preco_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_mov   uuid := nullif(current_setting('cdl.preco_mov', true), '')::uuid;
  v_saldo numeric;
begin
  if tg_op = 'UPDATE' and new.preco_custo is not distinct from old.preco_custo then return null; end if;
  if tg_op = 'INSERT' and new.preco_custo is null then return null; end if;
  -- Saldo antes da mudança (sem a própria entrada que trouxe o preço novo).
  select coalesce(sum(case when tipo = 'saida' then -quantidade else quantidade end), 0)
    into v_saldo
    from public.movimentacoes_estoque
   where produto_id = new.id and id is distinct from v_mov;
  insert into public.estoque_precos (produto_id, preco_anterior, preco_novo, origem, movimentacao_id, saldo_na_data, usuario_email, created_at)
  values (new.id, case when tg_op = 'UPDATE' then old.preco_custo end, new.preco_custo,
          coalesce(nullif(current_setting('cdl.preco_origem', true), ''), 'cadastro'), v_mov, greatest(v_saldo, 0),
          public.estoque_email_sessao(), coalesce(new.preco_atualizado_em, now()));
  return null;
end;
$$;

drop trigger if exists trg_cadastro_de_produtos_preco_historico on public.cadastro_de_produtos;
create trigger trg_cadastro_de_produtos_preco_historico
  after insert or update on public.cadastro_de_produtos
  for each row execute function public.estoque_produto_preco_historico();

-- 4c. Entrada/origem sem preço digitado: usa o preço atual do cadastro.
--     Saída e transferência: o preço é do banco (custo das camadas), nunca do app.
create or replace function public.estoque_mov_preco_padrao()
returns trigger language plpgsql as $$
begin
  if new.transferencia or new.tipo = 'saida' then
    new.preco_unitario := null;
  elsif new.preco_unitario is null then
    select preco_custo into new.preco_unitario from public.cadastro_de_produtos where id = new.produto_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_movimentacoes_estoque_preco_padrao on public.movimentacoes_estoque;
create trigger trg_movimentacoes_estoque_preco_padrao
  before insert on public.movimentacoes_estoque
  for each row execute function public.estoque_mov_preco_padrao();

-- 4d. Custo das saídas de um produto: percorre os lançamentos em ordem e
--     consome as camadas de compra da mais antiga para a mais nova.
--     Histórico incompleto (saída sem camada que a cubra) usa o último preço
--     de compra conhecido, ou o do cadastro.
create or replace function public.estoque_recalcula_custos(p_produto uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r        record;
  q_qtd    numeric[] := '{}';
  q_preco  numeric[] := '{}';
  i        int := 1;
  v_falta  numeric;
  v_usa    numeric;
  v_custo  numeric;
  v_ultimo numeric;
  v_padrao numeric;
begin
  -- Marca o recálculo: os gatilhos de ajuste e de recálculo ignoram as
  -- atualizações de preço feitas aqui (sem carimbo de edição nem recursão).
  perform set_config('cdl.estoque_recalculo', '1', true);
  select preco_custo into v_padrao from public.cadastro_de_produtos where id = p_produto;
  for r in select id, tipo, quantidade, preco_unitario
             from public.movimentacoes_estoque
            where produto_id = p_produto and not transferencia
            order by created_at, id loop
    if r.tipo <> 'saida' then
      q_qtd := q_qtd || r.quantidade;
      q_preco := q_preco || coalesce(r.preco_unitario, v_padrao, 0);
      v_ultimo := coalesce(r.preco_unitario, v_padrao, 0);
    else
      v_falta := r.quantidade;
      v_custo := 0;
      while v_falta > 0 and i <= coalesce(array_length(q_qtd, 1), 0) loop
        v_usa := least(v_falta, q_qtd[i]);
        v_custo := v_custo + v_usa * q_preco[i];
        q_qtd[i] := q_qtd[i] - v_usa;
        v_falta := v_falta - v_usa;
        if q_qtd[i] <= 0 then i := i + 1; end if;
      end loop;
      if v_falta > 0 then v_custo := v_custo + v_falta * coalesce(v_ultimo, v_padrao, 0); end if;
      v_custo := round(v_custo / nullif(r.quantidade, 0), 4);
      if r.preco_unitario is distinct from v_custo then
        update public.movimentacoes_estoque set preco_unitario = v_custo where id = r.id;
      end if;
    end if;
  end loop;
  perform set_config('cdl.estoque_recalculo', '', true);
end;
$$;

revoke all on function public.estoque_recalcula_custos(uuid) from public, anon, authenticated;

-- 4e. Depois de gravar um lançamento: a Entrada com preço novo atualiza o
--     cadastro (com a data da entrada) e o custo das saídas é recalculado.
create or replace function public.estoque_mov_custos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('cdl.estoque_recalculo', true) = '1' then return null; end if;
  -- Remoção em cascata do produto: não há o que recalcular.
  if tg_op = 'DELETE' and not exists (select 1 from public.cadastro_de_produtos where id = old.produto_id) then return null; end if;

  if tg_op = 'INSERT' and new.tipo = 'entrada' and not new.transferencia and new.preco_unitario is not null then
    perform set_config('cdl.preco_origem', 'entrada', true);
    perform set_config('cdl.preco_mov', new.id::text, true);
    perform set_config('cdl.preco_data', new.created_at::text, true);
    update public.cadastro_de_produtos
       set preco_custo = round(new.preco_unitario, 2)
     where id = new.produto_id and preco_custo is distinct from round(new.preco_unitario, 2);
    perform set_config('cdl.preco_origem', '', true);
    perform set_config('cdl.preco_mov', '', true);
    perform set_config('cdl.preco_data', '', true);
  end if;

  if tg_op <> 'INSERT' then perform public.estoque_recalcula_custos(old.produto_id); end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.produto_id <> old.produto_id) then
    perform public.estoque_recalcula_custos(new.produto_id);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_movimentacoes_estoque_custos on public.movimentacoes_estoque;
create trigger trg_movimentacoes_estoque_custos
  after insert or update or delete on public.movimentacoes_estoque
  for each row execute function public.estoque_mov_custos();

-- 4f. Ajuste de lançamento: mesma regra de antes, mas ignora o recálculo de
--     custo (não é edição de ninguém) e só dispara quando o usuário muda o
--     lançamento — não quando o banco grava o custo da saída.
create or replace function public.estoque_valida_ajuste()
returns trigger language plpgsql as $$
declare
  k       record;
  v_saldo numeric;
begin
  if current_setting('cdl.estoque_recalculo', true) = '1' then return new; end if;
  if old.transferencia or new.transferencia then
    if new.transferencia is distinct from old.transferencia or new.tipo <> old.tipo
       or new.produto_id <> old.produto_id or new.setor <> old.setor then
      raise exception 'Numa transferência só a quantidade e a observação podem ser ajustadas.';
    end if;
  end if;
  if (old.tipo = 'origem') <> (new.tipo = 'origem') or (old.tipo = 'origem' and new.produto_id <> old.produto_id) then
    raise exception 'O lançamento de origem não muda de tipo nem de produto.';
  end if;

  perform 1 from public.cadastro_de_produtos where id in (old.produto_id, new.produto_id) order by id for update;

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

  -- Deixou de ser entrada de compra: perde o vínculo com a nota fiscal.
  if new.tipo <> 'entrada' or new.transferencia then new.nota_fiscal_id := null; end if;
  -- Virou saída: o custo passa a ser o das camadas (recalculado depois).
  if new.tipo = 'saida' or new.transferencia then new.preco_unitario := null; end if;

  new.editado_em := now();
  new.editado_por := public.estoque_email_sessao();
  return new;
end;
$$;

drop trigger if exists trg_movimentacoes_estoque_valida_ajuste on public.movimentacoes_estoque;
create trigger trg_movimentacoes_estoque_valida_ajuste
  before update of produto_id, tipo, setor, setor_consumo, transferencia, quantidade, observacao, nota_fiscal_id
  on public.movimentacoes_estoque
  for each row execute function public.estoque_valida_ajuste();

-- ---------------------------------------------------------------------
-- 5. Dados existentes
-- ---------------------------------------------------------------------
-- Gatilhos de usuário desligados só durante a carga (não carimbam edição,
-- não recalculam linha a linha nem gravam histórico de preço).
alter table public.cadastro_de_produtos  disable trigger user;
alter table public.movimentacoes_estoque disable trigger user;

-- 5a. Nomes em maiúsculas e data do preço atual (sem data melhor: a última atualização do cadastro).
update public.cadastro_de_produtos set nome = upper(btrim(nome)) where nome is distinct from upper(btrim(nome));
update public.cadastro_de_produtos set preco_atualizado_em = updated_at
 where preco_custo is not null and preco_atualizado_em is null;

-- 5b. Compras antigas sem preço gravado ficam com o preço atual do cadastro.
update public.movimentacoes_estoque m
   set preco_unitario = p.preco_custo
  from public.cadastro_de_produtos p
 where p.id = m.produto_id and m.tipo <> 'saida' and not m.transferencia
   and m.preco_unitario is null and p.preco_custo is not null;

-- 5c. PDFs anexados às entradas viram notas fiscais (o número vem do nome
--     do arquivo, quando houver) e a entrada passa a apontar para elas.
insert into public.notas_fiscais (numero, fornecedor, data_emissao, observacao, arquivo_nome, arquivo_path, arquivo_bytes, usuario_email, created_at)
select coalesce(substring(m.nota_fiscal_nome from '([0-9]{3,})'), 'S/N'),
       'Não informado',
       (m.created_at at time zone 'America/Cuiaba')::date,
       'Migrada do anexo da entrada de ' || to_char(m.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '. Complete fornecedor e número.',
       m.nota_fiscal_nome, m.nota_fiscal_path, m.nota_fiscal_bytes, m.usuario_email, m.created_at
  from public.movimentacoes_estoque m
 where m.nota_fiscal_path is not null and m.nota_fiscal_id is null
   and not exists (select 1 from public.notas_fiscais n where n.arquivo_path = m.nota_fiscal_path);

update public.movimentacoes_estoque m
   set nota_fiscal_id = n.id, nota_fiscal_nome = null, nota_fiscal_path = null, nota_fiscal_bytes = null
  from public.notas_fiscais n
 where n.arquivo_path = m.nota_fiscal_path and m.nota_fiscal_id is null;

alter table public.cadastro_de_produtos  enable trigger user;
alter table public.movimentacoes_estoque enable trigger user;

-- 5d. Custo de todas as saídas pelas camadas (a mais antiga primeiro).
select public.estoque_recalcula_custos(id) from public.cadastro_de_produtos;

-- ---------------------------------------------------------------------
-- 6. Acesso (RLS)
-- ---------------------------------------------------------------------
alter table public.notas_fiscais  enable row level security;
alter table public.estoque_precos enable row level security;
revoke all on public.notas_fiscais, public.estoque_precos from anon;
grant select, insert, update, delete on public.notas_fiscais to authenticated;
grant select on public.estoque_precos to authenticated;

drop policy if exists nf_select on public.notas_fiscais;
drop policy if exists nf_insert on public.notas_fiscais;
drop policy if exists nf_update on public.notas_fiscais;
drop policy if exists nf_delete on public.notas_fiscais;
create policy nf_select on public.notas_fiscais for select to authenticated using (public.cdl_secao('estoque'));
create policy nf_insert on public.notas_fiscais for insert to authenticated
  with check (
    public.cdl_secao('estoque') and not public.cdl_restrito()
    and (usuario_email is null or lower(usuario_email) = lower(auth.jwt() ->> 'email'))
  );
create policy nf_update on public.notas_fiscais for update to authenticated
  using (public.cdl_pode_editar('estoque')) with check (public.cdl_pode_editar('estoque'));
create policy nf_delete on public.notas_fiscais for delete to authenticated
  using (public.cdl_pode_editar('estoque'));

drop policy if exists precos_select on public.estoque_precos;
create policy precos_select on public.estoque_precos for select to authenticated using (public.cdl_secao('estoque'));

-- A API (PostgREST) passa a enxergar as tabelas e colunas novas na hora.
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
-- 1) Saídas sem custo calculado (deve voltar 0, salvo produtos sem nenhum preço).
select count(*) as saidas_sem_custo
  from public.movimentacoes_estoque m join public.cadastro_de_produtos p on p.id = m.produto_id
 where m.tipo = 'saida' and not m.transferencia and m.preco_unitario is null and p.preco_custo is not null;
-- 2) Notas fiscais (as migradas aparecem com fornecedor "Não informado").
select numero, fornecedor, data_emissao, arquivo_nome from public.notas_fiscais order by created_at desc limit 20;
-- 3) Policies das tabelas novas.
select tablename, policyname, cmd from pg_policies
 where schemaname = 'public' and tablename in ('notas_fiscais', 'estoque_precos') order by tablename, cmd;
