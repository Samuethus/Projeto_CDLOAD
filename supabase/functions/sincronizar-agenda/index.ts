// CDLoad · Edge Function "sincronizar-agenda"
//
// Cria, atualiza ou cancela o evento de uma campanha na agenda de todos os
// participantes. O evento é criado na agenda de uma conta ORGANIZADORA da
// organização, com os participantes como convidados: o Outlook / Google
// envia o convite e o horário fica bloqueado na agenda de cada pessoa.
//
// Provedores (cada um só roda se os secrets dele estiverem definidos):
//   Outlook (Microsoft 365, Graph):  MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_ORGANIZADOR_EMAIL
//   Google Calendar (Gmail pessoal): GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN, [GOOGLE_CALENDAR_ID]
//   Google Calendar (Workspace):     GOOGLE_SERVICE_ACCOUNT_JSON, GOOGLE_ORGANIZADOR_EMAIL, [GOOGLE_CALENDAR_ID]
// Passo a passo em supabase/LEIA-ME.md.
//
// Segurança: a função usa o login de quem chamou (nada de service_role).
// Só passa quem tem a seção "campanhas" liberada (mesma regra do RLS);
// alterar ou cancelar o evento de uma campanha existente é só do Administrador.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const TZ_IANA = 'America/Cuiaba';
const TZ_WINDOWS = 'Central Brazilian Standard Time';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DATA_RE = /^\d{4}-\d{2}-\d{2}$/;
const HORA_RE = /^\d{2}:\d{2}$/;

type Participante = { nome: string; email: string };
type Formato = 'dia_inteiro' | 'horario' | 'horario_diario';
type Evento = {
  titulo: string;
  descricaoHtml: string;
  local: string;
  participantes: Participante[];
  dataInicio: string;
  dataFim: string;
  horaInicio: string | null;
  horaFim: string | null;
  formato: Formato;
};
type Provedor = {
  chave: 'outlook' | 'google';
  configurado: () => boolean;
  criar: (ev: Evento) => Promise<string>;
  atualizar: (id: string, ev: Evento) => Promise<boolean>;
  cancelar: (id: string) => Promise<void>;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const env = (k: string) => (Deno.env.get(k) ?? '').trim();

const escHtml = (s: unknown) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

function addDias(data: string, n: number): string {
  const d = new Date(data + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

const dataBR = (d: string) => d.split('-').reverse().join('/');

async function falha(res: Response, contexto: string): Promise<never> {
  const texto = await res.text();
  let msg = texto.slice(0, 300);
  try {
    const j = JSON.parse(texto);
    msg = j?.error?.message ?? j?.error_description ?? msg;
  } catch { /* resposta não-JSON */ }
  throw new Error(`${contexto} (${res.status}): ${msg}`);
}

// deno-lint-ignore no-explicit-any
function montarEvento(camp: any): Evento {
  const p = camp.planejamento_e_objetivos ?? {};
  const pm = camp.publico_e_midia ?? {};
  const et = camp.estrutura_tecnica ?? {};

  const dataInicio = String(p.data_inicio ?? '');
  const dataFim = String(p.data_fim || p.data_inicio || '');
  if (!DATA_RE.test(dataInicio) || !DATA_RE.test(dataFim)) throw new Error('A campanha não tem data de início/fim válida.');
  if (dataFim < dataInicio) throw new Error('A data de fim da campanha é anterior à data de início.');

  const horaInicio = HORA_RE.test(et.horario_inicio ?? '') ? et.horario_inicio : null;
  const horaFim = HORA_RE.test(et.horario_fim ?? '') ? et.horario_fim : null;
  const comHorario = !!(horaInicio && horaFim && horaFim > horaInicio);

  const vistos = new Set<string>();
  const participantes: Participante[] = [];
  for (const item of Array.isArray(et.participantes) ? et.participantes : []) {
    const email = String(item?.email ?? '').trim().toLowerCase();
    if (!EMAIL_RE.test(email) || vistos.has(email)) continue;
    vistos.add(email);
    participantes.push({ nome: String(item?.nome ?? '').trim(), email });
  }

  const local = [p.local, p.sala_reservada].filter(Boolean).join(' – ');
  const linhas = [
    ['Tipo de agenda', p.tipo_agenda],
    ['Local', local],
    ['Vigência', `${dataBR(dataInicio)} a ${dataBR(dataFim)}`],
    ['Times envolvidos', (et.times_envolvidos ?? []).join(', ')],
    ['Descrição', pm.descricao],
  ].filter(([, v]) => v);

  const descricaoHtml =
    linhas.map(([k, v]) => `<p><b>${escHtml(k)}:</b> ${escHtml(v)}</p>`).join('') +
    '<p style="color:#6b7280">Evento gerado pela plataforma CDLoad · Núcleo de Inteligência.</p>';

  return {
    titulo: String(camp.nome_campanha ?? 'Campanha'),
    descricaoHtml,
    local,
    participantes,
    dataInicio,
    dataFim,
    horaInicio: comHorario ? horaInicio : null,
    horaFim: comHorario ? horaFim : null,
    formato: !comHorario ? 'dia_inteiro' : dataFim > dataInicio ? 'horario_diario' : 'horario',
  };
}

// ---------------- Outlook / Microsoft 365 (Microsoft Graph) ----------------

let msToken: { valor: string; expira: number } | null = null;

async function tokenMicrosoft(): Promise<string> {
  if (msToken && msToken.expira > Date.now() + 60_000) return msToken.valor;
  const res = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(env('MS_TENANT_ID'))}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: env('MS_CLIENT_ID'),
      client_secret: env('MS_CLIENT_SECRET'),
      scope: 'https://graph.microsoft.com/.default',
      grant_type: 'client_credentials',
    }),
  });
  if (!res.ok) await falha(res, 'Login no Microsoft 365');
  const j = await res.json();
  msToken = { valor: j.access_token, expira: Date.now() + Number(j.expires_in ?? 3600) * 1000 };
  return msToken.valor;
}

function corpoOutlook(ev: Evento) {
  const tz = TZ_WINDOWS;
  // deno-lint-ignore no-explicit-any
  const base: any = {
    subject: ev.titulo,
    body: { contentType: 'HTML', content: ev.descricaoHtml },
    location: { displayName: ev.local },
    attendees: ev.participantes.map((p) => ({ emailAddress: { address: p.email, name: p.nome || p.email }, type: 'required' })),
    showAs: 'busy',
    isReminderOn: true,
    reminderMinutesBeforeStart: 60,
    allowNewTimeProposals: false,
  };
  if (ev.formato === 'dia_inteiro') {
    return {
      ...base,
      isAllDay: true,
      start: { dateTime: `${ev.dataInicio}T00:00:00`, timeZone: tz },
      end: { dateTime: `${addDias(ev.dataFim, 1)}T00:00:00`, timeZone: tz },
    };
  }
  base.isAllDay = false;
  base.start = { dateTime: `${ev.dataInicio}T${ev.horaInicio}:00`, timeZone: tz };
  base.end = { dateTime: `${ev.dataInicio}T${ev.horaFim}:00`, timeZone: tz };
  if (ev.formato === 'horario_diario') {
    base.recurrence = {
      pattern: { type: 'daily', interval: 1 },
      range: { type: 'endDate', startDate: ev.dataInicio, endDate: ev.dataFim, recurrenceTimeZone: tz },
    };
  }
  return base;
}

const graphEventos = () => `https://graph.microsoft.com/v1.0/users/${encodeURIComponent(env('MS_ORGANIZADOR_EMAIL'))}/events`;

const outlook: Provedor = {
  chave: 'outlook',
  configurado: () => !!(env('MS_TENANT_ID') && env('MS_CLIENT_ID') && env('MS_CLIENT_SECRET') && env('MS_ORGANIZADOR_EMAIL')),
  async criar(ev) {
    const res = await fetch(graphEventos(), {
      method: 'POST',
      headers: { Authorization: `Bearer ${await tokenMicrosoft()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(corpoOutlook(ev)),
    });
    if (!res.ok) await falha(res, 'Outlook: criar evento');
    return (await res.json()).id;
  },
  async atualizar(id, ev) {
    const res = await fetch(`${graphEventos()}/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      headers: { Authorization: `Bearer ${await tokenMicrosoft()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(corpoOutlook(ev)),
    });
    if (res.status === 404) return false;
    if (!res.ok) await falha(res, 'Outlook: atualizar evento');
    return true;
  },
  async cancelar(id) {
    const res = await fetch(`${graphEventos()}/${encodeURIComponent(id)}/cancel`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${await tokenMicrosoft()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ comment: 'Evento cancelado na plataforma CDLoad.' }),
    });
    if (res.status === 404) return;
    if (!res.ok) await falha(res, 'Outlook: cancelar evento');
  },
};

// ---------------- Google Calendar (Workspace, conta de serviço) ----------------

let googleToken: { valor: string; expira: number } | null = null;

const b64url = (dados: Uint8Array | string) => {
  const bytes = typeof dados === 'string' ? new TextEncoder().encode(dados) : dados;
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

// Gmail pessoal: OAuth do próprio dono da agenda (client id/secret + refresh
// token gerado uma vez no OAuth Playground). Tem prioridade sobre a conta de serviço.
const googleOAuth = () => !!(env('GOOGLE_CLIENT_ID') && env('GOOGLE_CLIENT_SECRET') && env('GOOGLE_REFRESH_TOKEN'));

async function tokenGoogleOAuth(): Promise<string> {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: env('GOOGLE_CLIENT_ID'),
      client_secret: env('GOOGLE_CLIENT_SECRET'),
      refresh_token: env('GOOGLE_REFRESH_TOKEN'),
    }),
  });
  if (!res.ok) await falha(res, 'Login no Google (refresh token)');
  const j = await res.json();
  googleToken = { valor: j.access_token, expira: Date.now() + Number(j.expires_in ?? 3600) * 1000 };
  return googleToken.valor;
}

async function tokenGoogle(): Promise<string> {
  if (googleToken && googleToken.expira > Date.now() + 60_000) return googleToken.valor;
  if (googleOAuth()) return tokenGoogleOAuth();
  let sa: { client_email: string; private_key: string };
  try {
    sa = JSON.parse(env('GOOGLE_SERVICE_ACCOUNT_JSON'));
  } catch {
    throw new Error('GOOGLE_SERVICE_ACCOUNT_JSON não é um JSON válido.');
  }
  const der = Uint8Array.from(
    atob(sa.private_key.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '')),
    (c) => c.charCodeAt(0),
  );
  const chave = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const agora = Math.floor(Date.now() / 1000);
  const cabecalho = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    sub: env('GOOGLE_ORGANIZADOR_EMAIL'),
    scope: 'https://www.googleapis.com/auth/calendar.events',
    aud: 'https://oauth2.googleapis.com/token',
    iat: agora,
    exp: agora + 3600,
  }));
  const assinatura = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', chave, new TextEncoder().encode(`${cabecalho}.${claims}`)));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${cabecalho}.${claims}.${b64url(assinatura)}`,
    }),
  });
  if (!res.ok) await falha(res, 'Login no Google Workspace');
  const j = await res.json();
  googleToken = { valor: j.access_token, expira: Date.now() + Number(j.expires_in ?? 3600) * 1000 };
  return googleToken.valor;
}

function corpoGoogle(ev: Evento) {
  // deno-lint-ignore no-explicit-any
  const base: any = {
    summary: ev.titulo,
    description: ev.descricaoHtml,
    location: ev.local,
    attendees: ev.participantes.map((p) => ({ email: p.email, displayName: p.nome || undefined })),
    transparency: 'opaque',
    guestsCanModify: false,
  };
  if (ev.formato === 'dia_inteiro') {
    return { ...base, start: { date: ev.dataInicio }, end: { date: addDias(ev.dataFim, 1) } };
  }
  base.start = { dateTime: `${ev.dataInicio}T${ev.horaInicio}:00`, timeZone: TZ_IANA };
  base.end = { dateTime: `${ev.dataInicio}T${ev.horaFim}:00`, timeZone: TZ_IANA };
  if (ev.formato === 'horario_diario') {
    // UNTIL é em UTC: 23:59:59 do último dia em Cuiabá (UTC-4) = 03:59:59Z do dia seguinte.
    const ate = addDias(ev.dataFim, 1).replace(/-/g, '') + 'T035959Z';
    base.recurrence = [`RRULE:FREQ=DAILY;UNTIL=${ate}`];
  }
  return base;
}

const googleEventos = () =>
  `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(env('GOOGLE_CALENDAR_ID') || 'primary')}/events`;

const google: Provedor = {
  chave: 'google',
  configurado: () => googleOAuth() || !!(env('GOOGLE_SERVICE_ACCOUNT_JSON') && env('GOOGLE_ORGANIZADOR_EMAIL')),
  async criar(ev) {
    const res = await fetch(`${googleEventos()}?sendUpdates=all`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${await tokenGoogle()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(corpoGoogle(ev)),
    });
    if (!res.ok) await falha(res, 'Google: criar evento');
    return (await res.json()).id;
  },
  async atualizar(id, ev) {
    const res = await fetch(`${googleEventos()}/${encodeURIComponent(id)}?sendUpdates=all`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${await tokenGoogle()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(corpoGoogle(ev)),
    });
    if (res.status === 404 || res.status === 410) return false;
    if (!res.ok) await falha(res, 'Google: atualizar evento');
    return true;
  },
  async cancelar(id) {
    const res = await fetch(`${googleEventos()}/${encodeURIComponent(id)}?sendUpdates=all`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${await tokenGoogle()}` },
    });
    if (res.status === 404 || res.status === 410) return;
    if (!res.ok) await falha(res, 'Google: cancelar evento');
  },
};

const PROVEDORES: Provedor[] = [outlook, google];

// ---------------- Handler ----------------

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, erro: 'Método não permitido.' }, 405);

  const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  });

  const { data: permitido, error: erroPermissao } = await supabase.rpc('cdl_secao', { chave: 'campanhas' });
  if (erroPermissao || permitido !== true) return json({ ok: false, erro: 'Sem permissão para a seção Campanhas.' }, 403);

  // deno-lint-ignore no-explicit-any
  let entrada: any;
  try {
    entrada = await req.json();
  } catch {
    return json({ ok: false, erro: 'Corpo da requisição inválido.' }, 400);
  }
  const campanhaId = String(entrada?.campanha_id ?? '');
  const acao = entrada?.acao === 'cancelar' ? 'cancelar' : 'sincronizar';
  if (!campanhaId) return json({ ok: false, erro: 'campanha_id é obrigatório.' }, 400);

  const { data: camp, error: erroCampanha } = await supabase
    .from('campanhas')
    .select('id,nome_campanha,planejamento_e_objetivos,publico_e_midia,estrutura_tecnica,agenda_sync')
    .eq('id', campanhaId)
    .maybeSingle();
  if (erroCampanha) {
    const semColuna = /agenda_sync/.test(erroCampanha.message);
    return json({ ok: false, erro: semColuna ? 'Falta a coluna agenda_sync: rode supabase/schema_agenda.sql.' : erroCampanha.message }, 500);
  }
  if (!camp) return json({ ok: false, erro: 'Campanha não encontrada.' }, 404);

  // Editar/remover é só do Administrador: os demais só sincronizam a campanha
  // que acabaram de criar (ainda sem evento) e nunca cancelam.
  const { data: admin } = await supabase.rpc('cdl_admin');
  const temEvento = Object.keys(camp.agenda_sync ?? {}).length > 0;
  if (admin !== true && (acao === 'cancelar' || temEvento)) {
    return json({ ok: false, erro: 'Só um Administrador pode alterar ou cancelar a agenda de uma campanha existente.' }, 403);
  }

  let evento: Evento | null = null;
  if (acao === 'sincronizar') {
    try {
      evento = montarEvento(camp);
    } catch (e) {
      return json({ ok: false, erro: (e as Error).message }, 400);
    }
  }
  // Sem participantes não há convite: se já existia evento, ele é cancelado.
  const cancelar = acao === 'cancelar' || !evento || evento.participantes.length === 0;

  // deno-lint-ignore no-explicit-any
  const sync: Record<string, any> = { ...(camp.agenda_sync ?? {}) };
  const provedores: Record<string, string> = {};
  let houveErro = false;

  for (const p of PROVEDORES) {
    const atual = sync[p.chave];
    if (!p.configurado()) {
      if (!cancelar) provedores[p.chave] = 'não configurado';
      continue;
    }
    try {
      if (cancelar) {
        if (atual?.event_id) {
          await p.cancelar(atual.event_id);
          provedores[p.chave] = 'evento cancelado nas agendas';
        }
        delete sync[p.chave];
        continue;
      }
      const ev = evento!;
      let id: string | null = null;
      let status = `convite enviado para ${ev.participantes.length} participante(s)`;
      if (atual?.event_id && atual.formato === ev.formato) {
        if (await p.atualizar(atual.event_id, ev)) {
          id = atual.event_id;
          status = `evento atualizado para ${ev.participantes.length} participante(s)`;
        }
      } else if (atual?.event_id) {
        // Mudou de "dia inteiro" para "com horário" (ou vice-versa): recria.
        await p.cancelar(atual.event_id);
      }
      if (!id) id = await p.criar(ev);
      sync[p.chave] = { event_id: id, formato: ev.formato, sincronizado_em: new Date().toISOString() };
      provedores[p.chave] = status;
    } catch (e) {
      houveErro = true;
      provedores[p.chave] = 'erro: ' + (e as Error).message;
      console.error(`[sincronizar-agenda] ${p.chave}:`, e);
    }
  }

  if (!PROVEDORES.some((p) => p.configurado()) && !cancelar) {
    return json({ ok: false, erro: 'Nenhuma agenda configurada no Supabase (secrets do Outlook ou do Google).', provedores }, 503);
  }

  // UPDATE direto em `campanhas` é só do Administrador (RLS); a função do banco
  // deixa quem criou a campanha gravar os ids do evento (supabase/somente_admin_edita.sql).
  const { error: erroGravar } = await supabase.rpc('cdl_gravar_agenda_sync', { p_campanha: campanhaId, p_sync: sync });
  if (erroGravar) console.error('[sincronizar-agenda] gravar agenda_sync:', erroGravar);

  return json({
    ok: !houveErro,
    provedores,
    erro: houveErro ? Object.values(provedores).filter((v) => v.startsWith('erro')).join(' | ') : undefined,
  });
});
