"""Extrai a PNAD Contínua para o indicador "IBGE: PNAD" do Panorama Econômico.

Fonte: API do SIDRA (apisidra.ibge.gov.br), com os mesmos números da publicação mensal do IBGE
"Indicadores IBGE: PNAD Contínua [mensal]" (biblioteca, catálogo 73086). A biblioteca fica atrás de
proteção anti-robô e publica PDF; o SIDRA é a base estruturada oficial do relatório.
  Mensal (trimestre móvel, Brasil):
    6381 taxa de desocupação · 6318 pessoas por condição na força de trabalho · 8513 taxa de informalidade
    6390 rendimento médio real e nominal (habitual) · 6392 massa de rendimento real
    6323 ocupados por grupamento de atividade · 6320 ocupados por posição na ocupação
  Trimestral (Brasil e UFs): 4099 taxa de desocupação — a PNAD mensal não abre estados.

Gera assets/data/ibge_pnad.js (window.IBGE_PNAD), carregado sob demanda pelo Dashboard.
Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml) e só regrava o
arquivo se os dados mudaram.

Formato (null = sem dado):
  meses: ['2012-03', ...]              último mês de cada trimestre móvel (mar = jan-fev-mar)
  br: { desoc, informal (%), forca, ocup, desocup, fora (mil pessoas), rend, rend_nom (R$), massa (R$ milhões) }
  ativ: { nomes: [...], v: [[mil pessoas por mês], ...] }      grupamentos de atividade
  pos:  { nomes: [...], v: [[...], ...] }                       posição na ocupação
  uf:   { trimestres: ['2012-1', ...], desoc: [[% por trimestre], ...] }  alinhado a locais (0 = Brasil)
  locais: { sig: ['BR', 'AC', ...], nomes: ['Brasil', 'Acre', ...] }
"""
import datetime
import json
import os
import sys
import time
import urllib.request

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'ibge_pnad.js')
API = 'https://apisidra.ibge.gov.br/values/'
UA = {'User-Agent': 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'}
UF = [(12, 'AC', 'Acre'), (27, 'AL', 'Alagoas'), (16, 'AP', 'Amapá'), (13, 'AM', 'Amazonas'), (29, 'BA', 'Bahia'),
      (23, 'CE', 'Ceará'), (53, 'DF', 'Distrito Federal'), (32, 'ES', 'Espírito Santo'), (52, 'GO', 'Goiás'),
      (21, 'MA', 'Maranhão'), (51, 'MT', 'Mato Grosso'), (50, 'MS', 'Mato Grosso do Sul'), (31, 'MG', 'Minas Gerais'),
      (15, 'PA', 'Pará'), (25, 'PB', 'Paraíba'), (41, 'PR', 'Paraná'), (26, 'PE', 'Pernambuco'), (22, 'PI', 'Piauí'),
      (33, 'RJ', 'Rio de Janeiro'), (24, 'RN', 'Rio Grande do Norte'), (43, 'RS', 'Rio Grande do Sul'),
      (11, 'RO', 'Rondônia'), (14, 'RR', 'Roraima'), (42, 'SC', 'Santa Catarina'), (35, 'SP', 'São Paulo'),
      (28, 'SE', 'Sergipe'), (17, 'TO', 'Tocantins')]
# Grupamentos (c888) e posições (c11913) na ordem e com os nomes curtos do painel.
ATIV = [(47947, 'Agropecuária'), (47948, 'Indústria'), (47949, 'Construção'), (47950, 'Comércio e reparação de veículos'),
        (56622, 'Transporte, armazenagem e correio'), (56623, 'Alojamento e alimentação'),
        (56624, 'Informação, finanças e atividades profissionais'), (60032, 'Administração pública, educação e saúde'),
        (56627, 'Outros serviços'), (56628, 'Serviços domésticos')]
# Posições: "Com/Sem carteira" = empregados do setor privado (exclusive domésticos).
POS = [(31722, 'Com carteira'), (31723, 'Sem carteira'), (31724, 'Doméstico'),
       (31727, 'Setor público'), (96170, 'Empregador'), (96171, 'Conta própria'), (31731, 'Familiar')]


def sidra(caminho):
    for t in range(3):
        try:
            req = urllib.request.Request(API + caminho, headers=UA)
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.loads(r.read().decode('utf-8'))[1:]
        except Exception:
            if t == 2:
                raise
            time.sleep(10 * (t + 1))


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None   # "...", "-", "X": sem dado / sigilo


def mes(p):
    return '%s-%s' % (p[:4], p[4:6])


def serie(tab, var, meses, extra=''):
    """Série mensal (trimestre móvel) Brasil, alinhada a meses."""
    im = {m: i for i, m in enumerate(meses)}
    v = [None] * len(meses)
    for l in sidra('t/%d/n1/all/v/%d/p/all%s' % (tab, var, extra)):
        m = mes(l['D3C'])
        if m in im:
            v[im[m]] = num(l['V'])
    return v


def por_categoria(tab, var, cls, cats, meses):
    im = {m: i for i, m in enumerate(meses)}
    pos = {c: k for k, (c, _) in enumerate(cats)}
    v = [[None] * len(meses) for _ in cats]
    ids = ','.join(str(c) for c, _ in cats)
    for l in sidra('t/%d/n1/all/v/%d/p/all/c%d/%s' % (tab, var, cls, ids)):
        c = int(l['D4C'])
        m = mes(l['D3C'])
        if c in pos and m in im:
            v[pos[c]][im[m]] = num(l['V'])
    return {'nomes': [n for _, n in cats], 'v': v}


def main():
    desoc = sidra('t/6381/n1/all/v/4099/p/all')
    meses = sorted({mes(l['D3C']) for l in desoc})
    if not meses:
        sys.exit('SIDRA não devolveu a taxa de desocupação (tabela 6381).')
    im = {m: i for i, m in enumerate(meses)}
    tx = [None] * len(meses)
    for l in desoc:
        tx[im[mes(l['D3C'])]] = num(l['V'])

    cond = por_categoria(6318, 1641, 629, [(32386, 'forca'), (32387, 'ocup'), (32446, 'desocup'), (32447, 'fora')], meses)
    br = {'desoc': tx, 'informal': serie(8513, 12466, meses),
          'rend': serie(6390, 5933, meses), 'rend_nom': serie(6390, 5929, meses), 'massa': serie(6392, 6293, meses)}
    for n, v in zip(cond['nomes'], cond['v']):
        br[n] = v

    # Trimestral por UF (a PNAD mensal só tem Brasil).
    linhas = sidra('t/4099/n1/all/v/4099/p/all') + sidra('t/4099/n3/all/v/4099/p/all')
    trimestres = sorted({l['D3C'] for l in linhas})
    it = {p: i for i, p in enumerate(trimestres)}
    cod = {'1': 0}
    cod.update({str(c): k + 1 for k, (c, _, _) in enumerate(UF)})
    uf = [[None] * len(trimestres) for _ in range(len(UF) + 1)]
    for l in linhas:
        k = cod.get(l['D1C'])
        if k is not None:
            uf[k][it[l['D3C']]] = num(l['V'])

    dados = {
        'fonte': 'IBGE · PNAD Contínua (SIDRA)',
        'meses': meses,
        'br': br,
        'ativ': por_categoria(6323, 4090, 888, ATIV, meses),
        'pos': por_categoria(6320, 4090, 11913, POS, meses),
        'uf': {'trimestres': ['%s-%d' % (p[:4], int(p[4:])) for p in trimestres], 'desoc': uf},
        'locais': {'sig': ['BR'] + [s for _, s, _ in UF], 'nomes': ['Brasil'] + [n for _, _, n in UF]},
    }
    corpo = json.dumps(dados, ensure_ascii=False, separators=(',', ':'))
    if os.path.exists(SAIDA) and corpo in open(SAIDA, encoding='utf-8').read():
        print('Sem mudanças (até %s).' % meses[-1])
        return
    js = ('// Gerado por scripts/ibge_pnad_extrair.py - não editar à mão.\n'
          '// Extraído em %s do SIDRA/IBGE (PNAD Contínua).\n'
          'window.IBGE_PNAD = %s;\n') % (datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'), corpo)
    open(SAIDA, 'w', encoding='utf-8').write(js)
    print('Gravado %s: %d trimestres móveis (%s a %s), %d trimestres por UF (até %s).' % (
        os.path.relpath(SAIDA, RAIZ), len(meses), meses[0], meses[-1], len(trimestres), dados['uf']['trimestres'][-1]))


if __name__ == '__main__':
    main()
