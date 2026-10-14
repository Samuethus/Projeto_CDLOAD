// Dashboard › Panorama Econômico › SPC: Inadimplência.
// Fonte: relatórios do SPC Brasil anexados na seção Inadimplência (PDF), lidos e transcritos à mão:
//   relat_inadimplencia_MT_<mês>.pdf ............ "Inadimplência no Mato Grosso" (mt)
//   Análise-Inadimplência-BReRegiões-PF_<mês>.pdf  "Inadimplência de Pessoas Físicas" — Brasil e regiões (br)
// Cuiabá: o SPC Brasil ainda não enviou relatório do município (cuiaba fica vazio até chegar o 1º PDF).
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
//                painel (switch Dashboard | Gráfico, filtro Região): uma linha por região ao longo das edições, então
//                transcreva as 5 regiões em TODA edição nova — o total do Brasil do mesmo gráfico vai em estimativa.
//   estimativa   (Brasil) negativados no país e por faixa etária [milhões, % da população da faixa]
//   historico    (Brasil) variação mensal do mesmo mês nos últimos 10 anos (devedores e dívidas)
window.SPC_INAD = {
  fonte: 'SPC Brasil',
  atualizado: '2026-10-13',
  locais: { cuiaba: 'Cuiabá', mt: 'Mato Grosso', br: 'Brasil' },
  faixas: ['18 a 24 anos', '25 a 29 anos', '30 a 39 anos', '40 a 49 anos', '50 a 64 anos', '65 a 84 anos', '85 anos ou mais'],
  valores: ['Até R$ 500', 'R$ 500,01 a R$ 1.000', 'R$ 1.000,01 a R$ 2.500', 'R$ 2.500,01 a R$ 7.500', 'Acima de R$ 7.500'],
  atrasos: ['Até 90 dias', '91 dias a 1 ano', '1 a 3 anos', '3 a 4 anos', '4 a 5 anos'],
  meses: ['2025-11', '2026-06'],
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
    }
  }
};
