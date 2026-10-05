-- ============================================================================
-- CDLoad · Usuários: Setor e Último acesso
--
-- Rode em Supabase > SQL Editor (idempotente).
--
--   setor          texto escolhido no cadastro (Marketing, Institucional,
--                  Núcleo Inteligência, Comercial, Departamento Pessoal,
--                  Presidência, Assessoria, RH, Financeiro, Certificado
--                  Digital). Segue o RLS de
--                  `usuarios`: só Administrador altera.
--   ultimo_acesso  data/hora da última entrada na plataforma (login ou sessão
--                  restaurada ao abrir o app).
--
-- O RLS só deixa o Administrador editar `usuarios`; por isso o próprio usuário
-- grava o acesso pela função registrar_acesso() (security definer), que só
-- altera a linha do e-mail da sessão e só a coluna ultimo_acesso.
-- ============================================================================

alter table public.usuarios
  add column if not exists setor text,
  add column if not exists ultimo_acesso timestamptz;

comment on column public.usuarios.setor is 'Setor do usuário (lista fixa no cadastro do app).';
comment on column public.usuarios.ultimo_acesso is 'Última entrada na plataforma (gravada por registrar_acesso()).';

create or replace function public.registrar_acesso()
returns void
language sql
security definer
set search_path = public
as $$
  update public.usuarios u
     set ultimo_acesso = now()
    from auth.users a
   where a.id = auth.uid()
     and a.email_confirmed_at is not null
     and lower(a.email) = lower(u.email)
     and u.status = 'Ativo';
$$;

revoke all on function public.registrar_acesso() from public, anon;
grant execute on function public.registrar_acesso() to authenticated;

select nome, email, setor, ultimo_acesso from public.usuarios order by nome;
