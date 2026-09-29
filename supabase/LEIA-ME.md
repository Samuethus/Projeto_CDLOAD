# Passo a passo no Supabase (fazer ANTES de publicar)

Estas etapas só podem ser feitas por você, no painel do Supabase.

## 1. Configurar o Auth (Authentication)

1. **Providers > Email:** deixe **Confirm email = ON** (obrigatório: impede que alguém crie conta com o e-mail de outra pessoa) e **Minimum password length = 8**.
2. **URL Configuration:** `Site URL` = endereço do GitHub Pages (`https://SEU-USUARIO.github.io/SEU-REPO/`) e adicione o mesmo endereço em `Redirect URLs`.
3. Se quiser evitar cadastros por estranhos, mantenha o Sign up habilitado: o cadastro sozinho **não dá acesso a nada**, pois o RLS exige que o e-mail esteja em `usuarios` e ativo.

## 2. Aplicar o SQL (nesta ordem)

1. **SQL Editor** > cole o conteúdo de [schema_estoque.sql](schema_estoque.sql) > **Run** (cria as tabelas do Estoque; RLS fica ligado e sem policies — ninguém acessa nada ainda, nem o `anon`).
2. Cole o conteúdo de [schema_relatorios.sql](schema_relatorios.sql) > **Run** (cria a tabela e o bucket de Storage do módulo Relatórios, também sem acesso ainda).
3. Cole o conteúdo de [seguranca_rls.sql](seguranca_rls.sql) > **Run** (concede o acesso real: login + seção liberada; remover produto/movimentação do Estoque e remover relatório ficam restritos a Administrador).
4. A última consulta lista os administradores. Confirme que o e-mail do administrador principal aparece (se não, use o `insert` comentado no fim do arquivo).
5. Cole o conteúdo de [schema_clipping.sql](schema_clipping.sql) > **Run** (Clipping News: concede os privilégios da tabela `clipping_news` — resolve o erro *permission denied for table clipping_news* — e liga a coleta automática no Google Notícias a cada 30 minutos). O resultado da última linha deve trazer `"ok": true` e quantas notícias novas entraram.

## Clipping News (Google Notícias)

- **Escopo:** todas as notícias do Google Notícias sobre dois players, para comparação no Dashboard — **CDL Cuiabá** ("CDL Cuiabá", "Câmara de Dirigentes Lojistas de Cuiabá", "Fundação CDL Cuiabá" + site oficial) e **Fecomércio MT** ("Fecomércio MT", "Fecomércio Mato Grosso"). Cada notícia fica marcada com o(s) player(s) na coluna `players`. Para mudar atores/termos, edite `clipping_players()` e rode o arquivo de novo.
- A coleta roda sozinha a cada 30 minutos (`pg_cron`), e a seção dispara uma busca rápida (últimos 7 dias) ao ser aberta se a última tiver mais de 1 hora.
- **Portal:** cada notícia é ligada ao portal pelo domínio do site (`clipping_portais`), com um nome padrão por portal — o filtro "Portal" nunca repete o mesmo veículo com grafias diferentes. Para padronizar o nome de um portal novo, inclua-o na lista `insert into public.clipping_portais` do SQL e rode de novo.
- **Site oficial da CDL:** a cada 30 minutos, `clipping_coletar_site_cdl()` lê https://www.cdlcuiaba.com.br/ultimas-noticias. **Todas** as matérias do site entram, sem checagem de palavra-chave, com o portal **"Site Oficial"**, título, data, linha fina e a capa em 800x600. O site é ISO-8859-1; o texto é relido na codificação certa (`clipping_decodificar_resposta`). As mesmas matérias vindas pelos buscadores ficam `duplicada`.
- **Busca ampliada:** Google Notícias (janelas de 1, 7 e 30 dias + busca geral a cada 30 min; todo dia às 05h uma varredura completa mês a mês desde janeiro). A mesma matéria achada duas vezes aparece uma vez só (`link_chave`); a que vem pelos termos dos dois players fica marcada com os dois.
- **Portais bloqueados:** `pnbonline.com.br` (alerta de segurança do antivírus) nunca é gravado nem acessado; para bloquear outro, inclua na função `clipping_dominio_bloqueado()`.
- **Verificação e imagens:** a cada 5 minutos, `clipping_verificar_materias()` descobre o link direto e a imagem de capa de até 15 matérias. Não filtra mais nada: a notícia aparece no app desde a coleta. Sem imagem, o app mostra uma arte gerada pela categoria.
- Conferir o volume por player: `select unnest(players) as player, count(*) from clipping_news where coalesce(verificacao, '') not in ('duplicada', 'bloqueada', 'fora_escopo') group by 1;`
- **Dashboard › Painel Clipping News:** lê essas mesmas notícias e compara os players (volume, share of voice, veículos, tom, evolução, palavras, temas). Não precisa de SQL próprio.
- Categoria, plataforma e sentimento são estimados pelo título e pelo veículo; corrija pelo botão **Editar** do card (a edição não é sobrescrita pelas próximas coletas).
- Remover uma notícia do Google só a oculta, para ela não voltar na coleta seguinte.
- Conferir as coletas: `select * from clipping_coletas order by iniciado_em desc limit 10;` e o agendamento: `select * from cron.job_run_details order by start_time desc limit 10;`.

## 3. Primeiro acesso do administrador

1. Abra o site, digite o e-mail do admin e uma **nova senha** (8+ caracteres) e clique em **Primeiro acesso**.
2. Confirme pelo e-mail recebido e entre normalmente.
3. Em **Usuários**, cadastre as demais pessoas (nome, e-mail, perfil e seções). Cada uma faz o **Primeiro acesso** com o próprio e-mail.

## 4. Trocar credenciais antigas

- As senhas que existiam em `usuarios.senha` e a `cdload2026` foram expostas: não reutilize.
- Se a chave anon ficou pública em algum momento, rotacione em Project Settings > API e atualize o secret `SUPABASE_ANON_KEY` do GitHub.

## Esqueci a senha

Não há tela própria ainda. Um administrador do projeto Supabase pode enviar o reset em Authentication > Users.
