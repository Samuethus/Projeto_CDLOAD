-- ============================================================================
-- CDLoad · Campanhas → Agenda (Outlook / Google Calendar)
--
-- Rode UMA vez em Supabase > SQL Editor (idempotente).
-- Guarda, por campanha, os ids dos eventos criados pela Edge Function
-- `sincronizar-agenda`, para que editar a campanha ATUALIZE o mesmo evento
-- (em vez de mandar um convite novo) e remover a campanha o CANCELE.
--
-- Não precisa de policy nova: a coluna segue o RLS da tabela `campanhas`
-- (seção "campanhas"), e a função grava com o login de quem salvou.
-- ============================================================================

alter table public.campanhas
  add column if not exists agenda_sync jsonb not null default '{}'::jsonb;

comment on column public.campanhas.agenda_sync is
  'Estado da sincronização com agendas: { outlook: { event_id, sincronizado_em }, google: { event_id, sincronizado_em } }';
