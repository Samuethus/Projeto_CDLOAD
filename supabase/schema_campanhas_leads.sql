-- ============================================================================
-- CDLoad · Campanhas › Leads (e-mail informativo pela Penso)
--
-- Rode em Supabase > SQL Editor (idempotente), depois de schema_agenda.sql e
-- schema_usuarios_edicao.sql. Pode rodar de novo sem perder dados.
--
-- 1) cdl_gravar_leads_envio — progresso do envio em campanhas.agenda_sync->'leads':
--      { enviados: ["email", ...], falhas: [{email, erro}], total, atualizado_em,
--        lotes: [{em, n}] }   (lotes = envios das últimas 72 h, para o limite diário)
--    Só ACRESCENTA a `enviados` (ninguém consegue "desmarcar" e provocar reenvio)
--    e não depende de "Edição": o envio de listas grandes vai em vários lotes.
-- 2) cdl_leads_enviados_24h — e-mails a leads enviados nas últimas 24 h, somando
--    todas as campanhas (limite diário da conta da Penso).
-- ============================================================================

-- ---------- 1) Progresso do envio ----------
create or replace function public.cdl_gravar_leads_envio(p_campanha uuid, p_leads jsonb)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare
  atual jsonb;
  enviados jsonb;
  lotes jsonb;
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

  -- Lotes: os anteriores + o novo (p_leads.lote), só das últimas 72 h.
  select coalesce(jsonb_agg(x order by x ->> 'em'), '[]'::jsonb) into lotes
    from jsonb_array_elements(
           coalesce(atual -> 'lotes', '[]'::jsonb)
           || case when jsonb_typeof(p_leads -> 'lote') = 'object' then jsonb_build_array(p_leads -> 'lote') else '[]'::jsonb end
         ) x
   where (x ->> 'em')::timestamptz > now() - interval '72 hours';

  update public.campanhas c
     set agenda_sync = coalesce(c.agenda_sync, '{}'::jsonb) || jsonb_build_object('leads',
           jsonb_build_object(
             'enviados', enviados,
             'falhas', coalesce(p_leads -> 'falhas', atual -> 'falhas', '[]'::jsonb),
             'total', coalesce(p_leads -> 'total', atual -> 'total'),
             'atualizado_em', coalesce(p_leads -> 'atualizado_em', to_jsonb(now())),
             'lotes', lotes
           ))
   where c.id = p_campanha;
end;
$$;

revoke all on function public.cdl_gravar_leads_envio(uuid, jsonb) from public, anon;
grant execute on function public.cdl_gravar_leads_envio(uuid, jsonb) to authenticated;

-- ---------- 2) Enviados nas últimas 24 h (todas as campanhas) ----------
create or replace function public.cdl_leads_enviados_24h()
returns integer
language plpgsql stable security definer
set search_path = public, auth
as $$
declare
  total integer;
begin
  if not public.cdl_secao('campanhas') then
    raise exception 'Sem permissão para a seção Campanhas.' using errcode = '42501';
  end if;
  select coalesce(sum((l ->> 'n')::int), 0) into total
    from public.campanhas c,
         jsonb_array_elements(coalesce(c.agenda_sync -> 'leads' -> 'lotes', '[]'::jsonb)) l
   where (l ->> 'em')::timestamptz > now() - interval '24 hours';
  return total;
end;
$$;

revoke all on function public.cdl_leads_enviados_24h() from public, anon;
grant execute on function public.cdl_leads_enviados_24h() to authenticated;

-- ---------- Conferência ----------
-- Devem aparecer as duas funções (security definer = true).
select p.proname, p.prosecdef as security_definer
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('cdl_gravar_leads_envio', 'cdl_leads_enviados_24h');

-- Descadastro removido do CDLoad: se a tabela leads_descadastro tiver sido criada por uma versão anterior
-- deste arquivo, ela não é mais usada. Para apagá-la (opcional): drop table if exists public.leads_descadastro;
