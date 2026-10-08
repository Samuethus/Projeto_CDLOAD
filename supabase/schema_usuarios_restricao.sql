-- ============================================================================
-- CDLoad · Usuários: Restrição (usuário restrito)
--
-- Rode em Supabase > SQL Editor (idempotente), DEPOIS de schema_seguranca_rls.sql
-- (aquele script recria as policies das tabelas e apagaria as daqui).
--
--   restrito   flag "Restrição" do cadastro (Usuários › cadastro/edição).
--              Usuário restrito, no Estoque, só vê a tela de leitura do produto
--              e só registra SAÍDA. Administrador nunca é restrito.
--
-- Além da tela, o banco garante a regra com policies RESTRICTIVE (somam-se às
-- policies normais com AND): o restrito não grava entrada, transferência nem
-- origem, e não cadastra produto — mesmo chamando a API diretamente.
-- ============================================================================

alter table public.usuarios
  add column if not exists restrito boolean not null default false;

comment on column public.usuarios.restrito is
  'Usuário restrito: no Estoque só registra saída pela leitura do produto (flag "Restrição" do cadastro).';

-- true quando o usuário da sessão está marcado como restrito (Administrador nunca é).
create or replace function public.cdl_restrito()
returns boolean
language sql stable security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.usuarios u
    join auth.users a on lower(a.email) = lower(u.email)
    where a.id = auth.uid()
      and u.restrito
      and u.cargo <> 'Administrador'
  );
$$;

revoke all on function public.cdl_restrito() from public, anon;
grant execute on function public.cdl_restrito() to authenticated;

-- Movimentações: restrito só insere saída comum (não transferência).
drop policy if exists mov_insert_restrito on public.movimentacoes_estoque;
create policy mov_insert_restrito on public.movimentacoes_estoque
  as restrictive for insert to authenticated
  with check (not public.cdl_restrito() or (tipo = 'saida' and coalesce(transferencia, false) = false));

-- Produtos: restrito não cadastra produto novo.
drop policy if exists produtos_insert_restrito on public.cadastro_de_produtos;
create policy produtos_insert_restrito on public.cadastro_de_produtos
  as restrictive for insert to authenticated
  with check (not public.cdl_restrito());

select nome, email, cargo, restrito from public.usuarios order by nome;
