// @ts-nocheck — roda em Deno (Supabase); o TypeScript do VS Code não conhece Deno nem imports npm:
// CDLoad · Edge Function "surveymonkey-sincronizar"
//
// Copia a conta do Survey Monkey (API v3) para as tabelas survey_* do Supabase (supabase/schema_surveymonkey.sql).
// Dois modos, no mesmo endereço:
//
// A. Sincronização (pg_cron a cada 15 min, corpo vazio):
//   1. Pastas ............ GET /survey_folders
//   2. Formulários ....... GET /surveys (nº de respostas e data de alteração); o que mudou fica "pendente".
//                          A pasta de cada formulário é relida 1x por dia ou quando aparece formulário novo.
//   3. Webhook ........... garante o webhook "response_completed" apontando para esta função (modo B),
//                          cobrindo todos os formulários (só com o secret SURVEYMONKEY_WEBHOOK_CHAVE).
//   4. Para cada pendente, até acabar o tempo ou o limite de chamadas:
//        estrutura ...... GET /surveys/{id}/details (só se o formulário foi alterado)
//        coletores ...... GET /surveys/{id}/collectors (status Aberto/Encerrado e link de resposta "url")
//        respostas ...... GET /surveys/{id}/responses/bulk, INCREMENTAL a partir da última lida
//   5. Coletores dos formulários abertos, 1x por hora (link de um coletor novo aparece sem esperar resposta).
//   6. Registra a execução em survey_sincronizacoes.
//   Requer supabase/schema_surveymonkey_link_coletor.sql (colunas url e coletores_lidos_em).
//   O que não coube no tempo continua na execução seguinte, do ponto onde parou.
//
// B. Tempo real (webhook do Survey Monkey a cada resposta enviada, ?chave=SURVEYMONKEY_WEBHOOK_CHAVE):
//   lê só aquela resposta (GET /surveys/{s}/responses/{r}/details), grava em survey_respostas e atualiza a
//   contagem do formulário. O app recebe a linha nova pelo Supabase Realtime e atualiza a tela na hora.
//   O Survey Monkey confere o endereço com um HEAD ao criar o webhook (respondido com 200).
//
// Secrets: SURVEYMONKEY_TOKEN (Access Token do app privado: escopos de leitura + "View/Create webhooks").
//          SURVEYMONKEY_WEBHOOK_CHAVE (texto aleatório; sem ele o modo B fica desligado).
//          SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já vêm do próprio Supabase.
// Publicação: npx supabase functions deploy surveymonkey-sincronizar --no-verify-jwt
//   (sem JWT porque quem chama é o pg_cron e o Survey Monkey; a sincronização ignora chamadas a menos de
//   5 min da anterior e o webhook exige a chave).
//
// LGPD: pergunta de contato (nome, e-mail, telefone, CPF, endereço...) fica marcada como dado_pessoal
// e a resposta dela não é gravada (só "respondida"). O IP do respondente nunca é lido.

import { createClient } from 'npm:@supabase/supabase-js@2';

const API = Deno.env.get('SURVEYMONKEY_API') ?? 'https://api.surveymonkey.com/v3';
const TEMPO_MAX_MS = 110_000;         // a Edge Function tem ~150 s; sobra margem para gravar o registro
const INTERVALO_MIN_MS = 5 * 60_000;  // proteção contra chamadas repetidas
const DIA_MIN = 25;                   // para quando restarem menos chamadas que isso no dia
const MINUTO_MIN = 5;
const WEBHOOK_NOME = 'CDLoad · respostas em tempo real';

const env = (k: string) => (Deno.env.get(k) ?? '').trim();
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

class Parar extends Error {}

// Pergunta de contato / identificação: o conteúdo não é importado.
const PESSOAL_RE = /\b(nome|e-?mail|telefone|celular|whats ?app|fone|cpf|cnpj|rg|endereco|cep|nascimento|contato|instagram)\b/;
const normalizar = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
const semHtml = (s: unknown) => String(s ?? '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();

// Datas da API vêm sem fuso ("2026-10-09T19:11:00"): são UTC.
// Sempre devolvidas como ISO em UTC ("...Z"), para poderem ser comparadas como texto.
const utc = (s: unknown) => (s ? new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(String(s)) ? String(s) : String(s) + 'Z').toISOString() : null);
const paraApi = (iso: string) => new Date(iso).toISOString().slice(0, 19);

// Uma resposta da API → linha de survey_respostas (perguntas de dado pessoal só como "respondida").
// deno-lint-ignore no-explicit-any
function linhaResposta(r: any, formularioId: string, pessoais: Set<string>) {
  const resp: Record<string, unknown[]> = {};
  for (const pg of r.pages ?? []) for (const q of pg.questions ?? []) {
    const qid = String(q.id);
    // deno-lint-ignore no-explicit-any
    resp[qid] = pessoais.has(qid) ? [{ p: 1 }] : (q.answers ?? []).map((a: any) => {
      const o: Record<string, string> = {};
      if (a.choice_id) o.c = String(a.choice_id);
      if (a.row_id) o.r = String(a.row_id);
      if (a.col_id) o.k = String(a.col_id);
      if (a.other_id) o.o = String(a.other_id);
      if (a.text != null && a.text !== '') o.t = String(a.text).slice(0, 2000);
      return o;
    });
  }
  return { id: String(r.id), formulario_id: formularioId, coletor_id: r.collector_id ? String(r.collector_id) : null,
    status: r.response_status ?? null, iniciada_em: utc(r.date_created), modificada_em: utc(r.date_modified), respostas: resp };
}

Deno.serve(async (req) => {
  // O Survey Monkey confere o endereço do webhook com um HEAD antes de criá-lo.
  if (req.method === 'HEAD') return new Response(null, { status: 200 });
  if (req.method !== 'POST') return json({ ok: false, erro: 'Use POST.' }, 405);
  const token = env('SURVEYMONKEY_TOKEN');
  if (!token) return json({ ok: false, erro: 'Falta o secret SURVEYMONKEY_TOKEN no Supabase.' }, 503);

  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  const inicio = Date.now();
  let chamadas = 0;

  // ---------------- API do Survey Monkey ----------------
  // deno-lint-ignore no-explicit-any
  async function api(caminho: string, metodo = 'GET', corpo?: unknown): Promise<any> {
    if (Date.now() - inicio > TEMPO_MAX_MS) throw new Parar('tempo');
    const url = caminho.startsWith('http') ? caminho : API + caminho;
    const res = await fetch(url, {
      method: metodo,
      headers: { Authorization: 'Bearer ' + token, Accept: 'application/json', ...(corpo ? { 'Content-Type': 'application/json' } : {}) },
      ...(corpo ? { body: JSON.stringify(corpo) } : {}),
    });
    chamadas++;
    const dia = Number(res.headers.get('X-Ratelimit-App-Global-Day-Remaining') ?? 'NaN');
    const minuto = Number(res.headers.get('X-Ratelimit-App-Global-Minute-Remaining') ?? 'NaN');
    if (res.status === 429) throw new Parar('limite de chamadas da API (429)');
    if (!res.ok) {
      const txt = (await res.text()).slice(0, 300);
      throw new Error(`${res.status} em ${metodo} ${url.replace(API, '')}: ${txt}`);
    }
    const resposta = await res.json();
    if (dia < DIA_MIN) throw new Parar(`limite diário quase no fim (${dia} chamadas restantes)`);
    if (minuto < MINUTO_MIN) await new Promise((r) => setTimeout(r, 15_000));
    return resposta;
  }
  // Lista paginada (segue links.next).
  // deno-lint-ignore no-explicit-any
  async function todos(caminho: string): Promise<any[]> {
    // deno-lint-ignore no-explicit-any
    const out: any[] = [];
    let prox: string | null = caminho;
    while (prox) {
      const j = await api(prox);
      out.push(...(j.data ?? []));
      prox = j.links?.next ?? null;
    }
    return out;
  }
  async function gravar(tabela: string, linhas: Record<string, unknown>[], conflito = 'id') {
    for (let i = 0; i < linhas.length; i += 500) {
      const { error } = await db.from(tabela).upsert(linhas.slice(i, i + 500), { onConflict: conflito });
      if (error) throw new Error(`gravar ${tabela}: ${error.message}`);
    }
  }
  // Coletores do formulário (canal + link de resposta "url"); o formulário fica "OPEN" se algum coletor estiver aberto.
  async function lerColetores(formularioId: string) {
    const coletores = await todos(`/surveys/${formularioId}/collectors?per_page=100&include=type,status,response_count,date_created,url`);
    await gravar('survey_coletores', coletores.map((c) => ({
      id: String(c.id), formulario_id: formularioId, nome: c.name ?? null, tipo: c.type ?? null, status: c.status ?? null,
      qtd_respostas: c.response_count ?? null, criado_em: utc(c.date_created), url: c.url ?? null,
    })));
    await db.from('survey_formularios').update({ status: coletores.some((c) => c.status === 'open') ? 'OPEN' : 'CLOSED',
      coletores_lidos_em: new Date().toISOString() }).eq('id', formularioId);
  }
  // Contagem do formulário = respostas gravadas (o app mostra na lista; a sincronização confere com a API).
  async function recontar(formularioId: string) {
    const { count } = await db.from('survey_respostas').select('id', { count: 'exact', head: true }).eq('formulario_id', formularioId);
    await db.from('survey_formularios').update({ qtd_respostas: count ?? 0 }).eq('id', formularioId);
  }

  // =============== B. Webhook: uma resposta nova, gravada na hora ===============
  let corpo: Record<string, unknown> = {};
  try { corpo = await req.json(); } catch { /* corpo vazio: sincronização */ }
  if (corpo && corpo.event_type) {
    const chave = env('SURVEYMONKEY_WEBHOOK_CHAVE');
    if (!chave || new URL(req.url).searchParams.get('chave') !== chave) return json({ ok: false, erro: 'Chave do webhook inválida.' }, 403);
    // deno-lint-ignore no-explicit-any
    const rec = (corpo.resources ?? {}) as any;
    const sid = String(rec.survey_id ?? ''), rid = String(corpo.object_id ?? '');
    if (corpo.object_type !== 'response' || !sid || !rid) return json({ ok: true, ignorado: 'Evento sem resposta.' });
    try {
      const { data: f } = await db.from('survey_formularios').select('id').eq('id', sid).maybeSingle();
      const { data: qs } = await db.from('survey_perguntas').select('id,dado_pessoal').eq('formulario_id', sid);
      // Formulário novo ou estrutura ainda não lida: a sincronização seguinte traz tudo (não dá para saber quais perguntas são pessoais).
      if (!f || !qs?.length) {
        if (f) await db.from('survey_formularios').update({ pendente: true }).eq('id', sid);
        return json({ ok: true, adiado: 'Formulário ainda não sincronizado: entra na próxima sincronização.' });
      }
      if (corpo.event_type === 'response_deleted') {
        await db.from('survey_respostas').delete().eq('id', rid);
      } else {
        const r = await api(`/surveys/${sid}/responses/${rid}/details`);
        const pessoais = new Set((qs ?? []).filter((q) => q.dado_pessoal).map((q) => q.id));
        await gravar('survey_respostas', [linhaResposta(r, sid, pessoais)]);
      }
      await recontar(sid);
      return json({ ok: true, formulario: sid, resposta: rid, chamadas_api: chamadas });
    } catch (e) {
      console.error('[surveymonkey-sincronizar] webhook', sid, rid, e);
      // Marca o formulário para a sincronização seguinte reler o que faltou.
      await db.from('survey_formularios').update({ pendente: true }).eq('id', sid);
      return json({ ok: false, erro: (e as Error).message }, 500);
    }
  }

  // =============== A. Sincronização completa (pg_cron) ===============
  // Proteção: uma execução por vez e no máximo uma a cada 5 minutos.
  const { data: ultima } = await db.from('survey_sincronizacoes').select('iniciado_em').order('id', { ascending: false }).limit(1).maybeSingle();
  if (ultima && inicio - new Date(ultima.iniciado_em).getTime() < INTERVALO_MIN_MS) {
    return json({ ok: true, ignorado: 'Última sincronização há menos de 5 minutos.' });
  }
  const { data: reg, error: erroReg } = await db.from('survey_sincronizacoes').insert({}).select('id').single();
  if (erroReg) return json({ ok: false, erro: 'Rode supabase/schema_surveymonkey.sql: ' + erroReg.message }, 500);

  let atualizados = 0, respostasNovas = 0, total = 0;
  const erros: string[] = [];

  let parada = '';
  try {
    // ---------------- 1. Pastas ----------------
    const pastas = await todos('/survey_folders?per_page=100');
    const agora = new Date().toISOString();
    // Todas as linhas com as mesmas colunas: no upsert em lote, coluna ausente vira null (e qtd_formularios é not null).
    await gravar('survey_pastas', [{ id: '0', titulo: 'Sem pasta', qtd_formularios: 0, atualizado_em: agora },
      // deno-lint-ignore no-explicit-any
      ...pastas.map((p: any) => ({ id: String(p.id), titulo: p.title ?? '', qtd_formularios: p.num_surveys ?? 0, atualizado_em: agora }))]);

    // ---------------- 2. Formulários ----------------
    const lista = await todos('/surveys?per_page=1000&include=response_count,date_created,date_modified,question_count,preview');
    total = lista.length;
    const { data: atuais } = await db.from('survey_formularios').select('id,pasta_id,qtd_respostas,modificado_em,pendente');
    const porId = new Map((atuais ?? []).map((f) => [f.id, f]));

    // Pasta de cada formulário: relida quando aparece formulário novo ou 1x por dia.
    const { data: refPasta } = await db.from('survey_formularios').select('atualizado_em').eq('ativo', true)
      .order('atualizado_em', { ascending: true }).limit(1).maybeSingle();
    // deno-lint-ignore no-explicit-any
    const temNovo = lista.some((s: any) => !porId.has(String(s.id)));
    const pastaDe = new Map<string, string>();
    const relerPastas = temNovo || !refPasta || Date.now() - new Date(refPasta.atualizado_em).getTime() > 24 * 3600_000;
    if (relerPastas) {
      for (const p of pastas) {
        for (const s of await todos(`/surveys?per_page=1000&folder_id=${p.id}`)) pastaDe.set(String(s.id), String(p.id));
      }
    }

    // deno-lint-ignore no-explicit-any
    const linhas = lista.map((s: any) => {
      const id = String(s.id), ant = porId.get(id);
      const modificado = utc(s.date_modified);
      const mudou = !ant || ant.qtd_respostas !== (s.response_count ?? 0)
        || (ant.modificado_em && modificado ? new Date(ant.modificado_em).getTime() !== new Date(modificado).getTime() : true);
      return {
        id, titulo: semHtml(s.title), qtd_perguntas: s.question_count ?? null, qtd_respostas: s.response_count ?? 0,
        link_preview: s.preview ?? null, criado_em: utc(s.date_created), modificado_em: modificado, ativo: true,
        pasta_id: relerPastas ? (pastaDe.get(id) ?? '0') : (ant?.pasta_id ?? '0'),
        pendente: !!(ant?.pendente || mudou),
        // Todas as linhas com ou todas sem atualizado_em (formulário novo sempre força relerPastas).
        ...(relerPastas || !ant ? { atualizado_em: agora } : {}),
      };
    });
    await gravar('survey_formularios', linhas);
    // Excluídos no Survey Monkey: ficam inativos (os dados continuam).
    const ids = new Set(linhas.map((l) => l.id));
    const sumiram = (atuais ?? []).filter((f) => !ids.has(f.id)).map((f) => f.id);
    if (sumiram.length) await db.from('survey_formularios').update({ ativo: false, pendente: false }).in('id', sumiram);

    // ---------------- 3. Webhook de tempo real ----------------
    // Criado na primeira execução; atualizado quando aparece formulário novo (o webhook lista os formulários).
    const chaveWh = env('SURVEYMONKEY_WEBHOOK_CHAVE');
    if (chaveWh) {
      try {
        const destino = `${env('SUPABASE_URL')}/functions/v1/surveymonkey-sincronizar?chave=${encodeURIComponent(chaveWh)}`;
        // deno-lint-ignore no-explicit-any
        const existente = (await todos('/webhooks?per_page=100')).find((w: any) => w.name === WEBHOOK_NOME);
        const config = { name: WEBHOOK_NOME, event_type: 'response_completed', object_type: 'survey', object_ids: [...ids], subscription_url: destino };
        if (!existente) await api('/webhooks', 'POST', config);
        else if (temNovo) await api(`/webhooks/${existente.id}`, 'PATCH', { object_ids: [...ids], subscription_url: destino });
      } catch (e) {
        if (e instanceof Parar) throw e;
        erros.push('webhook: ' + (e as Error).message);
      }
    }

    // ---------------- 4. Formulários pendentes ----------------
    // Menores primeiro: mais formulários ficam completos em cada execução.
    const { data: pendentes } = await db.from('survey_formularios')
      .select('id,modificado_em,estrutura_lida_em,respostas_lidas_ate,qtd_respostas')
      .eq('pendente', true).eq('ativo', true).order('qtd_respostas', { ascending: true });

    for (const f of pendentes ?? []) {
      try {
        // 4a. Estrutura (páginas → perguntas → opções), só se o formulário foi alterado.
        if (!f.estrutura_lida_em || f.estrutura_lida_em !== f.modificado_em) {
          const det = await api(`/surveys/${f.id}/details`);
          const perguntas: Record<string, unknown>[] = [];
          // deno-lint-ignore no-explicit-any
          (det.pages ?? []).forEach((pg: any, ip: number) => (pg.questions ?? []).forEach((q: any, iq: number) => {
            const titulo = semHtml(q.headings?.[0]?.heading) || '(sem título)';
            const a = q.answers ?? {};
            // deno-lint-ignore no-explicit-any
            // weight = nota da opção nas escalas de avaliação (estrelas); na = opção "N/A" (fica fora da média).
            const op = (xs: any[]) => (xs ?? []).map((x: any) => ({ id: String(x.id), text: semHtml(x.text),
              ...(typeof x.weight === 'number' ? { weight: x.weight } : {}), ...(x.is_na ? { na: true } : {}) }));
            const pessoal = q.family === 'demographic' || PESSOAL_RE.test(normalizar(titulo));
            perguntas.push({
              id: String(q.id), formulario_id: f.id, pagina: pg.position ?? ip + 1, posicao: q.position ?? iq + 1, titulo,
              familia: q.family ?? '', subtipo: q.subtype ?? null, dado_pessoal: pessoal,
              opcoes: { choices: op(a.choices), rows: op(a.rows), cols: op(a.cols),
                ...(a.other ? { other: { id: String(a.other.id), text: semHtml(a.other.text) } } : {}) },
            });
          }));
          await db.from('survey_perguntas').delete().eq('formulario_id', f.id)
            .not('id', 'in', `(${perguntas.map((p) => p.id).join(',') || '0'})`);
          await gravar('survey_perguntas', perguntas);
          await db.from('survey_formularios').update({ estrutura_lida_em: f.modificado_em }).eq('id', f.id);
        }
        const { data: qs } = await db.from('survey_perguntas').select('id,dado_pessoal').eq('formulario_id', f.id);
        const pessoais = new Set((qs ?? []).filter((q) => q.dado_pessoal).map((q) => q.id));

        // 4b. Coletores (status Aberto/Encerrado e link de resposta).
        await lerColetores(f.id);

        // 4c. Respostas, incrementais (a partir da última lida), 100 por chamada, gravando a cada página.
        let cursor: string | null = utc(f.respostas_lidas_ate);
        let prox: string | null = `/surveys/${f.id}/responses/bulk?per_page=100&sort_by=date_modified&sort_order=ASC`
          + (cursor ? `&start_modified_at=${encodeURIComponent(paraApi(cursor))}` : '');
        while (prox) {
          const pag = await api(prox);
          // deno-lint-ignore no-explicit-any
          const linhasR = (pag.data ?? []).map((r: any) => linhaResposta(r, f.id, pessoais));
          for (const l of linhasR) if (l.modificada_em && (!cursor || l.modificada_em > cursor)) cursor = l.modificada_em;
          await gravar('survey_respostas', linhasR);
          respostasNovas += linhasR.length;
          await db.from('survey_formularios').update({ respostas_lidas_ate: cursor }).eq('id', f.id);
          prox = pag.links?.next ?? null;
        }

        await db.from('survey_formularios').update({ pendente: false }).eq('id', f.id);
        atualizados++;
      } catch (e) {
        if (e instanceof Parar) throw e;
        erros.push(`${f.id}: ${(e as Error).message}`);
        console.error('[surveymonkey-sincronizar]', f.id, e);
      }
    }

    // ---------------- 5. Coletores dos formulários abertos (1x por hora) ----------------
    // Coletor novo (link novo) não muda o formulário nem o nº de respostas: sem esta releitura, o link
    // só apareceria quando chegasse a primeira resposta por ele.
    const umaHora = new Date(Date.now() - 3600_000).toISOString();
    const { data: abertos } = await db.from('survey_formularios').select('id').eq('ativo', true).eq('pendente', false).eq('status', 'OPEN')
      .or(`coletores_lidos_em.is.null,coletores_lidos_em.lt."${umaHora}"`);
    for (const f of abertos ?? []) {
      try { await lerColetores(f.id); }
      catch (e) { if (e instanceof Parar) throw e; erros.push(`${f.id} (coletores): ${(e as Error).message}`); }
    }
  } catch (e) {
    if (e instanceof Parar) parada = e.message;
    else { erros.push((e as Error).message); console.error('[surveymonkey-sincronizar]', e); }
  }

  const { count: pendentes } = await db.from('survey_formularios').select('id', { count: 'exact', head: true })
    .eq('pendente', true).eq('ativo', true);
  await db.from('survey_sincronizacoes').update({
    finalizado_em: new Date().toISOString(), formularios: total, atualizados, respostas_novas: respostasNovas,
    pendentes: pendentes ?? null, chamadas_api: chamadas, erros: erros.length ? erros.join(' | ').slice(0, 4000) : null,
  }).eq('id', reg.id);

  return json({ ok: !erros.length, formularios: total, atualizados, respostas_novas: respostasNovas, pendentes, chamadas_api: chamadas,
    continua_na_proxima: parada || undefined, erros: erros.length ? erros : undefined });
});
