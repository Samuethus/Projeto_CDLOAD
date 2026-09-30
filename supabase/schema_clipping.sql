-- =====================================================================
-- CDLoad · Clipping News — coleta automática no Google Notícias
--
-- Execute em Supabase > SQL Editor DEPOIS de `seguranca_rls.sql` (usa a
-- função `cdl_secao`). É idempotente: pode ser rodado de novo sem
-- apagar dados.
--
-- O que faz:
--   1. Garante a tabela `clipping_news` e acrescenta as colunas da coleta
--      (link, id do Google, termo buscado, data/hora exata, ocultação).
--   2. Corrige o erro "permission denied for table clipping_news":
--      concede os privilégios ao papel `authenticated` (o RLS continua
--      exigindo login + seção "clipping" liberada) e tira tudo do `anon`.
--   3. Cria `clipping_coletar()`, que busca no RSS do Google Notícias as
--      palavras-chave abaixo e grava só as notícias novas (sem duplicar).
--   4. Agenda a coleta a cada 30 minutos (pg_cron) e roda a primeira agora.
--   5. Portais: cada notícia aponta para `clipping_portais` pelo domínio
--      do veículo, com um nome padrão por portal (o Google às vezes chama
--      o mesmo site de "Diario de Cuiabá" e de "diariodecuiaba.com.br").
--   6. Verificação: `clipping_verificar_materias()` abre cada matéria e só
--      a publica no app se ela CITA uma das palavras-chave no texto (não
--      conta menção só em links "Leia também", menus e rodapés). Aproveita
--      e guarda o link real e a imagem de capa (og:image). Lotes a cada 5 min.
--   7. Site oficial: `clipping_coletar_site_cdl()` lê TODAS as matérias de
--      cdlcuiaba.com.br/ultimas-noticias (com a capa), a cada 30 min, sem
--      checagem de palavra-chave. Portal: "Site Oficial".
--   8. Busca ampliada no Google: janelas de 1/7/30 dias a cada 30 min +
--      varredura diária mês a mês do ano.
--   9. Domínios bloqueados (clipping_dominio_bloqueado): pnbonline.com.br
--      nunca é gravado nem acessado.
--
--  10. Escopo atual (substitui a regra de citação no texto): TODAS as
--      notícias do Google Notícias sobre dois atores, para comparação no
--      Dashboard — cada uma marcada em `players`:
--        CDL Cuiabá    : "CDL Cuiabá", "Câmara de Dirigentes Lojistas de
--                        Cuiabá", "Fundação CDL Cuiabá" (+ site oficial)
--        Fecomércio MT : "Fecomércio MT", "Fecomércio Mato Grosso"
--      Para trocar, edite a função clipping_players() e rode de novo.
--      A verificação só completa link direto e imagem (não filtra mais) e
--      o Bing saiu da busca.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.cdl_secao(text)') is null then
    raise exception 'Rode supabase/seguranca_rls.sql antes deste arquivo (falta a função cdl_secao).';
  end if;
end $$;

create extension if not exists pgcrypto;
create extension if not exists http with schema extensions;  -- requisições HTTP de dentro do banco
create extension if not exists pg_cron;                       -- agendamento

-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------
create table if not exists public.clipping_news (
  id                uuid primary key default gen_random_uuid(),
  titulo            text not null,
  resumo            text not null,
  fonte             text not null,
  data_publicacao   date not null,
  categoria         text not null,
  canal             text not null,
  sentimento        text not null default 'Neutro', -- 'Positivo' | 'Neutro' | 'Negativo'
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.clipping_news add column if not exists origem       text not null default 'manual'; -- 'manual' | 'google_news'
alter table public.clipping_news add column if not exists link         text;
alter table public.clipping_news add column if not exists google_id    text;
alter table public.clipping_news add column if not exists termo_busca  text;
alter table public.clipping_news add column if not exists publicado_em timestamptz;
-- Notícia do Google removida no app fica só oculta: se fosse apagada,
-- voltaria na coleta seguinte.
alter table public.clipping_news add column if not exists oculta       boolean not null default false;

-- Portais (veículos): um nome padrão por domínio.
create table if not exists public.clipping_portais (
  dominio     text primary key,          -- ex.: gazetadigital.com.br
  nome        text not null,             -- ex.: Gazeta Digital
  url         text,                      -- página inicial do portal
  created_at  timestamptz not null default now()
);

alter table public.clipping_news add column if not exists portal_dominio text
  references public.clipping_portais (dominio) on update cascade on delete set null;
-- Link direto da matéria no portal (o `link` é o redirecionamento do Google).
alter table public.clipping_news add column if not exists link_original     text;
alter table public.clipping_news add column if not exists imagem_url        text;
-- null = pendente | 'ok' | 'sem_imagem' | 'erro' (tenta até 3 vezes)
alter table public.clipping_news add column if not exists imagem_status     text;
alter table public.clipping_news add column if not exists imagem_tentativas integer not null default 0;
-- A matéria cita a palavra-chave? null = ainda não verificada | 'confirmada'
-- | 'descartada' (não cita) | 'erro' (tenta até 3 vezes) | 'nao_verificavel'.
-- O app só mostra notícias do Google 'confirmada'.
alter table public.clipping_news add column if not exists verificacao       text;
alter table public.clipping_news add column if not exists verificada_em     timestamptz;
-- Notícias gravadas antes da verificação existir: recomeça a contagem de tentativas.
update public.clipping_news set imagem_tentativas = 0
 where origem = 'google_news' and verificacao is null and imagem_tentativas <> 0;
create index if not exists clipping_news_verificacao_idx on public.clipping_news (verificacao);
-- Id da matéria na fonte lida diretamente (ex.: 'cdl:4978' = cdlcuiaba.com.br/noticias/.../4978).
alter table public.clipping_news add column if not exists fonte_id          text;
create unique index if not exists clipping_news_fonte_id_key on public.clipping_news (fonte_id);
-- Endereço da matéria normalizado (sem http/www/parâmetros): a mesma
-- matéria achada pelo Google e no site oficial vira uma só.
alter table public.clipping_news add column if not exists link_chave        text;
create index if not exists clipping_news_link_chave_idx on public.clipping_news (link_chave);
-- Ator(es) a que a notícia se refere: 'CDL Cuiabá', 'Fecomércio MT' (ver clipping_players).
alter table public.clipping_news add column if not exists players           text[] not null default '{}';
create index if not exists clipping_news_players_idx on public.clipping_news using gin (players);

create index if not exists clipping_news_portal_idx on public.clipping_news (portal_dominio);
create unique index if not exists clipping_news_google_id_key on public.clipping_news (google_id);
create index if not exists clipping_news_recentes_idx
  on public.clipping_news (data_publicacao desc, publicado_em desc);

-- Histórico das coletas (o app mostra "Atualizado em ...").
create table if not exists public.clipping_coletas (
  id             bigint generated always as identity primary key,
  iniciado_em    timestamptz not null default now(),
  finalizado_em  timestamptz,
  origem         text not null,          -- 'automatica' (pg_cron / SQL Editor) | 'app'
  encontradas    integer not null default 0,
  novas          integer not null default 0,
  erros          text
);
create index if not exists clipping_coletas_iniciado_idx on public.clipping_coletas (iniciado_em desc);

-- ---------------------------------------------------------------------
-- 2. Privilégios + RLS (mesmas regras de seguranca_rls.sql)
-- ---------------------------------------------------------------------
alter table public.clipping_news enable row level security;
alter table public.clipping_coletas enable row level security;
alter table public.clipping_portais enable row level security;

revoke all on public.clipping_news, public.clipping_coletas, public.clipping_portais from anon;
grant select, insert, update, delete on public.clipping_news to authenticated;
grant select on public.clipping_coletas to authenticated;  -- gravação só via clipping_coletar()
grant select on public.clipping_portais to authenticated;  -- idem
grant all on public.clipping_news, public.clipping_coletas, public.clipping_portais to service_role;

drop policy if exists clipping_portais_select on public.clipping_portais;
create policy clipping_portais_select on public.clipping_portais for select to authenticated using (public.cdl_secao('clipping'));

drop policy if exists clipping_select on public.clipping_news;
drop policy if exists clipping_insert on public.clipping_news;
drop policy if exists clipping_update on public.clipping_news;
drop policy if exists clipping_delete on public.clipping_news;
create policy clipping_select on public.clipping_news for select to authenticated using (public.cdl_secao('clipping'));
create policy clipping_insert on public.clipping_news for insert to authenticated with check (public.cdl_secao('clipping'));
create policy clipping_update on public.clipping_news for update to authenticated using (public.cdl_secao('clipping')) with check (public.cdl_secao('clipping'));
create policy clipping_delete on public.clipping_news for delete to authenticated using (public.cdl_secao('clipping'));

drop policy if exists clipping_coletas_select on public.clipping_coletas;
create policy clipping_coletas_select on public.clipping_coletas for select to authenticated using (public.cdl_secao('clipping'));

-- ---------------------------------------------------------------------
-- 3. Classificação automática (plataforma, categoria e sentimento)
-- ---------------------------------------------------------------------

-- Plataforma a partir do nome do veículo.
create or replace function public.clipping_classificar_canal(fonte text)
returns text
language sql immutable
as $$
  select case
    when fonte ~* '(\mtv\M|globo\M|record|\msbt\M|\mband\M|tvca|centro am[eé]rica)' then 'TV'
    when fonte ~* '(r[aá]dio|\mfm\M|\mcbn\M)'                                       then 'Rádio'
    when fonte ~* '(jornal|di[aá]rio|gazeta|folha)'                                 then 'Jornal'
    when fonte ~* '(cdlcuiaba|cdl cuiab|prefeitura|\.gov|governo|sebrae|assembleia|c[aâ]mara municipal)' then 'Site institucional'
    else 'Portal'
  end
$$;

-- Categoria pelo título (a primeira regra que casar vence).
create or replace function public.clipping_classificar_categoria(t text)
returns text
language sql immutable
as $$
  select case
    when t ~* '(liquida|campanha|promo[cç]|black friday|natal|dia d[aeo]s? (m[aã]es|pais|crian[cç]as|namorados|consumidor)|sorteio|pr[eê]mio|concurso|feir[aã]o|desconto)' then 'Campanhas'
    when t ~* '(curso|capacita|palestra|workshop|qualifica|treinamento|aprendiz|inscri[cç])'                   then 'Capacitação'
    when t ~* '(golpe|seguran[cç]a|furto|roubo|assalto|crime|pol[ií]cia|fraude)'                              then 'Segurança'
    when t ~* '(digital|tecnologia|internet|\mpix\M|aplicativo|intelig[eê]ncia artificial|e-commerce|online)'  then 'Tecnologia'
    when t ~* '(venda|economia|inadimpl|juros|pesquisa|[ií]ndice|consum|varejo|emprego|\mpib\M|infla[cç]|tribut|imposto|d[ií]vida|endivid|faturamento|\mspc\M)' then 'Economia'
    when t ~* '(posse|presidente|diretoria|elei[cç]|homenag|parceria|reuni[aã]o|assembleia|anivers[aá]rio|funda[cç][aã]o)' then 'Institucional'
    else 'Comércio'
  end
$$;

-- Sentimento por contagem de termos positivos x negativos no título.
-- É uma estimativa: o sentimento pode ser corrigido no app (Editar).
create or replace function public.clipping_classificar_sentimento(t text)
returns text
language sql immutable
as $$
  with c as (
    select
      (select count(*) from unnest(array[
        'cresc', 'recorde', '\mlan[cç]a', 'inaugur', 'parceria', 'premia', 'homenag', 'conquist',
        'otimis', 'gratuit', 'oportunidade', '\mvagas\M', 'investiment', 'avan[cç]', 'melhor',
        'sucesso', 'celebra', 'comemora', 'aquec', 'movimenta', 'alta nas vendas',
        'aumento (nas|das) vendas', 'descontos?'
      ]) r where t ~* r) as pos,
      (select count(*) from unnest(array[
        'queda', '\mca(i|em)\M', '\mrecu[ao]', 'retra[cç]', 'crise', 'golpe', 'fraude', 'preju[ií]z',
        'demiss', 'fechament', 'fecha(m)? as portas', 'fal[eê]ncia', 'roubo', 'furto', 'crime',
        'preocupa', 'cr[ií]tica', 'den[uú]ncia', 'protesto', 'endivid', 'pior', 'baixa nas vendas',
        'inadimpl[eê]ncia (sobe|cresce|aumenta|dispara)'
      ]) r where t ~* r) as neg
  )
  select case
    -- queda da inadimplência/endividamento é notícia boa para o comércio
    when t ~* '(inadimpl|endivid)' and t ~* '(recu|\mca(i|em)\M|queda|diminu|redu[cz])' then 'Positivo'
    when pos > neg then 'Positivo'
    when neg > pos then 'Negativo'
    else 'Neutro'
  end from c
$$;

-- ---------------------------------------------------------------------
-- 3b. Portais: nome padrão por domínio
-- ---------------------------------------------------------------------

-- Chave de comparação: minúsculas, sem acento, só letras e números.
create or replace function public.clipping_chave(v text)
returns text
language sql immutable
as $$
  select regexp_replace(
    translate(lower(coalesce(v, '')),
              'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'),
    '[^a-z0-9]', '', 'g')
$$;

-- Domínio a partir de uma URL: "https://www.gazetadigital.com.br/x" -> "gazetadigital.com.br".
create or replace function public.clipping_dominio(url text)
returns text
language sql immutable
as $$
  select nullif(lower(substring(url from '^https?://(?:www\.)?([^/:?#]+)')), '')
$$;

-- Nomes padronizados dos portais já conhecidos. Portal novo entra com o
-- nome que o Google usar; para padronizar, inclua aqui e rode de novo.
insert into public.clipping_portais (dominio, nome, url) values
  ('sapicua.com.br',             'Sapicuá',              'https://www.sapicua.com.br'),
  ('diariodecuiaba.com.br',      'Diário de Cuiabá',     'https://www.diariodecuiaba.com.br'),
  ('rdnews.com.br',              'RDNews',               'https://www.rdnews.com.br'),
  ('gazetadigital.com.br',       'Gazeta Digital',       'https://www.gazetadigital.com.br'),
  ('matogrossoeconomico.com.br', 'MT Econômico',         'https://www.matogrossoeconomico.com.br'),
  ('g1.globo.com',               'G1',                   'https://g1.globo.com'),
  ('primeirapagina.com.br',      'Primeira Página',      'https://www.primeirapagina.com.br'),
  ('cdlcuiaba.com.br',           'Site Oficial',         'https://www.cdlcuiaba.com.br'),
  ('circuitomt.com.br',          'Circuito MT',          'https://www.circuitomt.com.br'),
  ('midiajur.com.br',            'MídiaJur',             'https://www.midiajur.com.br'),
  ('obomdanoticia.com.br',       'O Bom da Notícia',     'https://www.obomdanoticia.com.br'),
  ('folhamax.com',               'FolhaMax',             'https://www.folhamax.com'),
  ('omatogrosso.com',            'O Mato Grosso',        'https://www.omatogrosso.com'),
  ('pnbonline.com.br',           'PNB Online',           'https://www.pnbonline.com.br'),
  ('odocumento.com.br',          'O Documento',          'https://www.odocumento.com.br'),
  ('midianews.com.br',           'MidiaNews',            'https://www.midianews.com.br'),
  ('olhardireto.com.br',         'Olhar Direto',         'https://www.olhardireto.com.br'),
  ('mt.agenciasebrae.com.br',    'Agência Sebrae MT',    'https://mt.agenciasebrae.com.br'),
  ('portalmatogrosso.com.br',    'Portal Mato Grosso',   'https://www.portalmatogrosso.com.br'),
  ('noticiamax.com.br',          'Notícia Max',          'https://www.noticiamax.com.br'),
  ('onortao.com.br',             'O Nortão',             'https://www.onortao.com.br'),
  ('hnt.com.br',                 'HiperNotícias',        'https://www.hnt.com.br'),
  ('plantaonews.com.br',         'Plantão News',         'https://www.plantaonews.com.br'),
  ('olivre.com.br',              'O Livre',              'https://www.olivre.com.br'),
  ('bra1.com.br',                'Bra1',                 'https://www.bra1.com.br'),
  ('cliquef5.com.br',            'Clique F5',            'https://www.cliquef5.com.br'),
  ('semana7.com.br',             'Semana 7',             'https://www.semana7.com.br'),
  ('unicanews.com.br',           'Única News',           'https://www.unicanews.com.br'),
  ('aguaboanews.com.br',         'Água Boa News',        'https://www.aguaboanews.com.br'),
  ('cbncuiaba.com.br',           'CBN Cuiabá',           'https://www.cbncuiaba.com.br'),
  ('cuiaba.mt.gov.br',           'Prefeitura de Cuiabá', 'https://www.cuiaba.mt.gov.br'),
  ('vgnoticias.com.br',          'VG Notícias',          'https://www.vgnoticias.com.br'),
  ('estacaolivremt.com.br',      'Estação Livre MT',     'https://www.estacaolivremt.com.br'),
  ('en.com.br',                  'EN',                   'https://www.en.com.br')
on conflict (dominio) do update set nome = excluded.nome, url = excluded.url;

-- Garante o portal de uma notícia e devolve o domínio. O nome fica o
-- primeiro recebido; só é trocado se o atual for o próprio domínio
-- ("rdnews.com.br") e chegar um nome de verdade ("Rdnews").
create or replace function public.clipping_registrar_portal(p_url text, p_nome text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dominio text := public.clipping_dominio(p_url);
  v_nome    text := nullif(btrim(p_nome), '');
begin
  if v_dominio is null then return null; end if;
  insert into public.clipping_portais (dominio, nome, url)
  values (v_dominio, coalesce(v_nome, v_dominio), 'https://' || v_dominio)
  on conflict (dominio) do update
    set nome = excluded.nome
    where clipping_portais.nome ~* '^[a-z0-9.-]+\.[a-z]{2,}$'
      and excluded.nome !~* '^[a-z0-9.-]+\.[a-z]{2,}$';
  return v_dominio;
end;
$$;

-- Liga ao portal as notícias antigas (gravadas antes desta versão), pelo
-- nome do veículo, e padroniza o `fonte` de todas as notícias do Google.
create or replace function public.clipping_vincular_portais()
returns void
language sql
security definer
set search_path = public
as $$
  update public.clipping_news n
     set portal_dominio = p.dominio
    from public.clipping_portais p
   where n.portal_dominio is null
     and n.origem = 'google_news'
     and public.clipping_chave(n.fonte) <> ''
     and (   public.clipping_chave(n.fonte) = public.clipping_chave(p.nome)
          or public.clipping_chave(n.fonte) = public.clipping_chave(p.dominio)
          or public.clipping_chave(n.fonte) = public.clipping_chave(split_part(p.dominio, '.', 1))
          -- "HiperNotícias - Você bem informado" -> "HiperNotícias" (só nomes longos, sem casar "EN" com "Encontro")
          or (length(public.clipping_chave(p.nome)) >= 6
              and public.clipping_chave(n.fonte) like public.clipping_chave(p.nome) || '%'));

  update public.clipping_news n
     set fonte = p.nome
    from public.clipping_portais p
   where n.portal_dominio = p.dominio
     and n.origem = 'google_news'
     and n.fonte is distinct from p.nome;
$$;

-- ---------------------------------------------------------------------
-- 3c. Palavras-chave e leitura do texto da matéria
-- ---------------------------------------------------------------------

-- Atores monitorados e os termos buscados no Google Notícias para cada um
-- (frase exata). Cada notícia recebe o(s) ator(es) cujo termo a trouxe
-- (coluna `players`), base da comparação no Dashboard.
-- Para incluir um ator/termo, acrescente uma linha e rode o arquivo de novo.
create or replace function public.clipping_players()
returns table (player text, termo text, principal boolean)
language sql immutable
as $$
  select * from (values
    ('CDL Cuiabá',    'CDL Cuiabá',                              true),
    ('CDL Cuiabá',    'Câmara de Dirigentes Lojistas de Cuiabá', false),
    ('CDL Cuiabá',    'Fundação CDL Cuiabá',                     false),
    ('Fecomércio MT', 'Fecomércio MT',                           true),
    ('Fecomércio MT', 'Fecomércio Mato Grosso',                  false)
  ) v (player, termo, principal)
$$;

-- Todos os termos (compatibilidade com as funções de texto abaixo).
create or replace function public.clipping_palavras_chave()
returns text[]
language sql immutable
as $$
  select array_agg(termo) from public.clipping_players()
$$;

-- Resolve entidades HTML ("Funda&ccedil;&atilde;o" -> "Fundação"), sem
-- mexer em maiúsculas/acentos. Usada nos títulos do site da CDL e na
-- normalização abaixo.
create or replace function public.clipping_decodificar_html(v text)
returns text
language plpgsql immutable
as $$
declare
  cod text;
begin
  if v is null then return null; end if;
  for cod in select distinct m[1] from regexp_matches(v, '&#([0-9]{2,5});', 'g') m loop
    if cod::int between 32 and 55295 then
      v := replace(v, '&#' || cod || ';', chr(cod::int));
    end if;
  end loop;
  for cod in select distinct m[1] from regexp_matches(v, '&#[xX]([0-9a-fA-F]{2,4});', 'g') m loop
    if ('x' || lpad(cod, 8, '0'))::bit(32)::int between 32 and 55295 then
      v := regexp_replace(v, '&#[xX]' || cod || ';', chr(('x' || lpad(cod, 8, '0'))::bit(32)::int), 'g');
    end if;
  end loop;
  v := replace(replace(replace(replace(v, '&aacute;', 'á'), '&eacute;', 'é'), '&iacute;', 'í'), '&oacute;', 'ó');
  v := replace(replace(replace(replace(v, '&uacute;', 'ú'), '&atilde;', 'ã'), '&otilde;', 'õ'), '&ccedil;', 'ç');
  v := replace(replace(replace(replace(v, '&acirc;', 'â'), '&ecirc;', 'ê'), '&ocirc;', 'ô'), '&agrave;', 'à');
  v := replace(replace(replace(replace(v, '&Aacute;', 'Á'), '&Eacute;', 'É'), '&Atilde;', 'Ã'), '&Ccedil;', 'Ç');
  v := replace(replace(replace(replace(v, '&Iacute;', 'Í'), '&Oacute;', 'Ó'), '&Uacute;', 'Ú'), '&Ecirc;', 'Ê');
  v := replace(replace(replace(replace(v, '&quot;', '"'), '&#39;', ''''), '&apos;', ''''), '&nbsp;', ' ');
  v := replace(replace(replace(replace(v, '&ldquo;', '“'), '&rdquo;', '”'), '&lsquo;', '‘'), '&rsquo;', '’');
  v := replace(replace(replace(replace(v, '&ndash;', '–'), '&mdash;', '—'), '&lt;', '<'), '&gt;', '>');
  v := replace(v, '&amp;', '&');
  return v;
end;
$$;

-- Texto comparável: entidades HTML resolvidas, minúsculas, sem acento e
-- só letras/números separados por um espaço ("CDL-Cuiabá" = "cdl cuiaba").
create or replace function public.clipping_normalizar(v text)
returns text
language sql immutable
as $$
  select btrim(regexp_replace(
    translate(lower(coalesce(public.clipping_decodificar_html(v), '')),
              'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'),
    '[^a-z0-9]+', ' ', 'g'))
$$;

-- Texto corrido da matéria: tira scripts/estilos, menus, cabeçalho e
-- rodapé do site, barras laterais, formulários e TODO texto de link — é
-- nos links ("Leia também", "Mais lidas", manchetes de outras matérias)
-- que a palavra-chave aparece sem a matéria citá-la.
-- Obs.: no regex do Postgres a gula do padrão inteiro é a do primeiro
-- quantificador; por isso todos aqui são não-gulosos (*?).
create or replace function public.clipping_texto_materia(html text)
returns text
language plpgsql immutable
as $$
declare
  v   text := coalesce(html, '');
  tag text;
begin
  v := coalesce(substring(v from '(?i)<body[^>]*?>(.*)$'), v);
  v := regexp_replace(v, '<!--.*?-->', ' ', 'g');
  foreach tag in array array['script','style','noscript','svg','iframe','template','nav','aside','header','footer','form','select','button'] loop
    v := regexp_replace(v, '<' || tag || '(\s[^>]*?)??>.*?</' || tag || '\s*?>', ' ', 'gi');
  end loop;
  v := regexp_replace(v, '<a(\s[^>]*?)??>.*?</a\s*?>', ' ', 'gi');
  v := regexp_replace(v, '<[^>]*?>', ' ', 'g');
  return public.clipping_normalizar(v);
end;
$$;

-- O texto (já normalizado) cita alguma palavra-chave como frase inteira?
create or replace function public.clipping_cita_palavra_chave(texto_normalizado text)
returns boolean
language sql immutable
as $$
  select exists (
    select 1 from unnest(public.clipping_palavras_chave()) k
     where position(' ' || public.clipping_normalizar(k) || ' ' in ' ' || coalesce(texto_normalizado, '') || ' ') > 0)
$$;

-- ---------------------------------------------------------------------
-- 3d. Utilitários de coleta: bloqueio, links, codificação
-- ---------------------------------------------------------------------

-- Domínios que NUNCA são gravados nem acessados (segurança: alerta de antivírus).
create or replace function public.clipping_dominio_bloqueado(url_ou_dominio text)
returns boolean
language sql immutable
as $$
  select coalesce(public.clipping_dominio(url_ou_dominio), lower(btrim(url_ou_dominio)))
         ~ '(^|\.)(pnbonline\.com\.br)$'
$$;

-- Chave do endereço: sem http(s), www, parâmetros, âncora e barra final.
-- "https://www.site.com.br/materia/?utm=x" -> "site.com.br/materia"
create or replace function public.clipping_link_chave(url text)
returns text
language sql immutable
as $$
  select nullif(regexp_replace(regexp_replace(lower(btrim(url)), '^https?://(www\.)?', ''), '[?#].*$|/+$', '', 'g'), '')
$$;

-- %XX -> caractere (links do Bing vêm codificados no parâmetro url=).
create or replace function public.clipping_urldecode(v text)
returns text
language plpgsql immutable
as $$
declare
  r bytea := ''::bytea;
  i integer := 1;
  n integer;
  c text;
begin
  if v is null then return null; end if;
  n := length(v);
  while i <= n loop
    c := substr(v, i, 1);
    if c = '%' and substr(v, i + 1, 2) ~ '^[0-9a-fA-F]{2}$' then
      r := r || decode(substr(v, i + 1, 2), 'hex');
      i := i + 3;
    else
      r := r || convert_to(case when c = '+' then ' ' else c end, 'UTF8');
      i := i + 1;
    end if;
  end loop;
  return convert_from(r, 'UTF8');
end;
$$;

-- Corpo de uma resposta HTTP como texto certo. A extensão `http` entrega
-- os bytes da página como vieram; sites em ISO-8859-1/Windows-1252 (como
-- o da CDL) ficam com os acentos quebrando a leitura. Aqui os bytes são
-- relidos: UTF-8 se forem válidos, senão Windows-1252, senão Latin-1.
create or replace function public.clipping_decodificar_resposta(conteudo text)
returns text
language plpgsql immutable
as $$
declare
  b bytea;
begin
  if conteudo is null then return null; end if;
  b := textsend(conteudo);
  begin
    return convert_from(b, 'UTF8');
  exception when others then null;
  end;
  begin
    return convert_from(b, 'WIN1252');
  exception when others then null;
  end;
  return convert_from(b, 'LATIN1');
end;
$$;

-- pubDate RFC 822 em GMT ("Fri, 25 Sep 2026 07:49:17 GMT") -> timestamptz.
create or replace function public.clipping_data_rss(v text)
returns timestamptz
language plpgsql immutable
as $$
begin
  return to_timestamp(substring(v from '\d{1,2} \w{3} \d{4} \d{2}:\d{2}:\d{2}'),
                      'DD Mon YYYY HH24:MI:SS')::timestamp at time zone 'UTC';
exception when others then
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Coleta no Google Notícias — CDL Cuiabá e Fecomércio MT
--
-- Chamada pelo pg_cron (a cada 30 min, e uma varredura completa por dia),
-- pelo SQL Editor e pelo app ao abrir a seção (RPC). Para cada termo de
-- clipping_players():
--   * normal:   janelas de 1, 7 e 30 dias + busca geral;
--   * completa: + últimos 12 meses e mês a mês desde 01/01/2025 (cada mês
--               rende até 100 notícias);
--   * pelo app: só o termo principal de cada ator, últimos 7 dias (o app
--               tem limite de ~8 s).
-- Entra TUDO o que o Google devolver (sem checagem de texto), marcado com
-- o ator do termo. Desde 01/01/2025 (para permitir comparação ano a ano do
-- mesmo período) e nunca com data futura (pubDate mal formado/fuso do
-- Google); repetidas são ignoradas pelo id do Google e, quando a mesma
-- notícia vem por termos dos dois atores, ela fica marcada com os dois.
-- Ficam de fora só o site oficial da CDL (lido direto,
-- clipping_coletar_site_cdl) e domínios bloqueados.
-- ---------------------------------------------------------------------
drop function if exists public.clipping_coletar();

create or replace function public.clipping_coletar(p_completa boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  consultas    text[] := array[]::text[];
  atores       text[] := array[]::text[];   -- ator de cada consulta (mesma posição)
  janelas      text[];
  v_timeout    text := '20000';
  p            record;
  janela       text;
  i            integer;
  consulta     text;
  v_player     text;
  v_mes        date;
  v_url        text;
  resp         extensions.http_response;
  doc          xml;
  it           record;
  v_titulo     text;
  v_fonte      text;
  v_link       text;
  v_dominio    text;
  v_nova       boolean;
  v_ts         timestamptz;
  v_data       date;
  v_desde      date := date '2025-01-01';  -- fixo: permite comparar o mesmo período em anos diferentes
  v_origem     text := case when p_completa then 'completa' else 'automatica' end;
  v_app        boolean := false;
  v_ultima     timestamptz;
  v_coleta     bigint;
  v_encontradas integer := 0;
  v_novas      integer := 0;
  v_erros      text := '';
begin
  -- Pelo app (há usuário logado): confere a seção e evita coletas em sequência.
  if auth.uid() is not null then
    if not public.cdl_secao('clipping') then
      raise exception 'Sem permissão para atualizar o Clipping News.' using errcode = '42501';
    end if;
    v_app := true;
    v_origem := 'app';
    v_timeout := '3000';  -- 2 consultas x 3 s cabem no limite da API
    select max(iniciado_em) into v_ultima from public.clipping_coletas;
    if v_ultima > now() - interval '2 minutes' then
      return jsonb_build_object('ok', true, 'ignorada', true, 'ultima_coleta', v_ultima);
    end if;
  end if;

  -- Uma coleta por vez.
  if not pg_try_advisory_xact_lock(hashtext('cdload_clipping_coletar')) then
    return jsonb_build_object('ok', true, 'ignorada', true, 'motivo', 'coleta em andamento');
  end if;

  insert into public.clipping_coletas (origem) values (v_origem) returning id into v_coleta;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', v_timeout);

  -- Monta as consultas (termo entre aspas + janela), cada uma com seu ator.
  for p in select * from public.clipping_players() loop
    if v_app then
      continue when not p.principal;
      janelas := array[' when:7d'];
    else
      janelas := array[' when:1d', ' when:7d', ' when:30d', ''];
      if p_completa then
        janelas := janelas || ' when:1y'::text;
        v_mes := v_desde;
        while v_mes <= (now() at time zone 'America/Cuiaba')::date loop
          janelas := janelas || (' after:' || to_char(v_mes, 'YYYY-MM-DD')
                                 || ' before:' || to_char(v_mes + interval '1 month', 'YYYY-MM-DD'));
          v_mes := (v_mes + interval '1 month')::date;
        end loop;
      end if;
    end if;
    foreach janela in array janelas loop
      consultas := consultas || ('"' || p.termo || '"' || janela);
      atores    := atores || p.player;
    end loop;
  end loop;

  for i in 1 .. coalesce(array_length(consultas, 1), 0) loop
    consulta := consultas[i];
    v_player := atores[i];
    begin
      v_url := 'https://news.google.com/rss/search?q=' || extensions.urlencode(consulta)
            || '&hl=pt-BR&gl=BR&ceid=BR:pt-419';
      resp := extensions.http(('GET', v_url,
                array[extensions.http_header('User-Agent', 'Mozilla/5.0 (compatible; CDLoad-Clipping/1.0)')],
                null, null)::extensions.http_request);
      if resp.status <> 200 then raise exception 'HTTP %', resp.status; end if;

      -- A declaração <?xml encoding=...?> atrapalha o xmlparse de texto.
      doc := xmlparse(document regexp_replace(resp.content, '^\s*<\?xml[^>]*\?>', ''));

      for it in
        select * from xmltable('/rss/channel/item' passing doc columns
          titulo    text path 'title',
          fonte     text path 'source',
          fonte_url text path 'source/@url',
          link      text path 'link',
          guid      text path 'guid',
          pub       text path 'pubDate')
      loop
        continue when nullif(btrim(it.titulo), '') is null or nullif(btrim(it.guid), '') is null;
        v_encontradas := v_encontradas + 1;

        v_titulo := btrim(regexp_replace(it.titulo, '\s+', ' ', 'g'));
        v_fonte  := coalesce(nullif(btrim(it.fonte), ''), 'Google Notícias');
        v_link   := btrim(it.link);
        -- O Google acrescenta " - Veículo" ao fim do título.
        if right(v_titulo, length(v_fonte) + 3) = ' - ' || v_fonte then
          v_titulo := left(v_titulo, length(v_titulo) - length(v_fonte) - 3);
        end if;
        if v_link !~ '^https://' then v_link := null; end if;

        continue when public.clipping_dominio_bloqueado(it.fonte_url);
        -- Matérias do site oficial da CDL vêm direto de lá (clipping_coletar_site_cdl).
        continue when public.clipping_dominio(it.fonte_url) = 'cdlcuiaba.com.br';

        v_ts := coalesce(public.clipping_data_rss(it.pub), now());
        v_data := (v_ts at time zone 'America/Cuiaba')::date;
        -- Nunca aceita data futura (pubDate mal formado ou fuso do Google) nem
        -- anterior ao início da janela de comparação (v_desde).
        continue when v_data > (now() at time zone 'America/Cuiaba')::date;
        continue when v_data < v_desde;

        -- Portal pelo domínio do veículo, sempre com o mesmo nome.
        v_dominio := public.clipping_registrar_portal(it.fonte_url, v_fonte);
        if v_dominio is not null then
          select nome into v_fonte from public.clipping_portais where dominio = v_dominio;
        end if;

        insert into public.clipping_news
          (titulo, resumo, fonte, data_publicacao, categoria, canal, sentimento,
           origem, link, google_id, termo_busca, publicado_em, portal_dominio, players)
        values
          (v_titulo,
           'Encontrada no Google Notícias. Clique na imagem ou no título para ler a matéria completa.',
           v_fonte, v_data,
           public.clipping_classificar_categoria(v_titulo),
           public.clipping_classificar_canal(v_fonte),
           public.clipping_classificar_sentimento(v_titulo),
           'google_news', v_link, btrim(it.guid), consulta, v_ts, v_dominio, array[v_player])
        -- Já existente: soma o ator (a mesma notícia pode citar os dois) e
        -- completa o portal; não mexe no que foi editado no app.
        on conflict (google_id) do update
          set players = array(select distinct unnest(clipping_news.players || excluded.players) order by 1),
              portal_dominio = coalesce(clipping_news.portal_dominio, excluded.portal_dominio)
          where not (clipping_news.players @> excluded.players)
             or (clipping_news.portal_dominio is null and excluded.portal_dominio is not null)
        returning (xmax = 0) into v_nova;

        if v_nova then v_novas := v_novas + 1; end if;
        v_nova := null;
      end loop;
    exception when others then
      v_erros := v_erros || consulta || ': ' || sqlerrm || E'\n';
    end;
  end loop;

  perform public.clipping_vincular_portais();

  update public.clipping_coletas
     set finalizado_em = now(), encontradas = v_encontradas, novas = v_novas, erros = nullif(v_erros, '')
   where id = v_coleta;

  return jsonb_build_object('ok', v_erros = '', 'consultas', coalesce(array_length(consultas, 1), 0),
                            'encontradas', v_encontradas, 'novas', v_novas, 'erros', nullif(v_erros, ''));
end;
$$;

-- ---------------------------------------------------------------------
-- 4b. Verificação da matéria + link direto + imagem de capa
--
-- Para as notícias do Google (NÃO filtra mais: só completa os dados):
-- (1/2) Google: o link do RSS é um redirecionamento codificado. Abre a
--       página do Google, lê a assinatura (data-n-a-sg/ts) e pede o
--       endereço real (batchexecute "garturlreq").
-- (3)   Mesma matéria já existente (outra fonte / site oficial) = 'duplicada';
--       domínio bloqueado = 'bloqueada' (nem é acessado).
-- (4)   Abre a matéria e lê a imagem de capa (og:image / twitter:image).
--       A notícia aparece no app desde a coleta; a verificação só a enriquece.
-- Página que não abre depois de 3 tentativas fica 'nao_verificavel'.
-- Roda em lotes pelo pg_cron (a cada 5 min), das mais recentes primeiro.
-- ---------------------------------------------------------------------
drop function if exists public.clipping_processar_imagens(integer);

create or replace function public.clipping_verificar_materias(p_limite integer default 15)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r          record;
  resp       extensions.http_response;
  v_sg       text;
  v_ts       text;
  v_req      text;
  v_json     jsonb;
  v_url      text;
  v_chave    text;
  v_html     text;
  v_img      text;
  v_conf     integer := 0;
  v_dup      integer := 0;
  v_falhas   integer := 0;
  v_ua       extensions.http_header := extensions.http_header('User-Agent',
               'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36');
begin
  if not pg_try_advisory_xact_lock(hashtext('cdload_clipping_verificar')) then
    return jsonb_build_object('ok', true, 'ignorada', true, 'motivo', 'verificação em andamento');
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for r in
    select id, google_id, link_original, titulo, imagem_url, imagem_tentativas
      from public.clipping_news
     where origem = 'google_news' and not oculta
       and (google_id is not null or link_original is not null)
       and portal_dominio is distinct from 'cdlcuiaba.com.br'
       and (verificacao is null or (verificacao = 'erro' and imagem_tentativas < 3))
     order by publicado_em desc nulls last
     limit greatest(coalesce(p_limite, 15), 1)
  loop
    v_url := r.link_original;
    v_img := null;
    begin
      -- 1 e 2: endereço real da matéria (Google)
      if v_url is null then
        resp := extensions.http(('GET', 'https://news.google.com/rss/articles/' || r.google_id,
                                 array[v_ua], null, null)::extensions.http_request);
        if resp.status <> 200 then raise exception 'Google HTTP %', resp.status; end if;
        v_sg := substring(resp.content from 'data-n-a-sg="([^"]+)"');
        v_ts := substring(resp.content from 'data-n-a-ts="([0-9]+)"');
        if v_sg is null or v_ts is null then raise exception 'assinatura do Google não encontrada'; end if;

        v_req := '[[["Fbv4je",' || to_json(format(
          '["garturlreq",[["X","X",["X","X"],null,null,1,1,"US:en",null,1,null,null,null,null,null,0,1],"X","X",1,[1,1,1],1,1,null,0,0,null,0],"%s",%s,"%s"]',
          r.google_id, v_ts, v_sg))::text || ',null,"generic"]]]';
        resp := extensions.http(('POST', 'https://news.google.com/_/DotsSplashUi/data/batchexecute',
                                 array[v_ua], 'application/x-www-form-urlencoded;charset=UTF-8',
                                 'f.req=' || extensions.urlencode(v_req))::extensions.http_request);
        if resp.status <> 200 then raise exception 'Google batchexecute HTTP %', resp.status; end if;
        -- Resposta: )]}'  [["wrb.fr","Fbv4je","[\"garturlres\",\"https://...\",1]",...]]
        v_json := regexp_replace(resp.content, '^\)\]\}''\s*', '')::jsonb;
        v_url := ((v_json -> 0 ->> 2)::jsonb) ->> 1;
        if v_url is null or v_url !~ '^https?://' then v_url := null; raise exception 'endereço real não retornado'; end if;
      end if;
      v_chave := public.clipping_link_chave(v_url);

      -- 3: bloqueada / duplicada (sem abrir a matéria)
      if public.clipping_dominio_bloqueado(v_url) or exists (
           select 1 from public.clipping_news o
            where o.id <> r.id and o.link_chave = v_chave
              and (o.origem in ('cdl_site', 'manual') or o.verificacao = 'confirmada')) then
        update public.clipping_news
           set link_original = v_url, link_chave = v_chave,
               verificacao = case when public.clipping_dominio_bloqueado(v_url) then 'bloqueada' else 'duplicada' end,
               verificada_em = now(), imagem_tentativas = imagem_tentativas + 1
         where id = r.id;
        v_dup := v_dup + 1;
        continue;
      end if;

      -- 4: a matéria em si
      resp := extensions.http(('GET', v_url, array[v_ua], null, null)::extensions.http_request);
      if resp.status <> 200 then raise exception 'matéria HTTP %', resp.status; end if;
      v_html := public.clipping_decodificar_resposta(resp.content);


      begin
        v_img := coalesce(
          substring(v_html from '<meta[^>]+(?:property|name)=["'']og:image(?::secure_url|:url)?["''][^>]*content=["'']([^"'']+)'),
          substring(v_html from '<meta[^>]+content=["'']([^"'']+)["''][^>]*(?:property|name)=["'']og:image["'']'),
          substring(v_html from '<meta[^>]+name=["'']twitter:image(?::src)?["''][^>]*content=["'']([^"'']+)'));
        v_img := replace(btrim(v_img), '&amp;', '&');
        if v_img like '//%' then
          v_img := 'https:' || v_img;
        elsif v_img like '/%' then
          v_img := substring(v_url from '^https?://[^/]+') || v_img;
        end if;
        v_img := regexp_replace(v_img, '^http://', 'https://');  -- o app é servido em HTTPS
        if v_img !~ '^https://' then v_img := null; end if;
      exception when others then
        v_img := null;
      end;
      v_img := coalesce(v_img, r.imagem_url);  -- mantém a imagem que já existia

      update public.clipping_news
         set link_original     = v_url,
             link_chave        = v_chave,
             imagem_url        = v_img,
             imagem_status     = case when v_img is null then 'sem_imagem' else 'ok' end,
             verificacao       = 'confirmada',
             verificada_em     = now(),
             imagem_tentativas = imagem_tentativas + 1
       where id = r.id;
      v_conf := v_conf + 1;
    exception when others then
      -- O bloco foi desfeito, mas v_url (variável) sobrevive: guarda o link
      -- real já descoberto para a próxima tentativa não depender do Google.
      update public.clipping_news
         set link_original     = coalesce(link_original, v_url),
             link_chave        = coalesce(link_chave, public.clipping_link_chave(v_url)),
             verificacao       = case when r.imagem_tentativas + 1 >= 3 then 'nao_verificavel' else 'erro' end,
             verificada_em     = now(),
             imagem_tentativas = imagem_tentativas + 1
       where id = r.id;
      v_falhas := v_falhas + 1;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'processadas', v_conf,
                            'duplicadas_ou_bloqueadas', v_dup, 'falhas', v_falhas);
end;
$$;

-- ---------------------------------------------------------------------
-- 4c. Site oficial da CDL Cuiabá (https://www.cdlcuiaba.com.br/ultimas-noticias)
--
-- TODAS as matérias do site entram, sem exceção e sem checagem de
-- palavra-chave (são da própria entidade), com o portal "Site Oficial".
-- Lê a listagem (22 por página, mais recentes primeiro): título, link,
-- data, linha fina e a capa (a miniatura 90x68 da listagem trocada pela
-- versão 800x600 do próprio servidor da CDL). O site é ISO-8859-1: o texto
-- passa por clipping_decodificar_resposta.
--   * normal:   para na primeira página sem novidade;
--   * completa: percorre desde 01/01/2025 e atualiza título/resumo/capa.
-- Datas futuras (linha fina mal formada) são descartadas. As mesmas
-- matérias vindas pelos buscadores ficam 'duplicada'.
-- ---------------------------------------------------------------------
drop function if exists public.clipping_coletar_site_cdl();  -- versão anterior, sem parâmetro

create or replace function public.clipping_coletar_site_cdl(p_completa boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base      text := 'https://www.cdlcuiaba.com.br/includes/__index_lista_new.inc.php?sid=31&pageNum_Pagina=';
  v_desde     date := date '2025-01-01';  -- fixo: permite comparar o mesmo período em anos diferentes
  v_pagina    integer := 0;
  resp        extensions.http_response;
  v_html      text;
  item        text;
  v_url       text;
  v_id        text;
  v_titulo    text;
  v_img       text;
  v_quando    text;
  v_resumo    text;
  v_ts        timestamptz;
  v_data      date;
  v_nova      boolean;
  v_itens_pag integer;
  v_novas_pag integer;
  v_antiga    date;
  v_encontradas integer := 0;
  v_novas     integer := 0;
  v_erros     text := '';
  v_coleta    bigint;
  v_ua        extensions.http_header := extensions.http_header('User-Agent',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36');
begin
  if not pg_try_advisory_xact_lock(hashtext('cdload_clipping_site_cdl')) then
    return jsonb_build_object('ok', true, 'ignorada', true, 'motivo', 'leitura em andamento');
  end if;

  insert into public.clipping_coletas (origem) values ('site_cdl') returning id into v_coleta;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  insert into public.clipping_portais (dominio, nome, url)
  values ('cdlcuiaba.com.br', 'Site Oficial', 'https://www.cdlcuiaba.com.br')
  on conflict (dominio) do update set nome = 'Site Oficial';

  while v_pagina <= 30 loop
    begin
      resp := extensions.http(('GET', v_base || v_pagina, array[v_ua], null, null)::extensions.http_request);
      if resp.status <> 200 then raise exception 'HTTP %', resp.status; end if;
      v_html := public.clipping_decodificar_resposta(resp.content);
    exception when others then
      v_erros := v_erros || 'página ' || v_pagina || ': ' || sqlerrm || E'\n';
      exit;
    end;

    v_itens_pag := 0;
    v_novas_pag := 0;
    v_antiga    := null;

    -- Cada notícia da listagem é um <li>.
    for item in select regexp_split_to_table(v_html, '<li>') loop
      begin
        v_url := substring(item from 'href="(https://www\.cdlcuiaba\.com\.br/noticias/[^"]+?/[0-9]+)"');
        continue when v_url is null;
        v_id := substring(v_url from '/([0-9]+)$');

        v_titulo := coalesce(substring(item from 'class="MidiaTitulo">(.*?)</p>'),
                             substring(item from 'title="([^"]*?)"'));
        v_titulo := btrim(regexp_replace(public.clipping_decodificar_html(regexp_replace(v_titulo, '<[^>]*?>', ' ', 'g')), '\s+', ' ', 'g'));
        continue when coalesce(v_titulo, '') = '';

        -- "23.09.26 12h27" (horário de Cuiabá)
        v_quando := substring(item from '<strong>([0-9]{2}\.[0-9]{2}\.[0-9]{2} [0-9]{2}h[0-9]{2})</strong>');
        begin
          v_ts := to_timestamp(v_quando, 'DD.MM.YY HH24"h"MI')::timestamp at time zone 'America/Cuiaba';
        exception when others then
          v_ts := null;
        end;
        v_ts   := coalesce(v_ts, now());
        v_data := (v_ts at time zone 'America/Cuiaba')::date;
        -- Nunca aceita data futura (linha fina mal formada) — não conta nem
        -- para a paginação (v_antiga/v_itens_pag).
        continue when v_data > (now() at time zone 'America/Cuiaba')::date;
        v_antiga := least(coalesce(v_antiga, v_data), v_data);
        v_itens_pag := v_itens_pag + 1;
        continue when v_data < v_desde;
        v_encontradas := v_encontradas + 1;

        v_resumo := substring(item from '</strong>\s*?-\s*?(.*?)</p>');
        v_resumo := nullif(btrim(regexp_replace(public.clipping_decodificar_html(regexp_replace(coalesce(v_resumo, ''), '<[^>]*?>', ' ', 'g')), '\s+', ' ', 'g')), '');

        -- Capa: miniatura da listagem trocada pela versão 800x600.
        v_img := substring(item from 'src="(https?://[^"]*?/storage/webdisco/[^"]+?)"');
        v_img := regexp_replace(regexp_replace(v_img, '/[0-9]+x[0-9]+/', '/800x600/'), '^http://', 'https://');

        insert into public.clipping_news
          (titulo, resumo, fonte, data_publicacao, categoria, canal, sentimento,
           origem, link, link_original, link_chave, fonte_id, publicado_em, portal_dominio,
           imagem_url, imagem_status, verificacao, verificada_em, players)
        values
          (v_titulo,
           coalesce(v_resumo, 'Matéria publicada no site oficial da CDL Cuiabá. Clique na imagem ou no título para ler.'),
           'Site Oficial', v_data,
           public.clipping_classificar_categoria(v_titulo),
           'Site institucional',
           public.clipping_classificar_sentimento(v_titulo),
           'cdl_site', v_url, v_url, public.clipping_link_chave(v_url), 'cdl:' || v_id, v_ts, 'cdlcuiaba.com.br',
           v_img, case when v_img is null then 'sem_imagem' else 'ok' end, 'confirmada', now(),
           array['CDL Cuiabá'])
        -- Já existente: o site oficial é a referência (título, linha fina,
        -- data e capa); categoria/sentimento editados no app são mantidos.
        on conflict (fonte_id) do update
          set titulo = excluded.titulo, resumo = excluded.resumo, fonte = excluded.fonte,
              data_publicacao = excluded.data_publicacao, publicado_em = excluded.publicado_em,
              link = excluded.link, link_original = excluded.link_original, link_chave = excluded.link_chave,
              portal_dominio = excluded.portal_dominio, verificacao = 'confirmada',
              players = array(select distinct unnest(clipping_news.players || excluded.players) order by 1),
              imagem_url = coalesce(excluded.imagem_url, clipping_news.imagem_url),
              imagem_status = case when coalesce(excluded.imagem_url, clipping_news.imagem_url) is null then 'sem_imagem' else 'ok' end
          where p_completa
             or clipping_news.imagem_url is null
             or clipping_news.titulo is distinct from excluded.titulo
        returning (xmax = 0) into v_nova;

        if v_nova then v_novas_pag := v_novas_pag + 1; end if;
        v_nova := null;
      exception when others then
        v_erros := v_erros || 'item ' || coalesce(v_id, '?') || ': ' || sqlerrm || E'\n';
      end;
    end loop;

    v_novas := v_novas + v_novas_pag;
    exit when v_itens_pag = 0 or v_antiga < v_desde or (not p_completa and v_novas_pag = 0);
    v_pagina := v_pagina + 1;
  end loop;

  -- As matérias do site oficial vindas pelos buscadores saem (duplicadas).
  update public.clipping_news
     set verificacao = 'duplicada', verificada_em = now()
   where origem in ('google_news', 'bing_news')
     and (portal_dominio = 'cdlcuiaba.com.br' or public.clipping_dominio(link_original) = 'cdlcuiaba.com.br')
     and verificacao is distinct from 'duplicada';

  update public.clipping_coletas
     set finalizado_em = now(), encontradas = v_encontradas, novas = v_novas, erros = nullif(v_erros, '')
   where id = v_coleta;

  return jsonb_build_object('ok', v_erros = '', 'paginas_lidas', v_pagina + 1, 'materias_do_ano', v_encontradas,
                            'novas', v_novas, 'erros', nullif(v_erros, ''));
end;
$$;

-- ---------------------------------------------------------------------
-- 4d. Ajustes nos dados já gravados
-- ---------------------------------------------------------------------
-- Escopo novo: a regra de citação no texto caiu. As notícias do Google
-- descartadas por ela voltam a valer.
update public.clipping_news set verificacao = 'confirmada'
 where origem = 'google_news' and verificacao = 'descartada';

-- A busca agora é só no Google Notícias: o que veio do Bing sai do app.
update public.clipping_news set verificacao = 'fora_escopo', verificada_em = now()
 where origem = 'bing_news' and verificacao is distinct from 'fora_escopo';

-- Ator das notícias gravadas antes da coluna `players`: pelo termo que as
-- trouxe (Google), pelo site oficial (CDL) ou, nas manuais, pelo texto.
update public.clipping_news n
   set players = coalesce((
         select array_agg(distinct p.player order by p.player)
           from public.clipping_players() p
          where public.clipping_normalizar(coalesce(n.termo_busca, '')) like '%' || public.clipping_normalizar(p.termo) || '%'
             or (n.origem = 'manual'
                 and position(' ' || public.clipping_normalizar(p.termo) || ' '
                              in ' ' || public.clipping_normalizar(n.titulo || ' ' || n.resumo) || ' ') > 0)),
         '{}')
 where n.players = '{}' and n.origem in ('google_news', 'manual');
update public.clipping_news set players = array['CDL Cuiabá']
 where players = '{}' and (origem in ('cdl_site', 'manual', 'google_news'));

-- Portal do site oficial com o nome "Site Oficial" em todas as matérias dele.
update public.clipping_news set fonte = 'Site Oficial'
 where portal_dominio = 'cdlcuiaba.com.br' and fonte is distinct from 'Site Oficial';

-- Chave de endereço das notícias já gravadas.
update public.clipping_news set link_chave = public.clipping_link_chave(link_original)
 where link_chave is null and link_original is not null;

-- PNB Online: tudo o que já foi gravado sai do app e perde os links.
update public.clipping_news
   set verificacao = 'bloqueada', verificada_em = now(), link = null, link_original = null, imagem_url = null
 where (public.clipping_dominio_bloqueado(portal_dominio)
        or public.clipping_dominio_bloqueado(link_original)
        or public.clipping_dominio_bloqueado(link))
   and verificacao is distinct from 'bloqueada';
update public.clipping_portais set url = null where public.clipping_dominio_bloqueado(dominio);

-- ---------------------------------------------------------------------
-- Permissões das funções
-- ---------------------------------------------------------------------
-- Só o pg_cron / SQL Editor verificam matérias, leem o site da CDL e ligam portais (nada disso é exposto ao app).
revoke all on function public.clipping_verificar_materias(integer), public.clipping_vincular_portais(),
                       public.clipping_registrar_portal(text, text), public.clipping_coletar_site_cdl(boolean)
  from public, anon, authenticated;
revoke all on function public.clipping_coletar(boolean) from public, anon;
grant execute on function public.clipping_coletar(boolean) to authenticated;  -- o app sempre roda a versão curta
revoke all on function public.clipping_classificar_canal(text),
               public.clipping_classificar_categoria(text), public.clipping_classificar_sentimento(text),
               public.clipping_chave(text), public.clipping_dominio(text),
               public.clipping_palavras_chave(), public.clipping_normalizar(text), public.clipping_decodificar_html(text),
               public.clipping_texto_materia(text), public.clipping_cita_palavra_chave(text),
               public.clipping_dominio_bloqueado(text), public.clipping_link_chave(text), public.clipping_urldecode(text),
               public.clipping_decodificar_resposta(text), public.clipping_data_rss(text),
               public.clipping_players()
  from public, anon;

-- ---------------------------------------------------------------------
-- 5. Agendamento e primeira carga
--   coleta normal a cada 30 min · varredura completa todo dia às 05h (Cuiabá)
--   verificação a cada 5 min (15 matérias) · site oficial a cada 30 min
-- ---------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'cdload-clipping-imagens';  -- job de versão anterior
select cron.schedule('cdload-clipping-google-news', '*/30 * * * *', $$select public.clipping_coletar(false)$$);
select cron.schedule('cdload-clipping-completa', '0 9 * * *', $$select public.clipping_coletar(true)$$);
select cron.schedule('cdload-clipping-verificacao', '*/5 * * * *', $$select public.clipping_verificar_materias(15)$$);
select cron.schedule('cdload-clipping-site-cdl', '15,45 * * * *', $$select public.clipping_coletar_site_cdl(false)$$);

-- Liga as notícias já gravadas aos portais (nome padronizado).
select public.clipping_vincular_portais();

-- Primeira carga: site oficial COMPLETO (todas as matérias desde 01/01/2025)
-- + busca COMPLETA no Google Notícias para a CDL Cuiabá e a Fecomércio MT,
-- também desde 01/01/2025 (permite comparar o mesmo período em anos
-- diferentes). Leva alguns minutos a mais que antes, por cobrir mais meses.
--   "site_cdl": "ok": true e "materias_do_ano" com o total desde 2025;
--   "buscadores": "ok": true e quantas notícias novas entraram (já
--   aparecem no app; link direto e imagem chegam em seguida, 15 a cada 5 min).
-- Se "erros" vier preenchido, copie o texto e envie para ajuste.
select public.clipping_coletar_site_cdl(true) as site_cdl,
       public.clipping_coletar(true) as buscadores;

-- Opcional: as 10 notícias de EXEMPLO do protótipo (conteúdo ilustrativo,
-- não são matérias reais) ficam misturadas às reais. Para removê-las,
-- descomente e rode:
-- delete from public.clipping_news
--  where origem = 'manual'
--    and titulo in (
--      'CDL Cuiabá lança campanha para impulsionar as vendas do Dia das Mães',
--      'Índice de Confiança do Comércio da CDL Cuiabá aponta otimismo para o 1º trimestre',
--      'CDL Cuiabá promove capacitação gratuita para lojistas do centro histórico',
--      'Pesquisa da CDL Cuiabá mostra queda na inadimplência do comércio local',
--      'CDL Cuiabá alerta lojistas sobre golpes durante liquidações de fim de ano',
--      'CDL Cuiabá e Sebrae firmam parceria para digitalização do pequeno varejo',
--      'Comércio de Cuiabá projeta alta nas vendas de Black Friday, aponta CDL',
--      'CDL Cuiabá debate reforma tributária em painel com empresários locais',
--      'CDL Cuiabá registra queda no número de novas empresas abertas no semestre',
--      'CDL Cuiabá amplia atendimento a associados durante o Dia do Comerciário'
--    );
