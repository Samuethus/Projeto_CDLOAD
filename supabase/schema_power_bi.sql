-- ============================================================================
-- CDLoad · Permissão de acesso aos painéis do Power BI
--
-- Rode em Supabase > SQL Editor (idempotente).
-- Cria `usuarios.acesso_power_bi` (campo "Power BI" no cadastro de Usuários).
-- Sem a permissão, os cards de painéis da página inicial ficam visíveis e
-- com animação, mas o clique não abre nada. Administrador sempre tem acesso.
--
-- Quem já estava cadastrado mantém o acesso que tinha (true); cadastros novos
-- começam sem acesso (false) até um administrador liberar.
-- A coluna segue o RLS de `usuarios`: só Administrador altera.
-- ============================================================================

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'usuarios' and column_name = 'acesso_power_bi'
  ) then
    alter table public.usuarios add column acesso_power_bi boolean not null default true;
    alter table public.usuarios alter column acesso_power_bi set default false;
  end if;
end $$;

comment on column public.usuarios.acesso_power_bi is
  'Libera o clique nos painéis do Power BI da página inicial (Administrador sempre tem acesso).';

select nome, email, cargo, acesso_power_bi from public.usuarios order by nome;
