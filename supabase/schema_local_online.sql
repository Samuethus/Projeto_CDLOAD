-- ============================================================================
-- CDLoad · Campanhas › Local "Online" (sala "Virtual")
--
-- Rode em Supabase > SQL Editor (idempotente). Cadastra o local "Online" com a
-- sala "Virtual" na tabela `local` (campos "Local" e "Sala Reservada" da Etapa 1
-- do wizard de Campanhas). Se o local já existir, garante a sala "Virtual" sem
-- apagar as outras salas dele.
-- ============================================================================

insert into public.local (nome, salas)
values ('Online', '["Virtual"]'::jsonb)
on conflict (nome) do update
  set salas = case
                when public.local.salas @> '["Virtual"]'::jsonb then public.local.salas
                else public.local.salas || '["Virtual"]'::jsonb
              end,
      updated_at = now();
