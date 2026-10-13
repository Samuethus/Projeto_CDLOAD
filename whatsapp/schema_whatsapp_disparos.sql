-- ============================================================================
-- CDLoad · WhatsApp (UAZAPI) — Etapas 4, 5 e 6: templates, contatos e disparos
--
-- Rode em Supabase > SQL Editor (idempotente), DEPOIS de schema_whatsapp.sql.
-- ============================================================================

do $$
begin
  if to_regclass('public.wa_templates') is null then
    raise exception 'Rode whatsapp/schema_whatsapp.sql antes deste arquivo.';
  end if;
end $$;

-- ---------- Templates: categoria e cabeçalho (vindos do assistente da tela) ----------
alter table public.wa_templates add column if not exists categoria text not null default 'Marketing';
alter table public.wa_templates add column if not exists cabecalho text;
alter table public.wa_templates add column if not exists atualizado_em timestamptz not null default now();

-- ---------- Campanhas: erro do envio e hora da última atualização ----------
alter table public.wa_campanhas add column if not exists erro text;
alter table public.wa_campanhas add column if not exists atualizado_em timestamptz not null default now();

-- ---------- Envios: um por telefone em cada campanha ----------
create unique index if not exists wa_envios_campanha_tel_uk on public.wa_envios (campanha_id, telefone);

-- ---------- Resumo das campanhas (contadores por status) ----------
-- security_invoker: a view respeita o RLS de quem consulta (seção "whatsapp").
create or replace view public.wa_campanhas_resumo
with (security_invoker = true) as
select c.id, c.nome, c.status, c.agendada_para, c.delay_min, c.delay_max, c.uazapi_folder_id, c.erro,
       c.criado_em, c.atualizado_em,
       i.nome  as instancia_nome,
       t.nome  as template_nome,
       l.nome  as lista_nome,
       count(e.id)                                         as total,
       count(e.id) filter (where e.status = 'fila')        as na_fila,
       count(e.id) filter (where e.status = 'enviado')     as enviados,
       count(e.id) filter (where e.status = 'entregue')    as entregues,
       count(e.id) filter (where e.status = 'lido')        as lidos,
       count(e.id) filter (where e.status = 'falhou')      as falhas
  from public.wa_campanhas c
  left join public.wa_instancias i on i.id = c.instancia_id
  left join public.wa_templates  t on t.id = c.template_id
  left join public.wa_listas     l on l.id = c.lista_id
  left join public.wa_envios     e on e.campanha_id = c.id
 group by c.id, i.nome, t.nome, l.nome;

grant select on public.wa_campanhas_resumo to authenticated;

-- ---------- Tempo real também nos templates ----------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'wa_templates') then
    alter publication supabase_realtime add table public.wa_templates;
  end if;
end $$;

-- Conferência:
-- select * from public.wa_campanhas_resumo order by criado_em desc;
