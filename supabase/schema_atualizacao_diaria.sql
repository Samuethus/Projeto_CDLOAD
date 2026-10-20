-- =====================================================================
-- CDLoad · Atualização diária do Dashboard › Panorama Econômico com horário exato
--
-- Por quê: o cron do próprio GitHub Actions atrasa muito (agendado para 06:00 de Brasília, começava entre
-- 09:30 e 13:00). Aqui o pg_cron do Supabase chama o GitHub às 05:45 de Brasília (08:45 UTC) e dispara o
-- workflow .github/workflows/abve-diario.yml só com as fontes do Panorama (cnpj=false). Ele leva poucos
-- minutos e publica o site em seguida: os dados ficam no ar antes das 06:00.
-- Os agendamentos do próprio workflow continuam como reserva.
--
-- Antes de rodar:
--   1. No GitHub, crie um token "fine-grained" (Settings > Developer settings > Personal access tokens >
--      Fine-grained tokens) só para o repositório Samuethus/Projeto_CDLOAD, com a permissão
--      Repository permissions > Actions: Read and write. Validade: a maior possível (anote para renovar).
--   2. Troque COLE_AQUI_O_TOKEN abaixo pelo token e rode este arquivo em Supabase > SQL Editor.
--      O token fica criptografado no Vault do Supabase (não vai para tabela nem para o código).
-- É idempotente: rodar de novo atualiza o token e o agendamento.
-- =====================================================================

create extension if not exists pg_cron;   -- agendamento
create extension if not exists pg_net;    -- chamada HTTP a partir do banco

-- 1. Token do GitHub no Vault (cria ou atualiza)
do $$
declare
  v_token text := 'COLE_AQUI_O_TOKEN';
  v_id    uuid;
begin
  if v_token = 'COLE_AQUI_O_TOKEN' then
    raise exception 'Troque COLE_AQUI_O_TOKEN pelo token do GitHub antes de rodar.';
  end if;
  select id into v_id from vault.secrets where name = 'github_token_atualizacao';
  if v_id is null then
    perform vault.create_secret(v_token, 'github_token_atualizacao', 'GitHub: dispara o workflow abve-diario.yml (Actions: read/write)');
  else
    perform vault.update_secret(v_id, v_token);
  end if;
end $$;

-- 2. Função que dispara o workflow (só o pg_cron e o SQL Editor chamam; não fica exposta ao app)
create or replace function public.disparar_atualizacao_panorama(p_cnpj boolean default false)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'github_token_atualizacao';
  if v_token is null then
    raise exception 'Token do GitHub não encontrado no Vault (rode o item 1 deste arquivo).';
  end if;
  return net.http_post(
    url     := 'https://api.github.com/repos/Samuethus/Projeto_CDLOAD/actions/workflows/abve-diario.yml/dispatches',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_token,
                 'Accept', 'application/vnd.github+json',
                 'X-GitHub-Api-Version', '2022-11-28',
                 'User-Agent', 'cdload-supabase',
                 'Content-Type', 'application/json'),
    body    := jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('cnpj', p_cnpj::text)),
    timeout_milliseconds := 30000
  );
end $$;

revoke all on function public.disparar_atualizacao_panorama(boolean) from public, anon, authenticated;

-- 3. Agendamento: todo dia às 08:45 UTC = 05:45 em Brasília (o Brasil não tem horário de verão desde 2019)
select cron.unschedule(jobid) from cron.job where jobname = 'cdload-atualizacao-panorama';
select cron.schedule('cdload-atualizacao-panorama', '45 8 * * *', $$select public.disparar_atualizacao_panorama(false)$$);

-- 4. Teste agora (o GitHub responde 204 quando aceita; confira a execução na aba Actions do repositório)
select public.disparar_atualizacao_panorama(false);
-- Depois de alguns segundos:
-- select status_code, content from net._http_response order by id desc limit 1;
-- Histórico do agendamento:
-- select start_time, status, return_message from cron.job_run_details
--  where jobid = (select jobid from cron.job where jobname = 'cdload-atualizacao-panorama') order by start_time desc limit 10;
