"""Extrai os dados do Novo CAGED para o painel "Panorama Econômico" (indicador CAGED).

Fonte: Painel Novo CAGED (Ministério do Trabalho e Emprego), Power BI público.
Gera assets/data/caged_dados.js (window.CAGED_DADOS), carregado sob demanda pelo
Dashboard. Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml)
junto com a extração da ABVE; só regrava o arquivo se os dados mudaram.

Formato (compacto, mensal, a partir de ANO_INICIAL):
  meses: ['2023-01', ...]
  total: { adm, des, sal, est } por mês (Brasil)
  dims: { uf|setor|secao|ocup|mun: { nomes: [...], linhas: [[iMes, iNome, adm, des, sal(, est)], ...] } }
    uf: com estoque; ocup/mun: só os TOP_MAX com mais admissões no período.

Também gera assets/data/caged_relatorio.js (window.CAGED_RELATORIO), usado pelo
relatório em PDF "CAGED - Empregos Formais" (Relatórios > Gerar relatório):
  meses: ['2023-01', ...]
  regioes: { cuiaba|mt: { total: [[iMes, adm, des, sal], ...],
                          sexo|faixa|escol|setor: { nomes: [...], linhas: [[iMes, iNome, adm, des, sal], ...] } } }
"""
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import abve_pbi as p  # noqa: E402

p.usar(p.CAGED)
RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'caged_dados.js')
SAIDA_REL = os.path.join(RAIZ, 'assets', 'data', 'caged_relatorio.js')
ANO_INICIAL = 2023   # 2023 é a base de comparação do primeiro ano exibido (2024)
TOP_MAX = 100        # ocupações e municípios guardados para a visão Brasil
E = {'m': 'Medidas', 'd': 'TabelaDeDatas', 'g': 'Geográfico', 'e': 'Econômico', 'o': 'Ocupacional',
     's': 'Sexo', 'f': 'Faixa Etária', 'i': 'Grau de Instrução'}
BASE = [('ano', p.col('d', 'Ano')), ('mes', p.col('d', 'Mês'))]
MED = [('adm', p.medida('m', 'Admitidos')), ('des', p.medida('m', 'Desligados')), ('sal', p.medida('m', 'Saldo'))]


# Relatório em PDF: Cuiabá (código IBGE 510340) e Mato Grosso, por perfil e setor.
REGIOES = {'cuiaba': [p.filtro_in('g', 'Código Município', [510340])], 'mt': [p.filtro_in('g', 'UF Sigla', ['MT'])]}
DIMS_REL = {'sexo': ('s', 'Sexo.1'), 'faixa': ('f', 'Faixa Etária'), 'escol': ('i', 'Grau de Instrução'), 'setor': ('e', 'Grande Grupamento')}
ORDEM_ESCOL = ['Analfabeto', 'Até 5ª Incompleto', '5ª Completo Fundamental', '6ª a 9ª Fundamental', 'Fundamental Incompleto',
               'Fundamental Completo', 'Médio Incompleto', 'Médio Completo', 'Superior Incompleto', 'Superior Completo',
               'Pós-Graduação completa', 'Mestrado', 'Doutorado']


def relatorio(F_ANOS, meses, im, chave):
    def ordem(dim, n):
        if dim == 'escol':
            return (ORDEM_ESCOL.index(n) if n in ORDEM_ESCOL else 99, n)
        if dim == 'faixa':
            return (0 if n.startswith('Até') else 1, n)
        return (0, n)
    out = {}
    for reg, onde in REGIOES.items():
        tot = p.consultar(E, BASE + MED, [F_ANOS] + onde)
        r = {'total': sorted([im[chave(x)], int(x['adm'] or 0), int(x['des'] or 0), int(x['sal'] or 0)]
                             for x in tot if x['ano'] and x['mes'] and chave(x) in im)}
        for nome, (src, prop) in DIMS_REL.items():
            rs = [x for x in p.consultar(E, BASE + [('k', p.col(src, prop))] + MED, [F_ANOS] + onde)
                  if x['ano'] and x['mes'] and x['k'] and chave(x) in im
                  and str(x['k']).strip().lower() != 'não identificado']
            nomes = sorted({str(x['k']).strip() for x in rs}, key=lambda n: ordem(nome, n))
            ino = {n: i for i, n in enumerate(nomes)}
            r[nome] = {'nomes': nomes, 'linhas': sorted([im[chave(x)], ino[str(x['k']).strip()], int(x['adm'] or 0),
                                                       int(x['des'] or 0), int(x['sal'] or 0)] for x in rs)}
        out[reg] = r
    return {'fonte': 'Novo CAGED · Ministério do Trabalho e Emprego',
            'extraido_em': datetime.datetime.now().isoformat(timespec='seconds'),
            'meses': meses, 'regioes': out}


def gravar_relatorio(dados):
    corpo = lambda d: json.dumps({k: v for k, v in d.items() if k != 'extraido_em'}, ensure_ascii=False, separators=(',', ':'))
    try:
        with open(SAIDA_REL, encoding='utf-8') as f:
            antigo = json.loads(f.read().split('window.CAGED_RELATORIO = ', 1)[1].rstrip().rstrip(';'))
        if corpo(antigo) == corpo(dados):
            print('Sem mudanças no relatório do CAGED — arquivo mantido.')
            return
    except (OSError, IndexError, ValueError):
        pass
    js = ('// Gerado por scripts/caged_extrair.py — não editar à mão.\n'
          'window.CAGED_RELATORIO = ' + json.dumps(dados, ensure_ascii=False, separators=(',', ':')) + ';\n')
    with open(SAIDA_REL, 'w', encoding='utf-8') as f:
        f.write(js)
    print(f'{SAIDA_REL}: {len(js) // 1024} KB')


def main():
    anos = [str(a) for a in range(ANO_INICIAL, datetime.date.today().year + 1)]
    F_ANOS = p.filtro_in('d', 'Ano', anos)
    chave = lambda r: f"{r['ano']}-{str(r['mes']).zfill(2)}"
    tot = p.consultar(E, BASE + MED + [('est', p.medida('m', 'Estoque Mensal'))], [F_ANOS])
    tot = [r for r in tot if r['ano'] and r['mes'] and (r['adm'] or r['des'])]
    meses = sorted({chave(r) for r in tot})
    im = {m: i for i, m in enumerate(meses)}
    total = {k: [0] * len(meses) for k in ('adm', 'des', 'sal', 'est')}
    for r in tot:
        for k in total:
            total[k][im[chave(r)]] = int(r[k] or 0)

    def dim(expr_nome, where=None, com_est=False, nome=None):
        sel = BASE + [('k', expr_nome)] + ([('uf', p.col('g', 'UF Sigla'))] if nome else []) + MED \
            + ([('est', p.medida('m', 'Estoque Mensal'))] if com_est else [])
        rs = p.consultar(E, sel, [F_ANOS] + (where or []))
        ag = {}
        for r in rs:
            if not (r['ano'] and r['mes'] and r['k'] and chave(r) in im):
                continue
            n = nome(r) if nome else str(r['k']).strip()
            if n == 'Não Identificado':
                continue
            k = (im[chave(r)], n)
            v = ag.setdefault(k, [0, 0, 0, 0])
            for j, c in enumerate(('adm', 'des', 'sal', 'est')):
                v[j] += int(r.get(c) or 0)
        nomes = sorted({k[1] for k in ag})
        ino = {n: i for i, n in enumerate(nomes)}
        linhas = sorted([[k[0], ino[k[1]]] + (v if com_est else v[:3]) for k, v in ag.items()])
        return {'nomes': nomes, 'linhas': linhas}

    def top(prop_src, prop):
        rs = p.consultar(E, [('k', p.col(prop_src, prop)), ('adm', p.medida('m', 'Admitidos'))], [F_ANOS])
        return [r['k'] for r in sorted((r for r in rs if r['k'] is not None), key=lambda r: -(r['adm'] or 0))[:TOP_MAX]]

    ocups = top('o', 'Ocupação')
    muns = top('g', 'Código Município')
    dados = {
        'fonte': 'Novo CAGED · Ministério do Trabalho e Emprego',
        'extraido_em': datetime.datetime.now().isoformat(timespec='seconds'),
        'meses': meses,
        'total': total,
        'dims': {
            'uf': dim(p.col('g', 'UF Sigla'), com_est=True),
            'setor': dim(p.col('e', 'Grande Grupamento')),
            'secao': dim(p.col('e', 'CNAE 2.0 Seção')),
            'ocup': dim(p.col('o', 'Ocupação'), [p.filtro_in('o', 'Ocupação', ocups)]),
            'mun': dim(p.col('g', 'Município'), [p.filtro_in('g', 'Código Município', muns)],
                       nome=lambda r: f"{str(r['k']).strip()} ({r['uf']})"),
        },
    }

    os.makedirs(os.path.dirname(SAIDA), exist_ok=True)
    gravar_relatorio(relatorio(F_ANOS, meses, im, chave))
    corpo = lambda d: json.dumps({k: v for k, v in d.items() if k != 'extraido_em'}, ensure_ascii=False, separators=(',', ':'))
    try:
        with open(SAIDA, encoding='utf-8') as f:
            antigo = json.loads(f.read().split('window.CAGED_DADOS = ', 1)[1].rstrip().rstrip(';'))
        if corpo(antigo) == corpo(dados):
            print('Sem mudanças no CAGED — arquivo mantido.')
            return
    except (OSError, IndexError, ValueError):
        pass
    js = ('// Gerado por scripts/caged_extrair.py — não editar à mão.\n'
          'window.CAGED_DADOS = ' + json.dumps(dados, ensure_ascii=False, separators=(',', ':')) + ';\n')
    with open(SAIDA, 'w', encoding='utf-8') as f:
        f.write(js)
    print(f'{SAIDA}: {len(js) // 1024} KB · {meses[0]}..{meses[-1]} · '
          + ', '.join(f"{k}={len(v['linhas'])}" for k, v in dados['dims'].items()))


if __name__ == '__main__':
    main()
