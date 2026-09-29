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
--   7. Site oficial: `clipping_coletar_site_cdl()` lê as matérias direto de
--      cdlcuiaba.com.br/ultimas-noticias (com a capa), a cada 30 min.
--
-- Palavras-chave (entre aspas, frase exata):
--   "CDL Cuiabá"
--   "Câmara de Dirigentes Lojistas de Cuiabá"
--   "Fundação CDL Cuiabá"
-- Para trocar, edite a função clipping_palavras_chave() e rode de novo.
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
  ('cdlcuiaba.com.br',           'CDL Cuiabá',           'https://www.cdlcuiaba.com.br'),
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

-- Única lista de palavras-chave: usada na busca e na verificação.
create or replace function public.clipping_palavras_chave()
returns text[]
language sql immutable
as $$
  select array['CDL Cuiabá', 'Câmara de Dirigentes Lojistas de Cuiabá', 'Fundação CDL Cuiabá']
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
-- 4. Coleta no Google Notícias (RSS)
--
-- Chamada de 3 jeitos: pelo pg_cron (a cada 30 min), pelo SQL Editor e
-- pelo app ao abrir a seção (RPC). Pelo app exige a seção
-- "clipping" e respeita um intervalo mínimo de 2 minutos entre coletas.
-- Por termo, busca os últimos 7 dias (garante as mais recentes, já que o
-- RSS vem ordenado por relevância) e, fora do app, também a busca geral
-- (até 100 itens por termo).
-- Só grava notícias do ano corrente; as repetidas são ignoradas pelo
-- id do Google, o que preserva edições feitas no app.
-- ---------------------------------------------------------------------
create or replace function public.clipping_coletar()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  termos       text[] := public.clipping_palavras_chave();
  janelas      text[] := array[' when:7d', ''];
  v_timeout    text := '20000';
  termo        text;
  janela       text;
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
  v_desde      date := date_trunc('year', now() at time zone 'America/Cuiaba')::date;
  v_origem     text := 'automatica';
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
    v_origem := 'app';
    -- Chamadas da API têm statement_timeout curto (~8 s no Supabase):
    -- pelo app busca só os últimos 7 dias; a varredura completa fica no pg_cron.
    janelas := array[' when:7d'];
    v_timeout := '2500';  -- 3 termos x 2,5 s cabem no limite
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

  foreach termo in array termos loop
    foreach janela in array janelas loop
      begin
        v_url := 'https://news.google.com/rss/search?q='
              || extensions.urlencode('"' || termo || '"' || janela)
              || '&hl=pt-BR&gl=BR&ceid=BR:pt-419';

        resp := extensions.http((
          'GET', v_url,
          array[extensions.http_header('User-Agent', 'Mozilla/5.0 (compatible; CDLoad-Clipping/1.0)')],
          null, null
        )::extensions.http_request);

        if resp.status <> 200 then
          raise exception 'HTTP %', resp.status;
        end if;

        -- A declaração <?xml encoding=...?> atrapalha o xmlparse de texto.
        doc := xmlparse(document regexp_replace(resp.content, '^\s*<\?xml[^>]*\?>', ''));

        for it in
          select * from xmltable('/rss/channel/item' passing doc columns
            titulo text path 'title',
            fonte  text path 'source',
            fonte_url text path 'source/@url',
            link   text path 'link',
            guid   text path 'guid',
            pub    text path 'pubDate')
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

          -- Portal pelo domínio do veículo, sempre com o mesmo nome.
          v_dominio := public.clipping_registrar_portal(it.fonte_url, v_fonte);
          -- Matérias do site oficial da CDL vêm direto de lá (clipping_coletar_site_cdl).
          continue when v_dominio = 'cdlcuiaba.com.br';
          if v_dominio is not null then
            select nome into v_fonte from public.clipping_portais where dominio = v_dominio;
          end if;

          -- pubDate no formato RFC 822, em GMT: "Fri, 25 Sep 2026 07:49:17 GMT".
          begin
            v_ts := to_timestamp(substring(it.pub from '\d{1,2} \w{3} \d{4} \d{2}:\d{2}:\d{2}'),
                                 'DD Mon YYYY HH24:MI:SS')::timestamp at time zone 'UTC';
          exception when others then
            v_ts := null;
          end;
          v_ts := coalesce(v_ts, now());
          v_data := (v_ts at time zone 'America/Cuiaba')::date;
          continue when v_data < v_desde;

          insert into public.clipping_news
            (titulo, resumo, fonte, data_publicacao, categoria, canal, sentimento,
             origem, link, google_id, termo_busca, publicado_em, portal_dominio)
          values
            (v_titulo,
             'Encontrada no Google Notícias pela busca "' || termo || '". Clique na imagem ou no título para ler a matéria completa.',
             v_fonte, v_data,
             public.clipping_classificar_categoria(v_titulo),
             public.clipping_classificar_canal(v_fonte),
             public.clipping_classificar_sentimento(v_titulo),
             'google_news', v_link, btrim(it.guid), termo, v_ts, v_dominio)
          -- Já existente: só completa o portal de notícias antigas (não
          -- mexe no que foi editado no app).
          on conflict (google_id) do update
            set portal_dominio = excluded.portal_dominio
            where clipping_news.portal_dominio is null and excluded.portal_dominio is not null
          returning (xmax = 0) into v_nova;

          if v_nova then v_novas := v_novas + 1; end if;
          v_nova := null;
        end loop;
      exception when others then
        v_erros := v_erros || termo || janela || ': ' || sqlerrm || E'\n';
      end;
    end loop;
  end loop;

  perform public.clipping_vincular_portais();

  update public.clipping_coletas
     set finalizado_em = now(), encontradas = v_encontradas, novas = v_novas, erros = nullif(v_erros, '')
   where id = v_coleta;

  return jsonb_build_object('ok', v_erros = '', 'encontradas', v_encontradas, 'novas', v_novas,
                            'erros', nullif(v_erros, ''));
end;
$$;

-- ---------------------------------------------------------------------
-- 4b. Verificação da matéria + link direto + imagem de capa
--
-- O link do RSS é um redirecionamento codificado do Google. Para chegar à
-- matéria: (1) abre a página do Google e lê a assinatura (data-n-a-sg/ts);
-- (2) pede ao Google o endereço real (batchexecute "garturlreq");
-- (3) abre a matéria e:
--     - confere se ela CITA uma palavra-chave (no título dela ou no texto
--       corrido, sem contar links, menus e rodapés — ver
--       clipping_texto_materia). Não cita = 'descartada' e some do app;
--     - lê a imagem de capa (og:image / twitter:image).
-- Página que não abre depois de 3 tentativas fica 'nao_verificavel' (não
-- dá para confirmar a citação, então também não aparece no app).
-- São ~3 requisições por notícia: roda em lotes pelo pg_cron (a cada
-- 5 min), das mais recentes para as mais antigas.
-- ---------------------------------------------------------------------
drop function if exists public.clipping_processar_imagens(integer);

create or replace function public.clipping_verificar_materias(p_limite integer default 10)
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
  v_img      text;
  v_cita     boolean;
  v_conf     integer := 0;
  v_desc     integer := 0;
  v_falhas   integer := 0;
  v_ua       extensions.http_header := extensions.http_header('User-Agent',
               'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36');
begin
  if not pg_try_advisory_xact_lock(hashtext('cdload_clipping_verificar')) then
    return jsonb_build_object('ok', true, 'ignorada', true, 'motivo', 'verificação em andamento');
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for r in
    select id, google_id, link_original, titulo, imagem_tentativas
      from public.clipping_news
     where origem = 'google_news' and not oculta and google_id is not null
       and portal_dominio is distinct from 'cdlcuiaba.com.br'
       and (verificacao is null or (verificacao = 'erro' and imagem_tentativas < 3))
     order by publicado_em desc nulls last
     limit greatest(coalesce(p_limite, 10), 1)
  loop
    v_url := r.link_original;
    v_img := null;
    begin
      -- 1 e 2: endereço real da matéria
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

      -- 3: a matéria em si
      resp := extensions.http(('GET', v_url, array[v_ua], null, null)::extensions.http_request);
      if resp.status <> 200 then raise exception 'matéria HTTP %', resp.status; end if;

      v_cita := public.clipping_cita_palavra_chave(public.clipping_normalizar(r.titulo))
             or public.clipping_cita_palavra_chave(public.clipping_texto_materia(resp.content));

      begin
        v_img := coalesce(
          substring(resp.content from '<meta[^>]+(?:property|name)=["'']og:image(?::secure_url|:url)?["''][^>]*content=["'']([^"'']+)'),
          substring(resp.content from '<meta[^>]+content=["'']([^"'']+)["''][^>]*(?:property|name)=["'']og:image["'']'),
          substring(resp.content from '<meta[^>]+name=["'']twitter:image(?::src)?["''][^>]*content=["'']([^"'']+)'));
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

      update public.clipping_news
         set link_original     = v_url,
             imagem_url        = v_img,
             imagem_status     = case when v_img is null then 'sem_imagem' else 'ok' end,
             verificacao       = case when v_cita then 'confirmada' else 'descartada' end,
             verificada_em     = now(),
             imagem_tentativas = imagem_tentativas + 1
       where id = r.id;
      if v_cita then v_conf := v_conf + 1; else v_desc := v_desc + 1; end if;
    exception when others then
      -- O bloco foi desfeito, mas v_url (variável) sobrevive: guarda o link
      -- real já descoberto para a próxima tentativa não depender do Google.
      update public.clipping_news
         set link_original     = coalesce(link_original, v_url),
             verificacao       = case when r.imagem_tentativas + 1 >= 3 then 'nao_verificavel' else 'erro' end,
             verificada_em     = now(),
             imagem_tentativas = imagem_tentativas + 1
       where id = r.id;
      v_falhas := v_falhas + 1;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'confirmadas', v_conf, 'descartadas', v_desc, 'falhas', v_falhas);
end;
$$;

-- ---------------------------------------------------------------------
-- 4c. Site oficial da CDL Cuiabá (https://www.cdlcuiaba.com.br/ultimas-noticias)
--
-- Lê a listagem de notícias (22 por página, mais recentes primeiro) e
-- grava título, link, data, linha fina e a capa. A listagem traz a capa em
-- 90x68; o servidor da CDL tem a mesma imagem em 800x600, usada no card.
-- São as matérias da própria entidade, então entram já 'confirmada'.
-- As mesmas matérias vindas pelo Google Notícias ficam 'duplicada'.
-- Para na página em que nada é novo ou que já chega ao ano anterior.
-- ---------------------------------------------------------------------
create or replace function public.clipping_coletar_site_cdl()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base      text := 'https://www.cdlcuiaba.com.br/includes/__index_lista_new.inc.php?sid=31&pageNum_Pagina=';
  v_desde     date := date_trunc('year', now() at time zone 'America/Cuiaba')::date;
  v_pagina    integer := 0;
  resp        extensions.http_response;
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
  perform public.clipping_registrar_portal('https://www.cdlcuiaba.com.br', 'CDL Cuiabá');

  while v_pagina <= 15 loop
    begin
      resp := extensions.http(('GET', v_base || v_pagina, array[v_ua], null, null)::extensions.http_request);
      if resp.status <> 200 then raise exception 'HTTP %', resp.status; end if;
    exception when others then
      v_erros := v_erros || 'página ' || v_pagina || ': ' || sqlerrm || E'\n';
      exit;
    end;

    v_itens_pag := 0;
    v_novas_pag := 0;
    v_antiga    := null;

    -- Cada notícia da listagem é um <li>.
    for item in select regexp_split_to_table(resp.content, '<li>') loop
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
         origem, link, link_original, fonte_id, publicado_em, portal_dominio,
         imagem_url, imagem_status, verificacao, verificada_em)
      values
        (v_titulo,
         coalesce(v_resumo, 'Matéria publicada no portal oficial da CDL Cuiabá. Clique na imagem ou no título para ler.'),
         'CDL Cuiabá', v_data,
         public.clipping_classificar_categoria(v_titulo),
         'Site institucional',
         public.clipping_classificar_sentimento(v_titulo),
         'cdl_site', v_url, v_url, 'cdl:' || v_id, v_ts, 'cdlcuiaba.com.br',
         v_img, case when v_img is null then 'sem_imagem' else 'ok' end, 'confirmada', now())
      -- Já existente: só completa a capa se ainda não tinha.
      on conflict (fonte_id) do update
        set imagem_url = excluded.imagem_url, imagem_status = excluded.imagem_status
        where clipping_news.imagem_url is null and excluded.imagem_url is not null
      returning (xmax = 0) into v_nova;

      if v_nova then v_novas_pag := v_novas_pag + 1; end if;
      v_nova := null;
    end loop;

    v_novas := v_novas + v_novas_pag;
    exit when v_itens_pag = 0 or v_novas_pag = 0 or v_antiga < v_desde;
    v_pagina := v_pagina + 1;
  end loop;

  -- As matérias do site oficial vindas pelo Google Notícias saem (duplicadas).
  update public.clipping_news
     set verificacao = 'duplicada', verificada_em = now()
   where origem = 'google_news' and portal_dominio = 'cdlcuiaba.com.br'
     and verificacao is distinct from 'duplicada';

  update public.clipping_coletas
     set finalizado_em = now(), encontradas = v_encontradas, novas = v_novas, erros = nullif(v_erros, '')
   where id = v_coleta;

  return jsonb_build_object('ok', v_erros = '', 'paginas_lidas', v_pagina + 1, 'encontradas', v_encontradas,
                            'novas', v_novas, 'erros', nullif(v_erros, ''));
end;
$$;

-- Só o pg_cron / SQL Editor verificam matérias, leem o site da CDL e ligam portais (nada disso é exposto ao app).
revoke all on function public.clipping_verificar_materias(integer), public.clipping_vincular_portais(),
                       public.clipping_registrar_portal(text, text), public.clipping_coletar_site_cdl()
  from public, anon, authenticated;
revoke all on function public.clipping_coletar() from public, anon;
grant execute on function public.clipping_coletar() to authenticated;
revoke all on function public.clipping_classificar_canal(text),
               public.clipping_classificar_categoria(text), public.clipping_classificar_sentimento(text),
               public.clipping_chave(text), public.clipping_dominio(text),
               public.clipping_palavras_chave(), public.clipping_normalizar(text), public.clipping_decodificar_html(text),
               public.clipping_texto_materia(text), public.clipping_cita_palavra_chave(text)
  from public, anon;

-- ---------------------------------------------------------------------
-- 5. Agendamento (coleta a cada 30 min, verificação a cada 5 min) e primeira coleta
-- ---------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'cdload-clipping-imagens';  -- job da versão anterior
select cron.schedule('cdload-clipping-google-news', '*/30 * * * *', $$select public.clipping_coletar()$$);
select cron.schedule('cdload-clipping-verificacao', '*/5 * * * *', $$select public.clipping_verificar_materias(10)$$);
select cron.schedule('cdload-clipping-site-cdl', '15,45 * * * *', $$select public.clipping_coletar_site_cdl()$$);

-- Liga as notícias já gravadas aos portais (nome padronizado).
select public.clipping_vincular_portais();

-- Site da CDL + coleta do Google + um primeiro lote de 3 verificações (o
-- resto vem pelo pg_cron). "site_cdl" e "coleta" devem trazer "ok": true
-- e o total de notícias novas; "verificacao", quantas foram confirmadas/
-- descartadas. Erro de HTTP = o site recusou temporariamente; o
-- agendamento tenta de novo.
select public.clipping_coletar_site_cdl() as site_cdl,
       public.clipping_coletar() as coleta,
       public.clipping_verificar_materias(3) as verificacao;

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
