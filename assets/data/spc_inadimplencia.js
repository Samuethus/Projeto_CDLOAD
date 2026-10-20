// Dashboard › Panorama Econômico › SPC: Inadimplência.
// Fonte: relatórios do SPC Brasil anexados na seção Inadimplência (PDF), lidos e transcritos à mão:
//   relat_inadimplencia_MT_<mês>.pdf ............ "Inadimplência no Mato Grosso" (mt)
//   Análise-Inadimplência-BReRegiões-PF_<mês>.pdf  "Inadimplência de Pessoas Físicas" — Brasil e regiões (br)
//   Cuiabá-MT_<mês>.pdf ......................... "Inadimplência em Cuiabá/MT" (cuiaba) — mesmo formato do MT
// 2026 (pasta "2. Pesquisa CDL/2. Relatório Inadimplencia/2026" do OneDrive): Brasil PF em todos os meses (jan–set),
// Mato Grosso de mai a set e Cuiabá de jun a set; os meses sem o relatório ficam sem a abrangência.
// Atenção: o PDF Brasil de mai/2026 traz no Gráfico 12 a legenda "(ref. abr/2026)" por engano — o texto diz maio.
// O relatório de Pessoas Jurídicas (Análise-Inadimplência-BReRegiões-PJ_<mês>.pdf) não entra neste painel.
//
// Para incluir uma edição nova: copie um bloco de edicoes, troque a chave ('AAAA-MM' = mês de referência dos
// dados) e os números, e acrescente o mês em `meses`. Percentuais em % (7.61 = 7,61%), valores em R$.
//
// Campos (por abrangência):
//   devedores / dividas   { anual: variação contra o mesmo mês do ano anterior, mensal: contra o mês anterior }
//   dividaMedia           R$ devidos por consumidor negativado (soma das dívidas)
//   dividasPorDevedor     dívidas em atraso por inadimplente (no Brasil, "empresas credoras por inadimplente")
//   atrasoMeses · idadeMedia · sexo { homens, mulheres } (% dos inadimplentes)
//   faixaEtaria  [18–24, 25–29, 30–39, 40–49, 50–64, 65–84, 85+] (% dos inadimplentes)
//   valor        [até R$ 500, R$ 500,01–1.000, R$ 1.000,01–2.500, R$ 2.500,01–7.500, acima de R$ 7.500]
//   atraso       [até 90 dias, 91 dias a 1 ano, 1 a 3 anos, 3 a 4 anos, 4 a 5 anos] · atrasoAnual (só Brasil)
//   setor        participação no número de dívidas por setor credor · setorAnual (só Brasil)
//   comparativo  (Mato Grosso) Centro-Oeste e Brasil no mesmo mês
//   regioes      (Brasil) variação por região + estimativa de negativados (milhões e % da população adulta)
//                — negativadosMi e popAdulta vêm do "Gráfico 12 - Estimativa de inadimplentes" (mapa do Brasil, pág. 5
//                do PDF Brasil: "Norte: 6,86 milhões (48,45% da população adulta)"...). Alimentam a visão Gráfico do
//                painel (switch Dashboard | Gráfico, filtro Região): uma linha por região ao longo das edições.
//                O Gráfico também LÊ SOZINHO esse mapa em todo PDF de abrangência Brasil anexado na seção Inadimplência
//                (pdf.js no navegador, sem API; cache no IndexedDB) — basta anexar o PDF para a edição entrar na linha.
//                O que está transcrito aqui vale quando o PDF não pode ser lido (sem acesso à seção, PDF fora do padrão).
//   mensal       (visão Gráfico) tabelas mensais anexadas na seção ("Inadimplência Mensal 2025 · Janeiro Centro-Oeste 45,78%"),
//                também lidas sozinhas dos PDFs; aqui ficam como reserva. Comparativo jan–dez de um ano contra o anterior.
//   estimativa   (Brasil) negativados no país e por faixa etária [milhões, % da população da faixa]
//   historico    (Brasil) variação mensal do mesmo mês nos últimos 10 anos (devedores e dívidas)
window.SPC_INAD = {
  fonte: 'SPC Brasil',
  atualizado: '2026-10-20',
  locais: { cuiaba: 'Cuiabá', mt: 'Mato Grosso', br: 'Brasil' },
  faixas: ['18 a 24 anos', '25 a 29 anos', '30 a 39 anos', '40 a 49 anos', '50 a 64 anos', '65 a 84 anos', '85 anos ou mais'],
  valores: ['Até R$ 500', 'R$ 500,01 a R$ 1.000', 'R$ 1.000,01 a R$ 2.500', 'R$ 2.500,01 a R$ 7.500', 'Acima de R$ 7.500'],
  atrasos: ['Até 90 dias', '91 dias a 1 ano', '1 a 3 anos', '3 a 4 anos', '4 a 5 anos'],
  meses: ['2025-11', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09'],
  // Séries mensais de % da população adulta negativada (visão Gráfico, comparativo ano a ano). Reserva do que o painel lê
  // sozinho da tabela mensal anexada na seção Inadimplência. Atenção: a tabela de 2025 usa base de 2.608.340 adultos
  // (ordem de grandeza de Mato Grosso, não do Centro-Oeste) e difere do SPC Brasil em nov/2025 (45,00% x 47,08%);
  // dezembro foi digitado à mão na planilha de origem (Dados_Inadimplência_2025.xlsx). Usada como Centro-Oeste por decisão do usuário.
  mensal: [
    { local: 'Centro-Oeste', arquivo: 'Inadimplencia_2024_Centro-Oeste.pdf', meses: {   // pasta Janeiro 2024 da seção
      '2024-01': 44.76, '2024-02': 46.14, '2024-03': 46.03, '2024-04': 45.31, '2024-05': 43.82, '2024-06': 43.38,
      '2024-07': 43.83, '2024-08': 43.78, '2024-09': 43.85, '2024-10': 44.57, '2024-11': 45.01, '2024-12': 45.05 } },
    { local: 'Centro-Oeste', arquivo: 'Inadimplencia_2025_Centro-Oeste.pdf', meses: {
      '2025-01': 45.78, '2025-02': 45.77, '2025-03': 46.95, '2025-04': 46.93, '2025-05': 46.55, '2025-06': 46.33,
      '2025-07': 43.81, '2025-08': 43.87, '2025-09': 44.22, '2025-10': 44.68, '2025-11': 45.00, '2025-12': 45.80 } }
    // 2026 não usa mais tabela mensal: cada mês sai do Gráfico 12 do relatório Brasil PF do mês (edicoes['2026-MM'].br).
  ],
  edicoes: {
    '2025-11': {
      mt: {
        arquivo: 'relat_inadimplencia_MT_nov2025.pdf',
        devedores: { anual: 6.75, mensal: 0.72 }, dividas: { anual: 12.12, mensal: 1.03 },
        dividaMedia: 5514.01, dividasPorDevedor: 2.310, atrasoMeses: 27.4, idadeMedia: 43.8,
        sexo: { homens: 53.45, mulheres: 46.55 },
        faixaEtaria: [7.48, 12.33, 26.81, 22.48, 19.52, 9.89, 1.33],
        valor: [26.24, 12.97, 20.02, 21.54, 19.24],
        atraso: [10.63, 17.00, 36.08, 17.67, 18.62],
        setor: { 'Bancos': 52.50, 'Comércio': 22.96, 'Água e Luz': 10.56, 'Outros': 9.81, 'Comunicação': 4.17 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 7.27, devedoresMensal: 0.88, dividasAnual: 13.55, dividasMensal: 1.01, dividasPorDevedor: 2.348 },
          'Brasil': { devedoresAnual: 8.93, devedoresMensal: 1.29, dividasAnual: 14.81, dividasMensal: 0.92, dividasPorDevedor: 2.227 }
        }
      },
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_nov2025.pdf',
        devedores: { anual: 8.93, mensal: 1.29 }, dividas: { anual: 14.81, mensal: 0.92 },
        dividaMedia: 4781.98, dividasPorDevedor: 2.23, atrasoMeses: 28.5, idadeMedia: 45.1,
        sexo: { homens: 48.79, mulheres: 51.21 },
        faixaEtaria: [8.00, 11.66, 23.41, 21.22, 20.31, 12.05, 2.08],
        valor: [30.95, 13.02, 18.89, 20.03, 17.11],
        atraso: [8.89, 16.86, 35.09, 19.70, 19.46],
        atrasoAnual: [12.64, 7.59, -5.32, 21.43, 30.12],
        setor: { 'Bancos': 65.24, 'Água e Luz': 10.79, 'Comércio': 9.19, 'Outros': 9.11, 'Comunicação': 5.67 },
        setorAnual: { 'Água e Luz': 23.78, 'Comércio': 0.90, 'Comunicação': 9.93, 'Bancos': 14.76, 'Outros': 25.36 },
        regioes: {
          'Norte':        { devedoresMensal: 0.83, devedoresAnual: 8.62, dividasMensal: 1.18,  dividasAnual: 16.01, negativadosMi: 6.53,  popAdulta: 46.57 },
          'Nordeste':     { devedoresMensal: 0.44, devedoresAnual: 6.76, dividasMensal: -0.79, dividasAnual: 11.09, negativadosMi: 19.26, popAdulta: 43.82 },
          'Centro-Oeste': { devedoresMensal: 0.88, devedoresAnual: 7.27, dividasMensal: 1.01,  dividasAnual: 13.55, negativadosMi: 6.19,  popAdulta: 47.08 },
          'Sudeste':      { devedoresMensal: 1.81, devedoresAnual: 7.56, dividasMensal: 1.63,  dividasAnual: 14.48, negativadosMi: 31.35, popAdulta: 43.88 },
          'Sul':          { devedoresMensal: 1.82, devedoresAnual: 9.22, dividasMensal: 1.93,  dividasAnual: 16.00, negativadosMi: 9.62,  popAdulta: 39.70 }
        },
        estimativa: { negativadosMi: 72.96, popAdulta: 43.74,
          faixaEtaria: [[6.49, 30.07], [8.91, 52.24], [17.85, 52.61], [16.10, 49.77], [15.18, 41.60], [7.95, 34.54], [0.478, 20.10]] },
        historico: { meses: ['2016-11', '2017-11', '2018-11', '2019-11', '2020-11', '2021-11', '2022-11', '2023-11', '2024-11', '2025-11'],
          devedores: [0.13, 0.15, 1.90, 0.04, -1.38, 0.71, 1.12, 0.54, 0.89, 1.29],
          dividas: [-0.36, -0.14, 1.85, 0.07, -1.73, 1.60, 2.06, 0.42, 0.59, 0.92] }
      }
    },
    '2026-01': {
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_jan2026.pdf',
        devedores: { anual: 9.39, mensal: 0.85 }, dividas: { anual: 15.76, mensal: 1.88 },
        dividaMedia: 4898.02, dividasPorDevedor: 2.26, atrasoMeses: 28.8, idadeMedia: 45.2,
        sexo: { homens: 48.73, mulheres: 51.27 },
        faixaEtaria: [7.88, 11.54, 23.34, 21.22, 20.50, 12.20, 2.09],
        valor: [30.65, 12.78, 18.81, 20.14, 17.64],
        atraso: [8.53, 16.45, 35.47, 19.42, 20.13],
        atrasoAnual: [10.26, 8.10, -3.73, 16.80, 34.30],
        setor: { 'Bancos': 65.59, 'Água e Luz': 11.00, 'Outros': 9.14, 'Comércio': 8.84, 'Comunicação': 5.44 },
        setorAnual: { 'Água e Luz': 24.81, 'Comércio': 1.80, 'Comunicação': 9.71, 'Bancos': 15.08, 'Outros': 31.70 },
        regioes: {
          'Norte':        { devedoresMensal: 0.96,  devedoresAnual: 8.70,  dividasMensal: 2.07,  dividasAnual: 16.24, negativadosMi: 6.60,  popAdulta: 46.94 },
          'Nordeste':     { devedoresMensal: 0.19,  devedoresAnual: 7.06,  dividasMensal: 1.38,  dividasAnual: 12.30, negativadosMi: 19.27, popAdulta: 43.78 },
          'Centro-Oeste': { devedoresMensal: 0.82,  devedoresAnual: 7.42,  dividasMensal: 1.92,  dividasAnual: 14.35, negativadosMi: 6.23,  popAdulta: 47.31 },
          'Sudeste':      { devedoresMensal: 1.15,  devedoresAnual: 8.89,  dividasMensal: 2.15,  dividasAnual: 15.93, negativadosMi: 31.61, popAdulta: 44.19 },
          'Sul':          { devedoresMensal: 0.49,  devedoresAnual: 9.33,  dividasMensal: 1.48,  dividasAnual: 16.58, negativadosMi: 9.58,  popAdulta: 39.51 }
        },
        estimativa: { negativadosMi: 73.30, popAdulta: 43.88,
          faixaEtaria: [[6.42, 29.83], [8.86, 52.04], [17.87, 52.71], [16.18, 49.90], [15.40, 42.06], [8.09, 34.92], [0.482, 20.13]] },
        historico: { meses: ['2017-01', '2018-01', '2019-01', '2020-01', '2021-01', '2022-01', '2023-01', '2024-01', '2025-01', '2026-01'],
          devedores: [0.13, 0.96, -0.97, 0.58, -0.37, 1.54, 0.56, 0.75, 1.57, 0.85],
          dividas: [0.07, 0.87, -2.11, 0.71, -0.34, 2.91, 1.42, 1.46, 3.09, 1.88] }
      }
    },
    '2026-02': {
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_fev2026.pdf',
        devedores: { anual: 10.22, mensal: 0.71 }, dividas: { anual: 17.76, mensal: 2.28 },
        dividaMedia: 4992.43, dividasPorDevedor: 2.29, atrasoMeses: 28.9, idadeMedia: 45.2,
        sexo: { homens: 48.65, mulheres: 51.35 },
        faixaEtaria: [7.92, 11.56, 23.39, 21.22, 20.47, 12.13, 2.06],
        valor: [29.90, 12.60, 18.96, 20.49, 18.05],
        atraso: [8.21, 16.36, 35.48, 19.44, 20.51],
        atrasoAnual: [12.13, 8.47, -2.45, 15.01, 36.25],
        setor: { 'Bancos': 66.22, 'Água e Luz': 10.56, 'Outros': 9.04, 'Comércio': 8.67, 'Comunicação': 5.51 },
        setorAnual: { 'Água e Luz': 27.28, 'Comércio': 2.14, 'Comunicação': 14.82, 'Bancos': 17.26, 'Outros': 31.79 },
        regioes: {
          'Norte':        { devedoresMensal: 0.68,  devedoresAnual: 9.16,  dividasMensal: 2.08,  dividasAnual: 17.96, negativadosMi: 6.65,  popAdulta: 47.24 },
          'Nordeste':     { devedoresMensal: 0.64,  devedoresAnual: 7.58,  dividasMensal: 2.01,  dividasAnual: 14.18, negativadosMi: 19.41, popAdulta: 44.05 },
          'Centro-Oeste': { devedoresMensal: 0.71,  devedoresAnual: 7.67,  dividasMensal: 2.00,  dividasAnual: 15.41, negativadosMi: 6.28,  popAdulta: 47.62 },
          'Sudeste':      { devedoresMensal: 0.43,  devedoresAnual: 9.80,  dividasMensal: 2.35,  dividasAnual: 18.02, negativadosMi: 31.76, popAdulta: 44.36 },
          'Sul':          { devedoresMensal: 0.61,  devedoresAnual: 9.81,  dividasMensal: 2.06,  dividasAnual: 18.11, negativadosMi: 9.65,  popAdulta: 39.75 }
        },
        estimativa: { negativadosMi: 73.74, popAdulta: 44.11,
          faixaEtaria: [[6.49, 30.18], [8.93, 52.47], [18.01, 53.12], [16.27, 50.15], [15.46, 42.18], [8.09, 34.84], [0.482, 20.05]] },
        historico: { meses: ['2017-02', '2018-02', '2019-02', '2020-02', '2021-02', '2022-02', '2023-02', '2024-02', '2025-02', '2026-02'],
          devedores: [-0.05, 0.55, -0.08, -0.22, -0.17, 0.70, 0.47, -0.49, -0.04, 0.71],
          dividas: [-0.35, 0.40, -0.33, -0.11, -0.30, 1.72, 1.32, -0.20, 0.54, 2.28] }
      }
    },
    '2026-03': {
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_mar2026.pdf',
        devedores: { anual: 9.54, mensal: 0.92 }, dividas: { anual: 17.31, mensal: 1.65 },
        dividaMedia: 5044.65, dividasPorDevedor: 2.31, atrasoMeses: 28.8, idadeMedia: 45.2,
        sexo: { homens: 48.60, mulheres: 51.40 },
        faixaEtaria: [8.06, 11.67, 23.65, 21.48, 20.73, 12.31, 2.10],
        valor: [29.79, 12.44, 18.90, 20.60, 18.27],
        atraso: [8.75, 16.25, 35.20, 19.25, 20.55],
        atrasoAnual: [8.91, 7.11, -2.08, 12.68, 36.54],
        setor: { 'Bancos': 66.39, 'Água e Luz': 10.63, 'Outros': 9.08, 'Comércio': 8.49, 'Comunicação': 5.41 },
        setorAnual: { 'Água e Luz': 26.32, 'Comércio': 2.34, 'Comunicação': 12.51, 'Bancos': 16.70, 'Outros': 32.78 },
        regioes: {
          'Norte':        { devedoresMensal: 1.24,  devedoresAnual: 9.73,  dividasMensal: 2.21,  dividasAnual: 19.14, negativadosMi: 6.74,  popAdulta: 47.81 },
          'Nordeste':     { devedoresMensal: 0.87,  devedoresAnual: 6.60,  dividasMensal: 1.84,  dividasAnual: 13.67, negativadosMi: 19.59, popAdulta: 44.43 },
          'Centro-Oeste': { devedoresMensal: 0.82,  devedoresAnual: 6.71,  dividasMensal: 1.52,  dividasAnual: 14.35, negativadosMi: 6.33,  popAdulta: 47.99 },
          'Sudeste':      { devedoresMensal: 0.44,  devedoresAnual: 8.97,  dividasMensal: 1.07,  dividasAnual: 17.24, negativadosMi: 31.90, popAdulta: 44.53 },
          'Sul':          { devedoresMensal: 1.14,  devedoresAnual: 9.25,  dividasMensal: 1.72,  dividasAnual: 17.57, negativadosMi: 9.75,  popAdulta: 40.18 }
        },
        estimativa: { negativadosMi: 74.31, popAdulta: 44.42,
          faixaEtaria: [[6.56, 30.56], [8.97, 52.75], [18.12, 53.45], [16.39, 50.46], [15.59, 42.47], [8.18, 35.12], [0.492, 20.41]] },
        historico: { meses: ['2017-03', '2018-03', '2019-03', '2020-03', '2021-03', '2022-03', '2023-03', '2024-03', '2025-03', '2026-03'],
          devedores: [0.44, 0.85, 1.19, 1.95, 2.09, 0.23, 1.01, 0.89, 1.54, 0.92],
          dividas: [0.24, 1.08, 1.01, 1.78, 1.90, 0.30, 1.81, 0.47, 2.05, 1.65] }
      }
    },
    '2026-04': {
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_abr2026.pdf',
        devedores: { anual: 9.25, mensal: 0.81 }, dividas: { anual: 16.99, mensal: 1.94 },
        dividaMedia: 5111.64, dividasPorDevedor: 2.34, atrasoMeses: 28.9, idadeMedia: 45.2,
        sexo: { homens: 48.61, mulheres: 51.39 },
        faixaEtaria: [8.11, 11.65, 23.63, 21.48, 20.73, 12.29, 2.10],
        valor: [29.40, 12.35, 18.86, 20.82, 18.57],
        atraso: [8.46, 16.45, 35.12, 19.17, 20.79],
        atrasoAnual: [4.14, 8.28, -1.75, 10.63, 37.32],
        setor: { 'Bancos': 66.65, 'Água e Luz': 10.23, 'Outros': 9.16, 'Comércio': 8.43, 'Comunicação': 5.53 },
        setorAnual: { 'Água e Luz': 22.38, 'Comércio': 2.35, 'Comunicação': 17.73, 'Bancos': 16.47, 'Outros': 31.65 },
        regioes: {
          'Norte':        { devedoresMensal: 1.85,  devedoresAnual: 10.48, dividasMensal: 2.85,  dividasAnual: 19.67, negativadosMi: 6.86,  popAdulta: 48.58 },
          'Nordeste':     { devedoresMensal: 0.47,  devedoresAnual: 6.52,  dividasMensal: 1.70,  dividasAnual: 13.65, negativadosMi: 19.69, popAdulta: 44.64 },
          'Centro-Oeste': { devedoresMensal: 0.47,  devedoresAnual: 6.66,  dividasMensal: 1.68,  dividasAnual: 14.39, negativadosMi: 6.37,  popAdulta: 48.21 },
          'Sudeste':      { devedoresMensal: 0.33,  devedoresAnual: 8.00,  dividasMensal: 1.50,  dividasAnual: 16.24, negativadosMi: 32.02, popAdulta: 44.67 },
          'Sul':          { devedoresMensal: 1.38,  devedoresAnual: 9.97,  dividasMensal: 2.37,  dividasAnual: 18.09, negativadosMi: 9.88,  popAdulta: 40.69 }
        },
        estimativa: { negativadosMi: 74.82, popAdulta: 44.69,
          faixaEtaria: [[6.64, 30.95], [9.01, 53.04], [18.23, 53.77], [16.50, 50.74], [15.70, 42.71], [8.25, 35.28], [0.496, 20.48]] },
        historico: { meses: ['2017-04', '2018-04', '2019-04', '2020-04', '2021-04', '2022-04', '2023-04', '2024-04', '2025-04', '2026-04'],
          devedores: [-0.35, 0.04, 0.78, 1.68, 0.98, 0.46, 0.23, 0.40, 1.09, 0.81],
          dividas: [-1.94, -0.30, 1.23, 1.38, 1.81, 0.85, 0.20, 0.52, 2.22, 1.94] }
      }
    },
    '2026-05': {
      mt: {
        arquivo: 'relat_inadimplencia_MT_mai2026.pdf',
        devedores: { anual: 7.22, mensal: 0.73 }, dividas: { anual: 13.13, mensal: 1.23 },
        dividaMedia: 6036.00, dividasPorDevedor: 2.406, atrasoMeses: 28.3, idadeMedia: 44.0,
        sexo: { homens: 53.41, mulheres: 46.59 },
        faixaEtaria: [7.06, 11.93, 26.88, 22.77, 19.98, 9.94, 1.29],
        valor: [23.78, 12.28, 20.16, 22.57, 21.21],
        atraso: [9.21, 16.92, 35.38, 18.12, 20.37],
        setor: { 'Bancos': 54.80, 'Comércio': 21.52, 'Outros': 10.48, 'Água e Luz': 9.22, 'Comunicação': 3.99 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 7.08, devedoresMensal: 0.46, dividasAnual: 14.08, dividasMensal: 0.55, dividasPorDevedor: 2.462 },
          'Brasil': { devedoresAnual: 8.87, devedoresMensal: 0.44, dividasAnual: 15.64, dividasMensal: 0.41, dividasPorDevedor: 2.336 }
        }
      },
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_mai2026.pdf',
        devedores: { anual: 8.87, mensal: 0.44 }, dividas: { anual: 15.64, mensal: 0.41 },
        dividaMedia: 5145.04, dividasPorDevedor: 2.34, atrasoMeses: 28.9, idadeMedia: 45.3,
        sexo: { homens: 48.66, mulheres: 51.34 },
        faixaEtaria: [8.00, 11.55, 23.56, 21.53, 20.86, 12.37, 2.13],
        valor: [29.19, 12.33, 18.87, 20.91, 18.70],
        atraso: [8.58, 16.67, 34.61, 18.71, 21.43],
        atrasoAnual: [13.60, 6.35, -2.03, 5.10, 38.35],
        setor: { 'Bancos': 66.19, 'Água e Luz': 10.68, 'Outros': 9.25, 'Comércio': 8.24, 'Comunicação': 5.63 },
        setorAnual: { 'Água e Luz': 24.93, 'Comércio': -0.22, 'Comunicação': 16.22, 'Bancos': 14.63, 'Outros': 30.75 },
        regioes: {
          'Norte':        { devedoresMensal: 0.03,  devedoresAnual: 9.52,  dividasMensal: -0.01, dividasAnual: 17.49, negativadosMi: 6.85,  popAdulta: 48.48 },
          'Nordeste':     { devedoresMensal: 0.36,  devedoresAnual: 6.04,  dividasMensal: 0.39,  dividasAnual: 12.28, negativadosMi: 19.74, popAdulta: 44.71 },
          'Centro-Oeste': { devedoresMensal: 0.46,  devedoresAnual: 7.08,  dividasMensal: 0.55,  dividasAnual: 14.08, negativadosMi: 6.39,  popAdulta: 48.32 },
          'Sudeste':      { devedoresMensal: 0.65,  devedoresAnual: 7.94,  dividasMensal: 0.58,  dividasAnual: 15.09, negativadosMi: 32.17, popAdulta: 44.86 },
          'Sul':          { devedoresMensal: 0.42,  devedoresAnual: 9.86,  dividasMensal: 0.21,  dividasAnual: 16.88, negativadosMi: 9.91,  popAdulta: 40.78 }
        },
        estimativa: { negativadosMi: 75.06, popAdulta: 44.80,
          faixaEtaria: [[6.57, 30.70], [8.97, 52.83], [18.23, 53.79], [16.59, 50.97], [15.86, 43.06], [8.33, 35.53], [0.504, 20.76]] },
        historico: { meses: ['2017-05', '2018-05', '2019-05', '2020-05', '2021-05', '2022-05', '2023-05', '2024-05', '2025-05', '2026-05'],
          devedores: [1.31, 0.57, 0.07, -0.85, 0.59, 0.80, 2.05, -0.82, 0.78, 0.44],
          dividas: [2.40, 0.90, 0.75, -1.11, 0.90, 1.71, 3.82, -0.61, 1.59, 0.41] }
      }
    },
    '2026-06': {
      cuiaba: {
        arquivo: 'Cuiabá-MT_jun26 (002).pdf',
        devedores: { anual: 5.05, mensal: -0.65 }, dividas: { anual: 10.64, mensal: -0.97 },
        dividaMedia: 6577.36, dividasPorDevedor: 2.49, atrasoMeses: 29.3, idadeMedia: 45.4,
        sexo: { homens: 52.04, mulheres: 47.96 },
        faixaEtaria: [5.67, 10.56, 25.45, 23.62, 21.66, 11.44, 1.44],
        valor: [23.09, 11.86, 19.68, 22.05, 23.32],
        atraso: [8.07, 16.86, 34.40, 17.94, 22.73],
        setor: { 'Bancos': 60.66, 'Comércio': 14.72, 'Outros': 11.82, 'Água e Luz': 9.88, 'Comunicação': 2.92 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 6.89, devedoresMensal: 0.22, dividasAnual: 12.69, dividasMensal: -0.20, dividasPorDevedor: 2.45 },
          'Brasil': { devedoresAnual: 7.55, devedoresMensal: -0.30, dividasAnual: 13.32, dividasMensal: -0.59, dividasPorDevedor: 2.33 }
        }
      },
      mt: {
        arquivo: 'relat_inadimplencia_MT_jun2026.pdf',
        devedores: { anual: 7.61, mensal: -0.10 }, dividas: { anual: 12.84, mensal: -0.22 },
        dividaMedia: 6026.45, dividasPorDevedor: 2.403, atrasoMeses: 28.5, idadeMedia: 44.0,
        sexo: { homens: 53.44, mulheres: 46.56 },
        faixaEtaria: [7.18, 11.96, 26.81, 22.73, 19.94, 9.92, 1.30],
        valor: [23.94, 12.29, 20.09, 22.49, 21.19],
        atraso: [9.10, 17.01, 35.17, 17.73, 20.99],
        setor: { 'Bancos': 54.30, 'Comércio': 21.69, 'Outros': 10.60, 'Água e Luz': 9.39, 'Comunicação': 4.02 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 6.89, devedoresMensal: 0.22, dividasAnual: 12.69, dividasMensal: -0.20, dividasPorDevedor: 2.452 },
          'Brasil': { devedoresAnual: 7.55, devedoresMensal: -0.30, dividasAnual: 13.32, dividasMensal: -0.59, dividasPorDevedor: 2.33 }
        }
      },
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_jun2026.pdf',
        devedores: { anual: 7.55, mensal: -0.30 }, dividas: { anual: 13.32, mensal: -0.59 },
        dividaMedia: 5152.52, dividasPorDevedor: 2.33, atrasoMeses: 29.1, idadeMedia: 45.3,
        sexo: { homens: 48.66, mulheres: 51.34 },
        faixaEtaria: [8.05, 11.55, 23.54, 21.52, 20.85, 12.35, 2.14],
        valor: [29.23, 12.31, 18.84, 20.87, 18.75],
        atraso: [8.17, 16.93, 34.55, 18.08, 22.27],
        atrasoAnual: [6.64, 6.48, -0.90, -2.04, 38.32],
        setor: { 'Bancos': 65.76, 'Água e Luz': 10.78, 'Outros': 9.45, 'Comércio': 8.29, 'Comunicação': 5.72 },
        setorAnual: { 'Água e Luz': 22.16, 'Comércio': -0.14, 'Comunicação': 17.16, 'Bancos': 11.42, 'Outros': 30.98 },
        regioes: {
          'Norte':        { devedoresMensal: 0.05,  devedoresAnual: 8.57,  dividasMensal: -0.29, dividasAnual: 15.45, negativadosMi: 6.86,  popAdulta: 48.45 },
          'Nordeste':     { devedoresMensal: -0.44, devedoresAnual: 3.96,  dividasMensal: -0.81, dividasAnual: 9.10,  negativadosMi: 19.65, popAdulta: 44.48 },
          'Centro-Oeste': { devedoresMensal: 0.22,  devedoresAnual: 6.89,  dividasMensal: -0.20, dividasAnual: 12.69, negativadosMi: 6.40,  popAdulta: 48.34 },
          'Sudeste':      { devedoresMensal: -0.41, devedoresAnual: 6.43,  dividasMensal: -0.71, dividasAnual: 12.48, negativadosMi: 32.04, popAdulta: 44.65 },
          'Sul':          { devedoresMensal: -0.56, devedoresAnual: 10.67, dividasMensal: -0.64, dividasAnual: 17.06, negativadosMi: 9.86,  popAdulta: 40.53 }
        },
        estimativa: { negativadosMi: 74.80, popAdulta: 44.62,
          faixaEtaria: [[6.58, 30.77], [8.94, 52.70], [18.15, 53.55], [16.53, 50.73], [15.80, 42.85], [8.30, 35.28], [0.506, 20.78]] },
        historico: { meses: ['2017-06', '2018-06', '2019-06', '2020-06', '2021-06', '2022-06', '2023-06', '2024-06', '2025-06', '2026-06'],
          devedores: [-0.64, 0.61, -0.08, -2.51, -0.05, 0.64, -1.00, -0.43, 0.93, -0.30],
          dividas: [-1.12, 0.45, -0.82, -2.95, -0.11, 1.65, -1.46, -0.06, 1.44, -0.59] }
      }
    },
    '2026-07': {
      cuiaba: {
        arquivo: 'Cuiabá-MT_jul26.pdf',
        devedores: { anual: 4.86, mensal: 0.25 }, dividas: { anual: 11.58, mensal: 1.13 },
        dividaMedia: 6699.75, dividasPorDevedor: 2.51, atrasoMeses: 29.4, idadeMedia: 45.5,
        sexo: { homens: 52.03, mulheres: 47.97 },
        faixaEtaria: [5.66, 10.45, 25.43, 23.69, 21.72, 11.46, 1.43],
        valor: [22.60, 11.69, 19.63, 22.22, 23.86],
        atraso: [7.82, 17.16, 34.25, 17.38, 23.40],
        setor: { 'Bancos': 61.13, 'Comércio': 14.57, 'Outros': 11.98, 'Água e Luz': 9.43, 'Comunicação': 2.89 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 6.34, devedoresMensal: 0.26, dividasAnual: 12.53, dividasMensal: 0.87, dividasPorDevedor: 2.47 },
          'Brasil': { devedoresAnual: 7.80, devedoresMensal: 0.47, dividasAnual: 14.18, dividasMensal: 1.07, dividasPorDevedor: 2.34 }
        }
      },
      mt: {
        arquivo: 'relat_inadimplencia_MT_jul2026.pdf',
        devedores: { anual: 6.50, mensal: -0.06 }, dividas: { anual: 12.63, mensal: 0.69 },
        dividaMedia: 6145.15, dividasPorDevedor: 2.421, atrasoMeses: 28.7, idadeMedia: 44.0,
        sexo: { homens: 53.44, mulheres: 46.56 },
        faixaEtaria: [7.19, 11.94, 26.85, 22.77, 19.90, 9.91, 1.28],
        valor: [23.42, 12.13, 20.11, 22.68, 21.67],
        atraso: [8.55, 17.30, 35.12, 17.34, 21.69],
        setor: { 'Bancos': 54.81, 'Comércio': 21.54, 'Outros': 10.72, 'Água e Luz': 8.90, 'Comunicação': 4.02 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 6.34, devedoresMensal: 0.26, dividasAnual: 12.53, dividasMensal: 0.87, dividasPorDevedor: 2.467 },
          'Brasil': { devedoresAnual: 7.80, devedoresMensal: 0.47, dividasAnual: 14.18, dividasMensal: 1.07, dividasPorDevedor: 2.343 }
        }
      },
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_jul2026.pdf',
        devedores: { anual: 7.80, mensal: 0.47 }, dividas: { anual: 14.18, mensal: 1.07 },
        dividaMedia: 5205.30, dividasPorDevedor: 2.34, atrasoMeses: 29.2, idadeMedia: 45.3,
        sexo: { homens: 48.61, mulheres: 51.39 },
        faixaEtaria: [8.04, 11.51, 23.51, 21.53, 20.88, 12.40, 2.13],
        valor: [28.94, 12.22, 18.84, 21.01, 18.98],
        atraso: [8.13, 17.11, 34.37, 17.54, 22.84],
        atrasoAnual: [10.34, 6.34, 0.82, -6.56, 38.97],
        setor: { 'Bancos': 65.91, 'Água e Luz': 10.63, 'Outros': 9.58, 'Comércio': 8.21, 'Comunicação': 5.67 },
        setorAnual: { 'Água e Luz': 22.00, 'Comércio': -0.55, 'Comunicação': 12.62, 'Bancos': 12.92, 'Outros': 32.95 },
        regioes: {
          'Norte':        { devedoresMensal: 0.48,  devedoresAnual: 9.07,  dividasMensal: 0.97,  dividasAnual: 16.18, negativadosMi: 6.89,  popAdulta: 48.60 },
          'Nordeste':     { devedoresMensal: 0.69,  devedoresAnual: 4.88,  dividasMensal: 1.42,  dividasAnual: 10.81, negativadosMi: 19.76, popAdulta: 44.71 },
          'Centro-Oeste': { devedoresMensal: 0.26,  devedoresAnual: 6.34,  dividasMensal: 0.87,  dividasAnual: 12.53, negativadosMi: 6.41,  popAdulta: 48.39 },
          'Sudeste':      { devedoresMensal: 0.36,  devedoresAnual: 6.53,  dividasMensal: 0.95,  dividasAnual: 13.28, negativadosMi: 32.12, popAdulta: 44.73 },
          'Sul':          { devedoresMensal: 0.45,  devedoresAnual: 10.68, dividasMensal: 0.96,  dividasAnual: 17.52, negativadosMi: 9.89,  popAdulta: 40.64 }
        },
        estimativa: { negativadosMi: 75.08, popAdulta: 44.75,
          faixaEtaria: [[6.60, 30.90], [8.94, 52.75], [18.19, 53.68], [16.60, 50.87], [15.88, 43.00], [8.36, 35.45], [0.51, 20.84]] },
        historico: { meses: ['2017-07', '2018-07', '2019-07', '2020-07', '2021-07', '2022-07', '2023-07', '2024-07', '2025-07', '2026-07'],
          devedores: [-0.66, -0.44, -0.11, -0.95, -1.04, 0.96, 0.16, 0.01, 0.23, 0.47],
          dividas: [-0.91, -0.82, -0.32, -1.28, -1.36, 1.93, -0.62, -0.57, 0.31, 1.07] }
      }
    },
    '2026-08': {
      cuiaba: {
        arquivo: 'Cuiabá-MT_ago26.pdf',
        devedores: { anual: 2.40, mensal: -2.52 }, dividas: { anual: 7.43, mensal: -2.95 },
        dividaMedia: 6631.99, dividasPorDevedor: 2.50, atrasoMeses: 30.2, idadeMedia: 45.4,
        sexo: { homens: 52.10, mulheres: 47.90 },
        faixaEtaria: [5.66, 10.54, 25.73, 23.66, 21.52, 11.34, 1.40],
        valor: [22.48, 11.66, 19.75, 22.41, 23.69],
        atraso: [5.81, 17.42, 34.93, 17.48, 24.35],
        setor: { 'Bancos': 61.09, 'Comércio': 14.85, 'Outros': 12.33, 'Água e Luz': 8.76, 'Comunicação': 2.97 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 5.06, devedoresMensal: -1.08, dividasAnual: 10.10, dividasMensal: -1.24, dividasPorDevedor: 2.46 },
          'Brasil': { devedoresAnual: 5.02, devedoresMensal: -1.89, dividasAnual: 10.28, dividasMensal: -2.04, dividasPorDevedor: 2.34 }
        }
      },
      mt: {
        arquivo: 'MatoGrosso-MT_ago26.pdf',
        devedores: { anual: 3.98, mensal: -2.23 }, dividas: { anual: 8.90, mensal: -2.38 },
        dividaMedia: 6119.63, dividasPorDevedor: 2.418, atrasoMeses: 29.5, idadeMedia: 43.8,
        sexo: { homens: 53.42, mulheres: 46.58 },
        faixaEtaria: [7.20, 12.03, 27.09, 22.79, 19.67, 9.79, 1.26],
        valor: [23.15, 12.10, 20.21, 22.92, 21.62],
        atraso: [6.52, 17.65, 35.70, 17.50, 22.63],
        setor: { 'Bancos': 54.81, 'Comércio': 21.94, 'Outros': 10.91, 'Água e Luz': 8.17, 'Comunicação': 4.17 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 5.06, devedoresMensal: -1.08, dividasAnual: 10.10, dividasMensal: -1.24, dividasPorDevedor: 2.463 },
          'Brasil': { devedoresAnual: 5.02, devedoresMensal: -1.89, dividasAnual: 10.28, dividasMensal: -2.04, dividasPorDevedor: 2.34 }
        }
      },
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_ago2026.pdf',
        devedores: { anual: 5.02, mensal: -1.89 }, dividas: { anual: 10.28, mensal: -2.04 },
        dividaMedia: 5190.28, dividasPorDevedor: 2.34, atrasoMeses: 29.9, idadeMedia: 45.2,
        sexo: { homens: 48.58, mulheres: 51.42 },
        faixaEtaria: [7.99, 11.54, 23.65, 21.61, 20.78, 12.31, 2.12],
        valor: [28.77, 12.20, 18.90, 21.16, 18.97],
        atraso: [6.14, 17.49, 35.00, 17.51, 23.85],
        atrasoAnual: [-22.38, 8.32, 1.58, -9.67, 37.73],
        setor: { 'Bancos': 65.80, 'Água e Luz': 10.04, 'Outros': 9.86, 'Comércio': 8.32, 'Comunicação': 5.99 },
        setorAnual: { 'Água e Luz': 9.15, 'Comércio': -1.78, 'Comunicação': 14.94, 'Bancos': 9.08, 'Outros': 31.75 },
        regioes: {
          'Norte':        { devedoresMensal: -1.14, devedoresAnual: 6.38,  dividasMensal: -1.16, dividasAnual: 12.62, negativadosMi: 6.82,  popAdulta: 48.03 },
          'Nordeste':     { devedoresMensal: -1.19, devedoresAnual: 2.98,  dividasMensal: -1.38, dividasAnual: 7.82,  negativadosMi: 19.52, popAdulta: 44.13 },
          'Centro-Oeste': { devedoresMensal: -1.08, devedoresAnual: 5.06,  dividasMensal: -1.24, dividasAnual: 10.10, negativadosMi: 6.34,  popAdulta: 47.80 },
          'Sudeste':      { devedoresMensal: -2.71, devedoresAnual: 2.95,  dividasMensal: -3.02, dividasAnual: 8.32,  negativadosMi: 31.31, popAdulta: 43.58 },
          'Sul':          { devedoresMensal: -1.81, devedoresAnual: 8.32,  dividasMensal: -1.43, dividasAnual: 14.62, negativadosMi: 9.72,  popAdulta: 39.90 }
        },
        estimativa: { negativadosMi: 73.71, popAdulta: 43.90,
          faixaEtaria: [[6.44, 30.21], [8.79, 51.96], [17.95, 52.97], [16.34, 50.05], [15.52, 41.96], [8.16, 34.49], [0.499, 20.34]] },
        historico: { meses: ['2017-08', '2018-08', '2019-08', '2020-08', '2021-08', '2022-08', '2023-08', '2024-08', '2025-08', '2026-08'],
          devedores: [-0.06, -0.71, -0.70, -0.87, -0.53, 0.78, 1.14, -0.42, 0.71, -1.89],
          dividas: [-0.30, -0.66, -1.03, -1.40, -0.58, 1.72, 2.19, -0.37, 1.42, -2.04] }
      }
    },
    '2026-09': {
      cuiaba: {
        arquivo: 'Cuiabá-MT_set26.pdf',
        devedores: { anual: 3.03, mensal: 1.63 }, dividas: { anual: 9.74, mensal: 3.21 },
        dividaMedia: 6673.19, dividasPorDevedor: 2.54, atrasoMeses: 29.7, idadeMedia: 45.4,
        sexo: { homens: 52.13, mulheres: 47.87 },
        faixaEtaria: [5.78, 10.42, 25.47, 23.69, 21.77, 11.46, 1.40],
        valor: [22.47, 11.61, 19.75, 22.47, 23.70],
        atraso: [7.03, 17.48, 34.42, 17.00, 24.07],
        setor: { 'Bancos': 62.35, 'Comércio': 14.46, 'Outros': 12.28, 'Água e Luz': 7.98, 'Comunicação': 2.93 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 7.74, devedoresMensal: 2.27, dividasAnual: 14.36, dividasMensal: 3.37, dividasPorDevedor: 2.49 },
          'Brasil': { devedoresAnual: 6.97, devedoresMensal: 2.07, dividasAnual: 13.62, dividasMensal: 3.07, dividasPorDevedor: 2.36 }
        }
      },
      mt: {
        arquivo: 'relat_inadimplencia_MT_set2026.pdf',
        devedores: { anual: 5.02, mensal: 1.82 }, dividas: { anual: 11.22, mensal: 3.07 },
        dividaMedia: 6203.81, dividasPorDevedor: 2.447, atrasoMeses: 29.0, idadeMedia: 43.8,
        sexo: { homens: 53.42, mulheres: 46.58 },
        faixaEtaria: [7.41, 11.99, 26.94, 22.82, 19.82, 9.77, 1.23],
        valor: [22.96, 12.08, 20.21, 22.91, 21.84],
        atraso: [7.77, 17.70, 35.12, 17.07, 22.34],
        setor: { 'Bancos': 56.18, 'Comércio': 21.43, 'Outros': 10.86, 'Água e Luz': 7.41, 'Comunicação': 4.12 },
        comparativo: {
          'Centro-Oeste': { devedoresAnual: 7.74, devedoresMensal: 2.27, dividasAnual: 14.36, dividasMensal: 3.37, dividasPorDevedor: 2.489 },
          'Brasil': { devedoresAnual: 6.97, devedoresMensal: 2.07, dividasAnual: 13.62, dividasMensal: 3.07, dividasPorDevedor: 2.363 }
        }
      },
      br: {
        arquivo: 'Análise-Inadimplência-BReRegiões-PF_set2026.pdf',
        devedores: { anual: 6.97, mensal: 2.07 }, dividas: { anual: 13.62, mensal: 3.07 },
        dividaMedia: 5240.29, dividasPorDevedor: 2.36, atrasoMeses: 29.4, idadeMedia: 45.1,
        sexo: { homens: 48.62, mulheres: 51.38 },
        faixaEtaria: [8.68, 11.55, 23.35, 21.37, 20.70, 12.27, 2.08],
        valor: [28.69, 12.06, 18.83, 21.23, 19.19],
        atraso: [7.69, 17.43, 34.33, 16.88, 23.68],
        atrasoAnual: [6.30, 9.63, 1.89, -11.44, 34.48],
        setor: { 'Bancos': 65.95, 'Água e Luz': 10.14, 'Outros': 9.82, 'Comércio': 8.12, 'Comunicação': 5.97 },
        setorAnual: { 'Água e Luz': 12.08, 'Comércio': -1.77, 'Comunicação': 17.84, 'Bancos': 12.89, 'Outros': 36.08 },
        regioes: {
          'Norte':        { devedoresMensal: 0.85,  devedoresAnual: 7.25,  dividasMensal: 2.15,  dividasAnual: 14.99, negativadosMi: 6.89,  popAdulta: 48.45 },
          'Nordeste':     { devedoresMensal: 1.68,  devedoresAnual: 4.58,  dividasMensal: 2.44,  dividasAnual: 10.40, negativadosMi: 19.82, popAdulta: 44.77 },
          'Centro-Oeste': { devedoresMensal: 2.27,  devedoresAnual: 7.74,  dividasMensal: 3.37,  dividasAnual: 14.36, negativadosMi: 6.47,  popAdulta: 48.74 },
          'Sudeste':      { devedoresMensal: 2.21,  devedoresAnual: 5.60,  dividasMensal: 3.35,  dividasAnual: 12.62, negativadosMi: 31.89, popAdulta: 44.36 },
          'Sul':          { devedoresMensal: 3.26,  devedoresAnual: 9.75,  dividasMensal: 4.18,  dividasAnual: 17.19, negativadosMi: 9.99,  popAdulta: 41.01 }
        },
        estimativa: { negativadosMi: 75.05, popAdulta: 44.67,
          faixaEtaria: [[7.05, 33.08], [8.96, 53.02], [18.06, 53.30], [16.46, 50.38], [15.74, 42.50], [8.28, 34.89], [0.501, 20.35]] },
        historico: { meses: ['2017-09', '2018-09', '2019-09', '2020-09', '2021-09', '2022-09', '2023-09', '2024-09', '2025-09', '2026-09'],
          devedores: [-0.13, 0.09, -0.55, -0.16, -0.02, 0.93, -0.39, 0.47, 0.21, 2.07],
          dividas: [-0.43, -0.04, -1.74, -0.55, -0.26, 2.05, 0.23, 0.74, 0.05, 3.07] }
      }
    }
  }
};
