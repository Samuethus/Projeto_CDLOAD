# Relatório "Dados CESPC (SPC MT)" — Relatório de Monitoramento

Gerado em **Relatórios › Gerar relatório › 2. Dados CESPC (SPC MT)**, todo no navegador (sem API), em PDF.

## Fonte dos dados

O arquivo mensal **OPERAÇÃO_MT_<MÊS><AA> - Envio.xlsx** (SPC Brasil) enviado em **Documentos › 1. CESPC** — o mesmo
que alimenta o **Dashboard › Painel · SPC Mato Grosso**. O arquivo chega sem as abas de base; os dados vêm dos caches
das tabelas dinâmicas (leitura `spLerOperacao` no `index.html`; reserva em `assets/data/spc_mt.js`, gerada por
`scripts/spc_mt_extrair.py` com o mesmo resumo).

- **Fluxos do ano, mês a mês:** captação, cancelamento, consultas (por produto e por associado) e inclusões.
- **Retrato na data de referência:** associados ativos, faixas de consumo de consultas e de registros, registros ativos
  e recuperação por tempo de permanência, maiores associados por registros ativos/recuperação e por consumo.

## Layouts (pasta `branding`)

| Arquivo | Uso |
|---|---|
| `1.jpg` | Capa — o ano do selo verde é trocado pelo ano do relatório; abaixo dos logos, a abrangência e o período. |
| `2.png` | Páginas de análise — no canto superior direito, o título da página, a abrangência e o período. |

O PDF tem a proporção dos layouts (mais alto que o A4).

## Páginas (esquema de `modelo para preenchimento dos dados.pdf`)

1. **Capa** (layout 1).
2. **Visão geral** — KPIs: Associados (ativos), Consultas, Captação, Cancelamentos e Inclusão (acumulado de janeiro até
   o mês de referência); *Evolução de Captação x Cancelamento* (colunas por mês); *Evolução Inclusão* e *Evolução
   Consultas* (colunas por mês com a variação sobre o mês anterior, ↑ verde / ↓ vermelho); *Top 10 Associados*
   (consultas no ano) e *Top 10 Produtos* (consultas no ano).
3. **Tempo de permanência** — *Registros Ativos por Tempo de Permanência*, *Recuperação por Tempo de Permanência*
   (faixas da mais curta à mais longa) e a tabela *Associado | Registros Ativos | Recuperação* (maiores por registros
   ativos), com a linha **Total** de toda a abrangência.
4. **Faixa de consumo de consultas** — *Percentual de Associados por Faixa de Consumo* e a tabela *Entidade |
   Quantidade de Associados | Consultas* (uma entidade só: *Associado | Consultas | % da entidade*).
5. **Faixa de consumo de registros** — o mesmo da página 4 para registros.

## Etapas do gerador

1. **Relatório:** Dados CESPC (SPC MT).
2. **Mês de referência:** o relatório cobre de janeiro até o mês escolhido (sem o mês no arquivo, usa o último dele).
3. **Entidades:** *Todas as entidades* ou *Específicas* (lista suspensa com caixas de seleção, busca e marcar/desmarcar todas).
4. **Modelo de consolidação:**
   - **Total** — um único PDF somando as entidades escolhidas (todas = Mato Grosso).
   - **Individual** — um PDF por entidade.

Durante a geração aparece a contagem de PDFs consolidados (*X de N*) com barra de progresso. Mais de um PDF sai num
arquivo compactado (**.zip**).

## Regras de formatação

- Números inteiros com ponto de milhar (pt-BR); percentuais com duas casas e vírgula.
- Variação sobre o mês anterior = (mês − mês anterior) ÷ mês anterior × 100; mês anterior zero → sem variação.
- Nomes das entidades como no painel (município com acento: "CDL CUIABA/MT-2603" → "Cuiabá").
