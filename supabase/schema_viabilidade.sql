-- ============================================================================
-- CDLoad · Dashboard › Painel · Viabilidade: dados editáveis no Supabase
--
-- Rode em Supabase > SQL Editor (idempotente) DEPOIS de schema_usuarios_edicao.sql
-- (usa cdl_secao e cdl_pode_editar).
--
-- Antes os valores vinham fixos de assets/data/viabilidades.js. Agora o painel lê
-- estas tabelas; o arquivo continua como reserva (tabela vazia ou inexistente) e
-- como fonte das logos.
--
--   viabilidade_itens        uma linha por item do painel:
--     tipo = 'ferramenta'    custo anual = preco × frequencia (× licenças se por_licenca)
--     tipo = 'modulo'        pró (objetivo, prioridade, periodicidade, frequencia, horas)
--                            e contra (contra_objetivo, contra_prioridade) de cada módulo
--     tipo = 'plano'         captação = preco × leads (filtro Simulação Leads) × 12
--   viabilidade_parametros   linha única (id = 1): dias úteis por mês
--
-- Acesso: lê quem tem a seção Dashboard; edita/inclui/exclui quem pode editar
-- o Dashboard (Administrador, ou usuário com "Edição" e a seção liberada).
-- O seed só roda com a tabela vazia: rodar de novo não apaga edições.
-- ============================================================================

create table if not exists public.viabilidade_itens (
  id                 uuid primary key default gen_random_uuid(),
  tipo               text not null check (tipo in ('ferramenta', 'modulo', 'plano')),
  ordem              integer not null default 0,
  nome               text not null,
  descricao          text,
  objetivo           text,
  prioridade         text check (prioridade is null or prioridade in ('Alta', 'Média', 'Baixa')),
  plano              text,
  periodicidade      text check (periodicidade is null or periodicidade in ('Diário', 'Mensal', 'Anual')),
  frequencia         numeric check (frequencia is null or frequencia >= 0),
  preco              numeric check (preco is null or preco >= 0),
  horas              numeric check (horas is null or horas >= 0),
  por_licenca        boolean not null default false,
  logo               text,
  contra_objetivo    text,
  contra_prioridade  text check (contra_prioridade is null or contra_prioridade in ('Alta', 'Média', 'Baixa')),
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);

create index if not exists viabilidade_itens_tipo_ordem on public.viabilidade_itens (tipo, ordem);

comment on table public.viabilidade_itens is
  'Dashboard › Painel · Viabilidade: ferramentas (custo), módulos do CDLoad (prós × contras, horas salvas) e planos (captação).';

create table if not exists public.viabilidade_parametros (
  id              integer primary key default 1 check (id = 1),
  dias_uteis_mes  integer not null default 22 check (dias_uteis_mes between 1 and 31),
  atualizado_em   timestamptz not null default now(),
  atualizado_por  text
);

-- Carimbo de quem/quando editou (e-mail do login).
create or replace function public.viabilidade_carimbo()
returns trigger
language plpgsql
set search_path = public, auth
as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := coalesce(auth.jwt() ->> 'email', new.atualizado_por);
  return new;
end;
$$;

drop trigger if exists viabilidade_itens_carimbo on public.viabilidade_itens;
create trigger viabilidade_itens_carimbo before insert or update on public.viabilidade_itens
  for each row execute function public.viabilidade_carimbo();
drop trigger if exists viabilidade_parametros_carimbo on public.viabilidade_parametros;
create trigger viabilidade_parametros_carimbo before insert or update on public.viabilidade_parametros
  for each row execute function public.viabilidade_carimbo();

-- ---------- Acesso ----------
alter table public.viabilidade_itens enable row level security;
alter table public.viabilidade_parametros enable row level security;

revoke all on public.viabilidade_itens, public.viabilidade_parametros from anon;
grant select, insert, update, delete on public.viabilidade_itens, public.viabilidade_parametros to authenticated;

drop policy if exists viab_itens_select on public.viabilidade_itens;
drop policy if exists viab_itens_insert on public.viabilidade_itens;
drop policy if exists viab_itens_update on public.viabilidade_itens;
drop policy if exists viab_itens_delete on public.viabilidade_itens;
create policy viab_itens_select on public.viabilidade_itens for select to authenticated
  using (public.cdl_secao('dashboard'));
create policy viab_itens_insert on public.viabilidade_itens for insert to authenticated
  with check (public.cdl_pode_editar('dashboard'));
create policy viab_itens_update on public.viabilidade_itens for update to authenticated
  using (public.cdl_pode_editar('dashboard')) with check (public.cdl_pode_editar('dashboard'));
create policy viab_itens_delete on public.viabilidade_itens for delete to authenticated
  using (public.cdl_pode_editar('dashboard'));

drop policy if exists viab_param_select on public.viabilidade_parametros;
drop policy if exists viab_param_insert on public.viabilidade_parametros;
drop policy if exists viab_param_update on public.viabilidade_parametros;
create policy viab_param_select on public.viabilidade_parametros for select to authenticated
  using (public.cdl_secao('dashboard'));
create policy viab_param_insert on public.viabilidade_parametros for insert to authenticated
  with check (public.cdl_pode_editar('dashboard'));
create policy viab_param_update on public.viabilidade_parametros for update to authenticated
  using (public.cdl_pode_editar('dashboard')) with check (public.cdl_pode_editar('dashboard'));

-- ---------- Carga inicial (valores da planilha, out/2026 — iguais a viabilidades.js) ----------
insert into public.viabilidade_parametros (id, dias_uteis_mes) values (1, 22)
on conflict (id) do nothing;

insert into public.viabilidade_itens
  (tipo, ordem, nome, logo, descricao, objetivo, prioridade, plano, periodicidade, frequencia, preco, por_licenca)
select * from (values
  ('ferramenta', 1, 'Power BI',      'powerbi',      'Ferramenta de manipulação e análise de dados', 'Painéis de dados',               'Alta',  'Licença por usuário', 'Mensal', 12::numeric, 109.20::numeric, true),
  ('ferramenta', 2, 'Survey Monkey', 'surveymonkey', 'Criação e gestão de formulários',              'Captura de dados do mercado',    'Alta',  'Plano individual',    'Anual',  12, 100,    false),
  ('ferramenta', 3, 'GisMaps',       'gismaps',      'Criação de mapas',                             'Criação rápida de mapas',        'Alta',  'Plano individual',    'Anual',  1,  120,    false),
  ('ferramenta', 4, 'Canva',         'canva',        'Construção de materiais visuais',              'Layout relatórios / dashboards', 'Média', 'Canva Pro',           'Mensal', 12, 35,     false),
  ('ferramenta', 5, 'Claude',        'claude',       'Automatização de processos',                   'Agente de IA – assessoria',      'Média', 'Claude Pro',          'Mensal', 12, 110,    false)
) v
where not exists (select 1 from public.viabilidade_itens where tipo = 'ferramenta');

insert into public.viabilidade_itens
  (tipo, ordem, nome, objetivo, prioridade, periodicidade, frequencia, horas, contra_objetivo, contra_prioridade)
select * from (values
  ('modulo', 1, 'Home',       'Centralização dos painéis', 'Alta', 'Diário', 2::numeric, 0.1::numeric, 'Nenhum',                    'Baixa'),
  ('modulo', 2, 'Dashboard',  'Dados online – CAGED',      'Alta', 'Mensal', 1, 5,   'Dados sensíveis não podem', 'Baixa'),
  ('modulo', 3, 'Clipping',   'Pesquisa online',           'Alta', 'Diário', 5, 0.1, 'Segurança',                 'Média'),
  ('modulo', 4, 'Usuários',   'Controle de acesso',        'Alta', 'Mensal', 2, 0.5, 'Alta demanda',              'Baixa'),
  ('modulo', 5, 'Relatórios', 'Gerador automático PDF',    'Alta', 'Diário', 1, 2,   'Nenhum',                    'Baixa')
) v
where not exists (select 1 from public.viabilidade_itens where tipo = 'modulo');

insert into public.viabilidade_itens
  (tipo, ordem, nome, objetivo, prioridade, plano, periodicidade, preco)
select 'plano', 1, 'Planos Consultoria', 'Prestação de serviço CDLs', 'Alta', 'Profissional', 'Mensal', 120
where not exists (select 1 from public.viabilidade_itens where tipo = 'plano');

notify pgrst, 'reload schema';

-- Conferência: 5 ferramentas, 5 módulos, 1 plano.
select tipo, count(*) from public.viabilidade_itens group by tipo order by tipo;
