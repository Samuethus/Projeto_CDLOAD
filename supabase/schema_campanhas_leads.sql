-- ============================================================================
-- CDLoad · Campanhas › Leads (e-mail informativo pela Penso)
--
-- Rode em Supabase > SQL Editor (idempotente), depois de schema_agenda.sql e
-- schema_usuarios_edicao.sql.
--
-- A Edge Function `sincronizar-agenda` (ação "leads") envia um e-mail individual a
-- cada lead do CSV da campanha (Etapa 3) e registra o progresso em
-- campanhas.agenda_sync->'leads':
--   { enviados: ["email", ...], falhas: [{email, erro}], total, atualizado_em }
-- Quem está em `enviados` nunca recebe de novo.
--
-- O envio de uma lista grande acontece em lotes (várias chamadas). Por isso o
-- registro não pode depender de "Edição" (cdl_gravar_agenda_sync só deixa gravar
-- num agenda_sync vazio): esta função só ACRESCENTA e-mails a `enviados` — ninguém
-- consegue "desmarcar" um envio e provocar reenvio — e só mexe na chave `leads`.
-- ============================================================================

create or replace function public.cdl_gravar_leads_envio(p_campanha uuid, p_leads jsonb)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare
  atual jsonb;
  enviados jsonb;
begin
  if not public.cdl_secao('campanhas') then
    raise exception 'Sem permissão para a seção Campanhas.' using errcode = '42501';
  end if;

  select coalesce(c.agenda_sync -> 'leads', '{}'::jsonb) into atual
    from public.campanhas c where c.id = p_campanha for update;
  if not found then
    raise exception 'Campanha não encontrada.' using errcode = 'P0002';
  end if;

  -- União (sem repetição) do que já estava gravado com o que chegou.
  select coalesce(jsonb_agg(distinct e order by e), '[]'::jsonb) into enviados
    from (
      select jsonb_array_elements_text(coalesce(atual -> 'enviados', '[]'::jsonb)) as e
      union
      select jsonb_array_elements_text(coalesce(p_leads -> 'enviados', '[]'::jsonb))
    ) t;

  update public.campanhas c
     set agenda_sync = coalesce(c.agenda_sync, '{}'::jsonb) || jsonb_build_object('leads',
           jsonb_build_object(
             'enviados', enviados,
             'falhas', coalesce(p_leads -> 'falhas', atual -> 'falhas', '[]'::jsonb),
             'total', coalesce(p_leads -> 'total', atual -> 'total'),
             'atualizado_em', coalesce(p_leads -> 'atualizado_em', to_jsonb(now()))
           ))
   where c.id = p_campanha;
end;
$$;

revoke all on function public.cdl_gravar_leads_envio(uuid, jsonb) from public, anon;
grant execute on function public.cdl_gravar_leads_envio(uuid, jsonb) to authenticated;

-- ---------- Conferência ----------
-- Deve listar a função com security definer = true.
select p.proname, p.prosecdef as security_definer
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'cdl_gravar_leads_envio';
