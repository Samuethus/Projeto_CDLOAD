// Dashboard › Panorama Econômico › SPC: Inadimplência.
// Fonte: relatórios do SPC Brasil anexados na seção Inadimplência (PDF), lidos e transcritos à mão:
//   relat_inadimplencia_MT_<mês>.pdf ............ "Inadimplência no Mato Grosso" (mt)
//   Análise-Inadimplência-BReRegiões-PF_<mês>.pdf  "Inadimplência de Pessoas Físicas" — Brasil e regiões (br)
//   Cuiabá-MT_<mês>.pdf ......................... "Inadimplência em Cuiabá/MT" (cuiaba) — a partir de set/2026, mesmo formato do MT
// Edições anteriores a set/2026 não têm Cuiabá (o SPC Brasil ainda não enviava o relatório do município).
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
  meses: ['2025-11', '2026-06', '2026-09'],
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
      '2025-07': 43.81, '2025-08': 43.87, '2025-09': 44.22, '2025-10': 44.68, '2025-11': 45.00, '2025-12': 45.80 } },
    { local: 'Centro-Oeste', arquivo: 'Inadimplencia_2026_Centro-Oeste.pdf', meses: {   // pasta Janeiro 2026 da seção (jan–mai/2026)
      '2026-01': 47.31, '2026-02': 48.00, '2026-03': 47.99, '2026-04': 48.21, '2026-05': 48.32 } }
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
    '2026-06': {
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
          'Brasil': { devedoresAnual: 7.55, devedoresMensal: -0.30, dividasAnual: 13.32, dividasMensal: -0.59, dividasPorDevedor: 2.330 }
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
          'Norte':        { devedoresMensal: 0.85, devedoresAnual: 7.25, dividasMensal: 2.15, dividasAnual: 14.99, negativadosMi: 6.89,  popAdulta: 48.45 },
          'Nordeste':     { devedoresMensal: 1.68, devedoresAnual: 4.58, dividasMensal: 2.44, dividasAnual: 10.40, negativadosMi: 19.82, popAdulta: 44.77 },
          'Centro-Oeste': { devedoresMensal: 2.27, devedoresAnual: 7.74, dividasMensal: 3.37, dividasAnual: 14.36, negativadosMi: 6.47,  popAdulta: 48.74 },
          'Sudeste':      { devedoresMensal: 2.21, devedoresAnual: 5.60, dividasMensal: 3.35, dividasAnual: 12.62, negativadosMi: 31.89, popAdulta: 44.36 },
          'Sul':          { devedoresMensal: 3.26, devedoresAnual: 9.75, dividasMensal: 4.18, dividasAnual: 17.19, negativadosMi: 9.99,  popAdulta: 41.01 }
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
