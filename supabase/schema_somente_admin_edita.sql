-- ============================================================================
-- CDLoad · Só Administrador edita e exclui dados
--
-- Rode em Supabase > SQL Editor DEPOIS de schema_seguranca_rls.sql, schema_agenda.sql
-- e schema_clipping.sql. É idempotente: pode rodar de novo sem quebrar.
--
-- Regra: quem tem a seção liberada (mesmo todas) só LÊ e CRIA registros.
-- Editar (UPDATE) e excluir (DELETE) é exclusivo de quem tem
-- cargo = 'Administrador' e status 'Ativo' em `usuarios`.
--
-- Tabelas que já eram assim e não mudam aqui: usuarios, local,
-- movimentacoes_estoque (mov_update/mov_delete em schema_seguranca_rls.sql e
-- schema_estoque_editar_movimentacao.sql), relatorios_arquivos e o bucket "relatorios".
-- ============================================================================

-- ---------- campanhas ----------
drop policy if exists campanhas_update on public.campanhas;
drop policy if exists campanhas_delete on public.campanhas;
create policy campanhas_update on public.campanhas for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy campanhas_delete on public.campanhas for delete to authenticated using (public.cdl_admin());

-- ---------- clipping_news (as coletas automáticas usam security definer e seguem funcionando) ----------
drop policy if exists clipping_update on public.clipping_news;
drop policy if exists clipping_delete on public.clipping_news;
create policy clipping_update on public.clipping_news for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy clipping_delete on public.clipping_news for delete to authenticated using (public.cdl_admin());

-- ---------- cadastro_de_produtos ----------
drop policy if exists produtos_update on public.cadastro_de_produtos;
drop policy if exists produtos_delete on public.cadastro_de_produtos;
create policy produtos_update on public.cadastro_de_produtos for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy produtos_delete on public.cadastro_de_produtos for delete to authenticated using (public.cdl_admin());

-- ---------- Agenda das campanhas ----------
-- A Edge Function `sincronizar-agenda` precisa gravar `campanhas.agenda_sync`
-- (ids dos eventos) logo depois que alguém CRIA uma campanha com participantes.
-- Como o UPDATE agora é só do Administrador, a gravação passa por esta função:
-- Administrador grava sempre; os demais só na campanha ainda sem evento (a
-- que acabaram de criar) — não conseguem mexer no evento de uma existente.
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
     and (public.cdl_admin() or coalesce(c.agenda_sync, '{}'::jsonb) = '{}'::jsonb);
  if not found then
    raise exception 'Só um Administrador pode alterar a agenda de uma campanha existente.' using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.cdl_gravar_agenda_sync(uuid, jsonb) from public, anon;
grant execute on function public.cdl_gravar_agenda_sync(uuid, jsonb) to authenticated;

-- ---------- Conferência ----------
-- Deve listar update/delete com "cdl_admin()" em campanhas, clipping_news e cadastro_de_produtos.
select tablename, policyname, cmd, qual
from pg_policies
where schemaname = 'public'
  and cmd in ('UPDATE', 'DELETE')
order by tablename, cmd;
