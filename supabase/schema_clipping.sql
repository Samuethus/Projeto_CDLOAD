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

revoke all on public.clipping_news, public.clipping_coletas from anon;
grant select, insert, update, delete on public.clipping_news to authenticated;
grant select on public.clipping_coletas to authenticated;  -- gravação só via clipping_coletar()
grant all on public.clipping_news, public.clipping_coletas to service_role;

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
-- 4. Coleta no Google Notícias (RSS)
--
-- Chamada de 3 jeitos: pelo pg_cron (a cada 30 min), pelo SQL Editor e
-- pelo botão "Buscar notícias" do app (RPC). Pelo app exige a seção
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
  v_ts         timestamptz;
  v_data       date;
  v_desde      date := date_trunc('year', now() at time zone 'America/Cuiaba')::date;
  v_origem     text := 'automatica';
  v_ultima     timestamptz;
  v_coleta     bigint;
  v_encontradas integer := 0;
  v_novas      integer := 0;
  v_erros      text := '';
  n            integer;
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
             origem, link, google_id, termo_busca, publicado_em)
          values
            (v_titulo,
             'Encontrada no Google Notícias pela busca "' || termo || '". Clique no título para ler a matéria completa.',
             v_fonte, v_data,
             public.clipping_classificar_categoria(v_titulo),
             public.clipping_classificar_canal(v_fonte),
             public.clipping_classificar_sentimento(v_titulo),
             'google_news', v_link, btrim(it.guid), termo, v_ts)
          on conflict (google_id) do nothing;

          get diagnostics n = row_count;
          v_novas := v_novas + n;
        end loop;
      exception when others then
        v_erros := v_erros || termo || janela || ': ' || sqlerrm || E'\n';
      end;
    end loop;
  end loop;

  update public.clipping_coletas
     set finalizado_em = now(), encontradas = v_encontradas, novas = v_novas, erros = nullif(v_erros, '')
   where id = v_coleta;

  return jsonb_build_object('ok', v_erros = '', 'encontradas', v_encontradas, 'novas', v_novas,
                            'erros', nullif(v_erros, ''));
end;
$$;

revoke all on function public.clipping_coletar() from public, anon;
grant execute on function public.clipping_coletar() to authenticated;
revoke all on function public.clipping_classificar_canal(text),
               public.clipping_classificar_categoria(text), public.clipping_classificar_sentimento(text)
  from public, anon;

-- ---------------------------------------------------------------------
-- 5. Agendamento (a cada 30 min) e primeira coleta
-- ---------------------------------------------------------------------
select cron.schedule('cdload-clipping-google-news', '*/30 * * * *', $$select public.clipping_coletar()$$);

-- Deve retornar "ok": true e o total de notícias novas. Se vier erro de
-- HTTP, o Google recusou temporariamente; o agendamento tenta de novo.
select public.clipping_coletar();

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
