"""Coordenadas dos CEPs do mapa de empresas (Dashboard > Panorama > EMPRESAS > Mapa).

O mapa só plota o endereço registrado de cada CNPJ (o CEP do estabelecimento na Receita): um ponto por CEP,
com a quantidade de CNPJs registrados nele — sem saldo nem outro cálculo.

scripts/cnpj_extrair.py agrega os estabelecimentos de Mato Grosso por CEP e grava assets/data/cnpj_ceps.js.
No CEP geral do município (termina em 000 — cidades onde quase todos usam o mesmo CEP) o ponto é separado
pelo BAIRRO registrado na Receita, para a cidade não virar um único ponto.

Este módulo põe latitude/longitude em cada ponto:
  1. cache scripts/cache/ceps_geo.csv (já consultados — inclusive os não encontrados, para não repetir);
  2. CEP novo ........ AwesomeAPI  GET cep.awesomeapi.com.br/json/{cep}        (coordenada da rua do CEP)
     bairro (CEP geral) AwesomeAPI GET cep.awesomeapi.com.br/search?q={bairro}  (perto da sede do município)
  3. sem coordenada (ainda não consultado ou não encontrado): sede do município (municipios_geo.js),
     marcado como aproximado.

Chave: AWESOMEAPI_KEY (cadastro gratuito em awesomeapi.com.br: 100 mil consultas/mês). Sem chave a cota é
por IP e muito baixa — nos servidores do GitHub ela já chega esgotada. A BrasilAPI NÃO é usada para
coordenada: em Mato Grosso ela devolve o centro da cidade para quase todo CEP (empilhava os CNPJs).
Coordenada repetida em 3+ CEPs comuns (= centro da cidade) é descartada do cache e consultada de novo.

Rodado sozinho (passo diário do GitHub Actions), consulta o que falta no cache dentro de um prazo
(CEP_GEO_MINUTOS, padrão 50) e regrava as coordenadas de assets/data/cnpj_ceps.js. Os pontos com mais
empresas vão primeiro.
"""
import csv
import datetime
import json
import os
import ssl
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'cnpj_ceps.js')
MUN_GEO = os.path.join(RAIZ, 'assets', 'data', 'municipios_geo.js')
CACHE = os.path.join(RAIZ, 'scripts', 'cache', 'ceps_geo.csv')
UA = 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'
BR = (-74.5, -34.5, -28.0, 5.8)   # lon/lat mínimos e máximos do Brasil (descarta coordenada absurda)
CABECALHO = ['cep', 'lon', 'lat', 'logradouro', 'bairro']
CHAVE = os.environ.get('AWESOMEAPI_KEY', '').strip()


# ---------------- Arquivos ----------------
def ler_js(caminho, var):
    """Objeto JSON de um arquivo 'window.VAR = {...};' (None se não existir)."""
    if not os.path.exists(caminho):
        return None
    txt = open(caminho, encoding='utf-8').read()
    i = txt.index('window.%s = ' % var) + len('window.%s = ' % var)
    return json.loads(txt[i:txt.rindex('}') + 1])


def cache_ler():
    """{chave: (lon, lat, logradouro, bairro)}; lon None = consultado e não encontrado.
    Chave = CEP, ou 'CEP|BAIRRO' nos pontos por bairro do CEP geral."""
    out = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding='utf-8-sig', newline='') as f:
            for l in csv.DictReader(f, delimiter=';'):
                lon, lat = l.get('lon') or '', l.get('lat') or ''
                out[l['cep']] = (float(lon), float(lat), l.get('logradouro', ''), l.get('bairro', '')) if lon and lat else (None, None, '', '')
    return out


def cache_limpar(cache):
    """Descarta coordenadas 'de cidade': o mesmo ponto em 3+ CEPs comuns (não terminados em 000)."""
    grupos = {}
    for k, v in cache.items():
        if v[0] is not None and '|' not in k and not k.endswith('000'):
            grupos.setdefault((v[0], v[1]), []).append(k)
    fora = [k for ks in grupos.values() if len(ks) >= 3 for k in ks]
    for k in fora:
        del cache[k]
    return len(fora)


def cache_gravar(cache):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, 'w', encoding='utf-8', newline='') as f:
        w = csv.writer(f, delimiter=';')
        w.writerow(CABECALHO)
        for k in sorted(cache):
            lon, lat, lg, br = cache[k]
            w.writerow([k, '' if lon is None else '%.5f' % lon, '' if lat is None else '%.5f' % lat, lg, br])


def sedes():
    """{código do município na Receita (SIAFI, 4 dígitos): (lon, lat, nome)}."""
    d = ler_js(MUN_GEO, 'MUNICIPIOS_GEO')
    return {str(l[4]).zfill(4): (l[2], l[3], l[1]) for l in d['linhas']} if d else {}


def chave_ponto(dados, i):
    b = (dados.get('bairro') or [''] * len(dados['ceps']))[i]
    return dados['ceps'][i] + ('|' + b.upper() if b else '')


# ---------------- Consulta (AwesomeAPI) ----------------
CTX = ssl.create_default_context()
norm = lambda s: ' '.join(unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode().upper().split())


def _get(url):
    h = {'User-Agent': UA, 'Accept': 'application/json'}
    if CHAVE:
        h['x-api-key'] = CHAVE
    r = urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20, context=CTX)
    return json.loads(r.read().decode('utf-8'))


def _ok(lon, lat):
    try:
        lon, lat = float(lon), float(lat)
    except (TypeError, ValueError):
        return None
    return (lon, lat) if BR[0] <= lon <= BR[2] and BR[1] <= lat <= BR[3] else None


def _consultar(url, tratar):
    """'limite' = cota/erro de rede (tenta de novo outro dia); None = não encontrado; tupla = achou."""
    for tentativa in range(3):
        try:
            return tratar(_get(url))
        except urllib.error.HTTPError as e:
            if e.code in (400, 404):
                return None
            if e.code == 429:
                return 'limite'
            time.sleep(2 * (tentativa + 1))
        except Exception:
            time.sleep(2 * (tentativa + 1))
    return 'limite'


def geocodificar_cep(cep):
    def tratar(j):
        p = _ok(j.get('lng'), j.get('lat'))
        return (p[0], p[1], j.get('address') or '', j.get('district') or '') if p else (None, None, j.get('address') or '', j.get('district') or '')
    r = _consultar('https://cep.awesomeapi.com.br/json/' + cep, tratar)
    return (None, None, '', '') if r is None else r


def geocodificar_bairro(bairro, sede):
    """Bairro do CEP geral: endereço desse bairro mais perto da sede do município (raio de 30 km)."""
    if not sede:
        return (None, None, '', '')
    q = urllib.parse.urlencode({'q': bairro, 'state': 'MT', 'lat': sede[1], 'lng': sede[0], 'd': 30, 'sort': 'asc', 'limit': 10})

    def tratar(j):
        alvo = norm(bairro)
        for x in j.get('results') or []:
            if norm(x.get('district')) == alvo or alvo in norm(x.get('district')):
                p = _ok(x.get('lng'), x.get('lat'))
                if p:
                    return (p[0], p[1], x.get('address') or '', x.get('district') or bairro)
        return (None, None, '', bairro)
    r = _consultar('https://cep.awesomeapi.com.br/search?' + q, tratar)
    return (None, None, '', bairro) if r is None else r


# ---------------- Coordenadas no arquivo do mapa ----------------
def aplicar(dados, cache, sede):
    """Preenche ll (lon, lat), aprox (1 = sede do município) e end ('logradouro · bairro') de cada ponto."""
    ll, aprox, end = [], [], []
    bairros = dados.get('bairro') or [''] * len(dados['ceps'])
    for i, mcod in enumerate(dados['munCod']):
        lon, lat, lg, br = cache.get(chave_ponto(dados, i), (None, None, '', ''))
        if bairros[i]:
            lg, br = '', bairros[i]   # ponto por bairro: o endereço mostrado é o bairro registrado na Receita
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
    if not CHAVE:
        print('Aviso: sem AWESOMEAPI_KEY a cota da AwesomeAPI é por IP e muito baixa (no GitHub costuma vir esgotada).')
    cache = cache_ler()
    descartados = cache_limpar(cache)
    sede = sedes()
    antes = (dados.get('ll'), dados.get('aprox'), dados.get('end'))
    # Mais empresas primeiro (ativas + aberturas + baixas do período).
    peso = [0] * len(dados['ceps'])
    for i, _r, at, ab, bx in dados['d']:
        peso[i] += at + sum(int(x) for x in (ab + ',' + bx).split(',') if x)
    bairros = dados.get('bairro') or [''] * len(dados['ceps'])
    pend = [i for _, i in sorted((-peso[i], i) for i in range(len(dados['ceps'])) if chave_ponto(dados, i) not in cache)]
    prazo = time.time() + 60 * float(os.environ.get('CEP_GEO_MINUTOS') or 50)
    novos = achados = 0
    print('Pontos: %d no mapa · %d no cache · %d coordenadas de cidade descartadas · %d a consultar'
          % (len(dados['ceps']), len(cache), descartados, len(pend)), flush=True)

    def consulta(i):
        if bairros[i]:
            return geocodificar_bairro(bairros[i], sede.get(str(dados['munCod'][i]).zfill(4)))
        return geocodificar_cep(dados['ceps'][i])

    with ThreadPoolExecutor(max_workers=4) as pool:
        for k in range(0, len(pend), 40):
            if time.time() > prazo:
                print('Prazo esgotado; o restante fica para a próxima execução.')
                break
            lote = pend[k:k + 40]
            res = list(pool.map(consulta, lote))
            limite = sum(r == 'limite' for r in res)
            for i, r in zip(lote, res):
                if r != 'limite':
                    cache[chave_ponto(dados, i)] = r
                    novos += 1
                    achados += r[0] is not None
            if k % 1000 == 0:
                print('  %d/%d consultados (%d com coordenada)' % (novos, len(pend), achados), flush=True)
                cache_gravar(cache)
            if limite == len(lote):
                print('Cota da AwesomeAPI esgotada (429) ou sem rede; o restante fica para a próxima execução.')
                break
    cache_gravar(cache)
    aplicar(dados, cache, sede)
    if (dados['ll'], dados['aprox'], dados['end']) == antes:
        print('Coordenadas sem mudança; %s mantido.' % os.path.relpath(SAIDA, RAIZ))
        return
    tam = gravar(dados)
    exatos = len(dados['aprox']) - sum(dados['aprox'])
    print('Gravado %s: %d KB · %d novos pontos consultados (%d com coordenada) · %d de %d pontos com coordenada própria'
          % (os.path.relpath(SAIDA, RAIZ), tam // 1024, novos, achados, exatos, len(dados['ceps'])))


if __name__ == '__main__':
    sys.exit(main())
