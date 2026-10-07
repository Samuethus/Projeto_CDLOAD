-- ============================================================================
-- CDLoad · Seção "Home" passa a ser liberada por usuário
--
-- Rode em Supabase > SQL Editor (idempotente).
-- Antes a Home ficava aberta para todos. Agora ela é uma seção como as outras
-- (Usuários > Permissões de Acesso > "Home"). Para ninguém perder o acesso ao
-- publicar, este script inclui "home" em quem já está cadastrado; depois, é só
-- desmarcar "Home" de quem não deve vê-la.
-- ============================================================================

update public.usuarios
   set secoes_permitidas = coalesce(secoes_permitidas, '[]'::jsonb) || '["home"]'::jsonb
 where not (coalesce(secoes_permitidas, '[]'::jsonb) ? 'home');

select nome, email, cargo, secoes_permitidas ? 'home' as acessa_home
from public.usuarios
order by nome;
