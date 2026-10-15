// CDLoad · Edge Function "descadastro-leads"
//
// "Não quero mais receber" do e-mail informativo das Campanhas (leads). Pública: publique com
// "Verify JWT" DESLIGADO (o lead não tem login). Cada link traz o e-mail (base64url), a campanha e uma
// assinatura HMAC gerada pela função sincronizar-agenda — sem a assinatura certa nada acontece, então
// ninguém descadastra o e-mail de outra pessoa.
//
// Entradas (POST):
//   - JSON { e, t, c }  ← página descadastro.html do site (o lead confirma num botão)
//   - "List-Unsubscribe=One-Click" com e/t/c na URL  ← botão "Cancelar inscrição" do Gmail/Outlook (RFC 8058)
// GET não descadastra (antivírus de e-mail abrem os links sozinhos); só orienta a usar a página.
//
// Ao descadastrar: grava em leads_descadastro (service role; supabase/schema_campanhas_leads.sql) — os envios
// seguintes pulam esse e-mail — e avisa a caixa organizadora da Penso por e-mail (SMTP 465, mesmos secrets
// PENSO_SMTP_* da sincronizar-agenda). Chave da assinatura: LEADS_DESCADASTRO_CHAVE ou, sem ela, a
// SUPABASE_SERVICE_ROLE_KEY (a mesma usada na sincronizar-agenda).

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const env = (k: string) => (Deno.env.get(k) ?? '').trim();
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const UUID_RE = /^[0-9a-f-]{36}$/i;

const b64url = (bytes: Uint8Array) => {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const deB64url = (s: string) => {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return new TextDecoder().decode(Uint8Array.from(b, (c) => c.charCodeAt(0)));
};

async function assinatura(email: string): Promise<string> {
  const chave = env('LEADS_DESCADASTRO_CHAVE') || env('SUPABASE_SERVICE_ROLE_KEY');
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(email.toLowerCase())))).slice(0, 32);
}
// Comparação em tempo constante.
const iguais = (a: string, b: string) => a.length === b.length && [...a].reduce((d, ch, i) => d | (ch.charCodeAt(0) ^ b.charCodeAt(i)), 0) === 0;

// ---- Aviso à caixa organizadora (SMTP mínimo, SSL 465) ----
const b64 = (t: string) => {
  const bytes = new TextEncoder().encode(t);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return (btoa(bin).match(/.{1,76}/g) ?? []).join('\r\n');
};
const utf8 = (s: string) => `=?UTF-8?B?${b64(s).replace(/\r\n/g, '')}?=`;

async function avisarOrganizador(email: string, campanha: string) {
  const host = env('PENSO_SMTP_HOST'), usuario = env('PENSO_SMTP_USUARIO'), senha = env('PENSO_SMTP_SENHA');
  const remetente = env('PENSO_REMETENTE') || usuario;
  if (!host || !usuario || !senha) return 'SMTP da Penso não configurado';
  const quando = new Date().toLocaleString('pt-BR', { timeZone: 'America/Cuiaba' });
  const corpo = `O lead ${email} pediu para não receber mais os e-mails informativos.\n\n` +
    `Campanha: ${campanha || '—'}\nData/hora: ${quando} (Cuiabá)\n\n` +
    'Ele foi incluído na lista de descadastrados (tabela leads_descadastro) e os próximos envios do CDLoad pulam este endereço.';
  const msg = [
    `From: ${utf8('CDLoad · Campanhas')} <${remetente}>`, `To: <${remetente}>`,
    `Subject: ${utf8(`Descadastro de lead: ${email}`)}`, `Date: ${new Date().toUTCString().replace('GMT', '+0000')}`,
    `Message-ID: <${crypto.randomUUID()}@${remetente.split('@')[1] || 'cdload'}>`, 'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: base64', '', b64(corpo), '',
  ].join('\r\n');

  const conn = await Deno.connectTls({ hostname: host, port: Number(env('PENSO_SMTP_PORTA') || 465) });
  const enc = new TextEncoder(), dec = new TextDecoder();
  const prazo = setTimeout(() => { try { conn.close(); } catch { /* fechada */ } }, 25_000);
  let buf = '';
  const esc = async (s: string) => { const d = enc.encode(s); for (let i = 0; i < d.length;) i += await conn.write(d.subarray(i)); };
  const resp = async () => {
    for (;;) {
      let i: number;
      while ((i = buf.indexOf('\r\n')) < 0) {
        const p = new Uint8Array(4096), n = await conn.read(p);
        if (n === null) throw new Error('conexão encerrada');
        buf += dec.decode(p.subarray(0, n), { stream: true });
      }
      const l = buf.slice(0, i); buf = buf.slice(i + 2);
      if (l.length < 4 || l[3] === ' ') return Number(l.slice(0, 3));
    }
  };
  const cmd = async (linha: string | null, ok: number[], rot: string) => {
    if (linha !== null) await esc(linha + '\r\n');
    const c = await resp();
    if (!ok.includes(c)) throw new Error(`${rot}: ${c}`);
  };
  try {
    await cmd(null, [220], 'conexão');
    await cmd('EHLO cdload', [250], 'EHLO');
    await cmd(`AUTH PLAIN ${b64(`\u0000${usuario}\u0000${senha}`).replace(/\r\n/g, '')}`, [235], 'login');
    await cmd(`MAIL FROM:<${remetente}>`, [250], 'remetente');
    await cmd(`RCPT TO:<${remetente}>`, [250, 251], 'destinatário');
    await cmd('DATA', [354], 'DATA');
    await esc(msg.replace(/\r\n\./g, '\r\n..') + '\r\n.\r\n');
    await cmd(null, [250], 'envio');
    await esc('QUIT\r\n');
    return null;
  } finally {
    clearTimeout(prazo);
    try { conn.close(); } catch { /* fechada */ }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  if (req.method === 'GET') {
    return new Response('Para deixar de receber os e-mails, use o link "Não quero mais receber" no rodapé da mensagem.', {
      headers: { ...CORS, 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
  if (req.method !== 'POST') return json({ ok: false, erro: 'Método não permitido.' }, 405);

  // Página (JSON) ou um clique do cliente de e-mail (parâmetros na URL, corpo List-Unsubscribe=One-Click).
  let e = url.searchParams.get('e') ?? '', t = url.searchParams.get('t') ?? '', c = url.searchParams.get('c') ?? '';
  if ((req.headers.get('content-type') ?? '').includes('application/json')) {
    try {
      const b = await req.json();
      e = String(b?.e ?? e); t = String(b?.t ?? t); c = String(b?.c ?? c);
    } catch { /* corpo inválido: segue com a URL */ }
  }
  let email = '';
  try { email = deB64url(e).trim().toLowerCase(); } catch { /* inválido */ }
  if (!EMAIL_RE.test(email) || !t || !iguais(t, await assinatura(email))) {
    return json({ ok: false, erro: 'Link de descadastro inválido ou incompleto.' }, 400);
  }

  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  const { data: existente } = await db.from('leads_descadastro').select('email').eq('email', email).maybeSingle();
  if (existente) return json({ ok: true, email, ja_descadastrado: true });

  let campanhaNome = '';
  if (UUID_RE.test(c)) {
    const { data } = await db.from('campanhas').select('nome_campanha').eq('id', c).maybeSingle();
    campanhaNome = data?.nome_campanha ?? '';
  }
  const { error } = await db.from('leads_descadastro').insert({ email, campanha_id: UUID_RE.test(c) ? c : null, campanha_nome: campanhaNome || null });
  if (error && !/duplicate key/i.test(error.message)) {
    console.error('[descadastro-leads] gravar:', error);
    return json({ ok: false, erro: 'Não foi possível registrar o descadastro agora. Tente de novo em instantes.' }, 500);
  }

  // Aviso à caixa organizadora: falha aqui não desfaz o descadastro.
  try {
    const erro = await avisarOrganizador(email, campanhaNome);
    if (erro) console.error('[descadastro-leads] aviso:', erro);
  } catch (err) {
    console.error('[descadastro-leads] aviso:', err);
  }
  return json({ ok: true, email });
});
