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
