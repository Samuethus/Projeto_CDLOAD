-- ============================================================================
-- CDLoad · Segurança do banco (Supabase Auth + RLS)
--
-- Rode UMA vez em Supabase > SQL Editor, DEPOIS de ler supabase/LEIA-ME.md.
-- É idempotente: pode rodar de novo sem quebrar.
--
-- O que faz:
--   1. Remove as policies permissivas antigas (anon com acesso total).
--   2. Tira TODO acesso do papel `anon` às tabelas do app.
--   3. Libera acesso só para quem está logado (Supabase Auth), tem e-mail
--      confirmado, está cadastrado e Ativo em `usuarios`, e tem a seção
--      correspondente liberada (ou é Administrador).
--   4. Editar (UPDATE) e excluir (DELETE) dados é exclusivo de Administrador,
--      mesmo para quem tem todas as seções liberadas. Quem tem a seção só
--      lê e cria registros.
--   5. Apaga a coluna `usuarios.senha` (senhas passam a ficar no Supabase Auth, com hash).
--
-- ATENÇÃO: depois deste script o app só funciona com login pelo Supabase Auth.
-- Cada pessoa precisa fazer o "Primeiro acesso" na tela de login.
-- ============================================================================

-- ---------- 1. Funções auxiliares (security definer: leem `usuarios` sem recursão de RLS) ----------

create or replace function public.cdl_ativo()
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
  );
$$;

create or replace function public.cdl_admin()
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
      and u.cargo = 'Administrador'
  );
$$;

create or replace function public.cdl_secao(chave text)
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
      and (u.cargo = 'Administrador' or u.secoes_permitidas ? chave)
  );
$$;

revoke all on function public.cdl_ativo(), public.cdl_admin(), public.cdl_secao(text) from public, anon;
grant execute on function public.cdl_ativo(), public.cdl_admin(), public.cdl_secao(text) to authenticated;

-- ---------- 2. Senhas fora da tabela ----------

alter table public.usuarios drop column if exists senha;

-- ---------- 3. Limpa policies antigas e bloqueia o anon ----------

do $$
declare
  t text;
  pol record;
begin
  foreach t in array array['campanhas','usuarios','clipping_news','local','cadastro_de_produtos','movimentacoes_estoque','relatorios_arquivos']
  loop
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- A view de saldo passa a respeitar o RLS de quem consulta.
alter view public.vw_estoque_saldo set (security_invoker = true);
revoke all on public.vw_estoque_saldo from anon;
grant select on public.vw_estoque_saldo to authenticated;

-- ---------- 4. Policies ----------

-- usuarios: qualquer usuário ativo lê (o Estoque lista nomes/e-mails); só administrador altera.
create policy usuarios_select on public.usuarios for select to authenticated using (public.cdl_ativo());
create policy usuarios_insert on public.usuarios for insert to authenticated with check (public.cdl_admin());
create policy usuarios_update on public.usuarios for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy usuarios_delete on public.usuarios for delete to authenticated using (public.cdl_admin());

-- campanhas: seção "campanhas" lê e cria; editar/remover só Administrador.
create policy campanhas_select on public.campanhas for select to authenticated using (public.cdl_secao('campanhas'));
create policy campanhas_insert on public.campanhas for insert to authenticated with check (public.cdl_secao('campanhas'));
create policy campanhas_update on public.campanhas for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy campanhas_delete on public.campanhas for delete to authenticated using (public.cdl_admin());

-- local (salas do wizard de campanhas): lê quem tem "campanhas"; só administrador altera
create policy local_select on public.local for select to authenticated using (public.cdl_secao('campanhas'));
create policy local_insert on public.local for insert to authenticated with check (public.cdl_admin());
create policy local_update on public.local for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy local_delete on public.local for delete to authenticated using (public.cdl_admin());

-- clipping_news: seção "clipping" lê e cria; editar/ocultar/remover só
-- Administrador (as coletas automáticas rodam em funções security definer).
create policy clipping_select on public.clipping_news for select to authenticated using (public.cdl_secao('clipping'));
create policy clipping_insert on public.clipping_news for insert to authenticated with check (public.cdl_secao('clipping'));
create policy clipping_update on public.clipping_news for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy clipping_delete on public.clipping_news for delete to authenticated using (public.cdl_admin());

-- estoque: seção "estoque" lê e cria; editar ou remover produto (e todo o
-- histórico junto, por causa do cascade) fica só para Administrador.
create policy produtos_select on public.cadastro_de_produtos for select to authenticated using (public.cdl_secao('estoque'));
create policy produtos_insert on public.cadastro_de_produtos for insert to authenticated with check (public.cdl_secao('estoque'));
create policy produtos_update on public.cadastro_de_produtos for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy produtos_delete on public.cadastro_de_produtos for delete to authenticated using (public.cdl_admin());

-- movimentações: o autor não pode ser forjado; ajustar ou remover um
-- lançamento (o que reescreve o saldo) fica só para Administrador — o
-- gatilho estoque_valida_ajuste impede saldo negativo e registra o ajuste.
create policy mov_select on public.movimentacoes_estoque for select to authenticated using (public.cdl_secao('estoque'));
create policy mov_insert on public.movimentacoes_estoque for insert to authenticated
  with check (
    public.cdl_secao('estoque')
    and (usuario_email is null or lower(usuario_email) = lower(auth.jwt() ->> 'email'))
  );
create policy mov_update on public.movimentacoes_estoque for update to authenticated using (public.cdl_admin()) with check (public.cdl_admin());
create policy mov_delete on public.movimentacoes_estoque for delete to authenticated using (public.cdl_admin());

-- relatorios_arquivos: seção "relatorios" lê e envia; o autor não pode
-- ser forjado; remover um material (e o arquivo correspondente no
-- Storage, apagado pelo app logo em seguida) fica só para Administrador.
create policy relatorios_select on public.relatorios_arquivos for select to authenticated using (public.cdl_secao('relatorios'));
create policy relatorios_insert on public.relatorios_arquivos for insert to authenticated
  with check (
    public.cdl_secao('relatorios')
    and (usuario_email is null or lower(usuario_email) = lower(auth.jwt() ->> 'email'))
  );
create policy relatorios_delete on public.relatorios_arquivos for delete to authenticated using (public.cdl_admin());

-- Storage do módulo Relatórios (bucket "relatorios"): mesmo controle de
-- acesso da tabela acima — ler/enviar exige a seção; remover é só admin.
drop policy if exists relatorios_storage_select on storage.objects;
drop policy if exists relatorios_storage_insert on storage.objects;
drop policy if exists relatorios_storage_delete on storage.objects;

create policy relatorios_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'relatorios' and public.cdl_secao('relatorios'));
create policy relatorios_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'relatorios' and public.cdl_secao('relatorios'));
create policy relatorios_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'relatorios' and public.cdl_admin());

-- ---------- 5. Conferência (rode e leia o resultado) ----------
-- Deve listar o administrador com cargo 'Administrador' e status 'Ativo'.
-- Se o e-mail dele não estiver aqui, insira/corrija ANTES de sair da página:
--   insert into public.usuarios (nome, email, cargo, status, secoes_permitidas)
--   values ('Administrador', 'SEU-EMAIL-DE-ADMIN', 'Administrador', 'Ativo', '[]'::jsonb)
--   on conflict (email) do update set cargo = 'Administrador', status = 'Ativo';
select nome, email, cargo, status from public.usuarios where cargo = 'Administrador';
