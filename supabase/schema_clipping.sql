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
--   6. Imagens: `clipping_processar_imagens()` descobre o link real da
--      matéria e a imagem de capa dela (og:image), em lotes a cada 10 min.
--
-- Palavras-chave (entre aspas, frase exata):
--   "CDL Cuiabá"
--   "Câmara de Dirigentes Lojistas de Cuiabá"
-- Para trocar, edite o array `termos` dentro de clipping_coletar().
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
  termos       text[] := array['CDL Cuiabá', 'Câmara de Dirigentes Lojistas de Cuiabá'];
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
    v_timeout := '3000';
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
-- 4b. Link direto e imagem de capa de cada matéria
--
-- O link do RSS é um redirecionamento codificado do Google. Para chegar à
-- matéria: (1) abre a página do Google e lê a assinatura (data-n-a-sg/ts);
-- (2) pede ao Google o endereço real (batchexecute "garturlreq");
-- (3) abre a matéria e lê a imagem de capa (og:image / twitter:image).
-- São ~3 requisições por notícia, então roda em lotes pelo pg_cron (a
-- cada 10 min), das mais recentes para as mais antigas. Sem imagem, o app
-- mostra uma arte gerada pelo tema (categoria) da notícia.
-- ---------------------------------------------------------------------
create or replace function public.clipping_processar_imagens(p_limite integer default 8)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r         record;
  resp      extensions.http_response;
  v_sg      text;
  v_ts      text;
  v_req     text;
  v_json    jsonb;
  v_url     text;
  v_img     text;
  v_ok      integer := 0;
  v_sem     integer := 0;
  v_falhas  integer := 0;
  v_ua      extensions.http_header := extensions.http_header('User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36');
begin
  if not pg_try_advisory_xact_lock(hashtext('cdload_clipping_imagens')) then
    return jsonb_build_object('ok', true, 'ignorada', true, 'motivo', 'processamento em andamento');
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for r in
    select id, google_id, link_original
      from public.clipping_news
     where origem = 'google_news' and not oculta and google_id is not null
       and (imagem_status is null or (imagem_status = 'erro' and imagem_tentativas < 3))
     order by publicado_em desc nulls last
     limit greatest(coalesce(p_limite, 8), 1)
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
        if v_url is null or v_url !~ '^https?://' then raise exception 'endereço real não retornado'; end if;
      end if;

      -- 3: imagem de capa (falha aqui não perde o link já descoberto)
      begin
        resp := extensions.http(('GET', v_url, array[v_ua], null, null)::extensions.http_request);
        if resp.status = 200 then
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
        end if;
      exception when others then
        v_img := null;
      end;

      update public.clipping_news
         set link_original     = v_url,
             imagem_url        = v_img,
             imagem_status     = case when v_img is null then 'sem_imagem' else 'ok' end,
             imagem_tentativas = imagem_tentativas + 1
       where id = r.id;
      if v_img is null then v_sem := v_sem + 1; else v_ok := v_ok + 1; end if;
    exception when others then
      update public.clipping_news
         set imagem_status = 'erro', imagem_tentativas = imagem_tentativas + 1
       where id = r.id;
      v_falhas := v_falhas + 1;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'com_imagem', v_ok, 'sem_imagem', v_sem, 'falhas', v_falhas);
end;
$$;

-- Só o pg_cron / SQL Editor processam imagens e portais (nada disso é exposto ao app).
revoke all on function public.clipping_processar_imagens(integer), public.clipping_vincular_portais(),
                       public.clipping_registrar_portal(text, text)
  from public, anon, authenticated;
revoke all on function public.clipping_coletar() from public, anon;
grant execute on function public.clipping_coletar() to authenticated;
revoke all on function public.clipping_classificar_canal(text),
               public.clipping_classificar_categoria(text), public.clipping_classificar_sentimento(text),
               public.clipping_chave(text), public.clipping_dominio(text)
  from public, anon;

-- ---------------------------------------------------------------------
-- 5. Agendamento (coleta a cada 30 min, imagens a cada 10 min) e primeira coleta
-- ---------------------------------------------------------------------
select cron.schedule('cdload-clipping-google-news', '*/30 * * * *', $$select public.clipping_coletar()$$);
select cron.schedule('cdload-clipping-imagens', '*/10 * * * *', $$select public.clipping_processar_imagens(8)$$);

-- Liga as notícias já gravadas aos portais (nome padronizado).
select public.clipping_vincular_portais();

-- Coleta + um primeiro lote de 3 imagens (o resto vem pelo pg_cron).
-- "coleta" deve trazer "ok": true e o total de notícias novas; "imagens",
-- quantas ganharam capa. Erro de HTTP = o Google recusou temporariamente;
-- o agendamento tenta de novo.
select public.clipping_coletar() as coleta, public.clipping_processar_imagens(3) as imagens;

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
