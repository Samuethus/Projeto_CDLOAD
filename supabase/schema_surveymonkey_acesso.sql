-- =====================================================================================
-- CDLoad · Survey Monkey — FORMULÁRIOS LIBERADOS POR USUÁRIO (botão "Acessos" da seção Survey)
-- =====================================================================================
--
-- COMO USAR
--   Supabase  >  SQL Editor  >  New query  >  cole este arquivo  >  RUN.
--   Pode rodar mais de uma vez (idempotente). Rode DEPOIS de schema_surveymonkey.sql.
--   Se schema_surveymonkey.sql for rodado de novo, rode este outra vez (aquele recria as
--   regras de leitura como "todos os formulários").
--
-- O QUE FAZ
--   Passo 1 — Cria usuarios.survey_formularios_permitidos (lista de ids de formulário):
--               null                      = todos os formulários (cadastros atuais: nada muda)
--               []                        = nenhum
--               ["417151428","421928762"] = só esses (visualização completa: lista, painel,
--                                           coletores e respostas individuais)
--             Só Administrador altera (RLS de `usuarios`). Administrador sempre vê todos.
--   Passo 2 — Funções que o RLS usa (calculadas 1x por consulta, não por linha).
--   Passo 3 — Leitura de survey_formularios, survey_perguntas, survey_coletores e
--             survey_respostas passa a respeitar a lista. O tempo real (Realtime) segue
--             as mesmas regras. Pastas e histórico de sincronização continuam com a seção.
-- =====================================================================================

-- Passo 1
alter table public.usuarios
  add column if not exists survey_formularios_permitidos jsonb;

comment on column public.usuarios.survey_formularios_permitidos is
  'Survey Monkey: ids dos formulários que o usuário visualiza (null = todos; [] = nenhum).';

-- Passo 2
-- true = vê todos os formulários: Administrador, ou seção Survey liberada sem lista definida.
create or replace function public.cdl_survey_todos()
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
        or (u.secoes_permitidas ? 'surveymonkey'
            and (u.survey_formularios_permitidos is null or jsonb_typeof(u.survey_formularios_permitidos) <> 'array'))
      )
  );
$$;

-- Ids liberados para quem tem lista definida (vazio para os demais).
create or replace function public.cdl_survey_lista()
returns text[]
language sql stable security definer
set search_path = public, auth
as $$
  select coalesce((
    select array(select jsonb_array_elements_text(u.survey_formularios_permitidos))
    from public.usuarios u
    join auth.users a on lower(a.email) = lower(u.email)
    where a.id = auth.uid()
      and a.email_confirmed_at is not null
      and u.status = 'Ativo'
      and u.secoes_permitidas ? 'surveymonkey'
      and jsonb_typeof(u.survey_formularios_permitidos) = 'array'
    limit 1
  ), '{}'::text[]);
$$;

revoke all on function public.cdl_survey_todos(), public.cdl_survey_lista() from public, anon;
grant execute on function public.cdl_survey_todos(), public.cdl_survey_lista() to authenticated;

-- Passo 3
drop policy if exists survey_formularios_select on public.survey_formularios;
create policy survey_formularios_select on public.survey_formularios for select to authenticated
  using ((select public.cdl_survey_todos()) or id = any ((select public.cdl_survey_lista())));

drop policy if exists survey_perguntas_select on public.survey_perguntas;
create policy survey_perguntas_select on public.survey_perguntas for select to authenticated
  using ((select public.cdl_survey_todos()) or formulario_id = any ((select public.cdl_survey_lista())));

drop policy if exists survey_coletores_select on public.survey_coletores;
create policy survey_coletores_select on public.survey_coletores for select to authenticated
  using ((select public.cdl_survey_todos()) or formulario_id = any ((select public.cdl_survey_lista())));

drop policy if exists survey_respostas_select on public.survey_respostas;
create policy survey_respostas_select on public.survey_respostas for select to authenticated
  using ((select public.cdl_survey_todos()) or formulario_id = any ((select public.cdl_survey_lista())));

notify pgrst, 'reload schema';

-- Conferência: quem tem lista definida (null = todos).
select nome, email, cargo,
       case when survey_formularios_permitidos is null then 'todos'
            else jsonb_array_length(survey_formularios_permitidos)::text || ' formulário(s)' end as survey
  from public.usuarios order by nome;
