// CDLoad · Edge Function "whatsapp-api" (esqueleto — Etapa 1)
//
// Único ponto de contato entre a plataforma e a UAZAPI. O navegador envia
// { acao, ... } com o login do usuário; a função valida o login e a seção
// "whatsapp" e roteia por `acao`.
//
// Secrets: UAZAPI_URL, UAZAPI_ADMIN_TOKEN, WHATSAPP_WEBHOOK_SEGREDO (este é usado pelo whatsapp-webhook).
// Ações atuais:
//   ping           → confirma login + permissão e informa se os secrets existem
//   uazapi_teste   → (só Administrador) GET /instance/all com o admintoken; fecha a Etapa 0
// Publicar: npx supabase functions deploy whatsapp-api

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const env = (k: string) => (Deno.env.get(k) ?? '').trim();

// deno-lint-ignore no-explicit-any
type Contexto = { supabase: any; entrada: Record<string, any> };
type Acao = (ctx: Contexto) => Promise<Response>;

// Escrita no banco e leitura do token: só aqui, com service role (o navegador nunca vê o token).
const admin = () =>
  createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });

// deno-lint-ignore no-explicit-any
async function uazapi(caminho: string, opcoes: { metodo?: string; token?: string; adminToken?: boolean; corpo?: unknown } = {}): Promise<any> {
  const base = env('UAZAPI_URL').replace(/\/+$/, '');
  if (!base || !env('UAZAPI_ADMIN_TOKEN')) throw new Error('Faltam os secrets UAZAPI_URL / UAZAPI_ADMIN_TOKEN.');
  const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (opcoes.adminToken) headers.admintoken = env('UAZAPI_ADMIN_TOKEN');
  if (opcoes.token) headers.token = opcoes.token;
  const res = await fetch(base + caminho, {
    method: opcoes.metodo ?? 'GET',
    headers,
    body: opcoes.corpo === undefined ? undefined : JSON.stringify(opcoes.corpo),
  });
  const corpo = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`UAZAPI ${caminho} respondeu ${res.status}${corpo?.error || corpo?.message ? ': ' + (corpo.error ?? corpo.message) : ''}`);
  return corpo;
}

// Carrega a instância (dados + token) pelo id. Só o service role lê wa_instancia_tokens.
async function carregarInstancia(id: unknown) {
  const db = admin();
  const { data: inst } = await db.from('wa_instancias').select('*').eq('id', String(id ?? '')).maybeSingle();
  if (!inst) throw new Error('Instância não encontrada.');
  const { data: tk } = await db.from('wa_instancia_tokens').select('token').eq('instancia_id', inst.id).maybeSingle();
  if (!tk?.token) throw new Error('Instância sem token guardado.');
  return { db, inst, token: tk.token as string };
}

// UAZAPI devolve o estado em `instance.status` (connected | connecting | disconnected) ou em `status`.
// deno-lint-ignore no-explicit-any
function interpretarStatus(r: any) {
  const inst = r?.instance ?? r ?? {};
  const bruto = String(inst.status ?? r?.status?.status ?? (r?.status?.connected ? 'connected' : '')).toLowerCase();
  const conectada = bruto === 'connected' || r?.status?.connected === true;
  const qr = inst.qrcode ?? r?.qrcode ?? '';
  const status = conectada ? 'conectada' : qr ? 'aguardando_qr' : bruto === 'connecting' ? 'conectando' : 'desconectada';
  const telefone = String(inst.owner ?? inst.phone ?? r?.status?.jid ?? '').replace(/[:@].*$/, '').replace(/\D/g, '') || null;
  return { status, telefone, qrcode: qr || null, paircode: (inst.paircode ?? r?.paircode ?? null) as string | null };
}

const exigirAdmin = async (supabase: Contexto['supabase']) => {
  const { data } = await supabase.rpc('cdl_admin');
  return data === true;
};

const acoes: Record<string, Acao> = {
  ping: () =>
    Promise.resolve(json({
      ok: true,
      secrets: {
        UAZAPI_URL: !!env('UAZAPI_URL'),
        UAZAPI_ADMIN_TOKEN: !!env('UAZAPI_ADMIN_TOKEN'),
        WHATSAPP_WEBHOOK_SEGREDO: !!env('WHATSAPP_WEBHOOK_SEGREDO'),
      },
    })),

  async uazapi_teste({ supabase }) {
    const { data: admin } = await supabase.rpc('cdl_admin');
    if (admin !== true) return json({ ok: false, erro: 'Só o Administrador pode testar a conexão.' }, 403);
    const base = env('UAZAPI_URL').replace(/\/+$/, '');
    if (!base || !env('UAZAPI_ADMIN_TOKEN')) return json({ ok: false, erro: 'Faltam os secrets UAZAPI_URL / UAZAPI_ADMIN_TOKEN.' }, 500);
    try {
      const res = await fetch(`${base}/instance/all`, { headers: { admintoken: env('UAZAPI_ADMIN_TOKEN') } });
      const corpo = await res.json().catch(() => null);
      if (!res.ok) return json({ ok: false, erro: `UAZAPI respondeu ${res.status}.` }, 502);
      return json({ ok: true, instancias: Array.isArray(corpo) ? corpo.length : null });
    } catch (e) {
      return json({ ok: false, erro: `Não foi possível falar com a UAZAPI: ${(e as Error).message}` }, 502);
    }
  },

  // ---------- Etapa 2 · Instâncias ----------

  async instancia_criar({ supabase, entrada }) {
    if (!(await exigirAdmin(supabase))) return json({ ok: false, erro: 'Só o Administrador cria instâncias.' }, 403);
    const nome = String(entrada.nome ?? '').trim().slice(0, 60);
    if (nome.length < 2) return json({ ok: false, erro: 'Informe um nome para a instância.' }, 400);
    const slug = nome.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'numero';
    const uazapiNome = `cdload-${slug}-${crypto.randomUUID().slice(0, 6)}`;

    const r = await uazapi('/instance/create', { metodo: 'POST', adminToken: true, corpo: { name: uazapiNome, systemName: 'cdload' } });
    const token = r?.token ?? r?.instance?.token;
    if (!token) throw new Error('A UAZAPI não devolveu o token da instância.');

    const { data: user } = await supabase.auth.getUser();
    const db = admin();
    const { data: inst, error } = await db.from('wa_instancias')
      .insert({ nome, uazapi_nome: uazapiNome, status: 'desconectada', ultimo_status_em: new Date().toISOString(), criado_por: user?.user?.id ?? null })
      .select('id').single();
    if (error) {
      // Não deixa instância órfã na UAZAPI se o banco recusou.
      await uazapi('/instance', { metodo: 'DELETE', token }).catch(() => {});
      throw new Error(error.message);
    }
    const { error: erroToken } = await db.from('wa_instancia_tokens').insert({ instancia_id: inst.id, token });
    if (erroToken) {
      await uazapi('/instance', { metodo: 'DELETE', token }).catch(() => {});
      await db.from('wa_instancias').delete().eq('id', inst.id);
      throw new Error(erroToken.message);
    }
    return json({ ok: true, id: inst.id });
  },

  // Sem `telefone` gera QR code; com `telefone` gera código de pareamento.
  async instancia_conectar({ entrada }) {
    const { db, inst, token } = await carregarInstancia(entrada.id);
    const telefone = String(entrada.telefone ?? '').replace(/\D/g, '');
    const r = await uazapi('/instance/connect', { metodo: 'POST', token, corpo: telefone ? { phone: telefone } : {} });
    const s = interpretarStatus(r);
    const status = s.status === 'conectada' ? 'conectada' : (s.qrcode || s.paircode) ? 'aguardando_qr' : 'conectando';
    await db.from('wa_instancias').update({ status, telefone: s.telefone ?? inst.telefone, ultimo_status_em: new Date().toISOString() }).eq('id', inst.id);
    return json({ ok: true, status, qrcode: s.qrcode, paircode: s.paircode });
  },

  // Consulta a UAZAPI e atualiza o banco (o cartão muda sozinho pelo Realtime).
  async instancia_status({ entrada }) {
    const { db, inst, token } = await carregarInstancia(entrada.id);
    const r = await uazapi('/instance/status', { token });
    const s = interpretarStatus(r);
    await db.from('wa_instancias').update({ status: s.status, telefone: s.telefone ?? inst.telefone, ultimo_status_em: new Date().toISOString() }).eq('id', inst.id);
    return json({ ok: true, status: s.status, qrcode: s.qrcode, paircode: s.paircode });
  },

  async instancia_desconectar({ entrada }) {
    const { db, inst, token } = await carregarInstancia(entrada.id);
    await uazapi('/instance/disconnect', { metodo: 'POST', token });
    await db.from('wa_instancias').update({ status: 'desconectada', ultimo_status_em: new Date().toISOString() }).eq('id', inst.id);
    return json({ ok: true });
  },

  async instancia_excluir({ supabase, entrada }) {
    if (!(await exigirAdmin(supabase))) return json({ ok: false, erro: 'Só o Administrador exclui instâncias.' }, 403);
    const { db, inst, token } = await carregarInstancia(entrada.id);
    await uazapi('/instance', { metodo: 'DELETE', token });
    await db.from('wa_instancias').delete().eq('id', inst.id);  // o token sai junto (on delete cascade)
    return json({ ok: true });
  },
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, erro: 'Método não permitido.' }, 405);

  // Usa o login de quem chamou; sem login válido o RPC recusa.
  const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  });

  const { data: permitido, error } = await supabase.rpc('cdl_secao', { chave: 'whatsapp' });
  if (error || permitido !== true) return json({ ok: false, erro: 'Sem permissão para a seção WhatsApp.' }, 403);

  // deno-lint-ignore no-explicit-any
  let entrada: Record<string, any>;
  try {
    entrada = await req.json();
  } catch {
    return json({ ok: false, erro: 'Corpo da requisição inválido.' }, 400);
  }

  const acao = acoes[String(entrada?.acao ?? '')];
  if (!acao) return json({ ok: false, erro: 'Ação desconhecida.' }, 400);
  try {
    return await acao({ supabase, entrada });
  } catch (e) {
    return json({ ok: false, erro: (e as Error).message }, 500);
  }
});
