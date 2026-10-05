# EXECUTÁVEL

Prompt / Instrução para Claude Code: Análise e Processamento do Controle de Estoque

Objetivo

Processar o conjunto de dados referente ao Controle de Estoque conforme apresentado no painel visual (dashboard) e gerar um relatório completo de análises, KPIs, sazonalidade, consumo por setor e padrão de movimentações/responsáveis.

1. Mapeamento das Métricas Gerais (KPIs Superiores)

Realizar o cálculo/extração dos seguintes indicadores consolidados:

Produtos Cadastrados: Total de SKUs únicos cadastrados (180).

Total de Entradas: Soma da quantidade de itens entrados no período (10.208).

Total de Saídas: Soma da quantidade de itens saídos no período (6.440).

Saldo em Estoque (Quantidade Atual): Diferença entre entradas e saídas (3.768 ~ 4 Mil).

2. Análise Temporal: Valor Gasto na Compra por Mês

Analisar a evolução financeira de compras mês a mês, identificando variações percentuais em relação ao mês anterior (MoM - Month over Month):

Janeiro: R$ 3.271,67 (+55,7%)

Fevereiro: R$ 6.167,84 (+88,5%) — Pico de compras no semestre

Março: R$ 2.804,03 (-54,5%) — Forte redução pós-pico

Abril: R$ 4.094,51 (+46,0%)

Maio: R$ 3.901,21 (-4,7%)

Junho: R$ 3.967,49 (+1,7%)

Tarefas da Análise Temporal:

Calcular o Gasto Total Acumulado no Semestre.

Calcular o Gasto Médio Mensal.

Identificar os meses de maior volatilidade (Fevereiro e Março) e correlacionar com o volume de entradas do período.

3. Análise Financeira por Setor (Alocação de Custos)

Mapear a distribuição do valor gasto/utilizado entre as unidades organizacionais:

Térreo: R$ 7.099,80 (Maior centro de custo)

2º Piso: R$ 6.517,01

Certificado Digital: R$ 3.144,21

1º Piso: R$ 1.271,23

Estoque Central: R$ 175,33

Diretoria: R$ 121,88

Tarefas de Alocação:

Calcular a participação percentual (%) de cada setor em relação ao custo total.

Agrupar os setores por representatividade (ex: Térreo + 2º Piso concentram a grande maioria do consumo financeiro).

4. Análise do Fluxo de Produtos (Entradas vs. Saídas)

4.1. Análise de Entradas (Volume e Valor)

Analisar a tabela de entradas mapeando:

Top produtos em quantidade movimentada (ex: Mexedor de Café com 4.550 un., Elástico de Dinheiro com 1.200 un., Saco de Lixo 30L com 470 un.).

Top produtos em valor investido (ex: Papel Higiênico Rolão R$ 3.103, Cafés R$ 3.108, Papel Toalha Bobina R$ 3.120, Resma A4 R$ 1.318, Capuccino R$ 1.539).

4.2. Análise de Saídas e Requisições

Analisar a tabela de saídas mapeando:

Frequência e volume de saídas dos produtos consumíveis (Mexedor de café, Papel Higiênico, Sacos de Lixo, Cafés, Copos Descartáveis).

Mapeamento dos Funcionários Solicitantes/Responsáveis pela Saída (ex: Jucilene, Matheus, Rosália, Gleiciane, Rosa, Laura).

5. Mapeamento de Oportunidades e Riscos (Insights de Negócio)

Ao processar os dados acima, gerar um relatório executivo destacando:

Curva ABC de Estoque: Quais itens representam 80% do valor gasto (Ex: Papéis, Cafés, Insumos de Escritório).

Gargalos e Discrepâncias:

Divergência entre volume de entradas x consumo imediato.

Concentração de requisições por poucos funcionários/setores.

Recomendações Práticas:

Política de estoque mínimo para itens essenciais de higienização e consumo diário.

Otimização de compras para evitar grandes picos (como o ocorrido em Fevereiro).