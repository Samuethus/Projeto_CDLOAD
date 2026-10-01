"""Cliente mínimo do Power BI "Publicar na Web" (relatório público da ABVE).

O relatório BI Frotas (https://abve.org.br/abve-data/bi-frotas/) é um Power BI
público. O navegador consulta o modelo pela API pública `querydata`, com a chave
do link de publicação; aqui fazemos o mesmo, com consultas agregadas próprias.

Uso: importado por scripts/abve_extrair.py. Só a biblioteca padrão do Python.
"""
import json
import urllib.request
import uuid

RESOURCE_KEY = '079ec3b8-1fd6-4c00-93b0-fd22b9258970'
CLUSTER = 'https://wabi-brazil-south-b-primary-api.analysis.windows.net'
DATASET_ID = 'bf99f664-ff4f-43e7-a258-139c3e11a6e2'
REPORT_ID = '8dfea0d6-d8e9-4d9c-b5bb-9de3509781b7'
MODEL_ID = 8592399


def col(src, prop):
    return {'Column': {'Expression': {'SourceRef': {'Source': src}}, 'Property': prop}}


def medida(src, prop):
    return {'Measure': {'Expression': {'SourceRef': {'Source': src}}, 'Property': prop}}


def soma(src, prop):
    return {'Aggregation': {'Expression': col(src, prop), 'Function': 0}}


def filtro_in(src, prop, valores):
    lit = [[{'Literal': {'Value': (f"'{v}'" if isinstance(v, str) else f'{v}L')}}] for v in valores]
    return {'Condition': {'In': {'Expressions': [col(src, prop)], 'Values': lit}}}


def consultar(entidades, selects, where=None, limite=30000):
    """entidades: {'b': 'BaseVendas_ABVE', ...}; selects: [(nome, expressão)].

    Retorna lista de dicts {nome: valor}."""
    query = {
        'Version': 2,
        'From': [{'Name': k, 'Entity': v, 'Type': 0} for k, v in entidades.items()],
        'Select': [dict(expr, Name=nome) for nome, expr in selects],
    }
    if where:
        query['Where'] = where
    corpo = {
        'version': '1.0.0',
        'queries': [{
            'Query': {'Commands': [{'SemanticQueryDataShapeCommand': {
                'Query': query,
                'Binding': {'Primary': {'Groupings': [{'Projections': list(range(len(selects)))}]},
                            'DataReduction': {'DataVolume': 4, 'Primary': {'Window': {'Count': limite}}},
                            'Version': 1},
                'ExecutionMetricsKind': 1}}]},
            'QueryId': '',
            'ApplicationContext': {'DatasetId': DATASET_ID, 'Sources': [{'ReportId': REPORT_ID}]},
        }],
        'cancelQueries': [],
        'modelId': MODEL_ID,
    }
    req = urllib.request.Request(
        CLUSTER + '/public/reports/querydata?synchronous=true',
        data=json.dumps(corpo).encode('utf-8'),
        headers={'Content-Type': 'application/json;charset=UTF-8',
                 'X-PowerBI-ResourceKey': RESOURCE_KEY,
                 'ActivityId': str(uuid.uuid4()), 'RequestId': str(uuid.uuid4()),
                 'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=120) as r:
        resp = json.load(r)
    return decodificar(resp, [n for n, _ in selects])


def decodificar(resp, nomes):
    """Decodifica o formato DSR (linhas comprimidas com R=repetir e Ø=nulo)."""
    res = resp['results'][0]['result']['data']
    if 'dsr' not in res:
        raise RuntimeError(json.dumps(res)[:2000])
    ds = res['dsr']['DS'][0]
    if 'odata.error' in ds:
        raise RuntimeError(json.dumps(ds['odata.error'])[:2000])
    dicts = ds.get('ValueDicts', {})
    linhas = ds['PH'][0].get('DM0', [])
    esquema = None
    anterior = None
    saida = []
    for ln in linhas:
        if 'S' in ln:
            esquema = ln['S']
        n = len(esquema)
        valores = [None] * n
        rep = ln.get('R', 0)
        nulos = ln.get('Ø', 0)
        dados = list(ln.get('C', []))
        for i in range(n):
            if rep & (1 << i):
                valores[i] = anterior[i]
            elif nulos & (1 << i):
                valores[i] = None
            else:
                v = dados.pop(0) if dados else None
                dn = esquema[i].get('DN')
                if dn and isinstance(v, int):
                    v = dicts[dn][v]
                valores[i] = v
        anterior = valores
        saida.append(dict(zip(nomes, valores)))
    return saida
