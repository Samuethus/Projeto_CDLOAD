-- =====================================================================
-- CDLoad · Estoque — ajuste (edição) de movimentações
--
-- Rode uma vez em Supabase > SQL Editor, num banco que já tem o Estoque.
-- É idempotente. (Banco novo não precisa: schema_estoque.sql e
-- seguranca_rls.sql já trazem tudo isto.)
--
-- Libera o ícone de lápis na tabela de Movimentações:
--   • só Administrador ajusta (policy mov_update, igual ao produto);
--   • o gatilho estoque_valida_ajuste impede saldo negativo em qualquer
--     estoque central afetado, trava tipo/produto da origem e, nas
--     transferências, só deixa mudar quantidade e observação;
--   • cada ajuste grava quem e quando (editado_por / editado_em).
--
-- Depende das colunas do modelo "estoques centrais + setor de consumo"
-- (setor_consumo, transferencia). Elas são criadas aqui também, caso
-- migracao_estoque_centrais.sql ainda não tenha sido rodado — mas rode-o
-- também, para ativar as regras e devolver às centrais o saldo antigo.
-- =====================================================================

alter table public.movimentacoes_estoque add column if not exists setor_consumo text;
alter table public.movimentacoes_estoque add column if not exists transferencia boolean not null default false;
alter table public.movimentacoes_estoque add column if not exists editado_em timestamptz;
alter table public.movimentacoes_estoque add column if not exists editado_por text;

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

  new.editado_em := now();
  new.editado_por := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', current_user);
  return new;
end;
$$;

drop trigger if exists trg_movimentacoes_estoque_valida_ajuste on public.movimentacoes_estoque;
create trigger trg_movimentacoes_estoque_valida_ajuste
  before update on public.movimentacoes_estoque
  for each row execute function public.estoque_valida_ajuste();

drop policy if exists mov_update on public.movimentacoes_estoque;
create policy mov_update on public.movimentacoes_estoque for update to authenticated
  using (public.cdl_admin()) with check (public.cdl_admin());

-- A API (PostgREST) passa a enxergar as colunas novas na hora — sem isso
-- aparece "Could not find the '...' column ... in the schema cache".
notify pgrst, 'reload schema';

-- Conferência: deve listar mov_update e mov_delete com cdl_admin().
select policyname, cmd, qual from pg_policies
 where schemaname = 'public' and tablename = 'movimentacoes_estoque' order by cmd;
