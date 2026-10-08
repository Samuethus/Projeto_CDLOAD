# Passo a passo no Supabase (fazer ANTES de publicar)

Estas etapas só podem ser feitas por você, no painel do Supabase.

## 1. Configurar o Auth (Authentication)

1. **Providers > Email:** deixe **Confirm email = ON** (obrigatório: impede que alguém crie conta com o e-mail de outra pessoa) e **Minimum password length = 8**.
2. **URL Configuration:** `Site URL` = endereço do GitHub Pages (`https://SEU-USUARIO.github.io/SEU-REPO/`) e adicione o mesmo endereço em `Redirect URLs`.
3. Se quiser evitar cadastros por estranhos, mantenha o Sign up habilitado: o cadastro sozinho **não dá acesso a nada**, pois o RLS exige que o e-mail esteja em `usuarios` e ativo.

## 2. Aplicar o SQL (nesta ordem)

1. **SQL Editor** > cole o conteúdo de [schema_estoque.sql](schema_estoque.sql) > **Run** (cria as tabelas do Estoque; RLS fica ligado e sem policies — ninguém acessa nada ainda, nem o `anon`).
2. Cole o conteúdo de [schema_relatorios.sql](schema_relatorios.sql) > **Run** (cria a tabela e o bucket de Storage do módulo Relatórios, também sem acesso ainda).
3. Cole o conteúdo de [schema_seguranca_rls.sql](schema_seguranca_rls.sql) > **Run** (concede o acesso real: login + seção liberada; remover produto/movimentação do Estoque e remover relatório ficam restritos a Administrador).
4. A última consulta lista os administradores. Confirme que o e-mail do administrador principal aparece (se não, use o `insert` comentado no fim do arquivo).
5. Cole o conteúdo de [schema_agenda.sql](schema_agenda.sql) > **Run** (coluna usada pela sincronização de agenda das Campanhas; ver seção abaixo).
6. Cole o conteúdo de [schema_clipping.sql](schema_clipping.sql) > **Run** (Clipping News: concede os privilégios da tabela `clipping_news` — resolve o erro *permission denied for table clipping_news* — e liga a coleta automática no Google Notícias a cada 30 minutos). O resultado da última linha deve trazer `"ok": true` e quantas notícias novas entraram.
7. Cole o conteúdo de [schema_somente_admin_edita.sql](schema_somente_admin_edita.sql) > **Run** (**só Administrador edita e exclui**: quem tem a seção liberada — mesmo todas — apenas lê e cria registros em Campanhas, Clipping, Estoque e Relatórios). A consulta final lista as policies de UPDATE/DELETE; todas devem usar `cdl_admin()`. Depois, republique a Edge Function (`npx supabase functions deploy sincronizar-agenda`), que passa a gravar a agenda por essa função.
8. Cole o conteúdo de [schema_secao_home.sql](schema_secao_home.sql) > **Run** (a **Home** vira uma seção liberada por usuário em **Usuários > Permissões de Acesso**; o script inclui "home" em todos os já cadastrados para ninguém perder o acesso — depois desmarque de quem não deve ver). Quem não tem a Home entra direto na primeira seção liberada.
9. Cole o conteúdo de [schema_paineis_usuario.sql](schema_paineis_usuario.sql) > **Run** (em **Usuários > Etapa 2**, escolha quais **painéis Power BI** aparecem na Home de cada usuário; os não selecionados ficam ocultos. Quem já estava cadastrado continua vendo todos até ser editado; usuário novo começa sem nenhum; Administrador vê todos. O script também apaga a coluna antiga `acesso_power_bi`, do campo "Power BI" que foi removido).
10. Cole o conteúdo de [schema_usuarios_setor_acesso.sql](schema_usuarios_setor_acesso.sql) > **Run** (em **Usuários**, cria o campo **Setor** do cadastro e a coluna **Último acesso**, gravada a cada entrada na plataforma pela função `registrar_acesso()` — o usuário comum só consegue atualizar o próprio horário).
11. Cole o conteúdo de [schema_secao_whatsapp.sql](schema_secao_whatsapp.sql) > **Run** (a seção **Disparo** passou a se chamar **WhatsApp**: troca a chave `disparo` por `whatsapp` nas seções liberadas de cada usuário — o app já aceita a chave antiga, então a ordem não importa).
12. **Só se o Estoque já tinha dados no modelo antigo** (saldo em RH, Institucional, Espaço): cole [schema_migracao_estoque_centrais.sql](schema_migracao_estoque_centrais.sql) > **Run**. O estoque passa a existir só em **Escritório** e **Almoxarifado** (o saldo que estava nos setores antigos é transferido para o Almoxarifado — troque a linha `DESTINO` se preferir o Escritório) e toda **saída** passa a exigir o **setor de consumo**. A consulta final deve voltar vazia. Banco novo não precisa: o `schema_estoque.sql` já cria tudo assim.
13. Cole o conteúdo de [schema_estoque_editar_movimentacao.sql](schema_estoque_editar_movimentacao.sql) > **Run** (libera o **lápis de edição** na tabela de Movimentações do Estoque — só Administrador; o banco impede ajuste que deixe saldo negativo e registra quem e quando editou). Banco novo não precisa. Rode **depois** do passo 12 — se aparecer *"Could not find the 'setor_consumo' column ... in the schema cache"*, é porque o passo 12 ainda não foi rodado.
14. Cole o conteúdo de [schema_estoque_nota_fiscal.sql](schema_estoque_nota_fiscal.sql) > **Run** (campo **Nota fiscal (PDF)** na **Entrada** do Estoque: cria as colunas `nota_fiscal_*` e o bucket privado `notas_fiscais` — só PDF, até 10 MB; quem tem a seção Estoque vê e anexa, só Administrador remove). As duas consultas finais devem mostrar o bucket e as 3 policies. Banco novo não precisa.
15. Cole o conteúdo de [schema_clipping_bloquear_dominios.sql](schema_clipping_bloquear_dominios.sql) > **Run** (Clipping News: **sites bloqueados por segurança** num cadastro único — hoje `pnbonline.com.br` e `jknoticias.com`. Tira do app o que já tinha sido gravado deles; a primeira consulta final lista os sites e quantas notícias ficaram retidas, a segunda deve voltar vazia).
16. Cole o conteúdo de [schema_usuarios_restricao.sql](schema_usuarios_restricao.sql) > **Run** (campo **Restrição** em **Usuários** › cadastro/edição: o usuário restrito, no **Estoque**, vê só a tela "Toque aqui para ler o produto" e registra apenas **saída**. O banco garante a regra: restrito não grava entrada, transferência nem cadastra produto. Rode **depois** do `schema_seguranca_rls.sql` — se aquele script for rodado de novo, rode este outra vez). Sem este passo, salvar um usuário com a Restrição marcada mostra o aviso para rodar o script.

## Estoque › estoques centrais e setor de consumo

- **Entrada** (compra do mês) e **origem** vão sempre para um dos dois estoques centrais: **Escritório** ou **Almoxarifado**.
- **Saída** = retirada da central, informando o **setor que consome**: Térreo, 1º Piso, 2º Piso, Espaço CDL, Administrativo, Financeiro, Certificado, Comercial, Diretoria, Recepção, RH, Jurídico. Para incluir ou renomear um setor, edite `STOCK_SETORES_CONSUMO` em `index.html` (o banco não trava a lista).
- **Nota fiscal:** a Entrada tem um campo para anexar o PDF da NF da compra (opcional, até 10 MB). Ele fica no bucket privado `notas_fiscais` e abre pelo ícone de documento na tabela de Movimentações. Na edição dá para substituir ou remover o PDF.
- **Transferência** move saldo entre as duas centrais e não conta como compra nem consumo.
- **Editar lançamento** (lápis na aba Movimentações, só Administrador): corrige produto, tipo (entrada/saída), estoque, setor de consumo, quantidade e observação. Na origem, produto e tipo ficam travados; na transferência, só quantidade e observação (as duas pontas são ajustadas juntas). Saídas antigas sem setor podem ser completadas por aqui.
- **Dashboard** e **Relatório** (Controle de Estoque) mostram o consumo por setor; saídas antigas, sem setor, aparecem como "Não informado".

## Clipping News (Google Notícias)

- **Escopo:** todas as notícias do Google Notícias sobre dois players, para comparação no Dashboard — **CDL Cuiabá** ("CDL Cuiabá", "Câmara de Dirigentes Lojistas de Cuiabá", "Fundação CDL Cuiabá" + site oficial) e **Fecomércio MT** ("Fecomércio MT", "Fecomércio Mato Grosso"). Cada notícia fica marcada com o(s) player(s) na coluna `players`. Para mudar atores/termos, edite `clipping_players()` e rode o arquivo de novo.
- A coleta roda sozinha a cada 30 minutos (`pg_cron`), e a seção dispara uma busca rápida (últimos 7 dias) ao ser aberta se a última tiver mais de 1 hora.
- **Portal:** cada notícia é ligada ao portal pelo domínio do site (`clipping_portais`), com um nome padrão por portal — o filtro "Portal" nunca repete o mesmo veículo com grafias diferentes. Para padronizar o nome de um portal novo, inclua-o na lista `insert into public.clipping_portais` do SQL e rode de novo.
- **Site oficial da CDL:** a cada 30 minutos, `clipping_coletar_site_cdl()` lê https://www.cdlcuiaba.com.br/ultimas-noticias. **Todas** as matérias do site entram, sem checagem de palavra-chave, com o portal **"Site Oficial"**, título, data, linha fina e a capa em 800x600. O site é ISO-8859-1; o texto é relido na codificação certa (`clipping_decodificar_resposta`). As mesmas matérias vindas pelos buscadores ficam `duplicada`.
- **Busca ampliada:** Google Notícias (janelas de 1, 7 e 30 dias + busca geral a cada 30 min; todo dia às 05h uma varredura completa mês a mês desde janeiro). A mesma matéria achada duas vezes aparece uma vez só (`link_chave`); a que vem pelos termos dos dois players fica marcada com os dois.
- **Sites bloqueados (segurança):** cadastro único na tabela `clipping_dominios_bloqueados` (domínio, motivo, data). De um site bloqueado — e de qualquer subdomínio dele — nada é gravado, acessado ou exibido; o que já estava gravado vira `bloqueada` e some do app e do Dashboard. Bloqueados hoje:

  | Domínio | Bloqueado em | Motivo |
  |---|---|---|
  | `pnbonline.com.br` | 01/09/2026 | Alerta do antivírus ao acessar o portal |
  | `jknoticias.com` | 07/10/2026 | Alerta do antivírus ao acessar o portal |

  Para bloquear outro: inclua a linha no passo 2 de [schema_clipping_bloquear_dominios.sql](schema_clipping_bloquear_dominios.sql) e rode o arquivo; acrescente o domínio também em `CLIP_DOMINIOS_BLOQUEADOS` no `index.html` (segunda barreira no navegador). Consultar a lista a qualquer momento: `select * from clipping_dominios_bloqueados order by bloqueado_em;`
- **Verificação e imagens:** a cada 5 minutos, `clipping_verificar_materias()` descobre o link direto e a imagem de capa de até 15 matérias. Não filtra mais nada: a notícia aparece no app desde a coleta. Sem imagem, o app mostra uma arte gerada pela categoria.
- **Citação ativa:** o player só fica na notícia se a matéria o cita no texto. Quando o nome aparece **apenas** no crédito/legenda da foto (ex.: "Foto: Divulgação CDL Cuiabá" numa matéria sobre pesquisa da Fecomércio), o player sai da notícia e não volta nas coletas seguintes (coluna `players_descartados`); sem nenhum player, a notícia fica `fora_escopo` e some do app e do Dashboard. Na dúvida (nome não encontrado na página, ex.: site montado por JavaScript), o player é mantido. Matérias novas passam pela regra na verificação; as já gravadas são revisadas por `clipping_revisar_citacoes()`, 15 a cada 5 minutos. Acompanhar: `select citacao_status, count(*) from clipping_news where origem = 'google_news' group by 1;` e ver as ajustadas: `select titulo, fonte, players, players_descartados, verificacao from clipping_news where citacao_status = 'ajustada' order by publicado_em desc;`. Para devolver um player a uma notícia (correção manual): `update clipping_news set players = players || 'CDL Cuiabá', players_descartados = array_remove(players_descartados, 'CDL Cuiabá'), verificacao = 'confirmada', citacao_status = 'ok' where id = '...';`
- Conferir o volume por player: `select unnest(players) as player, count(*) from clipping_news where coalesce(verificacao, '') not in ('duplicada', 'bloqueada', 'fora_escopo') group by 1;`
- **Dashboard › Painel Clipping News:** lê essas mesmas notícias e compara os players (volume, share of voice, veículos, tom, evolução, palavras, temas). Não precisa de SQL próprio.
- Categoria, plataforma e sentimento são estimados pelo título e pelo veículo; um Administrador corrige pelo botão **Editar** do card (a edição não é sobrescrita pelas próximas coletas).
- Remover (só Administrador) uma notícia do Google só a oculta, para ela não voltar na coleta seguinte.
- Conferir as coletas: `select * from clipping_coletas order by iniciado_em desc limit 10;` e o agendamento: `select * from cron.job_run_details order by start_time desc limit 10;`.

## Campanhas › Participantes e agenda (Outlook / Google Calendar)

Na **Etapa 3** do wizard de campanha há o campo **Participantes**: busca pelo nome das pessoas cadastradas e ativas em **Usuários** (e aceita e-mail de fora da organização digitado + Enter) e um **horário opcional**. Ao salvar, a plataforma chama a Edge Function `sincronizar-agenda`, que cria o evento na agenda de uma **conta organizadora** com todos os participantes como convidados. O Outlook/Google envia o convite e o período fica **bloqueado (Ocupado)** na agenda de cada um.

- Sem horário: evento de **dia inteiro** do início ao fim da vigência. Com horário: bloqueio **diário** naquele intervalo, do início ao fim da vigência.
- Editar a campanha (só Administrador) **atualiza o mesmo evento** (quem entrou recebe convite; quem saiu recebe cancelamento). Remover todos os participantes ou remover a campanha **cancela** o evento.
- Fuso: America/Cuiaba.

### Passo 1 — Banco
SQL Editor > cole [schema_agenda.sql](schema_agenda.sql) > **Run** (cria a coluna `campanhas.agenda_sync`).

### Passo 2 — Configure UMA agenda (ou as duas)
A CDL usa Microsoft 365 (`@cdlcuiaba.onmicrosoft.com`), então o **Outlook** é o caminho principal: o convite do Exchange também chega e entra na agenda de quem usa Gmail/Google. Configure o Google só se a organização tiver Google Workspace — **com os dois ligados, cada participante recebe dois convites**.

**Outlook (Microsoft 365)** — precisa de um administrador do Microsoft 365:
1. Portal do Azure > **Microsoft Entra ID > Registros de aplicativo > Novo registro** (nome: `CDLoad Agenda`, só contas deste diretório).
2. **Permissões de API > Adicionar > Microsoft Graph > Permissões de aplicativo > `Calendars.ReadWrite`** > **Conceder consentimento de administrador**.
3. **Certificados e segredos > Novo segredo do cliente** (anote o valor).
4. Escolha a caixa organizadora (ex.: `agenda@cdlcuiaba.onmicrosoft.com`). Recomendado: restringir o app só a essa caixa com uma *Application Access Policy* do Exchange (`New-ApplicationAccessPolicy -AppId <ID do app> -PolicyScopeGroupId agenda@... -AccessRight RestrictAccess`), senão o app pode escrever em qualquer agenda do tenant.

**Google Calendar (Gmail pessoal, @gmail.com)** — OAuth com refresh token:
1. Google Cloud Console > projeto > **APIs e serviços > Biblioteca** > ative a **Google Calendar API**.
2. **Tela de consentimento OAuth**: tipo *Externo*, adicione o escopo `.../auth/calendar.events` e clique em **Publicar app** (status *Em produção*; em *Teste* o refresh token expira em 7 dias).
3. **Credenciais > Criar credenciais > ID do cliente OAuth** > tipo **Aplicativo da Web** > em *URIs de redirecionamento autorizados* adicione `https://developers.google.com/oauthplayground` > anote **Client ID** e **Client secret**.
4. Abra https://developers.google.com/oauthplayground > engrenagem > marque **Use your own OAuth credentials** > cole Client ID e secret. No passo 1, digite o escopo `https://www.googleapis.com/auth/calendar.events` > **Authorize APIs** > entre com o Gmail organizador (se aparecer "app não verificado": *Avançado > Acessar*). No passo 2, **Exchange authorization code for tokens** > copie o **Refresh token**.
5. Secrets no Supabase: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN` (opcional `GOOGLE_CALENDAR_ID`; padrão = agenda principal). `GOOGLE_SERVICE_ACCOUNT_JSON` não é usado nesse modo.

**Google Calendar (Google Workspace)**:
1. Google Cloud Console > crie um projeto > ative a **Google Calendar API** > **Contas de serviço > Criar** > gere uma chave **JSON**.
2. Admin do Workspace > **Segurança > Controles de API > Delegação em todo o domínio** > adicione o *Client ID* da conta de serviço com o escopo `https://www.googleapis.com/auth/calendar.events`.
3. Escolha a conta organizadora do Workspace (ex.: `agenda@suaempresa.com.br`).

### Passo 3 — Publicar a função (Supabase CLI)
```bash
npx supabase login
npx supabase link --project-ref SEU_PROJECT_REF
# Outlook
npx supabase secrets set MS_TENANT_ID=... MS_CLIENT_ID=... MS_CLIENT_SECRET=... MS_ORGANIZADOR_EMAIL=agenda@cdlcuiaba.onmicrosoft.com
# Google (opcional)
npx supabase secrets set GOOGLE_SERVICE_ACCOUNT_JSON="$(cat chave-servico.json)" GOOGLE_ORGANIZADOR_EMAIL=agenda@suaempresa.com.br
# Opcional: aceitar chamadas só do site publicado
npx supabase secrets set APP_ORIGIN=https://SEU-USUARIO.github.io
npx supabase functions deploy sincronizar-agenda
```
Os segredos ficam só no Supabase (nunca no `config.js` nem no GitHub). A função usa o login de quem salvou a campanha e só aceita quem tem a seção **Campanhas** liberada. Logs: Supabase > Edge Functions > sincronizar-agenda > Logs.

## 3. Primeiro acesso do administrador

1. Abra o site, digite o e-mail do admin e uma **nova senha** (8+ caracteres) e clique em **Primeiro acesso**.
2. Confirme pelo e-mail recebido e entre normalmente.
3. Em **Usuários**, cadastre as demais pessoas (nome, e-mail, perfil e seções). Cada uma faz o **Primeiro acesso** com o próprio e-mail.

## 4. Trocar credenciais antigas

- As senhas que existiam em `usuarios.senha` e a `cdload2026` foram expostas: não reutilize.
- Se a chave anon ficou pública em algum momento, rotacione em Project Settings > API e atualize o secret `SUPABASE_ANON_KEY` do GitHub.

## Esqueci a senha

Não há tela própria ainda. Um administrador do projeto Supabase pode enviar o reset em Authentication > Users.
