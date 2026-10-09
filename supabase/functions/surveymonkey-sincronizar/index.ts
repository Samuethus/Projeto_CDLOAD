// CDLoad · Edge Function "surveymonkey-sincronizar"
//
// Copia a conta do Survey Monkey (API v3, somente leitura) para as tabelas survey_* do Supabase
// (supabase/schema_surveymonkey.sql). Chamada pelo pg_cron a cada 15 minutos.
//
// Cada execução:
//   1. Pastas ............ GET /survey_folders
//   2. Formulários ....... GET /surveys (nº de respostas e data de alteração); o que mudou fica "pendente".
//                          A pasta de cada formulário é relida 1x por dia ou quando aparece formulário novo.
//   3. Para cada pendente, até acabar o tempo ou o limite de chamadas:
//        estrutura ...... GET /surveys/{id}/details (só se o formulário foi alterado)
//        coletores ...... GET /surveys/{id}/collectors (status Aberto/Encerrado do formulário)
//        respostas ...... GET /surveys/{id}/responses/bulk, INCREMENTAL a partir da última lida
//   4. Registra a execução em survey_sincronizacoes.
// O que não coube no tempo continua na execução seguinte, do ponto onde parou.
//
// Secrets: SURVEYMONKEY_TOKEN (Access Token do app privado, 4 escopos de leitura).
//          SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já vêm do próprio Supabase.
// Publicação: npx supabase functions deploy surveymonkey-sincronizar --no-verify-jwt
//   (sem JWT porque quem chama é o pg_cron; a função ignora chamadas a menos de 5 min da anterior).
//
// LGPD: pergunta de contato (nome, e-mail, telefone, CPF, endereço...) fica marcada como dado_pessoal
// e a resposta dela não é gravada (só "respondida"). O IP do respondente nunca é lido.

import { createClient } from 'npm:@supabase/supabase-js@2';

const API = Deno.env.get('SURVEYMONKEY_API') ?? 'https://api.surveymonkey.com/v3';
const TEMPO_MAX_MS = 110_000;         // a Edge Function tem ~150 s; sobra margem para gravar o registro
const INTERVALO_MIN_MS = 5 * 60_000;  // proteção contra chamadas repetidas
const DIA_MIN = 25;                   // para quando restarem menos chamadas que isso no dia
const MINUTO_MIN = 5;

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

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, erro: 'Use POST.' }, 405);
  const token = env('SURVEYMONKEY_TOKEN');
  if (!token) return json({ ok: false, erro: 'Falta o secret SURVEYMONKEY_TOKEN no Supabase.' }, 503);

  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  const inicio = Date.now();

  // Proteção: uma execução por vez e no máximo uma a cada 5 minutos.
  const { data: ultima } = await db.from('survey_sincronizacoes').select('iniciado_em').order('id', { ascending: false }).limit(1).maybeSingle();
  if (ultima && inicio - new Date(ultima.iniciado_em).getTime() < INTERVALO_MIN_MS) {
    return json({ ok: true, ignorado: 'Última sincronização há menos de 5 minutos.' });
  }
  const { data: reg, error: erroReg } = await db.from('survey_sincronizacoes').insert({}).select('id').single();
  if (erroReg) return json({ ok: false, erro: 'Rode supabase/schema_surveymonkey.sql: ' + erroReg.message }, 500);

  let chamadas = 0, atualizados = 0, respostasNovas = 0, total = 0;
  const erros: string[] = [];

  // ---------------- API do Survey Monkey ----------------
  // deno-lint-ignore no-explicit-any
  async function api(caminho: string): Promise<any> {
    if (Date.now() - inicio > TEMPO_MAX_MS) throw new Parar('tempo');
    const url = caminho.startsWith('http') ? caminho : API + caminho;
    const res = await fetch(url, { headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' } });
    chamadas++;
    const dia = Number(res.headers.get('X-Ratelimit-App-Global-Day-Remaining') ?? 'NaN');
    const minuto = Number(res.headers.get('X-Ratelimit-App-Global-Minute-Remaining') ?? 'NaN');
    if (res.status === 429) throw new Parar('limite de chamadas da API (429)');
    if (!res.ok) {
      const txt = (await res.text()).slice(0, 300);
      throw new Error(`${res.status} em ${url.replace(API, '')}: ${txt}`);
    }
    const corpo = await res.json();
    if (dia < DIA_MIN) throw new Parar(`limite diário quase no fim (${dia} chamadas restantes)`);
    if (minuto < MINUTO_MIN) await new Promise((r) => setTimeout(r, 15_000));
    return corpo;
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

  let parada = '';
  try {
    // ---------------- 1. Pastas ----------------
    const pastas = await todos('/survey_folders?per_page=100');
    const agora = new Date().toISOString();
    await gravar('survey_pastas', [{ id: '0', titulo: 'Sem pasta', atualizado_em: agora },
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
        ...(relerPastas || !ant ? { atualizado_em: agora } : {}),
      };
    });
    await gravar('survey_formularios', linhas);
    // Excluídos no Survey Monkey: ficam inativos (os dados continuam).
    const ids = new Set(linhas.map((l) => l.id));
    const sumiram = (atuais ?? []).filter((f) => !ids.has(f.id)).map((f) => f.id);
    if (sumiram.length) await db.from('survey_formularios').update({ ativo: false, pendente: false }).in('id', sumiram);

    // ---------------- 3. Formulários pendentes ----------------
    // Menores primeiro: mais formulários ficam completos em cada execução.
    const { data: pendentes } = await db.from('survey_formularios')
      .select('id,modificado_em,estrutura_lida_em,respostas_lidas_ate,qtd_respostas')
      .eq('pendente', true).eq('ativo', true).order('qtd_respostas', { ascending: true });

    for (const f of pendentes ?? []) {
      try {
        // 3a. Estrutura (páginas → perguntas → opções), só se o formulário foi alterado.
        const pessoais = new Set<string>();
        if (!f.estrutura_lida_em || f.estrutura_lida_em !== f.modificado_em) {
          const det = await api(`/surveys/${f.id}/details`);
          const perguntas: Record<string, unknown>[] = [];
          // deno-lint-ignore no-explicit-any
          (det.pages ?? []).forEach((pg: any, ip: number) => (pg.questions ?? []).forEach((q: any, iq: number) => {
            const titulo = semHtml(q.headings?.[0]?.heading) || '(sem título)';
            const a = q.answers ?? {};
            // deno-lint-ignore no-explicit-any
            const op = (xs: any[]) => (xs ?? []).map((x: any) => ({ id: String(x.id), text: semHtml(x.text) }));
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
        (qs ?? []).forEach((q) => { if (q.dado_pessoal) pessoais.add(q.id); });

        // 3b. Coletores: o formulário está "OPEN" se algum coletor estiver aberto.
        const coletores = await todos(`/surveys/${f.id}/collectors?per_page=100&include=type,status,response_count,date_created`);
        await gravar('survey_coletores', coletores.map((c) => ({
          id: String(c.id), formulario_id: f.id, nome: c.name ?? null, tipo: c.type ?? null, status: c.status ?? null,
          qtd_respostas: c.response_count ?? null, criado_em: utc(c.date_created),
        })));
        await db.from('survey_formularios').update({ status: coletores.some((c) => c.status === 'open') ? 'OPEN' : 'CLOSED' }).eq('id', f.id);

        // 3c. Respostas, incrementais (a partir da última lida), 100 por chamada, gravando a cada página.
        let cursor: string | null = utc(f.respostas_lidas_ate);
        let prox: string | null = `/surveys/${f.id}/responses/bulk?per_page=100&sort_by=date_modified&sort_order=ASC`
          + (cursor ? `&start_modified_at=${encodeURIComponent(paraApi(cursor))}` : '');
        while (prox) {
          const pag = await api(prox);
          // deno-lint-ignore no-explicit-any
          const linhasR = (pag.data ?? []).map((r: any) => {
            const resp: Record<string, unknown[]> = {};
            // deno-lint-ignore no-explicit-any
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
            const mod = utc(r.date_modified);
            if (mod && (!cursor || mod > cursor)) cursor = mod;
            return { id: String(r.id), formulario_id: f.id, coletor_id: r.collector_id ? String(r.collector_id) : null,
              status: r.response_status ?? null, iniciada_em: utc(r.date_created), modificada_em: mod, respostas: resp };
          });
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
