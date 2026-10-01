"""Extrai os dados do BI Frotas da ABVE para o painel "Panorama Econômico".

Fonte: https://abve.org.br/abve-data/bi-frotas/ (Power BI público).
Gera assets/data/abve_frotas.js (window.ABVE_FROTAS), carregado sob demanda
pelo Dashboard. Para atualizar: `python scripts/abve_extrair.py` e commitar o
arquivo gerado.

Formato (compacto, mensal):
  meses: ['2022-01', ...]
  total: vendas de eletrificados por mês (BaseVendas_ABVE.Quantidade; BEV, PHEV, HEV,
         HEV FLEX e MHEV — sem MHEV 12V/48V, como o total do BI)
  mercado: { vendas, total } por mês — base usada pela ABVE para a
           participação dos eletrificados no mercado total
  dims: { tec|fab|uf|grupo|seg: { nomes: [...], linhas: [[iMes, iNome, qtd], ...] } }
  mun_mt: { nomes, linhas } — municípios de Mato Grosso
"""
import datetime
import json
import os
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(__file__))
import abve_pbi as p  # noqa: E402

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'abve_frotas.js')
E = {'b': 'BaseVendas_ABVE', 't': 'Tcalendario'}
BASE = [('ano', p.col('t', 'Ano')), ('mes', p.col('t', 'MêsNúmero'))]
MUN_BR_MAX = 120  # "Destaques no Brasil": municípios que mais emplacaram no histórico
GRUPOS_MAX = 80  # modelos: só os mais vendidos no histórico (o resto vira "Outros")
# Eletrificados na definição da ABVE (a mesma do total exibido no BI): sem MHEV 12V/48V.
TECNOLOGIAS = ['BEV', 'PHEV', 'HEV', 'HEV FLEX', 'MHEV']
F_TEC = p.filtro_in('b', 'Tipo_Tecnologia', TECNOLOGIAS)


def chave(r):
    return f"{int(r['ano']):04d}-{int(r['mes']):02d}"


def main():
    tot = p.consultar(E, BASE + [('qtd', p.medida('b', 'Quantidade'))], [F_TEC])
    meses = sorted({chave(r) for r in tot if r['ano'] and r['mes']})
    im = {m: i for i, m in enumerate(meses)}
    total = [0] * len(meses)
    for r in tot:
        if r['ano'] and r['mes']:
            total[im[chave(r)]] = int(r['qtd'] or 0)

    mk = p.consultar({'h': 'BaseSerieHistoricaEletrificados_ABVE', 't': 'Tcalendario'},
                     BASE + [('vendas', p.medida('h', 'Vendas de Eletrificados')),
                             ('mercado', p.medida('h', 'Soma_Mercado Geral'))])
    mercado = {'vendas': [0] * len(meses), 'total': [0] * len(meses)}
    for r in mk:
        if r['ano'] and r['mes'] and chave(r) in im:
            mercado['vendas'][im[chave(r)]] = int(float(r['vendas'] or 0))
            mercado['total'][im[chave(r)]] = int(float(r['mercado'] or 0))

    def dim(prop, where=None, manter=None):
        rs = p.consultar(E, BASE + [('nome', p.col('b', prop)), ('qtd', p.medida('b', 'Quantidade'))], [F_TEC] + (where or []))
        rs = [r for r in rs if r['ano'] and r['mes'] and chave(r) in im and (r['qtd'] or 0)]
        for r in rs:
            r['nome'] = (str(r['nome']).strip() if r['nome'] not in (None, '') else 'Não informado')
        if manter:
            soma = {}
            for r in rs:
                soma[r['nome']] = soma.get(r['nome'], 0) + int(r['qtd'])
            top = set(sorted(soma, key=soma.get, reverse=True)[:manter])
            agreg = {}
            for r in rs:
                n = r['nome'] if r['nome'] in top else 'Outros'
                k = (chave(r), n)
                agreg[k] = agreg.get(k, 0) + int(r['qtd'])
            rs = [{'m': k[0], 'nome': k[1], 'qtd': v} for k, v in agreg.items()]
        else:
            rs = [{'m': chave(r), 'nome': r['nome'], 'qtd': int(r['qtd'])} for r in rs]
        nomes = sorted({r['nome'] for r in rs})
        ino = {n: i for i, n in enumerate(nomes)}
        linhas = sorted([[im[r['m']], ino[r['nome']], r['qtd']] for r in rs])
        return {'nomes': nomes, 'linhas': linhas}

    dados = {
        'fonte': 'ABVE Data · BI Frotas (abve.org.br/abve-data/bi-frotas)',
        'extraido_em': datetime.datetime.now().isoformat(timespec='seconds'),
        'meses': meses,
        'total': total,
        'mercado': mercado,
        'dims': {
            'tec': dim('Tipo_Tecnologia'),
            'fab': dim('Fabricante'),
            'uf': dim('Estado'),
            'grupo': dim('GrupoModeloVeiculo', manter=GRUPOS_MAX),
            'seg': dim('Segmento'),
        },
        'mun_mt': dim('Municipio', where=[p.filtro_in('b', 'Estado', ['MT'])]),
    }
    # A base de vendas traz o município sem acento; o cadastro tem a grafia correta.
    sem_acento = lambda t: unicodedata.normalize('NFD', str(t)).encode('ascii', 'ignore').decode().upper().strip()
    cad = p.consultar({'c': 'Cadastro_Municipio'}, [('mun', p.col('c', 'Município')), ('uf', p.col('c', 'Estado'))],
                      [p.filtro_in('c', 'Estado', ['MT'])])
    grafia = {sem_acento(r['mun']): r['mun'] for r in cad if r['mun']}
    dados['mun_mt']['nomes'] = [grafia.get(sem_acento(n), n) for n in dados['mun_mt']['nomes']]

    # Destaques no Brasil: municípios que mais emplacaram no histórico (MUN_BR_MAX), por mês.
    # Nome no formato "Município (UF)", com a grafia do cadastro.
    tot_mun = p.consultar(E, [('cod', p.col('b', 'Municipio_Codigo')), ('qtd', p.medida('b', 'Quantidade'))], [F_TEC])
    top = [r['cod'] for r in sorted((r for r in tot_mun if r['cod']), key=lambda r: -(r['qtd'] or 0))[:MUN_BR_MAX]]
    rs = p.consultar(E, BASE + [('cod', p.col('b', 'Municipio_Codigo')), ('mun', p.col('b', 'Municipio')),
                                ('uf', p.col('b', 'Estado')), ('qtd', p.medida('b', 'Quantidade'))],
                     [F_TEC, p.filtro_in('b', 'Municipio_Codigo', top)])
    cad_br = p.consultar({'c': 'Cadastro_Municipio'}, [('mun', p.col('c', 'Município')), ('uf', p.col('c', 'Estado'))])
    grafia_br = {(r['uf'], sem_acento(r['mun'])): r['mun'] for r in cad_br if r['mun'] and r['uf']}
    nome_br = lambda r: f"{grafia_br.get((r['uf'], sem_acento(r['mun'])), str(r['mun']).title())} ({r['uf']})"
    agreg = {}
    for r in rs:
        if r['ano'] and r['mes'] and chave(r) in im and r['mun'] and (r['qtd'] or 0):
            k = (im[chave(r)], nome_br(r))
            agreg[k] = agreg.get(k, 0) + int(r['qtd'])
    nomes_br = sorted({k[1] for k in agreg})
    ino = {n: i for i, n in enumerate(nomes_br)}
    dados['mun_br'] = {'nomes': nomes_br, 'linhas': sorted([[k[0], ino[k[1]], v] for k, v in agreg.items()])}

    os.makedirs(os.path.dirname(SAIDA), exist_ok=True)
    js = ('// Gerado por scripts/abve_extrair.py — não editar à mão.\n'
          'window.ABVE_FROTAS = ' + json.dumps(dados, ensure_ascii=False, separators=(',', ':')) + ';\n')
    with open(SAIDA, 'w', encoding='utf-8') as f:
        f.write(js)
    print(f'{SAIDA}: {len(js) // 1024} KB · {meses[0]}..{meses[-1]} · '
          + ', '.join(f"{k}={len(v['linhas'])}" for k, v in dados['dims'].items())
          + f", mun_mt={len(dados['mun_mt']['linhas'])}, mun_br={len(dados['mun_br']['linhas'])}")


if __name__ == '__main__':
    main()
