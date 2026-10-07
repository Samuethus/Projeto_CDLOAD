-- ============================================================================
-- CDLoad · Seção "Disparo" renomeada para "WhatsApp"
--
-- Rode em Supabase > SQL Editor (idempotente).
-- Troca a chave 'disparo' por 'whatsapp' em usuarios.secoes_permitidas.
-- O app já converte a chave antiga ao ler os cadastros; este script só deixa
-- o banco com o nome novo.
-- ============================================================================

update public.usuarios
   set secoes_permitidas = (
         select coalesce(jsonb_agg(distinct case when s = 'disparo' then 'whatsapp' else s end), '[]'::jsonb)
           from jsonb_array_elements_text(secoes_permitidas) s
       )
 where secoes_permitidas ? 'disparo';

select nome, email, secoes_permitidas from public.usuarios order by nome;
