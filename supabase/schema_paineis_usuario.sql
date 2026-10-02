-- ============================================================================
-- CDLoad · Painéis Power BI liberados por usuário (Home)
--
-- Rode em Supabase > SQL Editor (idempotente).
-- Cria `usuarios.paineis_permitidos`: lista dos ids dos painéis (HUB_PAINEIS
-- no index.html) que aparecem na Home do usuário. Os demais ficam ocultos.
--
--   null      = todos os painéis (cadastros antigos e Administrador)
--   []        = nenhum painel
--   ["hub-nucleo","caged-empregos"] = só esses
--
-- Segue o RLS de `usuarios`: só Administrador altera.
-- ============================================================================

alter table public.usuarios
  add column if not exists paineis_permitidos jsonb;

comment on column public.usuarios.paineis_permitidos is
  'Ids dos painéis Power BI exibidos na Home (null = todos).';

-- O antigo campo "Power BI" (Sim/Não, travava o clique) foi substituído por
-- esta lista e saiu do app: a coluna dele deixa de existir.
alter table public.usuarios drop column if exists acesso_power_bi;

select nome, email, cargo, paineis_permitidos from public.usuarios order by nome;
