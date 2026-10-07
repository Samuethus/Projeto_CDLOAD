-- =====================================================================
-- CDLoad · Estoque — nota fiscal (PDF) nas entradas
--
-- Rode uma vez em Supabase > SQL Editor, num banco que já tem o Estoque.
-- É idempotente. (Banco novo não precisa: schema_estoque.sql e
-- seguranca_rls.sql já trazem tudo isto.)
--
--   movimentacoes_estoque.nota_fiscal_*  → nome, caminho no Storage e
--                                          tamanho do PDF (só em entrada
--                                          de compra — nunca em saída,
--                                          origem ou transferência)
--   bucket "notas_fiscais"               → o PDF em si: privado, só PDF,
--                                          até 10 MB. O app abre por link
--                                          assinado e temporário.
--
-- Acesso: quem tem a seção Estoque vê e anexa; só Administrador remove
-- (o mesmo controle das movimentações).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Colunas
-- ---------------------------------------------------------------------
alter table public.movimentacoes_estoque add column if not exists nota_fiscal_nome  text;
alter table public.movimentacoes_estoque add column if not exists nota_fiscal_path  text;
alter table public.movimentacoes_estoque add column if not exists nota_fiscal_bytes bigint;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_nota_fiscal_path_key') then
    alter table public.movimentacoes_estoque
      add constraint movimentacoes_estoque_nota_fiscal_path_key unique (nota_fiscal_path);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'movimentacoes_estoque_nota_fiscal_valida') then
    alter table public.movimentacoes_estoque
      add constraint movimentacoes_estoque_nota_fiscal_valida
      check (nota_fiscal_path is null or (tipo = 'entrada' and not transferencia and nota_fiscal_nome is not null));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Bucket privado, só PDF, até 10 MB
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notas_fiscais', 'notas_fiscais', false, 10485760, array['application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------
-- 3. Policies do Storage (mesmas de seguranca_rls.sql)
-- ---------------------------------------------------------------------
drop policy if exists notas_fiscais_select on storage.objects;
drop policy if exists notas_fiscais_insert on storage.objects;
drop policy if exists notas_fiscais_delete on storage.objects;

create policy notas_fiscais_select on storage.objects for select to authenticated
  using (bucket_id = 'notas_fiscais' and public.cdl_secao('estoque'));
create policy notas_fiscais_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'notas_fiscais' and public.cdl_secao('estoque'));
create policy notas_fiscais_delete on storage.objects for delete to authenticated
  using (bucket_id = 'notas_fiscais' and public.cdl_admin());

-- A API (PostgREST) passa a enxergar as colunas novas na hora.
notify pgrst, 'reload schema';

-- Conferência: o bucket e as 3 policies.
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'notas_fiscais';
select policyname, cmd from pg_policies where schemaname = 'storage' and policyname like 'notas_fiscais_%' order by cmd;
