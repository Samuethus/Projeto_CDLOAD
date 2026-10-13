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
//   instancia_sincronizar · instancia_registrar · instancia_conectar · instancia_status · instancia_desconectar
//   template_salvar · template_excluir · template_teste            (Etapa 4)
//   lista_importar · optout_adicionar                              (Etapa 5)
//   campanha_criar · campanha_controlar · campanha_atualizar       (Etapa 6)
// Publicar: Supabase > Edge Functions > whatsapp-api > Code, colar este arquivo e Deploy
// (passo a passo em whatsapp/LEIA-ME.md).

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

// Telefone em E.164 sem "+": 55 + DDD + número. Aceita com ou sem 55, com máscara.
function normalizarTelefone(v: unknown): string | null {
  let d = String(v ?? '').replace(/\D/g, '').replace(/^0+/, '');
  if (d.length === 10 || d.length === 11) d = '55' + d;
  return /^55\d{10,11}$/.test(d) ? d : null;
}

// Monta o texto final: cabeçalho em negrito + corpo com {{variáveis}} preenchidas.
// Variáveis: {{nome}}, {{primeiro_nome}}, {{telefone}} e qualquer coluna extra da lista importada.
// deno-lint-ignore no-explicit-any
function montarTexto(tpl: any, dados: Record<string, string>): string {
  const nome = String(dados.nome ?? '').trim();
  const valores: Record<string, string> = { ...dados, nome, primeiro_nome: nome.split(/\s+/)[0] ?? '' };
  const preencher = (s: string) => s.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, k) => valores[String(k).toLowerCase()] ?? '');
  const corpo = preencher(String(tpl.corpo ?? ''));
  return tpl.cabecalho ? `*${preencher(String(tpl.cabecalho))}*\n\n${corpo}` : corpo;
}

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

  // As instâncias são criadas no painel da UAZAPI. Aqui elas são importadas (com o token)
  // para wa_instancias / wa_instancia_tokens; os cartões aparecem sozinhos pelo Realtime.
  // No servidor de demonstração (/instance/all desligado) só atualiza as já registradas, pelo token de cada uma.
  async instancia_sincronizar() {
    const db = admin();
    // deno-lint-ignore no-explicit-any
    let lista: any;
    try {
      lista = await uazapi('/instance/all', { adminToken: true });
    } catch {
      const { data: tokens } = await db.from('wa_instancia_tokens').select('instancia_id,token');
      const agora = new Date().toISOString();
      for (const t of tokens ?? []) {
        try {
          const s = interpretarStatus(await uazapi('/instance/status', { token: t.token }));
          const dados: Record<string, unknown> = { status: s.status, ultimo_status_em: agora };
          if (s.telefone) dados.telefone = s.telefone;
          await db.from('wa_instancias').update(dados).eq('id', t.instancia_id);
        } catch { /* instância removida na UAZAPI ou fora do ar: mantém o último status */ }
      }
      return json({ ok: true, modo: 'status', total: (tokens ?? []).length, novas: 0 });
    }
    // deno-lint-ignore no-explicit-any
    const itens: any[] = Array.isArray(lista) ? lista : (lista?.instances ?? []);
    const { data: existentes } = await db.from('wa_instancias').select('id,uazapi_nome');
    const porNome = new Map<string, string>((existentes ?? []).map((i: { id: string; uazapi_nome: string }) => [i.uazapi_nome, i.id]));
    const agora = new Date().toISOString();
    let novas = 0;
    for (const it of itens) {
      const nomeUazapi = String(it?.name ?? it?.instanceName ?? '').trim();
      const token = String(it?.token ?? '').trim();
      if (!nomeUazapi || !token) continue;
      const s = interpretarStatus(it);
      let id = porNome.get(nomeUazapi);
      if (id) {
        await db.from('wa_instancias').update({ status: s.status, telefone: s.telefone, ultimo_status_em: agora }).eq('id', id);
      } else {
        const { data: nova, error } = await db.from('wa_instancias')
          .insert({ nome: String(it?.profileName || nomeUazapi), uazapi_nome: nomeUazapi, telefone: s.telefone, status: s.status, ultimo_status_em: agora })
          .select('id').single();
        if (error) throw new Error(error.message);
        id = nova.id as string;
        novas++;
      }
      await db.from('wa_instancia_tokens').upsert({ instancia_id: id, token });
    }
    return json({ ok: true, modo: 'lista', total: itens.length, novas });
  },

  // Registra uma instância pelo token dela (copiado do painel da UAZAPI). Necessário no
  // servidor de demonstração, onde /instance/all está desligado.
  async instancia_registrar({ entrada }) {
    const token = String(entrada.token ?? '').trim();
    if (token.length < 10) return json({ ok: false, erro: 'Cole o token da instância.' }, 400);
    let r;
    try {
      r = await uazapi('/instance/status', { token });
    } catch {
      return json({ ok: false, erro: 'Token não reconhecido pela UAZAPI.' }, 400);
    }
    const nomeUazapi = String(r?.instance?.name ?? r?.name ?? '').trim() || `instancia-${token.slice(0, 6)}`;
    const s = interpretarStatus(r);
    const db = admin();
    const { data: inst, error } = await db.from('wa_instancias')
      .upsert({
        nome: String(entrada.nome ?? '').trim() || String(r?.instance?.profileName || nomeUazapi),
        uazapi_nome: nomeUazapi, telefone: s.telefone, status: s.status, ultimo_status_em: new Date().toISOString(),
      }, { onConflict: 'uazapi_nome' })
      .select('id').single();
    if (error) throw new Error(error.message);
    const { error: erroToken } = await db.from('wa_instancia_tokens').upsert({ instancia_id: inst.id, token });
    if (erroToken) throw new Error(erroToken.message);
    return json({ ok: true, id: inst.id, status: s.status });
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

  // ---------- Etapa 4 · Templates ----------

  async template_salvar({ supabase, entrada }) {
    const nome = String(entrada.nome ?? '').trim().slice(0, 80);
    const corpo = String(entrada.corpo ?? '').trim();
    if (!nome) return json({ ok: false, erro: 'Informe o nome do template.' }, 400);
    if (!corpo) return json({ ok: false, erro: 'Escreva o corpo da mensagem.' }, 400);
    if (corpo.length > 4096) return json({ ok: false, erro: 'A mensagem passa de 4096 caracteres.' }, 400);
    const dados = {
      nome, corpo, tipo: 'texto',
      categoria: String(entrada.categoria ?? 'Marketing').slice(0, 40),
      cabecalho: String(entrada.cabecalho ?? '').trim() || null,
      atualizado_em: new Date().toISOString(),
    };
    const db = admin();
    if (entrada.id) {
      const { error } = await db.from('wa_templates').update(dados).eq('id', String(entrada.id));
      if (error) throw new Error(error.message);
      return json({ ok: true, id: entrada.id });
    }
    const { data: user } = await supabase.auth.getUser();
    const { data, error } = await db.from('wa_templates').insert({ ...dados, criado_por: user?.user?.id ?? null }).select('id').single();
    if (error) throw new Error(error.message);
    return json({ ok: true, id: data.id });
  },

  async template_excluir({ entrada }) {
    const { error } = await admin().from('wa_templates').delete().eq('id', String(entrada.id ?? ''));
    if (error) throw new Error(error.message);
    return json({ ok: true });
  },

  // Envia o template, com dados de exemplo, para um número informado.
  async template_teste({ entrada }) {
    const { data: tpl } = await admin().from('wa_templates').select('*').eq('id', String(entrada.id ?? '')).maybeSingle();
    if (!tpl) return json({ ok: false, erro: 'Template não encontrado.' }, 404);
    const telefone = normalizarTelefone(entrada.telefone);
    if (!telefone) return json({ ok: false, erro: 'Número inválido. Use DDD + número (ex.: 65999990000).' }, 400);
    const { token } = await carregarInstancia(entrada.instancia_id);
    const texto = montarTexto(tpl, { nome: 'Maria Silva', telefone });
    const r = await uazapi('/send/text', { metodo: 'POST', token, corpo: { number: telefone, text: texto } });
    return json({ ok: true, telefone, id: r?.messageid ?? r?.id ?? null });
  },

  // ---------- Etapa 5 · Contatos, listas e opt-out ----------

  // contatos: [{ nome, telefone, ...outros campos (viram variáveis {{campo}}) }]
  async lista_importar({ entrada }) {
    const nome = String(entrada.nome ?? '').trim().slice(0, 80);
    if (!nome) return json({ ok: false, erro: 'Dê um nome para a lista.' }, 400);
    const brutos = Array.isArray(entrada.contatos) ? entrada.contatos.slice(0, 5000) : [];
    const porTelefone = new Map<string, { nome: string | null; telefone: string; campos: Record<string, string>; origem: string }>();
    let invalidos = 0;
    for (const c of brutos) {
      const telefone = normalizarTelefone(c?.telefone);
      if (!telefone) { invalidos++; continue; }
      const campos: Record<string, string> = {};
      for (const [k, v] of Object.entries(c ?? {})) {
        if (k !== 'nome' && k !== 'telefone' && v != null && String(v).trim()) campos[k.toLowerCase()] = String(v).trim();
      }
      porTelefone.set(telefone, { nome: String(c?.nome ?? '').trim() || null, telefone, campos, origem: `lista: ${nome}` });
    }
    if (!porTelefone.size) return json({ ok: false, erro: 'Nenhum telefone válido na lista.' }, 400);

    const db = admin();
    const { data: lista, error } = await db.from('wa_listas').insert({ nome }).select('id').single();
    if (error) throw new Error(error.message);
    const contatos = [...porTelefone.values()];
    for (let i = 0; i < contatos.length; i += 500) {
      const { data: salvos, error: e1 } = await db.from('wa_contatos')
        .upsert(contatos.slice(i, i + 500), { onConflict: 'telefone' }).select('id');
      if (e1) throw new Error(e1.message);
      const { error: e2 } = await db.from('wa_listas_contatos')
        .upsert((salvos ?? []).map((s: { id: string }) => ({ lista_id: lista.id, contato_id: s.id })));
      if (e2) throw new Error(e2.message);
    }
    return json({ ok: true, id: lista.id, total: contatos.length, invalidos, duplicados: brutos.length - invalidos - contatos.length });
  },

  async optout_adicionar({ entrada }) {
    const telefone = normalizarTelefone(entrada.telefone);
    if (!telefone) return json({ ok: false, erro: 'Número inválido.' }, 400);
    const { error } = await admin().from('wa_optout').upsert({ telefone, motivo: String(entrada.motivo ?? 'manual').slice(0, 200) });
    if (error) throw new Error(error.message);
    return json({ ok: true, telefone });
  },

  // ---------- Etapa 6 · Disparos ----------

  // Cria a campanha, gera um envio por contato (sem opt-out, sem duplicados, só quem tem
  // WhatsApp) e entrega a fila para a UAZAPI (/sender/advanced), já com agendamento e intervalo.
  async campanha_criar({ supabase, entrada }) {
    const nome = String(entrada.nome ?? '').trim().slice(0, 120);
    if (!nome) return json({ ok: false, erro: 'Dê um nome ao disparo.' }, 400);
    const delayMin = Math.max(3, Math.floor(Number(entrada.delay_min) || 10));
    const delayMax = Math.max(delayMin, Math.floor(Number(entrada.delay_max) || 30));
    const agendadaPara = entrada.agendada_para ? new Date(String(entrada.agendada_para)) : null;
    if (agendadaPara && (isNaN(agendadaPara.getTime()) || agendadaPara.getTime() < Date.now() - 60_000)) {
      return json({ ok: false, erro: 'A data de agendamento já passou.' }, 400);
    }

    const { inst, token } = await carregarInstancia(entrada.instancia_id);
    if (inst.status !== 'conectada') return json({ ok: false, erro: 'A instância escolhida não está conectada.' }, 400);
    const db = admin();
    const { data: tpl } = await db.from('wa_templates').select('*').eq('id', String(entrada.template_id ?? '')).maybeSingle();
    if (!tpl) return json({ ok: false, erro: 'Template não encontrado.' }, 400);
    const { data: vinculos, error: eLista } = await db.from('wa_listas_contatos')
      .select('wa_contatos(id,nome,telefone,campos)').eq('lista_id', String(entrada.lista_id ?? ''));
    if (eLista) throw new Error(eLista.message);
    // deno-lint-ignore no-explicit-any
    const contatos: any[] = (vinculos ?? []).map((v: any) => v.wa_contatos).filter(Boolean);
    if (!contatos.length) return json({ ok: false, erro: 'A lista está vazia.' }, 400);

    const { data: saidas } = await db.from('wa_optout').select('telefone');
    const bloqueados = new Set((saidas ?? []).map((o: { telefone: string }) => o.telefone));
    const emOptout = contatos.filter((c) => bloqueados.has(c.telefone)).length;
    const vistos = new Set<string>();
    const fila = contatos.filter((c) => !bloqueados.has(c.telefone) && !vistos.has(c.telefone) && vistos.add(c.telefone));
    if (!fila.length) return json({ ok: false, erro: 'Todos os contatos da lista estão em opt-out.' }, 400);

    // Quem não tem WhatsApp sai da fila (se a verificação falhar, segue sem ela).
    const semWhatsapp = new Set<string>();
    try {
      for (let i = 0; i < fila.length; i += 50) {
        const numeros = fila.slice(i, i + 50).map((c) => c.telefone);
        const r = await uazapi('/chat/check', { metodo: 'POST', token, corpo: { numbers: numeros } });
        // deno-lint-ignore no-explicit-any
        for (const item of (Array.isArray(r) ? r : r?.numbers ?? r?.result ?? []) as any[]) {
          const n = String(item?.query ?? item?.number ?? '').replace(/\D/g, '');
          if (n && (item?.isInWhatsapp === false || item?.exists === false)) semWhatsapp.add(n);
        }
      }
    } catch { /* verificação indisponível: a própria UAZAPI marca a falha no envio */ }

    const { data: user } = await supabase.auth.getUser();
    const { data: camp, error: eCamp } = await db.from('wa_campanhas').insert({
      nome, instancia_id: inst.id, template_id: tpl.id, lista_id: String(entrada.lista_id),
      status: 'rascunho', agendada_para: agendadaPara?.toISOString() ?? null,
      delay_min: delayMin, delay_max: delayMax, total: fila.length, criado_por: user?.user?.id ?? null,
    }).select('id').single();
    if (eCamp) throw new Error(eCamp.message);

    const envios = fila.map((c) => ({
      campanha_id: camp.id, contato_id: c.id, telefone: c.telefone,
      texto_final: montarTexto(tpl, { ...(c.campos ?? {}), nome: c.nome ?? '', telefone: c.telefone }),
      status: semWhatsapp.has(c.telefone) ? 'falhou' : 'fila',
      erro: semWhatsapp.has(c.telefone) ? 'Número sem WhatsApp' : null,
    }));
    for (let i = 0; i < envios.length; i += 500) {
      const { error } = await db.from('wa_envios').insert(envios.slice(i, i + 500));
      if (error) throw new Error(error.message);
    }
    const validos = envios.filter((e) => e.status === 'fila');
    if (!validos.length) {
      await db.from('wa_campanhas').update({ status: 'concluida', erro: 'Nenhum número com WhatsApp.' }).eq('id', camp.id);
      return json({ ok: true, id: camp.id, enviados: 0, aviso: 'Nenhum número da lista tem WhatsApp.' });
    }

    try {
      const r = await uazapi('/sender/advanced', {
        metodo: 'POST', token,
        corpo: {
          delayMin, delayMax, info: `cdload: ${nome}`,
          ...(agendadaPara ? { scheduled_for: agendadaPara.getTime() } : {}),
          messages: validos.map((e) => ({ number: e.telefone, type: 'text', text: e.texto_final })),
        },
      });
      await db.from('wa_eventos').insert({ tipo: 'api:sender/advanced', payload: r });
      const folderId = String(r?.folder_id ?? r?.folderId ?? r?.folder?.id ?? '');
      await db.from('wa_campanhas').update({
        status: agendadaPara ? 'agendada' : 'enviando', uazapi_folder_id: folderId || null, erro: null, atualizado_em: new Date().toISOString(),
      }).eq('id', camp.id);
      return json({ ok: true, id: camp.id, enviados: validos.length, sem_whatsapp: semWhatsapp.size, optout: emOptout });
    } catch (e) {
      await db.from('wa_campanhas').update({ erro: (e as Error).message, atualizado_em: new Date().toISOString() }).eq('id', camp.id);
      throw e;
    }
  },

  // acao: pausar | retomar | enviar_agora | cancelar  →  /sender/edit
  async campanha_controlar({ entrada }) {
    const mapa: Record<string, [string, string]> = {
      pausar: ['stop', 'pausada'], retomar: ['continue', 'enviando'], enviar_agora: ['send_now', 'enviando'], cancelar: ['delete', 'cancelada'],
    };
    const par = mapa[String(entrada.acao ?? '')];
    if (!par) return json({ ok: false, erro: 'Ação inválida.' }, 400);
    const db = admin();
    const { data: camp } = await db.from('wa_campanhas').select('id,instancia_id,uazapi_folder_id').eq('id', String(entrada.id ?? '')).maybeSingle();
    if (!camp?.uazapi_folder_id) return json({ ok: false, erro: 'Disparo sem fila na UAZAPI.' }, 400);
    const { token } = await carregarInstancia(camp.instancia_id);
    await uazapi('/sender/edit', { metodo: 'POST', token, corpo: { folder_id: camp.uazapi_folder_id, action: par[0] } });
    await db.from('wa_campanhas').update({ status: par[1], atualizado_em: new Date().toISOString() }).eq('id', camp.id);
    if (par[1] === 'cancelada') await db.from('wa_envios').update({ status: 'falhou', erro: 'Cancelado' }).eq('campanha_id', camp.id).eq('status', 'fila');
    return json({ ok: true });
  },

  // Confere na UAZAPI o status de cada mensagem da campanha (enquanto o webhook da Etapa 3 não existe).
  async campanha_atualizar({ entrada }) {
    const db = admin();
    const { data: camp } = await db.from('wa_campanhas').select('id,instancia_id,uazapi_folder_id,status').eq('id', String(entrada.id ?? '')).maybeSingle();
    if (!camp?.uazapi_folder_id) return json({ ok: false, erro: 'Disparo sem fila na UAZAPI.' }, 400);
    const { token } = await carregarInstancia(camp.instancia_id);
    const atualizacoes = new Map<string, { status: string; erro: string | null; msgId: string | null }>();
    for (let pagina = 1; pagina <= 20; pagina++) {
      const r = await uazapi('/sender/listmessages', { metodo: 'POST', token, corpo: { folder_id: camp.uazapi_folder_id, page: pagina, pageSize: 500 } });
      // deno-lint-ignore no-explicit-any
      const msgs: any[] = Array.isArray(r) ? r : (r?.messages ?? r?.data ?? []);
      if (pagina === 1) await db.from('wa_eventos').insert({ tipo: 'api:sender/listmessages', payload: Array.isArray(r) ? { messages: r.slice(0, 5) } : { ...r, messages: msgs.slice(0, 5) } });
      for (const m of msgs) {
        const tel = String(m?.number ?? m?.chatid ?? m?.chatId ?? '').replace(/[:@].*$/, '').replace(/\D/g, '');
        if (!tel) continue;
        const bruto = String(m?.status ?? m?.messageStatus ?? '').toLowerCase();
        const status = /fail|error|erro/.test(bruto) ? 'falhou'
          : /read|lid|played/.test(bruto) ? 'lido'
          : /deliver|entreg/.test(bruto) ? 'entregue'
          : /sent|envi|server|success/.test(bruto) ? 'enviado' : 'fila';
        atualizacoes.set(tel, { status, erro: status === 'falhou' ? String(m?.error ?? m?.errorMessage ?? bruto) : null, msgId: m?.messageid ?? m?.messageId ?? null });
      }
      const totalPaginas = Number(r?.pagination?.totalPages ?? r?.totalPages ?? 1);
      if (!msgs.length || pagina >= totalPaginas) break;
    }
    // Só avança o status (fila → enviado → entregue → lido); nunca volta.
    const anteriores: Record<string, string[]> = {
      enviado: ['fila'], falhou: ['fila'], entregue: ['fila', 'enviado'], lido: ['fila', 'enviado', 'entregue'],
    };
    const campoTempo: Record<string, string> = { enviado: 'enviado_em', entregue: 'entregue_em', lido: 'lido_em' };
    const agora = new Date().toISOString();
    for (const [telefone, u] of atualizacoes) {
      if (!anteriores[u.status]) continue;
      await db.from('wa_envios').update({
        status: u.status, erro: u.erro, uazapi_msg_id: u.msgId,
        ...(campoTempo[u.status] ? { [campoTempo[u.status]]: agora } : {}),
      }).eq('campanha_id', camp.id).eq('telefone', telefone).in('status', anteriores[u.status]);
    }
    const { count } = await db.from('wa_envios').select('id', { count: 'exact', head: true }).eq('campanha_id', camp.id).eq('status', 'fila');
    if (count === 0 && ['enviando', 'agendada'].includes(camp.status)) {
      await db.from('wa_campanhas').update({ status: 'concluida', atualizado_em: agora }).eq('id', camp.id);
    }
    return json({ ok: true, conferidos: atualizacoes.size, na_fila: count ?? null });
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
