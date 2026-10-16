// @ts-nocheck — roda em Deno (Supabase); o TypeScript do VS Code não conhece Deno nem imports npm:
// CDLoad · Edge Function "sincronizar-agenda"
//
// Cria, atualiza ou cancela o evento de uma campanha na agenda de todos os
// participantes. O evento é criado na agenda de uma conta ORGANIZADORA da
// organização, com os participantes como convidados: o Outlook / Google
// envia o convite e o horário fica bloqueado na agenda de cada pessoa. Com a Penso, o
// evento também é gravado na agenda da conta organizadora (CalDAV do Zimbra).
//
// Provedores (cada um só roda se os secrets dele estiverem definidos):
//   Convite por e-mail (Penso, SMTP): PENSO_SMTP_HOST, PENSO_SMTP_USUARIO, PENSO_SMTP_SENHA,
//                                     [PENSO_SMTP_PORTA=465], [PENSO_REMETENTE], [PENSO_REMETENTE_NOME]
//   Outlook (Microsoft 365, Graph):  MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_ORGANIZADOR_EMAIL
//                                     (só com caixa no Exchange Online — não é o caso da CDL, e-mail na Penso)
//   Google Calendar (Gmail pessoal): GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN, [GOOGLE_CALENDAR_ID]
//   Google Calendar (Workspace):     GOOGLE_SERVICE_ACCOUNT_JSON, GOOGLE_ORGANIZADOR_EMAIL, [GOOGLE_CALENDAR_ID]
// O convite da Penso é um e-mail de reunião padrão (iCalendar): Outlook, Gmail, Apple e afins mostram
// Aceitar/Recusar e o evento entra na agenda da pessoa. A Penso é o canal principal: com ela configurada,
// TODOS os participantes (inclusive Gmail) recebem só por ela e o Google fica desligado (sem convite em
// dobro); eventos antigos do Google são cancelados na próxima sincronização da campanha.
//
// Ação "leads" (Campanhas › Etapa 3 › Leads): e-mail informativo individual para cada lead do CSV importado
// (assunto = Nome da campanha, corpo = Descrição), pela mesma conta dos convites, em nome de "Núcleo de Inteligência - CDL Cuiabá".
// Em lotes (~90 s cada; o app chama de novo até acabar), respeitando o limite diário da conta. Quem já
// recebeu não recebe de novo (requer supabase/schema_campanhas_leads.sql).
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
// inicio_fim: "Desconsiderar" na Etapa 1 — o horário fica bloqueado só no dia de início e no dia de fim
// (2 ocorrências, intervalo = dias entre as datas), sem ocupar os dias do meio.
type Formato = 'dia_inteiro' | 'horario' | 'horario_diario' | 'inicio_fim';
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
// deno-lint-ignore no-explicit-any
type Registro = Record<string, any>;   // o que ficou gravado em campanhas.agenda_sync[chave]
type Provedor = {
  chave: 'outlook' | 'google' | 'penso';
  configurado: () => boolean;
  criar: (ev: Evento) => Promise<string>;
  atualizar: (id: string, ev: Evento, anterior?: Registro) => Promise<boolean>;
  cancelar: (id: string, anterior?: Registro) => Promise<void>;
  // Dados extras guardados junto do event_id (a Penso guarda quem foi convidado, para cancelar depois).
  registro?: (ev: Evento) => Registro;
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

const diasEntre = (de: string, ate: string) => Math.round((Date.parse(ate + 'T00:00:00Z') - Date.parse(de + 'T00:00:00Z')) / 86_400_000);

// Horário padrão do "Desconsiderar" (só início e fim) quando a campanha não traz horário.
const HORA_SO_INICIO_FIM = ['06:00', '07:00'];

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

  const soInicioFim = et.agenda_so_inicio_fim === true;
  let horaInicio = HORA_RE.test(et.horario_inicio ?? '') ? et.horario_inicio : null;
  let horaFim = HORA_RE.test(et.horario_fim ?? '') ? et.horario_fim : null;
  if (soInicioFim && !(horaInicio && horaFim && horaFim > horaInicio)) [horaInicio, horaFim] = HORA_SO_INICIO_FIM;
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
    ['Descrição', et.descricao_email || pm.descricao],
  ].filter(([, v]) => v);

  const descricaoHtml =
    linhas.map(([k, v]) => `<p><b>${escHtml(k)}:</b> ${escHtml(v).replace(/\r?\n/g, '<br>')}</p>`).join('') +
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
    formato: !comHorario ? 'dia_inteiro' : dataFim === dataInicio ? 'horario' : soInicioFim ? 'inicio_fim' : 'horario_diario',
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
  } else if (ev.formato === 'inicio_fim') {
    base.recurrence = {
      pattern: { type: 'daily', interval: diasEntre(ev.dataInicio, ev.dataFim) },
      range: { type: 'numbered', startDate: ev.dataInicio, numberOfOccurrences: 2, recurrenceTimeZone: tz },
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
  } else if (ev.formato === 'inicio_fim') {
    base.recurrence = [`RRULE:FREQ=DAILY;INTERVAL=${diasEntre(ev.dataInicio, ev.dataFim)};COUNT=2`];
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

// ---------------- Convite por e-mail (SMTP da Penso, iCalendar / iMIP) ----------------
// O e-mail sai da conta da Penso com o convite no padrão iCalendar (RFC 5545/6047): o Outlook, o Gmail e
// afins mostram Aceitar/Recusar e, ao aceitar, o evento entra na agenda da pessoa. Editar a campanha manda a
// atualização (mesmo UID, SEQUENCE maior) e quem saiu da lista recebe o cancelamento.
// Porta 465 (SSL direto): o Supabase não deixa as Edge Functions abrirem as portas 25 e 587.
// Canal principal da CDL: com a Penso configurada, o Google fica desligado (ver googleDesligado).

const pensoRemetente = () => env('PENSO_REMETENTE') || env('PENSO_SMTP_USUARIO');
const pensoNome = () => env('PENSO_REMETENTE_NOME') || 'Agenda CDL';
// Nome do remetente nos e-mails aos leads: fixo, para não herdar o "Agenda CDL" dos convites (secret PENSO_REMETENTE_NOME).
// Vai no From (RFC 2047, UTF-8): Gmail, Outlook e Penso mostram este nome.
const LEADS_REMETENTE_NOME = 'Núcleo de Inteligência - CDL Cuiabá';
// A Penso é o canal único: todos os participantes recebem o convite por ela (Penso, Outlook, Gmail…).
const pensoDestinatarios = (ev: Evento) => ev.participantes;

function pensoStatus(ev: Evento, atualizado: boolean): string {
  const n = pensoDestinatarios(ev).length;
  const base = n ? `${atualizado ? 'atualização enviada' : 'convite enviado'} por e-mail para ${n} participante(s)` : 'nenhum convite por e-mail';
  const agenda = pensoAgendaStatus.get(ev);
  return agenda ? `${base} · ${agenda}` : base;
}

// SEQUENCE do iCalendar precisa crescer a cada versão do mesmo evento: segundos desde 2026-01-01.
const sequencia = () => Math.max(1, Math.floor((Date.now() - Date.UTC(2026, 0, 1)) / 1000));

const icsData = (d: string) => d.replace(/-/g, '');
// Cuiabá = UTC−4 o ano todo (sem horário de verão desde 2019): hora local → UTC.
function icsUtc(data: string, hora: string): string {
  const [a, m, d] = data.split('-').map(Number), [h, mi] = hora.split(':').map(Number);
  return new Date(Date.UTC(a, m - 1, d, h + 4, mi)).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}
const icsAgora = () => new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
const icsTexto = (s: string) => s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
const icsCn = (s: string) => s.replace(/["\r\n;:,]/g, ' ').trim();

// Linhas de até 75 bytes (RFC 5545 §3.1), sem partir um caractere UTF-8 ao meio.
function icsDobrar(linha: string): string {
  const enc = new TextEncoder();
  const partes: string[] = [];
  let atual = '', bytes = 0, limite = 75;
  for (const ch of linha) {
    const n = enc.encode(ch).length;
    if (bytes + n > limite) { partes.push(atual); atual = ''; bytes = 0; limite = 74; }
    atual += ch; bytes += n;
  }
  partes.push(atual);
  return partes.join('\r\n ');
}

const textoPuro = (html: string) =>
  html.replace(/<\/p>/gi, '\n').replace(/<[^>]+>/g, '')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&').trim();

// Dados do evento guardados no agenda_sync para conseguir cancelar mais tarde (quando a campanha some).
type EventoResumo = Pick<Evento, 'titulo' | 'local' | 'dataInicio' | 'dataFim' | 'horaInicio' | 'horaFim' | 'formato'> & { descricaoHtml?: string };

function montarIcs(metodo: 'REQUEST' | 'CANCEL', uid: string, ev: EventoResumo, convidados: Participante[]): string {
  const org = pensoRemetente();
  const linhas = [
    'BEGIN:VCALENDAR',
    'PRODID:-//CDL Cuiaba//CDLoad//PT-BR',
    'VERSION:2.0',
    'CALSCALE:GREGORIAN',
    `METHOD:${metodo}`,
    'BEGIN:VEVENT',
    `UID:${uid}`,
    `SEQUENCE:${sequencia()}`,
    `DTSTAMP:${icsAgora()}`,
  ];
  if (ev.formato === 'dia_inteiro') {
    linhas.push(`DTSTART;VALUE=DATE:${icsData(ev.dataInicio)}`, `DTEND;VALUE=DATE:${icsData(addDias(ev.dataFim, 1))}`,
      'X-MICROSOFT-CDO-ALLDAYEVENT:TRUE');
  } else {
    linhas.push(`DTSTART:${icsUtc(ev.dataInicio, ev.horaInicio!)}`, `DTEND:${icsUtc(ev.dataInicio, ev.horaFim!)}`);
    if (ev.formato === 'horario_diario') linhas.push(`RRULE:FREQ=DAILY;UNTIL=${icsData(addDias(ev.dataFim, 1))}T035959Z`);
    else if (ev.formato === 'inicio_fim') linhas.push(`RRULE:FREQ=DAILY;INTERVAL=${diasEntre(ev.dataInicio, ev.dataFim)};COUNT=2`);
  }
  linhas.push(`SUMMARY:${icsTexto(ev.titulo)}`);
  if (ev.local) linhas.push(`LOCATION:${icsTexto(ev.local)}`);
  if (ev.descricaoHtml) {
    linhas.push(`DESCRIPTION:${icsTexto(textoPuro(ev.descricaoHtml))}`,
      `X-ALT-DESC;FMTTYPE=text/html:${icsTexto(`<html><body>${ev.descricaoHtml}</body></html>`)}`);
  }
  linhas.push(`ORGANIZER;CN="${icsCn(pensoNome())}":mailto:${org}`);
  for (const p of convidados) {
    linhas.push(`ATTENDEE;CN="${icsCn(p.nome || p.email)}";CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${p.email}`);
  }
  if (metodo === 'CANCEL') {
    linhas.push('STATUS:CANCELLED', 'TRANSP:TRANSPARENT');
  } else {
    linhas.push('STATUS:CONFIRMED', 'TRANSP:OPAQUE', 'X-MICROSOFT-CDO-BUSYSTATUS:BUSY',
      'BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${icsTexto(ev.titulo)}`, 'TRIGGER:-PT60M', 'END:VALARM');
  }
  linhas.push('END:VEVENT', 'END:VCALENDAR');
  return linhas.map(icsDobrar).join('\r\n') + '\r\n';
}

// Base64 de texto UTF-8, em linhas de 76 caracteres (MIME).
function b64Mime(texto: string): string {
  const bytes = new TextEncoder().encode(texto);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return (btoa(bin).match(/.{1,76}/g) ?? []).join('\r\n');
}
const cabecalhoUtf8 = (s: string) => `=?UTF-8?B?${b64Mime(s).replace(/\r\n/g, '')}?=`;

function montarEmail(metodo: 'REQUEST' | 'CANCEL', assunto: string, ev: EventoResumo, ics: string, para: Participante[]): string {
  const dominio = pensoRemetente().split('@')[1] || 'cdload';
  const fronteira = (n: string) => `cdload-${n}-${crypto.randomUUID()}`;
  const misto = fronteira('misto'), alt = fronteira('alt');
  const periodo = ev.dataInicio === ev.dataFim ? dataBR(ev.dataInicio) : `${dataBR(ev.dataInicio)} a ${dataBR(ev.dataFim)}`;
  const horario = ev.formato === 'dia_inteiro' ? 'dia inteiro' : `${ev.horaInicio} às ${ev.horaFim}${ev.formato === 'horario_diario' ? ' (todos os dias)' : ev.formato === 'inicio_fim' ? ' (só no dia de início e no dia de fim)' : ''}`;
  const intro = metodo === 'CANCEL' ? 'Este evento foi cancelado na plataforma CDLoad.' : 'Você foi convidado(a) para este evento. Aceite o convite para adicioná-lo à sua agenda.';
  const html = `<p>${escHtml(intro)}</p><p><b>${escHtml(ev.titulo)}</b><br>${escHtml(periodo)} · ${escHtml(horario)}${ev.local ? `<br>${escHtml(ev.local)}` : ''}</p>${ev.descricaoHtml ?? ''}`;
  const texto = `${intro}\n\n${ev.titulo}\n${periodo} · ${horario}${ev.local ? `\n${ev.local}` : ''}\n\n${textoPuro(ev.descricaoHtml ?? '')}`;
  const nomeEmail = (p: Participante) => (p.nome ? `${cabecalhoUtf8(p.nome)} <${p.email}>` : `<${p.email}>`);
  return [
    `From: ${cabecalhoUtf8(pensoNome())} <${pensoRemetente()}>`,
    `To: ${para.map(nomeEmail).join(', ')}`,
    `Subject: ${cabecalhoUtf8(assunto)}`,
    `Date: ${new Date().toUTCString().replace('GMT', '+0000')}`,
    `Message-ID: <${crypto.randomUUID()}@${dominio}>`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/mixed; boundary="${misto}"`,
    '',
    `--${misto}`,
    `Content-Type: multipart/alternative; boundary="${alt}"`,
    '',
    `--${alt}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    b64Mime(texto),
    `--${alt}`,
    'Content-Type: text/html; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    b64Mime(html),
    `--${alt}`,
    `Content-Type: text/calendar; charset=UTF-8; method=${metodo}`,
    'Content-Transfer-Encoding: base64',
    '',
    b64Mime(ics),
    `--${alt}--`,
    `--${misto}`,
    `Content-Type: application/ics; name="${metodo === 'CANCEL' ? 'cancelamento' : 'convite'}.ics"`,
    `Content-Disposition: attachment; filename="${metodo === 'CANCEL' ? 'cancelamento' : 'convite'}.ics"`,
    'Content-Transfer-Encoding: base64',
    '',
    b64Mime(ics),
    `--${misto}--`,
    '',
  ].join('\r\n');
}

// Cliente SMTP mínimo: SSL direto (porta 465), AUTH PLAIN. Destinatário recusado (5xx) vira SmtpRecusa.
class SmtpRecusa extends Error {}

async function smtpAbrir() {
  const host = env('PENSO_SMTP_HOST'), porta = Number(env('PENSO_SMTP_PORTA') || 465);
  if (porta === 25 || porta === 587) throw new Error(`a porta ${porta} é bloqueada pelo Supabase; use a 465 (SSL).`);
  const conn = await Deno.connectTls({ hostname: host, port: porta });
  const enc = new TextEncoder(), dec = new TextDecoder();
  // Vigia: 30 s sem resposta do servidor fecha a conexão (rearmado a cada comando).
  let prazo = 0;
  const armar = () => { clearTimeout(prazo); prazo = setTimeout(() => { try { conn.close(); } catch { /* já fechada */ } }, 30_000); };
  let buf = '';
  const escrever = async (s: string) => {
    const dados = enc.encode(s);
    for (let i = 0; i < dados.length;) i += await conn.write(dados.subarray(i));
  };
  const resposta = async (): Promise<{ codigo: number; texto: string }> => {
    const linhas: string[] = [];
    for (;;) {
      let i: number;
      while ((i = buf.indexOf('\r\n')) < 0) {
        const pedaco = new Uint8Array(4096);
        const n = await conn.read(pedaco);
        if (n === null) throw new Error('o servidor encerrou a conexão.');
        buf += dec.decode(pedaco.subarray(0, n), { stream: true });
      }
      const linha = buf.slice(0, i);
      buf = buf.slice(i + 2);
      linhas.push(linha);
      if (linha.length < 4 || linha[3] === ' ') return { codigo: Number(linha.slice(0, 3)), texto: linhas.join(' | ') };
    }
  };
  // `rotulo` evita que a senha (AUTH) apareça em mensagens de erro e logs.
  const comando = async (linha: string | null, aceitos: number[], rotulo: string) => {
    armar();
    if (linha !== null) await escrever(linha + '\r\n');
    const r = await resposta();
    if (!aceitos.includes(r.codigo)) {
      const msg = `${rotulo}: ${r.texto}`;
      throw r.codigo >= 500 && r.codigo < 600 ? new SmtpRecusa(msg) : new Error(msg);
    }
    return r.texto;
  };
  const fechar = async () => {
    try { await escrever('QUIT\r\n'); } catch { /* já fechada */ }
    clearTimeout(prazo);
    try { conn.close(); } catch { /* já fechada */ }
  };
  try {
    await comando(null, [220], 'conexão');
    await comando('EHLO cdload', [250], 'EHLO');
    const credencial = b64Mime(`\u0000${env('PENSO_SMTP_USUARIO')}\u0000${env('PENSO_SMTP_SENHA')}`).replace(/\r\n/g, '');
    try {
      await comando(`AUTH PLAIN ${credencial}`, [235], 'login (usuário/senha da Penso)');
    } catch (e) {
      throw new Error((e as Error).message);   // login recusado não é recusa de destinatário
    }
  } catch (e) {
    await fechar();
    throw e;
  }
  return {
    // Devolve a resposta final do servidor (ex.: "250 2.0.0 Ok: queued as 4AbC123"): o protocolo da fila,
    // que o suporte da Penso usa para rastrear a entrega.
    async enviar(para: string[], mensagem: string): Promise<string> {
      try {
        await comando(`MAIL FROM:<${pensoRemetente()}>`, [250], 'remetente');
        for (const email of para) await comando(`RCPT TO:<${email}>`, [250, 251], `destinatário ${email}`);
        await comando('DATA', [354], 'DATA');
        // Ponto no início da linha é duplicado (RFC 5321 §4.5.2).
        armar();
        await escrever(mensagem.replace(/\r\n\./g, '\r\n..') + '\r\n.\r\n');
        return await comando(null, [250], 'envio');
      } catch (e) {
        // Recusa: limpa a transação para a próxima mensagem da mesma sessão.
        if (e instanceof SmtpRecusa) await comando('RSET', [250], 'RSET').catch(() => {});
        throw e;
      }
    },
    fechar,
  };
}

// Uma mensagem numa conexão própria; devolve a resposta final do servidor (protocolo da fila).
async function smtpEnviar(para: string[], mensagem: string): Promise<string> {
  const sessao = await smtpAbrir();
  try {
    return await sessao.enviar(para, mensagem);
  } finally {
    await sessao.fechar();
  }
}

async function pensoEnviar(metodo: 'REQUEST' | 'CANCEL', assunto: string, uid: string, ev: EventoResumo, para: Participante[]) {
  if (!para.length) return;
  const ics = montarIcs(metodo, uid, ev, para);
  try {
    await smtpEnviar(para.map((p) => p.email), montarEmail(metodo, assunto, ev, ics, para));
  } catch (e) {
    throw new Error(`Penso (SMTP ${env('PENSO_SMTP_HOST')}): ${(e as Error).message}`);
  }
}

// ---- Agenda da própria conta organizadora (CalDAV do Zimbra da Penso) ----
// O SMTP só entrega os convites; para o evento aparecer também na agenda da conta organizadora, ele é gravado
// por CalDAV (mesmo usuário/senha do SMTP) em https://suite.penso.com.br/dav/<conta>/Calendar/<uid>.ics.
// Gravado SEM os convidados como ATTENDEE (ficam listados na descrição): com ATTENDEE o Zimbra poderia
// disparar convites por conta própria, em dobro com os do SMTP. Mesmo UID do convite enviado.
// PENSO_CALDAV_URL troca a pasta (padrão acima) ou desliga a gravação com "off".
// Falha aqui não impede os convites: o status avisa e os e-mails seguem.
// Nome do arquivo = UID completo (como o Zimbra nomeia). Se o Zimbra já tiver um evento com esse UID em
// outro endereço (412 no-uid-conflict — ex.: a conta organizadora também recebeu o convite), a resposta traz
// o endereço dele: regrava lá e guarda em agenda_sync.penso.agenda_href para editar/remover depois.
const pensoAgendaStatus = new WeakMap<object, string>();
const pensoAgendaHref = new WeakMap<object, string>();

function pensoCalendario(): string | null {
  const conf = env('PENSO_CALDAV_URL');
  if (conf.toLowerCase() === 'off') return null;
  const base = conf || `https://suite.penso.com.br/dav/${encodeURIComponent(env('PENSO_SMTP_USUARIO'))}/Calendar/`;
  return base.endsWith('/') ? base : base + '/';
}
const pensoRecurso = (uid: string, href?: string) =>
  href ? new URL(href, pensoCalendario()!).href : `${pensoCalendario()}${encodeURIComponent(uid)}.ics`;
const pensoAuth = () => 'Basic ' + b64Mime(`${env('PENSO_SMTP_USUARIO')}:${env('PENSO_SMTP_SENHA')}`).replace(/\r\n/g, '');

function montarIcsAgenda(uid: string, ev: Evento, convidados: Participante[]): string {
  const lista = convidados.map((p) => (p.nome ? `${p.nome} <${p.email}>` : p.email)).join(', ');
  const html = ev.descricaoHtml + (lista ? `<p><b>Convidados:</b> ${escHtml(lista)}</p>` : '');
  const ics = montarIcs('REQUEST', uid, { ...ev, descricaoHtml: html }, []);
  // Cópia do organizador: sem METHOD (é um objeto de agenda, não uma mensagem de convite) e sem ORGANIZER.
  return ics.split('\r\n').filter((l) => !/^(METHOD|ORGANIZER)[:;]/.test(l)).join('\r\n');
}

// Grava (PUT) e registra em pensoAgendaStatus/pensoAgendaHref (lidos pelo status e pelo registro do evento).
async function pensoAgendaGravar(uid: string, ev: Evento, convidados: Participante[], href?: string): Promise<void> {
  if (!pensoCalendario()) return;
  const corpo = montarIcsAgenda(uid, ev, convidados);
  const put = (url: string) => fetch(url, {
    method: 'PUT',
    headers: { Authorization: pensoAuth(), 'Content-Type': 'text/calendar; charset=utf-8' },
    body: corpo,
  });
  try {
    let url = pensoRecurso(uid, href);
    let res = await put(url);
    if (res.status === 412) {
      const existente = (await res.text()).match(/<(?:\w+:)?href>\s*([^<\s]+)\s*<\/(?:\w+:)?href>/i)?.[1];
      if (!existente) throw new Error('412 sem o endereço do evento existente');
      url = pensoRecurso(uid, existente);
      res = await put(url);
    }
    if (!res.ok) throw new Error(`${res.status} ${(await res.text()).replace(/\s+/g, ' ').slice(0, 120)}`);
    pensoAgendaHref.set(ev, new URL(url).pathname);
    pensoAgendaStatus.set(ev, 'evento gravado na agenda do organizador');
  } catch (e) {
    if (href) pensoAgendaHref.set(ev, href);
    pensoAgendaStatus.set(ev, `agenda do organizador: erro ${(e as Error).message.slice(0, 120)}`);
  }
}

async function pensoAgendaRemover(uid: string, href?: string): Promise<void> {
  if (!pensoCalendario()) return;
  try {
    const res = await fetch(pensoRecurso(uid, href), { method: 'DELETE', headers: { Authorization: pensoAuth() } });
    if (!res.ok && res.status !== 404) console.error('[sincronizar-agenda] penso caldav delete:', res.status, await res.text());
  } catch (e) {
    console.error('[sincronizar-agenda] penso caldav delete:', e);
  }
}

const resumo = (ev: Evento): EventoResumo => ({
  titulo: ev.titulo, local: ev.local, dataInicio: ev.dataInicio, dataFim: ev.dataFim,
  horaInicio: ev.horaInicio, horaFim: ev.horaFim, formato: ev.formato,
});
// Convidados e dados do evento na última versão enviada (gravados em agenda_sync.penso).
const anteriores = (r?: Registro): Participante[] => (Array.isArray(r?.convidados) ? r!.convidados : []);

const penso: Provedor = {
  chave: 'penso',
  configurado: () => !!(env('PENSO_SMTP_HOST') && env('PENSO_SMTP_USUARIO') && env('PENSO_SMTP_SENHA')),
  registro: (ev) => {
    const href = pensoAgendaHref.get(ev);
    return { convidados: pensoDestinatarios(ev), evento: resumo(ev), ...(href ? { agenda_href: href } : {}) };
  },
  async criar(ev) {
    const uid = `cdload-${crypto.randomUUID()}@${pensoRemetente().split('@')[1] || 'cdload'}`;
    await pensoEnviar('REQUEST', `Convite: ${ev.titulo}`, uid, ev, pensoDestinatarios(ev));
    await pensoAgendaGravar(uid, ev, pensoDestinatarios(ev));
    return uid;
  },
  async atualizar(uid, ev, anterior) {
    const agora = pensoDestinatarios(ev), emails = new Set(agora.map((p) => p.email));
    const sairam = anteriores(anterior).filter((p) => !emails.has(p.email));
    await pensoEnviar('REQUEST', `Atualizado: ${ev.titulo}`, uid, ev, agora);
    await pensoEnviar('CANCEL', `Cancelado: ${ev.titulo}`, uid, ev, sairam);
    // PUT no mesmo endereço: cria (campanha antiga, de antes da gravação na agenda) ou substitui o evento.
    await pensoAgendaGravar(uid, ev, agora, anterior?.agenda_href);
    return true;
  },
  async cancelar(uid, anterior) {
    await pensoAgendaRemover(uid, anterior?.agenda_href);
    const ev = anterior?.evento as EventoResumo | undefined;
    if (!ev) return;   // sem os dados do envio anterior não há como montar o cancelamento
    await pensoEnviar('CANCEL', `Cancelado: ${ev.titulo}`, uid, ev, anteriores(anterior));
  },
};

const PROVEDORES: Provedor[] = [outlook, google, penso];

// ---------------- Leads: e-mail informativo (Campanhas › Etapa 3) ----------------
// Um e-mail individual por lead (ninguém vê o endereço dos outros): assunto = Nome da campanha, corpo = Descrição
// ("{Nome}" no texto vira o nome do lead). Montado como o convite, que chega ao Gmail: mesma conta, com o nome
// "Núcleo de Inteligência - CDL Cuiabá" (LEADS_REMETENTE_NOME), sem rodapé nem cabeçalhos extras, e cada e-mail numa conexão SMTP
// própria. Limite diário da conta da Penso (PENSO_LIMITE_DIARIO, padrão 2000, com 100 de folga para os convites)
// somando as últimas 24 h de todas as campanhas; o excedente fica pendente para um envio posterior. Cada chamada
// envia o que cabe em LEADS_TEMPO_MS; o app chama de novo enquanto houver pendentes. Progresso em agenda_sync.leads,
// gravado a cada e-mail (o app conta em tempo real)
// (supabase/schema_campanhas_leads.sql): quem já recebeu (ou foi recusado pelo servidor) não entra de novo.
const LEADS_TEMPO_MS = 90_000;
const LEADS_POR_CHAMADA = 400;
const LEADS_FOLGA_CONVITES = 100;
const leadsLimiteDiario = () => Number(env('PENSO_LIMITE_DIARIO')) || 2000;

type Lead = { nome: string; email: string };
// deno-lint-ignore no-explicit-any
function leadsDaCampanha(et: any): Lead[] {
  const vistos = new Set<string>(), out: Lead[] = [];
  for (const l of Array.isArray(et?.leads) ? et.leads : []) {
    const email = String(l?.email ?? '').trim().toLowerCase();
    if (!EMAIL_RE.test(email) || vistos.has(email)) continue;
    vistos.add(email);
    out.push({ nome: String(l?.nome ?? '').trim(), email });
  }
  return out;
}

// "{Nome}" → nome do lead (sem nome: some, junto com o espaço antes da pontuação: "Olá, {Nome}!" → "Olá!").
const personalizar = (texto: string, lead: Lead) =>
  texto.replace(/[ \t]*,?[ \t]*\{\s*nome\s*\}/gi, (m) => (lead.nome ? m.replace(/\{\s*nome\s*\}/i, lead.nome) : ''));

// Texto digitado → HTML: parágrafos por linha em branco, <br> por quebra simples.
const textoParaHtml = (t: string) =>
  t.trim().split(/\r?\n\s*\r?\n/).map((par) => `<p>${escHtml(par).replace(/\r?\n/g, '<br>')}</p>`).join('');

function montarEmailLead(assunto: string, corpo: string, lead: Lead): string {
  const dominio = pensoRemetente().split('@')[1] || 'cdload';
  const alt = `cdload-alt-${crypto.randomUUID()}`;
  const texto = personalizar(corpo, lead).trim();
  return [
    `From: ${cabecalhoUtf8(LEADS_REMETENTE_NOME)} <${pensoRemetente()}>`,
    `To: ${lead.nome ? `${cabecalhoUtf8(lead.nome)} <${lead.email}>` : `<${lead.email}>`}`,
    `Subject: ${cabecalhoUtf8(assunto)}`,
    `Date: ${new Date().toUTCString().replace('GMT', '+0000')}`,
    `Message-ID: <${crypto.randomUUID()}@${dominio}>`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/alternative; boundary="${alt}"`,
    '',
    `--${alt}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    b64Mime(texto),
    `--${alt}`,
    'Content-Type: text/html; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    b64Mime(textoParaHtml(texto)),
    `--${alt}--`,
    '',
  ].join('\r\n');
}

type LeadsDeps = {
  gravar: (reg: Registro) => Promise<string | null>;         // erro (texto) ou null
  enviados24h: () => Promise<number | string>;               // total ou erro (texto)
};

// deno-lint-ignore no-explicit-any
async function enviarLeads(camp: any, deps: LeadsDeps) {
  const et = camp.estrutura_tecnica ?? {}, pm = camp.publico_e_midia ?? {};
  const leads = leadsDaCampanha(et);
  const corpo = String(et.descricao_email || pm.descricao || '').trim();
  const assunto = String(camp.nome_campanha ?? '').trim();
  const anterior: Registro = camp.agenda_sync?.leads ?? {};
  const enviados = new Set<string>(Array.isArray(anterior.enviados) ? anterior.enviados : []);
  const falhas: { email: string; erro: string }[] = Array.isArray(anterior.falhas) ? anterior.falhas : [];
  const jaFalhou = new Set(falhas.map((f) => f.email));
  const aEnviar = () => leads.filter((l) => !enviados.has(l.email) && !jaFalhou.has(l.email));
  const resumoLeads = (extra: Registro = {}) => ({
    total: leads.length, enviados: leads.filter((l) => enviados.has(l.email)).length, falhas: falhas.length, pendentes: aEnviar().length, ...extra,
  });
  const msgSql = (erro: string) => (/cdl_|function|função|does not exist/i.test(erro) ? 'rode supabase/schema_campanhas_leads.sql no Supabase.' : erro);

  if (!leads.length) return { ok: true, leads: resumoLeads({ enviados_agora: 0 }) };
  if (!corpo) return { ok: false, erro: 'Preencha a Descrição da Etapa 3: ela é o corpo do e-mail enviado aos leads.' };
  if (!assunto) return { ok: false, erro: 'A campanha não tem nome (assunto do e-mail).' };
  if (!penso.configurado()) return { ok: false, erro: 'O envio aos leads usa a conta da Penso: configure os secrets PENSO_SMTP_* no Supabase.' };
  const pendentes = aEnviar();
  if (!pendentes.length) return { ok: true, leads: resumoLeads({ enviados_agora: 0 }) };

  // Limite diário da conta (todas as campanhas, últimas 24 h).
  const usados = await deps.enviados24h();
  if (typeof usados === 'string') return { ok: false, erro: 'Nenhum e-mail enviado: não foi possível conferir o limite diário: ' + msgSql(usados), leads: resumoLeads({ enviados_agora: 0 }) };
  const restante = leadsLimiteDiario() - LEADS_FOLGA_CONVITES - usados;
  if (restante <= 0) {
    return { ok: true, leads: resumoLeads({ enviados_agora: 0, limite_atingido: true, limite: leadsLimiteDiario(), usados_24h: usados }) };
  }

  // Sem conseguir gravar o controle não envia nada (senão os leads receberiam de novo na próxima vez).
  const msgRegistro = (erro: string, enviou: boolean) =>
    (enviou ? 'E-mails enviados, mas o controle de envio não foi gravado: ' : 'Nenhum e-mail enviado: não foi possível gravar o controle de envio: ') + msgSql(erro);
  const regAtual = (lote?: number) => ({
    enviados: [...enviados], falhas, total: leads.length, atualizado_em: new Date().toISOString(),
    ...(lote ? { lote: { em: new Date().toISOString(), n: lote } } : {}),
  });
  const erroAntes = await deps.gravar(regAtual());
  if (erroAntes) return { ok: false, erro: msgRegistro(erroAntes, false), leads: resumoLeads({ enviados_agora: 0 }) };

  // Um e-mail por conexão, como o convite.
  const inicio = Date.now(), maximo = Math.min(LEADS_POR_CHAMADA, restante);
  let agora = 0, erroConexao: string | null = null;
  for (const lead of pendentes) {
    if (agora >= maximo || Date.now() - inicio > LEADS_TEMPO_MS) break;
    try {
      const resposta = await smtpEnviar([lead.email], montarEmailLead(assunto, corpo, lead));
      console.log(`[sincronizar-agenda] lead ${lead.email} aceito pela Penso: ${resposta}`);
      enviados.add(lead.email);
      agora++;
      // Progresso a cada e-mail (sem o lote, que só entra no fim): o app lê agenda_sync.leads.enviados
      // durante a chamada e mostra a contagem em tempo real. Falha aqui não interrompe; a gravação final vale.
      const erroParcial = await deps.gravar(regAtual());
      if (erroParcial) console.error('[sincronizar-agenda] progresso dos leads:', erroParcial);
    } catch (e) {
      if (!(e instanceof SmtpRecusa)) {
        erroConexao = `Penso (SMTP ${env('PENSO_SMTP_HOST')}): ${(e as Error).message}`;
        console.error('[sincronizar-agenda] leads:', e);
        break;
      }
      falhas.push({ email: lead.email, erro: (e as Error).message.slice(0, 160) });
      jaFalhou.add(lead.email);
    }
  }

  const erroGravar = await deps.gravar(regAtual(agora));
  const limiteAgora = usados + agora >= leadsLimiteDiario() - LEADS_FOLGA_CONVITES && aEnviar().length > 0;
  const resumoFinal = resumoLeads({ enviados_agora: agora, ...(limiteAgora ? { limite_atingido: true, limite: leadsLimiteDiario(), usados_24h: usados + agora } : {}) });
  if (erroGravar) return { ok: false, erro: msgRegistro(erroGravar, agora > 0), leads: resumoFinal };
  if (erroConexao) return { ok: false, erro: erroConexao, leads: resumoFinal };
  return { ok: true, leads: resumoFinal };
}

// A Penso é a ferramenta principal da CDL: com ela configurada, o Google fica desligado e todos (inclusive
// Gmail) recebem só o convite por e-mail da Penso — sem convite em dobro. Sem a Penso, o Google volta a valer.
const googleDesligado = () => penso.configurado();

// Cria/atualiza/cancela o evento em cada provedor ativo e atualiza `sync` (campanhas.agenda_sync) no lugar.
// Campanha antiga com evento no Google: na primeira sincronização com o Google desligado, esse evento é
// cancelado (o Google avisa os convidados e tira da agenda deles) e o registro sai do agenda_sync.
async function sincronizarProvedores(sync: Registro, evento: Evento | null, cancelar: boolean) {
  const provedores: Record<string, string> = {};
  let houveErro = false;

  for (const p of PROVEDORES) {
    const atual = sync[p.chave];
    if (p.chave === 'google' && googleDesligado()) {
      if (!atual?.event_id) { delete sync.google; continue; }
      try {
        if (google.configurado()) {
          await google.cancelar(atual.event_id);
          provedores.google = 'evento antigo do Google cancelado (o convite agora vai só pela Penso)';
        }
        delete sync.google;
      } catch (e) {
        houveErro = true;
        provedores.google = 'erro ao cancelar o evento antigo do Google: ' + (e as Error).message;
        console.error('[sincronizar-agenda] google (desligado):', e);
      }
      continue;
    }
    if (!p.configurado()) {
      if (!cancelar) provedores[p.chave] = 'não configurado';
      continue;
    }
    try {
      if (cancelar) {
        if (atual?.event_id) {
          await p.cancelar(atual.event_id, atual);
          provedores[p.chave] = 'evento cancelado nas agendas';
        }
        delete sync[p.chave];
        continue;
      }
      const ev = evento!;
      let id: string | null = null;
      let status = `convite enviado para ${ev.participantes.length} participante(s)`;
      if (atual?.event_id && atual.formato === ev.formato) {
        if (await p.atualizar(atual.event_id, ev, atual)) {
          id = atual.event_id;
          status = `evento atualizado para ${ev.participantes.length} participante(s)`;
        }
      } else if (atual?.event_id) {
        // Mudou de "dia inteiro" para "com horário" (ou vice-versa): recria.
        await p.cancelar(atual.event_id, atual);
      }
      if (!id) id = await p.criar(ev);
      sync[p.chave] = { ...(p.registro?.(ev) ?? {}), event_id: id, formato: ev.formato, sincronizado_em: new Date().toISOString() };
      provedores[p.chave] = p.chave === 'penso' ? pensoStatus(ev, !!atual?.event_id && id === atual.event_id) : status;
    } catch (e) {
      houveErro = true;
      provedores[p.chave] = 'erro: ' + (e as Error).message;
      console.error(`[sincronizar-agenda] ${p.chave}:`, e);
    }
  }
  return { provedores, houveErro };
}

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
  const acao = entrada?.acao === 'cancelar' ? 'cancelar' : entrada?.acao === 'leads' ? 'leads' : 'sincronizar';
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

  // Leads: quem tem a seção dispara os pendentes (cada lead recebe uma vez só; nada é reenviado).
  if (acao === 'leads') {
    const r = await enviarLeads(camp, {
      gravar: async (reg) => {
        const { error } = await supabase.rpc('cdl_gravar_leads_envio', { p_campanha: campanhaId, p_leads: reg });
        if (!error) return null;
        console.error('[sincronizar-agenda] gravar leads:', error);
        return error.message;
      },
      enviados24h: async () => {
        const { data, error } = await supabase.rpc('cdl_leads_enviados_24h');
        return error ? error.message : Number(data) || 0;
      },
    });
    return json(r, r.ok ? 200 : 500);
  }

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
  const { provedores, houveErro } = await sincronizarProvedores(sync, evento, cancelar);

  if (!PROVEDORES.some((p) => p.configurado()) && !cancelar) {
    return json({ ok: false, erro: 'Nenhuma agenda configurada no Supabase (secrets da Penso, do Outlook ou do Google).', provedores }, 503);
  }

  // UPDATE direto em `campanhas` é só do Administrador (RLS); a função do banco
  // deixa quem criou a campanha gravar os ids do evento (supabase/schema_somente_admin_edita.sql).
  const { error: erroGravar } = await supabase.rpc('cdl_gravar_agenda_sync', { p_campanha: campanhaId, p_sync: sync });
  if (erroGravar) console.error('[sincronizar-agenda] gravar agenda_sync:', erroGravar);

  return json({
    ok: !houveErro,
    provedores,
    erro: houveErro ? Object.values(provedores).filter((v) => v.startsWith('erro')).join(' | ') : undefined,
  });
});
