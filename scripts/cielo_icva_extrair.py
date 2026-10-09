"""Extrai o ICVA (Índice Cielo do Varejo Ampliado) para o indicador "Cielo (ICVA)" do Panorama.

Fonte: https://ri.cielo.com.br/informacoes-financeiras/indice-cielo-do-varejo-ampliado-icva/
A página de RI traz o link da planilha com a base histórica (xlsx, "planilha_icva_<mes>_<ano>.xlsx"):
crescimento da receita de vendas do varejo, ano contra ano, nominal e deflacionado, com e sem
ajuste calendário, para o Brasil e as cinco regiões. A partir de out/2026 os relatórios mensais
passam ao Blog Cielo (https://blog.cielo.com.br/indice-icva/); o script procura a planilha nas
duas páginas e usa a primeira que tiver a aba "Índice Mensal".

Lê o xlsx só com a biblioteca padrão (zip + XML), sem dependências.
Gera assets/data/cielo_icva.js (window.CIELO_ICVA), carregado sob demanda pelo Dashboard.
Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml) e só regrava o
arquivo se os dados mudaram (a Cielo divulga uma vez por mês).

Formato (valores em %, 2 casas; null quando não há dado):
  meses: ['2013-01', ...]
  locais: { nomes: ['Brasil', 'Centro-Oeste', 'Nordeste', 'Norte', 'Sudeste', 'Sul'] }
  visoes: ['def', 'def_aj', 'nom', 'nom_aj']   (deflacionado/nominal, sem/com ajuste calendário)
  mensal: { '<visao>,<iLocal>': [variação anual % por mês] }
  trimestral: { periodos: ['1T13', ...], series: { '<def|nom>,<iLocal>': [...] } }
  anual: { anos: [2013, ...], series: { '<def|nom>,<iLocal>': [...] } }   (ano corrente = acumulado até o último mês)
"""
import datetime
import io
import json
import os
import re
import sys
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'cielo_icva.js')
PAGINAS = ['https://ri.cielo.com.br/informacoes-financeiras/indice-cielo-do-varejo-ampliado-icva/',
           'https://blog.cielo.com.br/indice-icva/']
UA = {'User-Agent': 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'}
LOCAIS = ['Brasil', 'Centro-Oeste', 'Nordeste', 'Norte', 'Sudeste', 'Sul']
VISOES = ['def', 'def_aj', 'nom', 'nom_aj']
NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
REL = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'


def baixar(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=90) as r:
        return r.read()


def norm(s):
    s = unicodedata.normalize('NFKD', str(s or '')).encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+', ' ', s).strip()


def ler_xlsx(dados):
    """{nome da aba: [linhas]} — cada linha é uma lista de valores (str, float ou None)."""
    z = zipfile.ZipFile(io.BytesIO(dados))
    compart = []
    if 'xl/sharedStrings.xml' in z.namelist():
        for si in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('m:si', NS):
            compart.append(''.join(t.text or '' for t in si.iter('{%s}t' % NS['m'])))
    rels = {r.get('Id'): r.get('Target') for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
    abas = {}
    for sh in ET.fromstring(z.read('xl/workbook.xml')).find('m:sheets', NS):
        alvo = rels[sh.get(REL)].lstrip('/')
        caminho = alvo if alvo.startswith('xl/') else 'xl/' + alvo
        linhas = []
        for row in ET.fromstring(z.read(caminho)).iter('{%s}row' % NS['m']):
            linha = {}
            for c in row.findall('m:c', NS):
                col = 0
                for ch in re.match(r'[A-Z]+', c.get('r')).group(0):
                    col = col * 26 + ord(ch) - 64
                v, t = c.find('m:v', NS), c.get('t')
                if t == 'inlineStr':
                    val = ''.join(x.text or '' for x in c.iter('{%s}t' % NS['m']))
                elif v is None or v.text is None:
                    val = None
                elif t == 's':
                    val = compart[int(v.text)]
                elif t in ('str', 'e'):
                    val = v.text
                else:
                    val = float(v.text)
                linha[col - 1] = val
            linhas.append([linha.get(i) for i in range(max(linha) + 1)] if linha else [])
        abas[sh.get('name')] = linhas
    return abas


def planilha():
    """(url, abas) da primeira planilha encontrada que tenha a aba "Índice Mensal"."""
    vistos = []
    for pag in PAGINAS:
        try:
            html = baixar(pag).decode('utf-8', 'ignore')
        except Exception as e:
            print('Aviso: não foi possível abrir %s (%s)' % (pag, e))
            continue
        urls = re.findall(r'https://filemanager-cdn\.mziq\.com/published/[0-9a-f-]+/[0-9a-f-]+', html)
        urls += re.findall(r'https://[^"\'\s<>]+?\.xlsx', html)
        for u in dict.fromkeys(urls):
            if u in vistos:
                continue
            vistos.append(u)
            try:
                dados = baixar(u)
                if not dados.startswith(b'PK'):
                    continue
                abas = ler_xlsx(dados)
            except Exception as e:
                print('Aviso: %s ignorado (%s)' % (u, e))
                continue
            if any(norm(n) == 'indice mensal' for n in abas):
                return u, abas
    sys.exit('Planilha do ICVA (aba "Índice Mensal") não encontrada em: ' + ', '.join(PAGINAS))


def aba(abas, nome):
    for n, linhas in abas.items():
        if norm(n) == nome:
            return linhas
    sys.exit('Aba "%s" não encontrada na planilha do ICVA.' % nome)


def cabecalho(linhas):
    for i, l in enumerate(linhas):
        if len(l) > 3 and norm(l[1]) == 'setor' and norm(l[2]) == 'localidade':
            return i
    sys.exit('Cabeçalho (Setor/Localidade/Visão) não encontrado.')


def local(nome):
    n = norm(nome).replace(' ', '')
    for i, l in enumerate(LOCAIS):
        if norm(l).replace(' ', '') == n:
            return i
    return None


def pct(v):
    return None if not isinstance(v, float) else round(v * 100, 2)


def visao(texto):
    t = norm(texto)
    base = 'def' if t.startswith('deflac') else 'nom' if t.startswith('nominal') else None
    if base is None:
        return None
    return base + ('_aj' if 'com ajuste' in t else '')


def ler_aba(linhas, rotulo_col):
    """(rótulos das colunas, {'<visao>,<iLocal>': [valores]}) do Varejo Total."""
    h = cabecalho(linhas)
    cols = [(j, rotulo_col(v)) for j, v in enumerate(linhas[h]) if j > 3 and v not in (None, '')]
    cols = [(j, r) for j, r in cols if r is not None]
    series = {}
    for l in linhas[h + 1:]:
        if len(l) < 4 or norm(l[1]) != 'varejo total':
            continue
        lo, vi = local(l[2]), visao(l[3])
        if lo is None or vi is None:
            continue
        series['%s,%d' % (vi, lo)] = [pct(l[j]) if j < len(l) else None for j, _ in cols]
    return [r for _, r in cols], series


def mes_de(v):
    if isinstance(v, float):
        d = datetime.date(1899, 12, 30) + datetime.timedelta(days=int(v))
        return '%04d-%02d' % (d.year, d.month)
    return None


def main():
    url, abas = planilha()
    meses, mensal = ler_aba(aba(abas, 'indice mensal'), mes_de)
    trim, trimestral = ler_aba(aba(abas, 'indice trimestral'), lambda v: str(v).strip() if re.fullmatch(r'\s*[1-4]T\d{2}\s*', str(v or '')) else None)
    anos, anual = ler_aba(aba(abas, 'indice anual'), lambda v: int(v) if isinstance(v, float) else None)
    if 'def,0' not in mensal or not meses:
        sys.exit('Planilha do ICVA com formato inesperado: %s' % url)
    # Corta meses finais sem nenhum dado (colunas reservadas para os próximos meses).
    ult = max(i for s in mensal.values() for i, v in enumerate(s) if v is not None)
    meses = meses[:ult + 1]
    mensal = {k: s[:ult + 1] for k, s in mensal.items()}

    dados = {
        'fonte': 'Cielo · Índice Cielo do Varejo Ampliado (ICVA)',
        'url_planilha': url,
        'meses': meses,
        'locais': {'nomes': LOCAIS},
        'visoes': VISOES,
        'mensal': mensal,
        'trimestral': {'periodos': trim, 'series': trimestral},
        'anual': {'anos': anos, 'series': anual},
    }
    corpo = json.dumps(dados, ensure_ascii=False, separators=(',', ':'))
    if os.path.exists(SAIDA) and corpo in open(SAIDA, encoding='utf-8').read():
        print('Sem mudanças (até %s).' % meses[-1])
        return
    js = ('// Gerado por scripts/cielo_icva_extrair.py - não editar à mão.\n'
          '// Extraído em %s de %s\n'
          'window.CIELO_ICVA = %s;\n') % (datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'), url, corpo)
    open(SAIDA, 'w', encoding='utf-8').write(js)
    print('Gravado %s: %d meses (%s a %s), %d séries mensais, %d trimestres, %d anos.' % (
        os.path.relpath(SAIDA, RAIZ), len(meses), meses[0], meses[-1], len(mensal), len(trim), len(anos)))


if __name__ == '__main__':
    main()
