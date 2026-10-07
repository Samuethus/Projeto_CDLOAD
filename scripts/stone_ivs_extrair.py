"""Extrai o Índice do Varejo Stone (IVS) para o painel "Painel · Stone (IVS)" do Dashboard.

Fonte: https://conteudo.stone.com.br/indice-do-varejo/ (divulgação mensal da Stone).
Cada edição publica um CSV público ("dataset_de_divulgacao_<mes>_<ano>.csv") com a série
completa desde jan/2022; a página de índice já traz o link dos CSVs das últimas edições.
O script pega o CSV mais recente — não usa o formulário de download (nome/e-mail/telefone).

Gera assets/data/stone_ivs.js (window.STONE_IVS), carregado sob demanda pelo Dashboard.
Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml) e só regrava o
arquivo se os dados mudaram (a Stone divulga uma vez por mês).

Formato:
  meses: ['2022-01', ...]
  locais: { sig: ['BR', 'AC', ...], nomes: ['Brasil', 'Acre', ...], regiao: ['Brasil', 'Norte', ...] }
  setores: ['geral restrito', 'geral ampliado', ...]   (no Brasil; nos estados só 'geral restrito')
  series: { '<iSetor>,<iLocal>': [indice, var_anual_%, indice_dessaz, var_mensal_dessaz_%] }
          cada item é uma lista por mês (null quando não há dado).
"""
import csv
import datetime
import io
import json
import os
import re
import sys
import urllib.request

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'stone_ivs.js')
PAGINA = 'https://conteudo.stone.com.br/indice-do-varejo/'
UA = {'User-Agent': 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'}
MESES_PT = ['janeiro', 'fevereiro', 'marco', 'abril', 'maio', 'junho', 'julho', 'agosto',
            'setembro', 'outubro', 'novembro', 'dezembro']
UF_NOME = {
    'AC': 'Acre', 'AL': 'Alagoas', 'AP': 'Amapá', 'AM': 'Amazonas', 'BA': 'Bahia', 'CE': 'Ceará',
    'DF': 'Distrito Federal', 'ES': 'Espírito Santo', 'GO': 'Goiás', 'MA': 'Maranhão', 'MT': 'Mato Grosso',
    'MS': 'Mato Grosso do Sul', 'MG': 'Minas Gerais', 'PA': 'Pará', 'PB': 'Paraíba', 'PR': 'Paraná',
    'PE': 'Pernambuco', 'PI': 'Piauí', 'RJ': 'Rio de Janeiro', 'RN': 'Rio Grande do Norte',
    'RS': 'Rio Grande do Sul', 'RO': 'Rondônia', 'RR': 'Roraima', 'SC': 'Santa Catarina',
    'SP': 'São Paulo', 'SE': 'Sergipe', 'TO': 'Tocantins'}
# Ordem dos setores: agregados primeiro (o "geral restrito" é o índice principal).
SETORES_ORDEM = ['geral restrito', 'geral ampliado', 'setores sensíveis a renda', 'setores sensíveis ao crédito']
COLUNAS = ['mes', 'indice_stone', 'indice_stone_yoy_change', 'indice_stone_seasonally_adj',
           'indice_stone_seasonally_adj_mom_change', 'uf / país', 'setor de atividade', 'região']


def baixar(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return r.read().decode('utf-8-sig')


def csv_mais_recente():
    """URL do CSV da edição mais recente listada na página de índice."""
    html = baixar(PAGINA)
    urls = set(re.findall(r'https://conteudo\.stone\.com\.br/wp-content/uploads/\d{4}/\d{2}/dataset_de_divulgacao_[a-z]+_\d{4}[^"\'\s<>]*\.csv', html))
    if not urls:
        # Página mudou: procura nas páginas das edições do Índice do Varejo (não as da Abrasel).
        for ed in sorted(set(re.findall(r'https://conteudo\.stone\.com\.br/indice-varejo/indice-do-varejo-[a-z0-9-]+/', html))):
            urls |= set(re.findall(r'https://conteudo\.stone\.com\.br/wp-content/uploads/[^"\'\s<>]*dataset_de_divulgacao[^"\'\s<>]*\.csv', baixar(ed)))
    if not urls:
        sys.exit('Nenhum CSV do Índice do Varejo Stone encontrado em ' + PAGINA)

    def chave(u):
        m = re.search(r'dataset_de_divulgacao_([a-z]+)_(\d{4})', u)
        mes = MESES_PT.index(m.group(1).replace('ç', 'c')) + 1 if m and m.group(1).replace('ç', 'c') in MESES_PT else 0
        return (int(m.group(2)) if m else 0, mes, u)
    return max(urls, key=chave)


def num(v):
    v = (v or '').strip()
    return None if v in ('', 'nan', 'NaN') else round(float(v), 2)


def main():
    url = csv_mais_recente()
    linhas = list(csv.DictReader(io.StringIO(baixar(url))))
    faltando = [c for c in COLUNAS if c not in (linhas[0].keys() if linhas else [])]
    if faltando:
        sys.exit('CSV com formato inesperado (faltam colunas: %s): %s' % (', '.join(faltando), url))

    meses = sorted({l['mes'][:7] for l in linhas})
    ufs = sorted({l['uf / país'] for l in linhas if l['uf / país'] != 'Brasil'}, key=lambda s: UF_NOME.get(s, s))
    sig = ['BR'] + ufs
    nomes = ['Brasil'] + [UF_NOME.get(u, u) for u in ufs]
    regiao = {l['uf / país']: l['região'] for l in linhas}
    setores_csv = {l['setor de atividade'] for l in linhas}
    setores = [s for s in SETORES_ORDEM if s in setores_csv] + sorted(setores_csv - set(SETORES_ORDEM))
    im = {m: i for i, m in enumerate(meses)}

    series = {}
    for l in linhas:
        loc = 0 if l['uf / país'] == 'Brasil' else sig.index(l['uf / país'])
        k = '%d,%d' % (setores.index(l['setor de atividade']), loc)
        s = series.setdefault(k, [[None] * len(meses) for _ in range(4)])
        i = im[l['mes'][:7]]
        for j, col in enumerate(COLUNAS[1:5]):
            s[j][i] = num(l[col])

    m = re.search(r'dataset_de_divulgacao_([a-z]+)_(\d{4})', url)
    dados = {
        'fonte': 'Stone · Índice do Varejo Stone (IVS)',
        'edicao': '%s/%s' % (m.group(1), m.group(2)) if m else '',
        'url_csv': url,
        'meses': meses,
        'locais': {'sig': sig, 'nomes': nomes, 'regiao': ['Brasil'] + [regiao.get(u, '') for u in ufs]},
        'setores': setores,
        'series': series,
    }
    corpo = json.dumps(dados, ensure_ascii=False, separators=(',', ':'))
    if os.path.exists(SAIDA):
        antigo = open(SAIDA, encoding='utf-8').read()
        if corpo in antigo:
            print('Sem mudanças (%s, até %s).' % (dados['edicao'], meses[-1]))
            return
    js = ('// Gerado por scripts/stone_ivs_extrair.py - não editar à mão.\n'
          '// Extraído em %s de %s\n'
          'window.STONE_IVS = %s;\n') % (datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'), url, corpo)
    open(SAIDA, 'w', encoding='utf-8').write(js)
    print('Gravado %s: %d meses (%s a %s), %d locais, %d setores, %d séries.' % (
        os.path.relpath(SAIDA, RAIZ), len(meses), meses[0], meses[-1], len(sig), len(setores), len(series)))


if __name__ == '__main__':
    main()
