-- ============================================================================
-- CDLoad · Usuários: Edição (editar e excluir sem ser Administrador)
--
-- Rode em Supabase > SQL Editor (idempotente) POR ÚLTIMO — depois de
-- schema_seguranca_rls.sql, schema_somente_admin_edita.sql, schema_clipping.sql,
-- schema_estoque_editar_movimentacao.sql e schema_estoque_nota_fiscal.sql.
-- Aqueles scripts recriam as mesmas policies como "só Administrador"; se algum
-- deles for rodado de novo, rode este outra vez.
--
--   edicao   flag "Edição" do cadastro (Usuários › cadastro/edição).
--            O usuário com Edição pode EDITAR e EXCLUIR registros nas seções
--            liberadas para ele — sem virar Administrador.
--
-- Regra (função cdl_pode_editar):
--   Administrador ativo ............................ edita e exclui em tudo
--   Usuário ativo com Edição, não restrito ......... edita e exclui só nas
--                                                    seções liberadas a ele
--   Demais ......................................... só lê e cria (como antes)
--
-- O cadastro de USUÁRIOS continua exclusivo do Administrador (policies de
-- `usuarios` não mudam): quem tem Edição não consegue se promover nem mudar
-- permissões de ninguém.
-- ============================================================================

alter table public.usuarios
  add column if not exists edicao boolean not null default false;

comment on column public.usuarios.edicao is
  'Edição: pode editar e excluir registros nas seções liberadas (flag "Edição" do cadastro).';

create or replace function public.cdl_pode_editar(chave text)
returns boolean
language sql stable security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.usuarios u
    join auth.users a on lower(a.email) = lower(u.email)
    where a.id = auth.uid()
      and a.email_confirmed_at is not null
      and u.status = 'Ativo'
      and (
        u.cargo = 'Administrador'
        or (u.edicao and not coalesce(u.restrito, false) and u.secoes_permitidas ? chave)
      )
  );
$$;

revoke all on function public.cdl_pode_editar(text) from public, anon;
grant execute on function public.cdl_pode_editar(text) to authenticated;

-- ---------- Campanhas ----------
drop policy if exists campanhas_update on public.campanhas;
drop policy if exists campanhas_delete on public.campanhas;
create policy campanhas_update on public.campanhas for update to authenticated
  using (public.cdl_pode_editar('campanhas')) with check (public.cdl_pode_editar('campanhas'));
create policy campanhas_delete on public.campanhas for delete to authenticated
  using (public.cdl_pode_editar('campanhas'));

-- Agenda de campanha existente: quem pode editar a campanha também pode regravar a agenda.
create or replace function public.cdl_gravar_agenda_sync(p_campanha uuid, p_sync jsonb)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
begin
  if not public.cdl_secao('campanhas') then
    raise exception 'Sem permissão para a seção Campanhas.' using errcode = '42501';
  end if;
  update public.campanhas c
     set agenda_sync = coalesce(p_sync, '{}'::jsonb)
   where c.id = p_campanha
     and (public.cdl_pode_editar('campanhas') or coalesce(c.agenda_sync, '{}'::jsonb) = '{}'::jsonb);
  if not found then
    raise exception 'Só quem tem Edição (ou um Administrador) pode alterar a agenda de uma campanha existente.' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.cdl_gravar_agenda_sync(uuid, jsonb) from public, anon;
grant execute on function public.cdl_gravar_agenda_sync(uuid, jsonb) to authenticated;

-- ---------- Clipping News ----------
drop policy if exists clipping_update on public.clipping_news;
drop policy if exists clipping_delete on public.clipping_news;
create policy clipping_update on public.clipping_news for update to authenticated
  using (public.cdl_pode_editar('clipping')) with check (public.cdl_pode_editar('clipping'));
create policy clipping_delete on public.clipping_news for delete to authenticated
  using (public.cdl_pode_editar('clipping'));

-- ---------- Estoque: produtos, movimentações e notas fiscais ----------
drop policy if exists produtos_update on public.cadastro_de_produtos;
drop policy if exists produtos_delete on public.cadastro_de_produtos;
create policy produtos_update on public.cadastro_de_produtos for update to authenticated
  using (public.cdl_pode_editar('estoque')) with check (public.cdl_pode_editar('estoque'));
create policy produtos_delete on public.cadastro_de_produtos for delete to authenticated
  using (public.cdl_pode_editar('estoque'));

-- (o gatilho estoque_valida_ajuste continua impedindo ajuste que deixe saldo negativo)
drop policy if exists mov_update on public.movimentacoes_estoque;
drop policy if exists mov_delete on public.movimentacoes_estoque;
create policy mov_update on public.movimentacoes_estoque for update to authenticated
  using (public.cdl_pode_editar('estoque')) with check (public.cdl_pode_editar('estoque'));
create policy mov_delete on public.movimentacoes_estoque for delete to authenticated
  using (public.cdl_pode_editar('estoque'));

drop policy if exists notas_fiscais_delete on storage.objects;
create policy notas_fiscais_delete on storage.objects for delete to authenticated
  using (bucket_id = 'notas_fiscais' and public.cdl_pode_editar('estoque'));

-- ---------- Relatórios (arquivos e bucket) ----------
drop policy if exists relatorios_delete on public.relatorios_arquivos;
create policy relatorios_delete on public.relatorios_arquivos for delete to authenticated
  using (public.cdl_pode_editar('relatorios'));

drop policy if exists relatorios_storage_delete on storage.objects;
create policy relatorios_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'relatorios' and public.cdl_pode_editar('relatorios'));

notify pgrst, 'reload schema';

-- ---------- Conferência ----------
-- UPDATE/DELETE de campanhas, clipping_news, cadastro_de_produtos, movimentacoes_estoque
-- e relatorios_arquivos devem usar cdl_pode_editar(...); os de usuarios continuam com cdl_admin().
select tablename, policyname, cmd, coalesce(qual, with_check) as regra
from pg_policies
where schemaname in ('public', 'storage') and cmd in ('UPDATE', 'DELETE')
order by tablename, cmd;
