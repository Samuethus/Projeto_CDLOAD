-- =====================================================================================
-- CDLoad · INADIMPLÊNCIA — usuário leitor da leitura automática (GitHub Actions)
-- =====================================================================================
--
-- PARA QUE SERVE
--   O script scripts/spc_inadimplencia_extrair.py (passo diário do workflow abve-diario.yml)
--   precisa abrir os PDFs que os usuários anexam na seção Inadimplência, guardados no bucket
--   PRIVADO "inadimplencia". Em vez da chave service_role (que ignora todas as regras de acesso),
--   o robô entra como um usuário comum da plataforma com SÓ a seção Inadimplência liberada e
--   SEM "Edição": lê a tabela inadimplencia_arquivos e baixa os PDFs pelas mesmas regras (RLS)
--   de schema_inadimplencia.sql, e não consegue remover nada nem ver as demais seções.
--
-- COMO USAR (uma vez)
--   1. Supabase > Authentication > Users > Add user > Create new user
--        e-mail: o mesmo de baixo (ex.: leitor-spc@cdlcuiaba.com.br) · senha forte · marque "Auto Confirm User".
--   2. Troque o e-mail abaixo (3 lugares) e rode este arquivo no SQL Editor (idempotente).
--      Rode DEPOIS de schema_inadimplencia.sql.
--   3. GitHub > repositório > Settings > Secrets and variables > Actions > New repository secret:
--        SPC_LEITOR_EMAIL ... o e-mail do passo 1
--        SPC_LEITOR_SENHA ... a senha do passo 1
--        ANTHROPIC_API_KEY .. chave da API da Anthropic (console.anthropic.com) — lê os números dos PDFs
--      (SUPABASE_URL e SUPABASE_ANON_KEY já existem: são os mesmos do deploy.)
-- =====================================================================================

insert into public.usuarios (nome, email, cargo, status, secoes_permitidas)
values ('Leitor automático SPC (robô)', 'leitor-spc@cdlcuiaba.com.br', 'Usuário', 'Ativo', '["configuracoes"]'::jsonb)
on conflict (email) do update
  set cargo = 'Usuário', status = 'Ativo', secoes_permitidas = '["configuracoes"]'::jsonb;

-- Sem "Edição" (não remove documentos), quando a coluna existir.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'usuarios' and column_name = 'edicao') then
    update public.usuarios set edicao = false where lower(email) = lower('leitor-spc@cdlcuiaba.com.br');
  end if;
end $$;

-- Conferência: o usuário tem de aparecer com status Ativo, só "configuracoes" e e-mail confirmado.
select u.nome, u.email, u.cargo, u.status, u.secoes_permitidas, a.email_confirmed_at is not null as email_confirmado
from public.usuarios u left join auth.users a on lower(a.email) = lower(u.email)
where lower(u.email) = lower('leitor-spc@cdlcuiaba.com.br');
