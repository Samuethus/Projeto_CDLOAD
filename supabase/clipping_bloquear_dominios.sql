-- =====================================================================
-- CDLoad · Clipping News — sites bloqueados (medida de segurança)
--
-- Cadastro ÚNICO de todos os sites com bloqueio manual. De um domínio
-- bloqueado (e de qualquer subdomínio dele: www., m., ...) nada é:
--   • gravado    — a coleta do Google Notícias descarta na hora;
--   • acessado   — a verificação não abre a matéria nem baixa a imagem;
--   • exibido    — o que já estava gravado vira 'bloqueada', perde links e
--                  imagem e some do app e do Dashboard.
--
-- Rode em Supabase > SQL Editor. É idempotente.
--
-- PARA BLOQUEAR OUTRO SITE: acrescente uma linha na lista do passo 2
-- (domínio sem http/www, motivo, data) e rode o arquivo inteiro de novo.
-- Mantenha também a lista CLIP_DOMINIOS_BLOQUEADOS em index.html igual a
-- esta (segunda barreira no navegador).
--
-- Sites bloqueados hoje:
--   pnbonline.com.br  · 01/09/2026 · alerta do antivírus ao acessar o portal
--   jknoticias.com    · 07/10/2026 · bloqueio manual solicitado pela equipe
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Cadastro (só as funções de coleta leem; nada exposto à API)
-- ---------------------------------------------------------------------
create table if not exists public.clipping_dominios_bloqueados (
  dominio       text primary key check (dominio = lower(btrim(dominio)) and dominio !~ '^(https?://|www\.)'),
  motivo        text not null,
  bloqueado_em  date not null default current_date
);
alter table public.clipping_dominios_bloqueados enable row level security;
revoke all on public.clipping_dominios_bloqueados from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Lista de sites bloqueados  <<< inclua novos aqui >>>
-- ---------------------------------------------------------------------
insert into public.clipping_dominios_bloqueados (dominio, motivo, bloqueado_em) values
  ('pnbonline.com.br', 'Segurança: alerta do antivírus ao acessar o portal', date '2026-09-01'),
  ('jknoticias.com',   'Segurança: bloqueio manual solicitado pela equipe',  date '2026-10-07')
on conflict (dominio) do update set motivo = excluded.motivo, bloqueado_em = excluded.bloqueado_em;

-- ---------------------------------------------------------------------
-- 3. A função usada pela coleta e pela verificação passa a ler o cadastro
--    (antes era uma lista fixa só com o PNB Online).
-- ---------------------------------------------------------------------
create or replace function public.clipping_dominio_bloqueado(url_ou_dominio text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.clipping_dominios_bloqueados b
     where coalesce(public.clipping_dominio(url_ou_dominio), lower(btrim(url_ou_dominio))) = b.dominio
        or coalesce(public.clipping_dominio(url_ou_dominio), lower(btrim(url_ou_dominio))) like '%.' || b.dominio
  )
$$;
revoke all on function public.clipping_dominio_bloqueado(text) from public, anon;

-- ---------------------------------------------------------------------
-- 4. O que já estava gravado desses sites sai do app agora
--    (pelo domínio do portal, pelo link da matéria ou pelo nome da fonte).
-- ---------------------------------------------------------------------
update public.clipping_news
   set verificacao = 'bloqueada', verificada_em = now(), link = null, link_original = null, imagem_url = null
 where (public.clipping_dominio_bloqueado(portal_dominio)
        or public.clipping_dominio_bloqueado(link_original)
        or public.clipping_dominio_bloqueado(link)
        or public.clipping_dominio_bloqueado(fonte))
   and verificacao is distinct from 'bloqueada';

update public.clipping_portais set url = null where public.clipping_dominio_bloqueado(dominio);

-- ---------------------------------------------------------------------
-- 5. Conferência
-- ---------------------------------------------------------------------
-- Sites bloqueados e quantas notícias de cada um ficaram retidas:
select b.dominio, b.motivo, to_char(b.bloqueado_em, 'DD/MM/YYYY') as bloqueado_em,
       (select count(*) from public.clipping_news n
         where n.verificacao = 'bloqueada'
           and (n.portal_dominio = b.dominio or n.portal_dominio like '%.' || b.dominio
                or lower(n.fonte) like '%' || b.dominio || '%')) as noticias_retidas
  from public.clipping_dominios_bloqueados b
 order by b.bloqueado_em, b.dominio;

-- Deve voltar vazio: nenhuma notícia visível no app vinda de site bloqueado.
select id, titulo, fonte, portal_dominio
  from public.clipping_news
 where coalesce(verificacao, '') not in ('duplicada', 'bloqueada', 'fora_escopo')
   and (public.clipping_dominio_bloqueado(portal_dominio)
        or public.clipping_dominio_bloqueado(link_original)
        or public.clipping_dominio_bloqueado(link)
        or public.clipping_dominio_bloqueado(fonte));
