-- =====================================================================
-- CDLoad · Uso da plataforma (Dashboard › Painel · Usuários Ativos)
--
-- Rode em Supabase > SQL Editor DEPOIS de schema_seguranca_rls.sql e de
-- schema_usuarios_dashboards.sql. É idempotente.
--
--   uso_eventos  → um registro por uso: acesso à plataforma (login), seção
--                  aberta no menu, painel do Dashboard consultado e ação
--                  (botões de salvar/registrar/exportar). Gravado pelo app,
--                  em lotes, com o e-mail de quem está logado.
--   uso_resumo() → totais por mês, usuário, tipo e seção (com os dias ativos
--                  do usuário no mês) para o painel. Não devolve eventos soltos.
--   registrar_acesso() → passa a gravar o "Último acesso" da seção Usuários
--                  e o evento de login do painel juntos (mesmo instante), e o
--                  último acesso já existente vira histórico de login.
--
-- Acesso: cada usuário só grava os próprios eventos. Os eventos brutos só o
-- Administrador lê. O resumo responde ao Administrador e a quem tem o painel
-- "Usuários Ativos" marcado explicitamente em Usuários › Acessos › Dashboards
-- (a lista "todos" dos cadastros antigos não inclui este painel).
-- =====================================================================

create table if not exists public.uso_eventos (
  id            bigint generated always as identity primary key,
  criado_em     timestamptz not null default now(),
  usuario_email text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  tipo          text not null check (tipo in ('login', 'secao', 'painel', 'acao')),
  secao         text check (secao is null or length(secao) <= 40),
  detalhe       text check (detalhe is null or length(detalhe) <= 120)
);
create index if not exists uso_eventos_criado_idx on public.uso_eventos (criado_em);
create index if not exists uso_eventos_usuario_idx on public.uso_eventos (usuario_email, criado_em);

comment on table public.uso_eventos is 'Uso da plataforma: acessos, seções, painéis do Dashboard e ações (painel Usuários Ativos).';

alter table public.uso_eventos enable row level security;
revoke all on public.uso_eventos from anon;
grant select, insert on public.uso_eventos to authenticated;

drop policy if exists uso_eventos_insert on public.uso_eventos;
drop policy if exists uso_eventos_select on public.uso_eventos;
create policy uso_eventos_insert on public.uso_eventos for insert to authenticated
  with check (public.cdl_ativo() and lower(usuario_email) = lower(auth.jwt() ->> 'email'));
create policy uso_eventos_select on public.uso_eventos for select to authenticated using (public.cdl_admin());

-- ---------------------------------------------------------------------
-- Resumo para o painel: anos p_ini..p_fim (datas no fuso de Cuiabá).
-- ---------------------------------------------------------------------
create or replace function public.uso_resumo(p_ini date, p_fim date)
returns table (mes text, usuario_email text, tipo text, secao text, detalhe text, qtd bigint, dias bigint)
language plpgsql stable security definer
set search_path = public, auth
as $$
begin
  if not (public.cdl_admin() or exists (
    select 1 from public.usuarios u
     where lower(u.email) = lower(auth.jwt() ->> 'email')
       and u.status = 'Ativo'
       and u.secoes_permitidas ? 'dashboard'
       and jsonb_typeof(u.dashboards_permitidos) = 'array'
       and u.dashboards_permitidos ? 'uso')) then
    raise exception 'Sem acesso ao painel Usuários Ativos.' using errcode = '42501';
  end if;
  return query
    with ev as (
      select lower(e.usuario_email) as email, e.tipo as t, e.secao as s,
             case when e.tipo in ('painel', 'acao') then e.detalhe end as det,
             to_char(e.criado_em at time zone 'America/Cuiaba', 'YYYY-MM') as m,
             (e.criado_em at time zone 'America/Cuiaba')::date as d
        from public.uso_eventos e
       where (e.criado_em at time zone 'America/Cuiaba')::date between p_ini and p_fim
    ), dias_mes as (
      select ev.m, ev.email, count(distinct ev.d) as n from ev group by ev.m, ev.email
    )
    select ev.m, ev.email, ev.t, ev.s, ev.det, count(*)::bigint, max(dm.n)::bigint
      from ev join dias_mes dm on dm.m = ev.m and dm.email = ev.email
     group by ev.m, ev.email, ev.t, ev.s, ev.det
     order by 1, 2, 3, 4, 5;
end;
$$;

revoke all on function public.uso_resumo(date, date) from public, anon;
grant execute on function public.uso_resumo(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- Acessos (login) por dia e usuário — gráfico "Evolução dos acessos" na
-- visão Mensal (dias do mês). Mesmo controle de acesso do uso_resumo().
-- ---------------------------------------------------------------------
create or replace function public.uso_logins_dia(p_ini date, p_fim date)
returns table (dia date, usuario_email text, qtd bigint)
language plpgsql stable security definer
set search_path = public, auth
as $$
begin
  if not (public.cdl_admin() or exists (
    select 1 from public.usuarios u
     where lower(u.email) = lower(auth.jwt() ->> 'email')
       and u.status = 'Ativo'
       and u.secoes_permitidas ? 'dashboard'
       and jsonb_typeof(u.dashboards_permitidos) = 'array'
       and u.dashboards_permitidos ? 'uso')) then
    raise exception 'Sem acesso ao painel Usuários Ativos.' using errcode = '42501';
  end if;
  return query
    select (e.criado_em at time zone 'America/Cuiaba')::date, lower(e.usuario_email), count(*)::bigint
      from public.uso_eventos e
     where e.tipo = 'login' and (e.criado_em at time zone 'America/Cuiaba')::date between p_ini and p_fim
     group by 1, 2
     order by 1, 2;
end;
$$;

revoke all on function public.uso_logins_dia(date, date) from public, anon;
grant execute on function public.uso_logins_dia(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- Integração com Usuários › Último acesso: uma entrada na plataforma é
-- gravada uma vez só, no mesmo instante, nos dois lugares — a coluna
-- usuarios.ultimo_acesso (seção Usuários) e o evento 'login' (painel).
-- registrar_acesso() é a mesma função que o app já chama ao entrar.
-- ---------------------------------------------------------------------
create or replace function public.registrar_acesso()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
  v_agora timestamptz := now();
begin
  update public.usuarios u
     set ultimo_acesso = v_agora
    from auth.users a
   where a.id = auth.uid()
     and a.email_confirmed_at is not null
     and lower(a.email) = lower(u.email)
     and u.status = 'Ativo'
  returning lower(u.email) into v_email;
  if v_email is not null then
    insert into public.uso_eventos (criado_em, usuario_email, tipo) values (v_agora, v_email, 'login');
  end if;
end;
$$;

revoke all on function public.registrar_acesso() from public, anon;
grant execute on function public.registrar_acesso() to authenticated;

-- Histórico: o último acesso já gravado em Usuários vira o evento de login
-- correspondente (uma vez só — rodar de novo não duplica).
insert into public.uso_eventos (criado_em, usuario_email, tipo, detalhe)
select u.ultimo_acesso, lower(u.email), 'login', 'ultimo_acesso'
  from public.usuarios u
 where u.ultimo_acesso is not null
   and not exists (select 1 from public.uso_eventos e
                    where e.tipo = 'login' and lower(e.usuario_email) = lower(u.email) and e.criado_em = u.ultimo_acesso);

notify pgrst, 'reload schema';

-- Conferência: as 2 regras de acesso, as funções e, por usuário, o último
-- acesso da seção Usuários ao lado do último login do painel (devem ser iguais).
select policyname, cmd from pg_policies where schemaname = 'public' and tablename = 'uso_eventos' order by cmd;
select proname from pg_proc where proname in ('uso_resumo', 'uso_logins_dia', 'registrar_acesso') order by proname;
select u.nome, u.ultimo_acesso as ultimo_acesso_usuarios,
       (select max(e.criado_em) from public.uso_eventos e where e.tipo = 'login' and lower(e.usuario_email) = lower(u.email)) as ultimo_login_painel
  from public.usuarios u
 order by u.ultimo_acesso desc nulls last;
