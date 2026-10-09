"""Extrai as inscrições no CNPJ (dados abertos da Receita Federal) para o indicador "EMPRESAS" do Panorama.

Fonte: Cadastro Nacional da Pessoa Jurídica — dados abertos da Receita Federal
  https://dados.gov.br/dados/conjuntos-dados/cadastro-nacional-da-pessoa-juridica---cnpj
  https://arquivos.receitafederal.gov.br/index.php/s/YggdBLfdninEJX9  (pasta mensal AAAA-MM, WebDAV público)
Usa os arquivos Estabelecimentos0..9.zip (~5 GB compactados, uma linha por estabelecimento — matriz
ou filial), além de Municipios.zip e Cnaes.zip. Baixa um arquivo por vez, lê em fluxo e apaga.

Mesmo racional do Novo CAGED, com estabelecimentos no lugar de vínculos:
  aberturas  = estabelecimentos com data de início de atividade no mês
  baixas     = estabelecimentos com situação cadastral BAIXADA (08) e data da situação no mês
  saldo      = aberturas − baixas
  estoque    = inscrições abertas e não baixadas (ativas, suspensas ou inaptas) no fim do mês,
               reconstruído a partir do estoque no início da série e do saldo mensal.
Por ser um retrato do cadastro, um mês recente pode crescer um pouco na edição seguinte
(inscrições e baixas registradas com data retroativa).

Gera assets/data/cnpj_empresas.js (window.CNPJ_EMPRESAS), carregado sob demanda pelo Dashboard.
Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml): consulta só a lista de pastas e
sai na hora se a edição mais recente já foi processada (a Receita publica uma vez por mês).

Formato:
  edicao: 'AAAA-MM' · meses: ['2023-01', ...] (até o mês anterior ao da edição)
  ufs: ['AC', ...] · cnaes: { cod: ['0111301', ...], nome: [...] }
  mun: { nome: [...], uf: [iUf, ...] }
  f:   [[iUf, iCnae, 'aberturas', 'baixas'], ...]   série mensal por estado × subclasse CNAE
  e0:  [[iUf, iCnae, estoque], ...]                  estoque no início da série
  fm:  [['aberturas', 'baixas'], ...]                série mensal por município (mesma ordem de mun)
  em0: [estoque por município no início da série]
  amostra: { colunas: [...], linhas: [[...], ...] }  até AMOSTRA_MAX estabelecimentos abertos no último mês
           (Mato Grosso primeiro), com as 30 colunas do arquivo Estabelecimentos e as descrições usadas
           no painel — só para entender a base (botão Exportar). E-mail e telefones vão mascarados.
  Séries compactas: valores mensais separados por vírgula, zero = vazio, zeros finais cortados
  ('3,,1' = [3, 0, 1, 0, ...]). O arquivo fica ~3x menor (e ~4x menor com a compressão do servidor).
"""
import datetime
import io
import json
import os
import re
import sys
import time
import unicodedata
import urllib.request
import zipfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'cnpj_empresas.js')
WEBDAV = 'https://arquivos.receitafederal.gov.br/public.php/webdav/'
TOKEN = 'YggdBLfdninEJX9'   # compartilhamento público "Dados Abertos CNPJ" (usuário do WebDAV, sem senha)
UA = 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'
ANO_INICIAL = 2023          # base de comparação do primeiro ano exibido (2024), como no CAGED
TMP = os.environ.get('CNPJ_TMP') or os.path.join(RAIZ, '.cnpj_tmp')
AMOSTRA_MAX = 10
AMOSTRA_UF = b'MT'
# Leiaute do arquivo Estabelecimentos (metadados da Receita Federal), na ordem das colunas.
COLUNAS_ESTAB = ['CNPJ básico', 'CNPJ ordem', 'CNPJ DV', 'Identificador matriz/filial', 'Nome fantasia', 'Situação cadastral',
                 'Data da situação cadastral', 'Motivo da situação cadastral', 'Nome da cidade no exterior', 'País',
                 'Data de início da atividade', 'CNAE fiscal principal', 'CNAE fiscal secundária', 'Tipo de logradouro',
                 'Logradouro', 'Número', 'Complemento', 'Bairro', 'CEP', 'UF', 'Município (código Receita)', 'DDD 1',
                 'Telefone 1', 'DDD 2', 'Telefone 2', 'DDD do fax', 'Fax', 'Correio eletrônico', 'Situação especial',
                 'Data da situação especial']
COLUNAS_EXTRA = ['Descrição matriz/filial', 'Descrição da situação cadastral', 'Descrição do CNAE principal',
                 'Município', 'Evento no painel', 'Grande setor (painel)', 'Associação (painel)']
SITUACAO = {'01': 'Nula', '1': 'Nula', '02': 'Ativa', '2': 'Ativa', '03': 'Suspensa', '3': 'Suspensa',
            '04': 'Inapta', '4': 'Inapta', '08': 'Baixada', '8': 'Baixada'}
CONTATO = {21, 22, 23, 24, 25, 26}   # DDDs e telefones/fax (índices na linha)


def mascarar(i, v):
    """Contatos de MEI costumam ser dados pessoais: e-mail e telefones saem mascarados na amostra."""
    if not v:
        return v
    if i == 27 and '@' in v:
        u, d = v.split('@', 1)
        return u[:2] + '***@' + d
    if i in CONTATO and i not in (21, 23, 25):   # telefones e fax (os DDDs ficam)
        return '*' * max(0, len(v) - 2) + v[-2:]
    return v


def setor_painel(cnae):
    d = int(cnae[:2]) if cnae[:2].isdigit() else 0
    return ('Agropecuária' if 1 <= d <= 3 else 'Indústria' if 5 <= d <= 39 else 'Construção' if 41 <= d <= 43
            else 'Comércio' if 45 <= d <= 47 else 'Serviços' if d >= 49 else '')


def req(caminho, metodo='GET', cabecalhos=None):
    import base64
    h = {'User-Agent': UA, 'Authorization': 'Basic ' + base64.b64encode((TOKEN + ':').encode()).decode()}
    h.update(cabecalhos or {})
    return urllib.request.Request(WEBDAV + caminho, method=metodo, headers=h)


def listar(caminho=''):
    with urllib.request.urlopen(req(caminho, 'PROPFIND', {'Depth': '1'}), timeout=120) as r:
        xml = r.read().decode('utf-8', 'ignore')
    return re.findall(r'<d:href>/public\.php/webdav/([^<]*)</d:href>', xml)


def baixar(caminho, destino):
    """Baixa para disco (zip precisa de acesso aleatório), com novas tentativas e retomada."""
    if os.environ.get('CNPJ_MANTER') and os.path.exists(destino):   # testes locais: reaproveita o que já baixou
        try:
            with zipfile.ZipFile(destino) as z:
                z.namelist()
            return
        except zipfile.BadZipFile:
            pass
    for t in range(5):
        try:
            feito = os.path.getsize(destino) if os.path.exists(destino) else 0
            r = urllib.request.urlopen(req(caminho, cabecalhos={'Range': 'bytes=%d-' % feito} if feito else None), timeout=300)
            if feito and r.status != 206:
                feito = 0
            with r, open(destino, 'ab' if feito else 'wb') as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            with zipfile.ZipFile(destino) as z:
                z.namelist()
            return
        except Exception as e:
            print('  tentativa %d de %s falhou: %s' % (t + 1, caminho, e))
            if t >= 2 and os.path.exists(destino):
                os.remove(destino)
            time.sleep(15 * (t + 1))
    raise RuntimeError('Não foi possível baixar ' + caminho)


def linhas_zip(arquivo):
    with zipfile.ZipFile(arquivo) as z:
        with z.open(z.namelist()[0]) as fh:
            for l in io.BufferedReader(fh, 1 << 22):
                yield l


def norm(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode().upper()
    return re.sub(r'[^A-Z0-9]+', ' ', s).strip()


def nomes_ibge():
    """(UF, nome normalizado) -> nome oficial com acentos (API de localidades do IBGE)."""
    try:
        r = urllib.request.urlopen(urllib.request.Request('https://servicodados.ibge.gov.br/api/v1/localidades/municipios',
                                                          headers={'User-Agent': UA}), timeout=120)
        b = r.read()
        if b[:2] == bytes([0x1F, 0x8B]):   # a API responde compactada mesmo sem pedir
            import gzip
            b = gzip.decompress(b)
        out = {}
        for m in json.loads(b.decode('utf-8')):
            uf = m['microrregiao']['mesorregiao']['UF']['sigla'] if m.get('microrregiao') else m['regiao-imediata']['regiao-intermediaria']['UF']['sigla']
            out[(uf, norm(m['nome']))] = m['nome']
        return out
    except Exception as e:
        print('Aviso: nomes do IBGE indisponíveis (%s); usando os da Receita.' % e)
        return {}


def titulo(s):
    pequenas = {'de', 'da', 'do', 'das', 'dos', 'e'}
    return ' '.join(w.lower() if i and w.lower() in pequenas else w.capitalize() for i, w in enumerate(s.split()))


def montar_amostra(brutas, cnae_nome, mun_rfb, ibge, mes):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from caged_extrair import GRP_ASSOC, assoc   # mesmas regras de associação do CAGED/Sefaz
    linhas = []
    for c in brutas:
        v = [x.decode('latin-1').strip().strip('"') for x in c]
        v = (v + [''] * len(COLUNAS_ESTAB))[:len(COLUNAS_ESTAB)]
        cnae = v[11].zfill(7)
        mun = mun_rfb.get(v[20].encode(), v[20])
        linhas.append([mascarar(i, x) for i, x in enumerate(v)] + [
            {'1': 'Matriz', '2': 'Filial'}.get(v[3], v[3]), SITUACAO.get(v[5], v[5]), cnae_nome.get(cnae, ''),
            ibge.get((v[19], norm(mun))) or titulo(mun), 'Abertura em ' + mes, setor_painel(cnae), GRP_ASSOC[assoc(cnae)]])
    return {'colunas': COLUNAS_ESTAB + COLUNAS_EXTRA, 'linhas': linhas}


def main():
    pastas = sorted(p.strip('/') for p in listar() if re.fullmatch(r'\d{4}-\d{2}/', p))
    if not pastas:
        sys.exit('Nenhuma pasta mensal encontrada no compartilhamento da Receita.')
    edicao = pastas[-1]
    if os.path.exists(SAIDA) and ('"edicao":"%s"' % edicao) in open(SAIDA, encoding='utf-8').read(2000):
        print('Sem mudanças (edição %s já processada).' % edicao)
        return
    arquivos = [a.split('/')[-1] for a in listar(edicao + '/')]
    estabs = sorted(a for a in arquivos if re.fullmatch(r'Estabelecimentos\d\.zip', a))
    if len(estabs) < 10 or 'Municipios.zip' not in arquivos or 'Cnaes.zip' not in arquivos:
        sys.exit('Edição %s incompleta (%d arquivos de estabelecimentos).' % (edicao, len(estabs)))
    os.makedirs(TMP, exist_ok=True)

    # Último mês completo: o anterior ao da edição (a extração é feita no início do mês).
    a, m = int(edicao[:4]), int(edicao[5:])
    a, m = (a, m - 1) if m > 1 else (a - 1, 12)
    meses = ['%04d-%02d' % (y, k) for y in range(ANO_INICIAL, a + 1) for k in range(1, 13) if (y, k) <= (a, m)]
    im = {mm.replace('-', '').encode(): i for i, mm in enumerate(meses)}   # b'202301' -> 0
    ini = ('%04d0101' % ANO_INICIAL).encode()
    fim = ('%04d%02d31' % (a, m)).encode()

    # Tabelas auxiliares
    for aux in ('Municipios.zip', 'Cnaes.zip'):
        baixar('%s/%s' % (edicao, aux), os.path.join(TMP, aux))
    cnae_nome = {}
    for l in linhas_zip(os.path.join(TMP, 'Cnaes.zip')):
        p = l.decode('latin-1').strip().strip('"').split('";"')
        if len(p) == 2:
            cnae_nome[p[0].zfill(7)] = p[1].strip()
    mun_rfb = {}
    for l in linhas_zip(os.path.join(TMP, 'Municipios.zip')):
        p = l.decode('latin-1').strip().strip('"').split('";"')
        if len(p) == 2:
            mun_rfb[p[0].encode()] = p[1].strip()

    ufs, cnaes, muns = {}, {}, {}
    mun_uf = {}
    f, e0, fm, em0 = {}, {}, {}, {}
    amostra, reserva = [], []   # aberturas do último mês: Mato Grosso primeiro, outros estados completam
    ultimo = meses[-1].replace('-', '').encode()
    def idx(d, k):
        i = d.get(k)
        if i is None:
            i = d[k] = len(d)
        return i

    t0 = time.time()
    total = 0
    # Downloads em paralelo (o servidor limita a velocidade por conexão); a leitura segue a ordem dos arquivos.
    from concurrent.futures import ThreadPoolExecutor
    pool = ThreadPoolExecutor(max_workers=4)
    futuros = {arq: pool.submit(baixar, '%s/%s' % (edicao, arq), os.path.join(TMP, arq)) for arq in estabs}
    for arq in estabs:
        destino = os.path.join(TMP, arq)
        futuros[arq].result()
        print('Lendo %s (%.0fs)...' % (arq, time.time() - t0), flush=True)
        n = 0
        for l in linhas_zip(destino):
            n += 1
            c = l.split(b'";"')
            if len(c) < 21:
                continue
            uf = c[19]
            if len(uf) != 2 or uf == b'EX':
                continue
            sit, dsit, dini, cnae, mun = c[5], c[6], c[10], c[11], c[20]
            baixada = sit == b'08'
            aberta_antes = dini < ini
            nova = not aberta_antes and dini <= fim
            baixa = baixada and ini <= dsit <= fim
            estoque0 = aberta_antes and not (baixada and dsit < ini)
            if not (nova or baixa or estoque0):
                continue
            iu = idx(ufs, uf)
            ic = idx(cnaes, cnae.zfill(7))
            imn = idx(muns, mun)
            mun_uf[imn] = iu
            if estoque0:
                e0[(iu, ic)] = e0.get((iu, ic), 0) + 1
                em0[imn] = em0.get(imn, 0) + 1
            if nova and dini[:6] == ultimo and len(amostra) < AMOSTRA_MAX:
                if uf == AMOSTRA_UF:
                    amostra.append(c)
                elif len(reserva) < AMOSTRA_MAX:
                    reserva.append(c)
            if nova:
                k = im.get(dini[:6])
                if k is not None:
                    v = f.setdefault((k, iu, ic), [0, 0]); v[0] += 1
                    w = fm.setdefault((k, imn), [0, 0]); w[0] += 1
            if baixa:
                k = im.get(dsit[:6])
                if k is not None:
                    v = f.setdefault((k, iu, ic), [0, 0]); v[1] += 1
                    w = fm.setdefault((k, imn), [0, 0]); w[1] += 1
        total += n
        print('  %s: %d linhas (%.0fs no total)' % (arq, n, time.time() - t0), flush=True)
        if not os.environ.get('CNPJ_MANTER'):
            os.remove(destino)
    if total < 30_000_000:
        sys.exit('Poucas linhas lidas (%d): edição incompleta?' % total)

    # Reordena estados, CNAEs e municípios (índices estáveis e legíveis).
    uf_ord = sorted(ufs, key=lambda u: u.decode())
    nu = {ufs[u]: i for i, u in enumerate(uf_ord)}
    cn_ord = sorted(cnaes, key=lambda c: c.decode())
    nc = {cnaes[c]: i for i, c in enumerate(cn_ord)}
    ibge = nomes_ibge()
    def nome_mun(cod, iu):
        bruto = mun_rfb.get(cod, cod.decode())
        uf = uf_ord[nu[iu]].decode()
        return ibge.get((uf, norm(bruto))) or titulo(bruto)
    mn = sorted(muns, key=lambda c: (uf_ord[nu[mun_uf[muns[c]]]], norm(mun_rfb.get(c, c.decode()))))
    nm = {muns[c]: i for i, c in enumerate(mn)}

    nM = len(meses)
    serie = lambda arr: ','.join('' if x == 0 else str(x) for x in arr).rstrip(',')
    pares = {}
    for (k, u, c), v in f.items():
        x = pares.setdefault((nu[u], nc[c]), [[0] * nM, [0] * nM])
        x[0][k] += v[0]; x[1][k] += v[1]
    porMun = [[[0] * nM, [0] * nM] for _ in mn]
    for (k, x), v in fm.items():
        porMun[nm[x]][0][k] += v[0]; porMun[nm[x]][1][k] += v[1]
    dados = {
        'fonte': 'Receita Federal · Cadastro Nacional da Pessoa Jurídica (dados abertos)',
        'edicao': edicao,
        'meses': meses,
        'ufs': [u.decode() for u in uf_ord],
        'cnaes': {'cod': [c.decode() for c in cn_ord], 'nome': [cnae_nome.get(c.decode(), c.decode()) for c in cn_ord]},
        'mun': {'nome': [nome_mun(c, mun_uf[muns[c]]) for c in mn], 'uf': [nu[mun_uf[muns[c]]] for c in mn]},
        'f': [[u, c, serie(v[0]), serie(v[1])] for (u, c), v in sorted(pares.items())],
        'e0': sorted([nu[u], nc[c], v] for (u, c), v in e0.items()),
        'fm': [[serie(v[0]), serie(v[1])] for v in porMun],
        'em0': [em0.get(muns[c], 0) for c in mn],
        'amostra': montar_amostra((amostra + reserva)[:AMOSTRA_MAX], cnae_nome, mun_rfb, ibge, meses[-1]),
    }
    corpo = json.dumps(dados, ensure_ascii=False, separators=(',', ':'))
    js = ('// Gerado por scripts/cnpj_extrair.py - não editar à mão.\n'
          '// Extraído em %s da edição %s dos dados abertos do CNPJ (Receita Federal).\n'
          'window.CNPJ_EMPRESAS = %s;\n') % (datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'), edicao, corpo)
    open(SAIDA, 'w', encoding='utf-8').write(js)
    print('Gravado %s: %d KB · %d linhas lidas · meses %s..%s · séries UF×CNAE %d · municípios %d' % (
        os.path.relpath(SAIDA, RAIZ), len(js) // 1024, total, meses[0], meses[-1], len(dados['f']), len(dados['fm'])))


if __name__ == '__main__':
    main()
