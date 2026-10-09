"""Coordenadas dos CEPs do mapa de empresas (Dashboard > Panorama > EMPRESAS > Mapa).

O mapa só plota o endereço registrado de cada CNPJ (o CEP do estabelecimento na Receita): um ponto por CEP,
com a quantidade de CNPJs registrados nele — sem saldo nem outro cálculo.

scripts/cnpj_extrair.py agrega os estabelecimentos de Mato Grosso por CEP e grava assets/data/cnpj_ceps.js.
Este módulo põe latitude/longitude em cada CEP:
  1. cache scripts/cache/ceps_geo.csv (CEPs já consultados — inclusive os não encontrados, para não repetir);
  2. CEP novo: AwesomeAPI (cep.awesomeapi.com.br) e, se faltar, BrasilAPI v2 (brasilapi.com.br);
  3. CEP sem coordenada (ainda não consultado ou não encontrado): sede do município (assets/data/municipios_geo.js),
     marcado como aproximado.

Rodado sozinho (passo diário do GitHub Actions), consulta os CEPs que faltam no cache, dentro de um prazo
(CEP_GEO_MINUTOS, padrão 40), e regrava as coordenadas de assets/data/cnpj_ceps.js. Os CEPs com mais
empresas vão primeiro; os demais ficam para os dias seguintes.
"""
import csv
import datetime
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'cnpj_ceps.js')
MUN_GEO = os.path.join(RAIZ, 'assets', 'data', 'municipios_geo.js')
CACHE = os.path.join(RAIZ, 'scripts', 'cache', 'ceps_geo.csv')
UA = 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'
BR = (-74.5, -34.5, -28.0, 5.8)   # lon/lat mínimos e máximos do Brasil (descarta coordenada absurda)
CABECALHO = ['cep', 'lon', 'lat', 'logradouro', 'bairro']


# ---------------- Arquivos ----------------
def ler_js(caminho, var):
    """Objeto JSON de um arquivo 'window.VAR = {...};' (None se não existir)."""
    if not os.path.exists(caminho):
        return None
    txt = open(caminho, encoding='utf-8').read()
    i = txt.index('window.%s = ' % var) + len('window.%s = ' % var)
    return json.loads(txt[i:txt.rindex('}') + 1])


def cache_ler():
    """{cep: (lon, lat, logradouro, bairro)}; lon None = consultado e não encontrado."""
    out = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding='utf-8', newline='') as f:
            for l in csv.DictReader(f, delimiter=';'):
                lon, lat = l.get('lon') or '', l.get('lat') or ''
                out[l['cep']] = (float(lon), float(lat), l.get('logradouro', ''), l.get('bairro', '')) if lon and lat else (None, None, '', '')
    return out


def cache_gravar(cache):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, 'w', encoding='utf-8', newline='') as f:
        w = csv.writer(f, delimiter=';')
        w.writerow(CABECALHO)
        for cep in sorted(cache):
            lon, lat, lg, br = cache[cep]
            w.writerow([cep, '' if lon is None else '%.5f' % lon, '' if lat is None else '%.5f' % lat, lg, br])


def sedes():
    """{código do município na Receita (SIAFI, 4 dígitos): (lon, lat)}."""
    d = ler_js(MUN_GEO, 'MUNICIPIOS_GEO')
    return {str(l[4]).zfill(4): (l[2], l[3]) for l in d['linhas']} if d else {}


# ---------------- Consulta ----------------
CTX = ssl.create_default_context()


def _get(url):
    r = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': 'application/json'}),
                               timeout=20, context=CTX)
    return json.loads(r.read().decode('utf-8'))


def _ok(lon, lat):
    try:
        lon, lat = float(lon), float(lat)
    except (TypeError, ValueError):
        return None
    return (lon, lat) if BR[0] <= lon <= BR[2] and BR[1] <= lat <= BR[3] else None


def geocodificar(cep):
    """(lon, lat, logradouro, bairro) | (None, None, '', '') se não houver | 'limite' se a API pediu pausa."""
    lg = br = ''
    for tentativa in range(3):
        try:
            j = _get('https://cep.awesomeapi.com.br/json/' + cep)
            lg, br = j.get('address') or '', j.get('district') or ''
            p = _ok(j.get('lng'), j.get('lat'))
            if p:
                return (p[0], p[1], lg, br)
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                break
            if e.code == 429:
                time.sleep(5 * (tentativa + 1))
                continue
            break
        except Exception:
            time.sleep(2)
    try:
        j = _get('https://brasilapi.com.br/api/cep/v2/' + cep)
        c = (j.get('location') or {}).get('coordinates') or {}
        p = _ok(c.get('longitude'), c.get('latitude'))
        lg, br = lg or j.get('street') or '', br or j.get('neighborhood') or ''
        if p:
            return (p[0], p[1], lg, br)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            return 'limite'
    except Exception:
        return 'limite'   # falha de rede: tenta de novo outro dia
    return (None, None, lg, br)


# ---------------- Coordenadas no arquivo do mapa ----------------
def aplicar(dados, cache, sede):
    """Preenche ll (lon, lat), aprox (1 = sede do município) e end ('logradouro · bairro') de cada CEP."""
    ll, aprox, end = [], [], []
    for cep, mcod in zip(dados['ceps'], dados['munCod']):
        lon, lat, lg, br = cache.get(cep, (None, None, '', ''))
        if lon is None:
            s = sede.get(str(mcod).zfill(4))
            ll.append([round(s[0], 5), round(s[1], 5)] if s else None)
            aprox.append(1)
        else:
            ll.append([round(lon, 5), round(lat, 5)])
            aprox.append(0)
        end.append(' · '.join(x for x in (lg, br) if x))
    dados['ll'], dados['aprox'], dados['end'] = ll, aprox, end
    return dados


def gravar(dados):
    js = ('// Gerado por scripts/cnpj_extrair.py e scripts/cnpj_ceps_geo.py - não editar à mão.\n'
          '// Estabelecimentos de %s por CEP (edição %s dos dados abertos do CNPJ); coordenadas atualizadas em %s.\n'
          'window.CNPJ_CEPS = %s;\n') % (dados['uf'], dados['edicao'], datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
                                         json.dumps(dados, ensure_ascii=False, separators=(',', ':')))
    open(SAIDA, 'w', encoding='utf-8').write(js)
    return len(js)


def main():
    dados = ler_js(SAIDA, 'CNPJ_CEPS')
    if not dados:
        print('Sem %s: rode scripts/cnpj_extrair.py antes.' % os.path.relpath(SAIDA, RAIZ))
        return
    cache = cache_ler()
    # Mais empresas primeiro (ativas + aberturas + baixas do período).
    peso = [0] * len(dados['ceps'])
    for i, _r, at, ab, bx in dados['d']:
        peso[i] += at + sum(int(x) for x in (ab + ',' + bx).split(',') if x)
    pend = [c for _, c in sorted((-peso[i], c) for i, c in enumerate(dados['ceps']) if c not in cache)]
    prazo = time.time() + 60 * float(os.environ.get('CEP_GEO_MINUTOS') or 40)
    novos = achados = 0
    print('CEPs: %d no mapa · %d no cache · %d a consultar' % (len(dados['ceps']), len(cache), len(pend)), flush=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        for k in range(0, len(pend), 40):
            if time.time() > prazo:
                print('Prazo esgotado; o restante fica para a próxima execução.')
                break
            lote = pend[k:k + 40]
            res = list(pool.map(geocodificar, lote))
            if 'limite' in res:
                print('API pediu pausa; aguardando 60s...', flush=True)
                time.sleep(60)
            for cep, r in zip(lote, res):
                if r != 'limite':
                    cache[cep] = r
                    novos += 1
                    achados += r[0] is not None
            if k % 1000 == 0:
                print('  %d/%d consultados (%d com coordenada)' % (novos, len(pend), achados), flush=True)
                cache_gravar(cache)
    if not novos:
        print('Nenhum CEP novo consultado; %s mantido.' % os.path.relpath(SAIDA, RAIZ))
        return
    cache_gravar(cache)
    aplicar(dados, cache, sedes())
    tam = gravar(dados)
    exatos = len(dados['aprox']) - sum(dados['aprox'])
    print('Gravado %s: %d KB · %d novos CEPs consultados (%d com coordenada) · %d de %d CEPs com coordenada própria'
          % (os.path.relpath(SAIDA, RAIZ), tam // 1024, novos, achados, exatos, len(dados['ceps'])))


if __name__ == '__main__':
    sys.exit(main())
