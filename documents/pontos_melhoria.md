# CDLoad — Diagnóstico do projeto e pontos de melhoria

> Levantamento de 12/10/2026, feito a partir de números do projeto (tamanhos, contagens e histórico do git) e do que foi visto no código durante as manutenções recentes. Não é uma leitura linha a linha.

## Resumo

O projeto **não é grande demais**: o repositório completo tem 36 MB, com 80 arquivos e cerca de 18 mil linhas de código próprio. O problema é a **concentração**: quase tudo está num único `index.html`.

## Tamanho

| Item | Tamanho |
|---|---|
| Repositório | 36 MB com histórico; arquivos atuais 25 MB |
| `index.html` | **15.106 linhas / 1,1 MB**: 2,2 mil de CSS, 10,8 mil de JS, 10 seções, 349 funções |
| Dados (`assets/data`) | ~9 MB; o maior é `cnpj_ceps.js` com 6,3 MB |
| Imagens dos relatórios (PNG) | ~12 MB |
| Scripts de dados (Python/PowerShell) + Edge Functions | ~3,2 mil linhas |
| SQL do Supabase | 23 arquivos soltos |

O tamanho geral é saudável. O ponto crítico é ter tudo num arquivo só.

## Infraestrutura

- **Site:** HTML estático, sem etapa de build, publicado no GitHub Pages pelo workflow de deploy. O `config.js` é gerado na publicação a partir dos secrets.
- **Banco:** Supabase, com login, banco protegido por RLS e duas Edge Functions:
  - **Agenda:** sincroniza a agenda.
  - **Survey Monkey:** sincronização a cada 15 min e tempo real por webhook.
- **Atualização de dados:** um GitHub Action diário que roda 9 extratores (ABVE, CAGED, Sefaz, IBGE, Stone, Cielo, CNPJ e CEPs). A extração do CNPJ baixa ~7 GB e leva horas.
- **Serviços externos:** Mapbox, AwesomeAPI (CEPs), API do Survey Monkey, dados abertos da Receita e SIDRA/IBGE.

## Pontos de melhoria, por prioridade

1. **`index.html` com 15 mil linhas.** Qualquer mudança mexe no arquivo inteiro e o risco de conflito é alto. Dá para separar por seção em arquivos CSS e JS próprios, ainda sem build.
2. **Nenhum teste automatizado.** Os scripts Python rodam pela primeira vez direto no GitHub. Isso já causou falhas silenciosas: a sincronização do Survey quebrava a cada execução e a extração do CNPJ parou quando a Receita bloqueou a listagem de pastas. Vale ter pelo menos um teste mínimo de cada extrator.
3. **Falhas escondidas no workflow.** Os passos usam `continue-on-error`, então uma falha aparece como "sucesso". Um alerta (e-mail ou issue) quando um passo falhar resolveria.
4. **SQL sem ordem nem controle.** São 23 arquivos sem numeração e sem registro do que já foi rodado. Ainda faltam confirmar `schema_surveymonkey_tempo_real`, `schema_surveymonkey_link_coletor` e `schema_supabase_visualizador`. Numerar (001_…) ou usar as migrations do Supabase CLI resolve.
5. **Mapa pesado.** O `cnpj_ceps.js` (6,3 MB) é baixado inteiro ao abrir o mapa. Dá para comprimir ou dividir por município.
6. **Histórico do git cresce com os dados.** Os arquivos gerados (6 MB por versão) entram no histórico a cada mudança. Por enquanto está tolerável; no futuro, os dados podem ir para Releases ou para o Storage do Supabase.
7. **Código repetido.** Paginação, cards de KPI, exportação CSV e rosca estão reimplementados em várias seções. Funções comuns reduziriam o volume e os bugs.
8. **Dependências externas sem verificação de integridade.** O Mapbox carrega sem SRI (o Supabase e o html5-qrcode têm). A CSP precisa de `'unsafe-inline'` porque todo o JS está dentro do HTML, e separar os arquivos permitiria endurecê-la.
9. **Documentação desatualizada.** O README ainda trata o Survey Monkey como "próxima etapa" e não cita o Dashboard/Panorama nem a seção Supabase.
10. **Pendências operacionais:** confirmar que a Edge Function do Survey foi republicada, que o secret do webhook foi criado e que os SQLs acima foram rodados.
