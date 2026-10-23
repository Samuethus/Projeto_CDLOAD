-- ============================================================================
-- CDLoad · Dashboards liberados por usuário (seção Dashboard, consulta)
--
-- Rode em Supabase > SQL Editor (idempotente).
-- Cria `usuarios.dashboards_permitidos`: lista das chaves dos painéis da seção
-- Dashboard (filtro "Painel") que o usuário pode consultar. Os demais somem
-- da lista de painéis dele.
--
--   null      = todos os painéis (cadastros antigos e Administrador)
--   []        = nenhum painel
--   ["panorama","spcmt"] = só esses
--
-- Chaves: estoque, clipping, intencao, panorama, spcmt, viabilidades.
-- Usuário novo é cadastrado sem nenhum acesso ([] em todas as listas); o
-- Administrador marca o que ele pode ver em Usuários › Acessos.
-- Segue o RLS de `usuarios`: só Administrador altera.
-- ============================================================================

alter table public.usuarios
  add column if not exists dashboards_permitidos jsonb;

comment on column public.usuarios.dashboards_permitidos is
  'Chaves dos painéis da seção Dashboard liberados para consulta (null = todos).';

notify pgrst, 'reload schema';

select nome, email, cargo,
       case when dashboards_permitidos is null then 'todos'
            else jsonb_array_length(dashboards_permitidos)::text || ' painel(is)' end as dashboards
  from public.usuarios order by nome;
