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
11. Cole o conteúdo de [schema_secao_whatsapp.sql](../whatsapp/schema_secao_whatsapp.sql) > **Run** (a seção **Disparo** passou a se chamar **WhatsApp**: troca a chave `disparo` por `whatsapp` nas seções liberadas de cada usuário — o app já aceita a chave antiga, então a ordem não importa).
12. **Só se o Estoque já tinha dados no modelo antigo** (saldo em RH, Institucional, Espaço): cole [schema_migracao_estoque_centrais.sql](schema_migracao_estoque_centrais.sql) > **Run**. O estoque passa a existir só em **Escritório** e **Almoxarifado** (o saldo que estava nos setores antigos é transferido para o Almoxarifado — troque a linha `DESTINO` se preferir o Escritório) e toda **saída** passa a exigir o **setor de consumo**. A consulta final deve voltar vazia. Banco novo não precisa: o `schema_estoque.sql` já cria tudo assim.
13. Cole o conteúdo de [schema_estoque_editar_movimentacao.sql](schema_estoque_editar_movimentacao.sql) > **Run** (libera o **lápis de edição** na tabela de Movimentações do Estoque — só Administrador; o banco impede ajuste que deixe saldo negativo e registra quem e quando editou). Banco novo não precisa. Rode **depois** do passo 12 — se aparecer *"Could not find the 'setor_consumo' column ... in the schema cache"*, é porque o passo 12 ainda não foi rodado.
14. Cole o conteúdo de [schema_estoque_nota_fiscal.sql](schema_estoque_nota_fiscal.sql) > **Run** (campo **Nota fiscal (PDF)** na **Entrada** do Estoque: cria as colunas `nota_fiscal_*` e o bucket privado `notas_fiscais` — só PDF, até 10 MB; quem tem a seção Estoque vê e anexa, só Administrador remove). As duas consultas finais devem mostrar o bucket e as 3 policies. Banco novo não precisa.
15. Cole o conteúdo de [schema_clipping_bloquear_dominios.sql](schema_clipping_bloquear_dominios.sql) > **Run** (Clipping News: **sites bloqueados por segurança** num cadastro único — hoje `pnbonline.com.br` e `jknoticias.com`. Tira do app o que já tinha sido gravado deles; a primeira consulta final lista os sites e quantas notícias ficaram retidas, a segunda deve voltar vazia).
16. Cole o conteúdo de [schema_usuarios_restricao.sql](schema_usuarios_restricao.sql) > **Run** (campo **Restrição** em **Usuários** › cadastro/edição: o usuário restrito, no **Estoque**, vê só a tela "Toque aqui para ler o produto" e registra apenas **saída**. O banco garante a regra: restrito não grava entrada, transferência nem cadastra produto. Rode **depois** do `schema_seguranca_rls.sql` — se aquele script for rodado de novo, rode este outra vez). Sem este passo, salvar um usuário com a Restrição marcada mostra o aviso para rodar o script.
17. Cole o conteúdo de [schema_usuarios_edicao.sql](schema_usuarios_edicao.sql) > **Run** (campo **Edição** em **Usuários** › cadastro/edição: o usuário com Edição **edita e exclui** registros nas seções liberadas para ele — Campanhas, Clipping News, Estoque e Relatórios — sem precisar ser Administrador. O cadastro de **Usuários** continua só do Administrador. Rode **por último**: os scripts dos passos 2, 6, 7, 13 e 14 recriam essas regras como "só Administrador"; se algum deles for rodado de novo, rode este outra vez). A consulta final lista as regras de UPDATE/DELETE, que devem usar `cdl_pode_editar(...)` (as de `usuarios` continuam com `cdl_admin()`).
18. Cole o conteúdo de [schema_viabilidade.sql](schema_viabilidade.sql) > **Run** (**Dashboard › Painel · Viabilidade** editável: cria as tabelas `viabilidade_itens` — ferramentas e custos, módulos do CDLoad, planos de captação — e `viabilidade_parametros` — dias úteis por mês —, já carregadas com os valores da planilha. Lê quem tem a seção Dashboard; edita pelo botão **Editar** da barra do painel quem pode editar o Dashboard — Administrador ou usuário com Edição e a seção liberada. Rode **depois** do passo 17. Rodar de novo não apaga edições. A consulta final deve mostrar 5 ferramentas, 5 módulos e 1 plano). Sem este passo o painel continua com os valores de `assets/data/viabilidades.js` e o botão Salvar fica bloqueado.
19. Cole o conteúdo de [schema_surveymonkey_acesso.sql](schema_surveymonkey_acesso.sql) > **Run** (**Usuários › Acessos › Formulários - Survey Monkey**, antes em Survey › Acessos, só Administrador: escolher, por usuário, quais formulários ele visualiza — lista, painel, coletores e respostas. Cria `usuarios.survey_formularios_permitidos` (`null` = todos, como hoje; lista de ids = só esses) e troca as regras de leitura de `survey_formularios`, `survey_perguntas`, `survey_coletores` e `survey_respostas` para respeitar a lista. Rode **depois** do `schema_surveymonkey.sql`; se aquele for rodado de novo, rode este outra vez). Sem este passo o botão Acessos avisa que falta a coluna.
20. Cole o conteúdo de [schema_inadimplencia.sql](schema_inadimplencia.sql) > **Run** (seção **Documentos**, antigas Configurações e Inadimplência — a chave da seção continua `configuracoes`, então quem já tinha acesso continua tendo: cria a tabela `inadimplencia_arquivos` e o bucket privado `inadimplencia`, com as pastas **1. CESPC** e **2. Inadimplência** na coluna `pasta`; na Inadimplência ficam os PDFs do SPC Brasil, com abrangência Cuiabá, Mato Grosso ou Brasil. Quem já rodou antes precisa rodar de novo para criar a coluna `pasta` — os documentos existentes vão para a Inadimplência. Lê e envia quem tem a seção; remove Administrador ou quem tem Edição. Rode **depois** do passo 17). As duas consultas finais devem mostrar o bucket e as 6 regras. Esses documentos alimentam o indicador **SPC: Inadimplência** do Dashboard › Panorama.
21. Cole o conteúdo de [schema_campanhas_leads.sql](schema_campanhas_leads.sql) > **Run** (Campanhas › Etapa 3 › **Leads**: controle de quem já recebeu — só acrescenta, então ninguém recebe duas vezes — e limite diário. Sem ele a função não envia aos leads. Rode **depois** dos passos 5 e 17; pode rodar de novo).
22. Cole o conteúdo de [schema_roadmap.sql](schema_roadmap.sql) > **Run** (seção **Roadmap**: cria a tabela `roadmap_interacoes` — uma flag por setor e dia de interação/reunião do Núcleo, tipo Reunião, Alinhamento ou Demanda. Lê e marca quem tem a seção `roadmap` liberada em **Usuários > Permissões de Acesso**; desmarca quem registrou a flag, quem tem Edição ou o Administrador. Rode **depois** do passo 17). A consulta final deve listar 3 regras. Sem este passo a seção avisa que não conseguiu carregar as interações.
23. Cole o conteúdo de [schema_estoque_precos_nf.sql](schema_estoque_precos_nf.sql) > **Run** (**Estoque: preço praticado e notas fiscais**. Cria o campo de preço na **Entrada**, a data da última mudança de preço do produto, o histórico `estoque_precos`, o cadastro `notas_fiscais` (botão **+ Nota Fiscal**) e o vínculo da entrada com a nota. Passa todos os nomes de produto para maiúsculas e transforma os PDFs já anexados às entradas em notas fiscais, com fornecedor "Não informado", que podem ser completadas depois. Rode **depois** dos passos 16 e 17; se o passo 13 for rodado de novo, rode este outra vez). As três consultas finais mostram as saídas sem custo (deve dar 0), as últimas notas e as 5 regras de acesso.
24. Cole o conteúdo de [schema_estoque_nf_itens.sql](schema_estoque_nf_itens.sql) > **Run** (**Estoque: nota fiscal lida do PDF**. Cria a tabela `notas_fiscais_itens`, com as linhas de produto de cada nota, e registra quem aprovou a nota e quando, além do tipo do PDF (DANFE ou NF-e). Cria também a função `estoque_nf_salvar`, que grava a nota e as linhas juntas e lança as entradas automáticas das linhas marcadas na coluna Entrada. Rode **depois** do passo 23; pode rodar de novo, e **quem já rodou precisa rodar outra vez** para criar as colunas do tipo do PDF e da entrada automática). As consultas finais devem mostrar 4 regras e a função. Sem este passo, a aprovação avisa para rodar o script.
25. **Uma única vez:** cole o conteúdo de [limpeza_notas_fiscais.sql](limpeza_notas_fiscais.sql) > **Run**. Ele **apaga todas as notas fiscais** para recomeçar com a leitura do PDF. Produtos e lançamentos de origem, entrada e saída continuam como estão: só some o vínculo da entrada com a nota. Depois, apague os PDFs em **Storage > notas_fiscais**, selecionando tudo e usando **Delete**; o Supabase não deixa apagar arquivos por SQL. **Não rode de novo** depois de cadastrar notas novas, senão elas também serão apagadas.
26. **Uma única vez:** padroniza o nome dos produtos cadastrados à mão com a descrição da nota fiscal. Antes, abra em **Editar** cada nota gravada antes da coluna "Código EAN Comercial" e aprove de novo (o PDF guardado é relido e os EAN são preenchidos). Depois cole [ajuste_nomes_produtos_nf_1_previa.sql](ajuste_nomes_produtos_nf_1_previa.sql) > **Run**: só consulta e lista nome atual × nome da nota de cada produto (`nome_repetido` = outro produto ficaria com o mesmo nome). Conferido, cole [ajuste_nomes_produtos_nf_2_aplicar.sql](ajuste_nomes_produtos_nf_2_aplicar.sql) > **Run**: troca só o nome (código de barras, saldo, preço e lançamentos não mudam) e guarda o nome anterior em `estoque_ajuste_nomes_nf`, com o comando para desfazer no cabeçalho do script.
27. Cole o conteúdo de [schema_usuarios_dashboards.sql](schema_usuarios_dashboards.sql) > **Run** (**Usuários › Acessos › Dashboards para consulta**: cria `usuarios.dashboards_permitidos`, a lista dos painéis da seção Dashboard que cada usuário pode consultar; `null` = todos, como hoje para os cadastros existentes). Sem este passo, salvar um usuário avisa que falta a coluna. Pode rodar de novo. Todos os acessos (seções, painéis da Home, dashboards e formulários do Survey Monkey) ficam agora no cadastro do usuário, e um usuário novo começa sem nenhum.
28. Cole o conteúdo de [schema_uso_eventos.sql](schema_uso_eventos.sql) > **Run** (**Dashboard › Painel · Usuários Ativos**: cria a tabela `uso_eventos`, onde o app registra acessos, seções abertas, painéis do Dashboard consultados e ações, e a função `uso_resumo`, que entrega ao painel os totais por mês. Cada usuário só grava os próprios eventos; os eventos brutos só o Administrador lê; o painel responde ao Administrador e a quem tiver "Usuários Ativos" marcado em Usuários › Acessos › Dashboards para consulta — a lista "todos" de cadastros antigos não inclui este painel. Rode **depois** do passo 27; pode rodar de novo). O registro de uso começa a partir deste passo: o painel mostra o que foi registrado desde então.

## Estoque › estoques centrais e setor de consumo

- **Entrada** (compra do mês) e **origem** vão sempre para um dos dois estoques centrais: **Escritório** ou **Almoxarifado**.
- **Saída** = retirada da central, informando o **setor que consome**: Térreo, 1º Piso, 2º Piso, Espaço CDL, Administrativo, Financeiro, Certificado, Comercial, Diretoria, Recepção, RH, Jurídico. Para incluir ou renomear um setor, edite `STOCK_SETORES_CONSUMO` em `index.html` (o banco não trava a lista).
- **Nota fiscal:** o botão **+ Nota Fiscal** (à direita da Saída, e também na central de operações) cadastra a nota em 3 etapas:
  1. **Tipo de arquivo e PDF:** escolha **DANFE**, o documento impresso pelo sistema do fornecedor, ou **NF-e**, o PDF da consulta no portal da NF-e. Depois anexe o PDF (até 10 MB). O texto é lido no próprio navegador, no formato escolhido. Se o tipo escolhido não reconhecer nenhum produto mas o outro reconhecer, o aviso sugere a troca; trocar o tipo lê o mesmo PDF de novo. O tipo fica gravado na nota (`tipo_arquivo`).
  2. **Dados da nota:** número, série, chave de acesso, data de emissão, valor total, fornecedor e CNPJ já vêm preenchidos pela leitura (em verde); confira e corrija.
  3. **Conferência:** as linhas de produto da nota (**Código EAN Comercial**, descrição, unidade, quantidade e valores) aparecem numa tabela. O EAN, que é o código de barras, vem do quadro de detalhes da NF-e; o código do produto no fornecedor fica guardado e aparece ao passar o mouse sobre o EAN. O DANFE normalmente não traz o EAN, então a coluna fica vazia e pode ser preenchida na edição da linha. A soma das linhas é comparada ao valor total da nota. O **lápis** de cada linha abre a edição dela, e o ✓ conclui. A coluna **Cadastro** confere se o produto já existe no estoque, comparando o Código EAN Comercial da linha com o código de barras dos produtos. Se já existe, mostra **Cadastrado**. Se não existe, mostra uma caixa: marcada, o produto é cadastrado ao aprovar a nota, com o EAN como código de barras, a descrição como nome, a unidade da nota (UN1 vira UN, PCT vira PC e assim por diante) e o valor unitário como preço. A caixa do cabeçalho marca todas as linhas. Linha sem EAN mostra **Sem EAN**; informe o EAN na edição da linha para poder cadastrar. A coluna **Entrada** marca as linhas que entram no estoque **automaticamente** ao aprovar a nota; a caixa do cabeçalho marca todas. Em cada linha marcada, escolha o **produto do estoque**. O sistema sugere um pelo código ou pela descrição (selo "sugerido"), mas confira. A entrada é lançada no Almoxarifado com a quantidade e o valor unitário da linha, na data do cadastro da nota, e fica vinculada à nota. O preço praticado segue a regra de sempre: se o valor da linha for diferente do preço do produto, o cadastro é atualizado e o saldo que já existia continua no preço anterior. Ao editar a nota, as linhas já lançadas aparecem como **Lançada** e não geram entrada de novo. A entrada manual, escolhendo a nota na Entrada, continua funcionando. Marque **"Conferi os dados da nota e as linhas dos produtos"** e aprove.

  A leitura funciona com dois formatos: o DANFE gerado pelo sistema do fornecedor e o PDF da **consulta do portal da NF-e** ([nfe.fazenda.gov.br](https://www.nfe.fazenda.gov.br/portal/consultaRecaptcha.aspx), "Imprimir"), em que cada produto vem com um quadro de detalhes. Nos dois, o valor de cada linha é o do produto antes do desconto, então a conferência mostra a diferença para o valor total da nota (descontos, frete). Uma nota escaneada (imagem) não tem texto: nesse caso os dados e as linhas são preenchidos à mão nas etapas 2 e 3. As linhas da nota **não** são ligadas aos produtos do estoque. Na **Entrada**, o campo **Nota fiscal** é uma lista suspensa com digitação para escolher uma única nota já cadastrada. A aba **Notas fiscais** lista as notas com os produtos de cada uma; o ícone de olho abre a nota para consulta e o de documento abre o PDF. O Exportar gera uma linha por produto da nota. Uma nota com entrada vinculada não pode ser removida.
- **Preço praticado:** a Entrada tem o campo **Preço unitário**, que já vem com o preço do cadastro. Se você digitar outro valor, o preço do produto é atualizado e a data da mudança fica registrada; mudar o preço no cadastro também registra a data. O saldo que já estava no estoque **continua com o preço anterior**: o histórico (`estoque_precos`) guarda quanto havia e quanto valia. O preço novo só vale para o que entrar depois. Cada saída fica com o custo das compras que consumiu, das mais antigas para as mais novas. Por isso, Dashboard e Relatório mostram compras e consumo pelo preço praticado, sem distorção quando o preço muda. A Saída não tem campo de preço.
- **Nome do produto:** é sempre gravado em letras maiúsculas, qualquer que seja o usuário. O banco também garante isso.
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

## Campanhas › Participantes e agenda (convite por e-mail da Penso)

Na **Etapa 3** do wizard de campanha há o campo **Participantes**: busca pelo nome das pessoas cadastradas e ativas em **Usuários** (e aceita e-mail de fora da organização digitado + Enter) e um **horário opcional**. Ao salvar, a plataforma chama a Edge Function `sincronizar-agenda`, que envia o evento aos participantes a partir de uma **conta organizadora**:

- **Todos os participantes** (e-mail da CDL na Penso, Outlook, Hotmail, Gmail, Apple…) recebem **um único e-mail de convite de reunião** (iCalendar) da conta organizadora da Penso. O Outlook/Gmail mostram **Aceitar / Recusar**; ao aceitar, o evento entra na agenda da pessoa como **Ocupado**.
- A **Penso é o canal principal**: com ela configurada, o Google Calendar fica **desligado** (evita convite em dobro). Campanha antiga que tinha evento no Google tem esse evento **cancelado na próxima edição** (o Google avisa os convidados e tira da agenda deles) e passa a ser só da Penso. Sem a Penso configurada, o Google volta a valer como reserva.

- Sem horário: evento de **dia inteiro** do início ao fim da vigência. Com horário: bloqueio **diário** naquele intervalo, do início ao fim da vigência.
- Editar a campanha (só Administrador) **atualiza o mesmo evento** (quem entrou recebe convite; quem saiu recebe cancelamento). Remover todos os participantes ou remover a campanha **cancela** o evento — no convite por e-mail, a atualização/cancelamento chega como e-mail e o Outlook ajusta a agenda sozinho.
- Fuso: America/Cuiaba.

### Leads (e-mail informativo aos associados)
Na **Etapa 3 › Leads** anexa-se um **CSV com as colunas Nome e E-mail** (separado por `;` ou `,`, com ou sem cabeçalho; o app oferece um modelo). Ao salvar a campanha, no mesmo processo dos convites:
- cada lead recebe um **e-mail individual** (ninguém vê o endereço dos outros) pela conta da Penso, pela mesma conta dos convites, com o nome de remetente **“Núcleo de Inteligência - CDL Cuiabá”** (fixo no código, não usa o secret `PENSO_REMETENTE_NOME` dos convites): **assunto = Nome da campanha**, **corpo = Descrição** da Etapa 3 (`{Nome}` no texto vira o nome de cada lead). O e-mail é simples, sem rodapé nem cabeçalhos extras, e cada um sai numa conexão própria — igual ao convite, que chega ao Gmail;
- **limite da conta: 2.000 e-mails por dia** — a função soma os envios das últimas 24 h de todas as campanhas e deixa 100 de folga para os convites; o excedente fica **pendente** e sai quando a campanha for salva de novo depois de 24 h (secret opcional `PENSO_LIMITE_DIARIO`);
- listas grandes vão em **lotes** (cada chamada envia o que cabe em ~90 s; o app repete e mostra o progresso no botão);
- quem **já recebeu não recebe de novo** (`agenda_sync.leads.enviados`); endereço recusado pelo servidor fica em `falhas`;
- se a gravação do controle falhar (ex.: SQL do passo 21 não rodado), **nada é enviado**.

### Passo 1 — Banco
SQL Editor > cole [schema_agenda.sql](schema_agenda.sql) > **Run** (cria a coluna `campanhas.agenda_sync`) e depois [schema_campanhas_leads.sql](schema_campanhas_leads.sql) (envio aos leads).

### Passo 2 — Configure a Penso
O e-mail da CDL (`@cdlcuiaba.com.br`) fica na **Penso** (MX `pensomail.com.br`), não no Microsoft 365 — por isso o caminho é o **convite por e-mail pela Penso**. O tenant Microsoft `cdlcba.onmicrosoft.com` não tem licença do Exchange, então a opção Outlook/Graph (no fim desta seção) não se aplica hoje.

**Penso (convite por e-mail)** — só precisa de uma conta de e-mail da Penso para ser a organizadora (ex.: `agenda@cdlcuiaba.com.br`; os convites saem em nome dela e as respostas Aceitar/Recusar chegam nela):
1. Servidor SMTP: **`suitesmtp.penso.com.br`, porta `465` (SSL)**. As Edge Functions do Supabase **não podem usar as portas 25 e 587**; `smtp.pensomail.com.br` só atende na 587, por isso não serve. Se a conta for de outra plataforma da Penso, confirme com o suporte um servidor SMTP com **SSL na porta 465**.
2. Usuário = e-mail completo da conta; senha = a da conta (se a Penso exigir, gere uma "senha de aplicativo").
3. Secrets no Supabase: `PENSO_SMTP_HOST`, `PENSO_SMTP_USUARIO`, `PENSO_SMTP_SENHA` (opcionais: `PENSO_SMTP_PORTA`, padrão 465; `PENSO_REMETENTE`, padrão = usuário; `PENSO_REMETENTE_NOME`, padrão "Agenda CDL").
4. Teste: crie uma campanha com você como participante — deve chegar o e-mail "Convite: …" com Aceitar/Recusar.
5. **Agenda da conta organizadora:** além de enviar os convites, a função grava o evento na agenda da própria conta da Penso por **CalDAV** (`https://suite.penso.com.br/dav/<conta>/Calendar/`, mesmo usuário/senha). O evento aparece lá com os convidados listados na descrição (sem convidados formais, para o Zimbra não disparar convites em dobro). Editar regrava e remover apaga. Para outra pasta use o secret `PENSO_CALDAV_URL`; `PENSO_CALDAV_URL=off` desliga. Se a gravação falhar, os convites saem do mesmo jeito e a mensagem ao salvar avisa.

**Reserva (não usadas com a Penso configurada):** Google Calendar e Outlook/Exchange abaixo só entram em ação se os secrets da Penso forem removidos. Os secrets do Google podem continuar no Supabase — servem para cancelar os eventos antigos do Google na migração.

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

**Outlook (Microsoft 365 / Exchange Online)** — só para caixas hospedadas no Exchange Online (não é o caso da CDL hoje):
1. Portal do Azure > **Microsoft Entra ID > Registros de aplicativo > Novo registro** (nome: `CDLoad Agenda`, só contas deste diretório).
2. **Permissões de API > Adicionar > Microsoft Graph > Permissões de aplicativo > `Calendars.ReadWrite`** > **Conceder consentimento de administrador**.
3. **Certificados e segredos > Novo segredo do cliente** (anote o valor).
4. Escolha a caixa organizadora no Exchange Online. Recomendado: restringir o app só a essa caixa com uma *Application Access Policy* do Exchange (`New-ApplicationAccessPolicy -AppId <ID do app> -PolicyScopeGroupId agenda@... -AccessRight RestrictAccess`), senão o app pode escrever em qualquer agenda do tenant.

### Passo 3 — Publicar a função

**Pelo painel do Supabase (sem instalar nada):**
1. Abra os [Secrets das Edge Functions](https://supabase.com/dashboard/project/xjexujpvnahaugizeyee/functions/secrets) e adicione `PENSO_SMTP_HOST`, `PENSO_SMTP_USUARIO` e `PENSO_SMTP_SENHA`.
2. Copie o código da função: [sincronizar-agenda/index.ts no GitHub](https://github.com/Samuethus/Projeto_CDLOAD/blob/main/supabase/functions/sincronizar-agenda/index.ts) (botão *Copy raw file*) ou [neste repositório](functions/sincronizar-agenda/index.ts).
3. Abra a [função sincronizar-agenda no painel](https://supabase.com/dashboard/project/xjexujpvnahaugizeyee/functions/sincronizar-agenda) > aba **Code** > cole o código > **Deploy**. Se a função ainda não existir, crie em [Edge Functions](https://supabase.com/dashboard/project/xjexujpvnahaugizeyee/functions) > **Deploy a new function** > *Via Editor*, com o nome `sincronizar-agenda`.
4. Acompanhe os envios em [Logs da função](https://supabase.com/dashboard/project/xjexujpvnahaugizeyee/functions/sincronizar-agenda/logs).

**Pelo Supabase CLI:**
```bash
npx supabase login
npx supabase link --project-ref xjexujpvnahaugizeyee
# Penso (convite por e-mail) — a senha vai direto para o Supabase, nunca para o GitHub
npx supabase secrets set PENSO_SMTP_HOST=suitesmtp.penso.com.br PENSO_SMTP_USUARIO=agenda@cdlcuiaba.com.br PENSO_SMTP_SENHA='...'
# Google (reserva: só vale sem a Penso; mantenha para cancelar eventos antigos do Google)
npx supabase secrets set GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... GOOGLE_REFRESH_TOKEN=...
# Outlook / Exchange Online (só se um dia houver caixa no Exchange)
npx supabase secrets set MS_TENANT_ID=... MS_CLIENT_ID=... MS_CLIENT_SECRET=... MS_ORGANIZADOR_EMAIL=...
# Opcional: aceitar chamadas só do site publicado
npx supabase secrets set APP_ORIGIN=https://SEU-USUARIO.github.io
npx supabase functions deploy sincronizar-agenda
```
Os segredos ficam só no Supabase (nunca no `config.js` nem no GitHub). A função usa o login de quem salvou a campanha e só aceita quem tem a seção **Campanhas** liberada. Logs: Supabase > Edge Functions > sincronizar-agenda > Logs.

## Survey Monkey ao vivo (Edge Function `surveymonkey-sincronizar`)

Copia pastas, formulários, perguntas, coletores e respostas do Survey Monkey para as tabelas `survey_*`, a cada 15 minutos. Planejamento completo em [../surveymonkey/LEIA-ME.md](../surveymonkey/LEIA-ME.md).

1. **Secret:** `SURVEYMONKEY_TOKEN` (Access Token do app privado do Survey Monkey) em **Edge Functions > Secrets**.
2. **Publicar a função** (sem JWT: quem chama é o pg_cron; a função ignora chamadas a menos de 5 min da anterior):
   ```bash
   npx supabase login
   npx supabase link --project-ref xjexujpvnahaugizeyee
   npx supabase functions deploy surveymonkey-sincronizar --no-verify-jwt
   ```
3. **SQL:** em [schema_surveymonkey.sql](schema_surveymonkey.sql), troque as duas ocorrências de `SEU_PROJECT_REF` pelo id do projeto (Project Settings > General > Project ID) > cole no SQL Editor > **Run**. Rode **depois** do `schema_seguranca_rls.sql`.
4. **Conferir:** depois de alguns minutos, rode as consultas comentadas no fim do arquivo. A primeira carga traz todo o histórico e pode levar algumas execuções (cada uma tem ~2 min e respeita o limite de chamadas da API); `pendentes` chega a 0 quando terminar. Erros: coluna `erros` de `survey_sincronizacoes` e **Edge Functions > surveymonkey-sincronizar > Logs**.

## Dashboard › Panorama Econômico: atualização diária às 06:00 (pg_cron → GitHub Actions)

O cron do próprio GitHub atrasa horas. Para o Panorama estar atualizado às 06:00 de Brasília, o Supabase dispara o workflow `abve-diario.yml` às 05:45 (só as fontes do Panorama, que levam poucos minutos):

1. No GitHub, crie um token *fine-grained* só para o repositório `Samuethus/Projeto_CDLOAD`, com **Actions: Read and write**.
2. Cole o token em `schema_atualizacao_diaria.sql` (no lugar de `COLE_AQUI_O_TOKEN`) e rode o arquivo no SQL Editor. O token fica no Vault.
3. Confira na aba **Actions** do GitHub a execução disparada pelo teste do final do arquivo.

Sem este passo, o workflow continua rodando pelos agendamentos de reserva do próprio GitHub (02:23 e 05:37 de Brasília), sujeitos ao atraso.

## 3. Primeiro acesso do administrador

1. Abra o site, digite o e-mail do admin e uma **nova senha** (8+ caracteres) e clique em **Primeiro acesso**.
2. Confirme pelo e-mail recebido e entre normalmente.
3. Em **Usuários**, cadastre as demais pessoas (nome, e-mail, perfil e seções). Cada uma faz o **Primeiro acesso** com o próprio e-mail.

## 4. Trocar credenciais antigas

- As senhas que existiam em `usuarios.senha` e a `cdload2026` foram expostas: não reutilize.
- Se a chave anon ficou pública em algum momento, rotacione em Project Settings > API e atualize o secret `SUPABASE_ANON_KEY` do GitHub.

## Esqueci a senha

Não há tela própria ainda. Um administrador do projeto Supabase pode enviar o reset em Authentication > Users.
