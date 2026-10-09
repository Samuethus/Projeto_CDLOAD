"""Extrai as inscrições no CNPJ (dados abertos da Receita Federal) para o indicador "EMPRESAS" do Panorama.

Fonte: Cadastro Nacional da Pessoa Jurídica — dados abertos da Receita Federal
  https://dados.gov.br/dados/conjuntos-dados/cadastro-nacional-da-pessoa-juridica---cnpj
  https://arquivos.receitafederal.gov.br/index.php/s/YggdBLfdninEJX9  (pasta mensal AAAA-MM, WebDAV público)

Bases cruzadas pelo CNPJ básico (8 primeiros dígitos):
  Estabelecimentos0..9.zip  uma linha por estabelecimento (matriz ou filial): datas, situação, CNAE, UF, município
  Empresas0..9.zip          porte da empresa, natureza jurídica, capital social
  Simples.zip               opção pelo Simples Nacional e pelo SIMEI (MEI), com datas de opção e exclusão
  Municipios / Cnaes / Naturezas.zip  tabelas de códigos
Cada arquivo é baixado em partes paralelas, lido em fluxo e apagado.

Período: só o ano atual e o anterior (ex.: 2025 e 2026) — o painel compara o ano atual com o anterior.

Mesmo racional do Novo CAGED, com estabelecimentos no lugar de vínculos:
  aberturas  = estabelecimentos com data de início de atividade no mês
  baixas     = estabelecimentos com situação cadastral BAIXADA (08) e data da situação no mês
  saldo      = aberturas − baixas
  estoque    = inscrições abertas e não baixadas (ativas, suspensas ou inaptas) no fim do mês,
               reconstruído a partir do estoque no início do período e do saldo mensal
  ativas     = estabelecimentos com situação ATIVA na edição (retrato atual)
Porte (Empresas) e regime tributário (Simples) entram no cruzamento:
  regime de uma abertura/baixa = o vigente no MÊS do evento (pelas datas de opção/exclusão), para que a
  baixa de um MEI conte como MEI (na baixa a Receita registra a exclusão do SIMEI); regime das ativas = o atual.
  Regimes: MEI (SIMEI) · Simples Nacional (sem MEI) · Não optante (Lucro Presumido/Real — a base aberta não separa).
Por ser um retrato do cadastro, um mês recente pode crescer um pouco na edição seguinte.

Gera assets/data/cnpj_empresas.js (window.CNPJ_EMPRESAS), carregado sob demanda pelo Dashboard.
Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml): consulta só a lista de pastas e
sai na hora se a edição mais recente já foi processada (a Receita publica uma vez por mês).

Formato (séries compactas: valores mensais separados por vírgula, zero = vazio, zeros finais cortados):
  edicao: 'AAAA-MM' · meses: ['2025-01', ...] (até o mês anterior ao da edição)
  ufs: ['AC', ...] · cnaes: { cod, nome } · mun: { nome, uf } · portes: [...] · regimes: [...]
  f:   [[iUf, iCnae, 'aberturas', 'baixas'], ...]           série mensal por estado × subclasse CNAE
  e0:  [[iUf, iCnae, estoque], ...]                          estoque no início do período
  fm:  [['aberturas', 'baixas'], ...]                        série mensal por município (ordem de mun)
  em0: [estoque por município no início do período]
  pr:  [[iUf, iPorte, iRegime, 'aberturas', 'baixas'], ...]  série mensal por estado × porte × regime
  at:  [[iUf, iPorte, iRegime, ativas], ...]                 estabelecimentos ativos na edição
  prm: [[iMun, iPorte, iRegime, 'aberturas', 'baixas'], ...] idem, por município de Mato Grosso
  atm: [[iMun, iPorte, iRegime, ativas], ...]                idem, por município de Mato Grosso
  amostra: { colunas, linhas }  até AMOSTRA_MAX aberturas do último mês (Mato Grosso primeiro), com todas
           as colunas das três bases + descrições do painel — botão Exportar. Contatos e CPF mascarados.
"""
import base64
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
from array import array
from concurrent.futures import ThreadPoolExecutor

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'cnpj_empresas.js')
WEBDAV = 'https://arquivos.receitafederal.gov.br/public.php/webdav/'
TOKEN = 'YggdBLfdninEJX9'   # compartilhamento público "Dados Abertos CNPJ" (usuário do WebDAV, sem senha)
UA = 'Mozilla/5.0 (CDLoad; Nucleo de Inteligencia CDL Cuiaba)'
TMP = os.environ.get('CNPJ_TMP') or os.path.join(RAIZ, '.cnpj_tmp')
PARTES = 8                  # downloads em partes paralelas (o servidor limita a velocidade por conexão)
UF_DETALHE = b'MT'          # municípios com porte × regime (Mato Grosso, foco da CDL Cuiabá)
AMOSTRA_MAX = 10
MAX_CNPJ = 100_000_000      # CNPJ básico tem 8 dígitos: vetores indexados por ele

PORTES = ['Microempresa', 'Empresa de Pequeno Porte', 'Demais', 'Não informado']
PORTE_COD = {b'01': 1, b'03': 2, b'05': 3}          # guardado +1 (0 = sem registro → Não informado)
REGIMES = ['MEI', 'Simples Nacional', 'Não optante']

# Leiautes (metadados da Receita Federal), na ordem das colunas.
COLUNAS_ESTAB = ['CNPJ básico', 'CNPJ ordem', 'CNPJ DV', 'Identificador matriz/filial', 'Nome fantasia', 'Situação cadastral',
                 'Data da situação cadastral', 'Motivo da situação cadastral', 'Nome da cidade no exterior', 'País',
                 'Data de início da atividade', 'CNAE fiscal principal', 'CNAE fiscal secundária', 'Tipo de logradouro',
                 'Logradouro', 'Número', 'Complemento', 'Bairro', 'CEP', 'UF', 'Município (código Receita)', 'DDD 1',
                 'Telefone 1', 'DDD 2', 'Telefone 2', 'DDD do fax', 'Fax', 'Correio eletrônico', 'Situação especial',
                 'Data da situação especial']
COLUNAS_EMPRESA = ['Razão social', 'Natureza jurídica', 'Qualificação do responsável', 'Capital social',
                   'Porte da empresa', 'Ente federativo responsável']   # (sem o CNPJ básico, já na 1ª coluna)
COLUNAS_SIMPLES = ['Opção pelo Simples', 'Data de opção pelo Simples', 'Data de exclusão do Simples',
                   'Opção pelo MEI', 'Data de opção pelo MEI', 'Data de exclusão do MEI']
COLUNAS_EXTRA = ['CNPJ', 'Descrição matriz/filial', 'Descrição da situação cadastral', 'Descrição do CNAE principal',
                 'Município', 'Descrição da natureza jurídica', 'Descrição do porte', 'Regime tributário (painel)',
                 'MEI ou ME (painel)', 'Evento no painel', 'Grande setor (painel)', 'Associação (painel)']
SITUACAO = {'01': 'Nula', '02': 'Ativa', '03': 'Suspensa', '04': 'Inapta', '08': 'Baixada'}


# ---------------- Download ----------------
def req(caminho, metodo='GET', cabecalhos=None):
    h = {'User-Agent': UA, 'Authorization': 'Basic ' + base64.b64encode((TOKEN + ':').encode()).decode()}
    h.update(cabecalhos or {})
    return urllib.request.Request(WEBDAV + caminho, method=metodo, headers=h)


def listar(caminho=''):
    """[(nome, tamanho)] de uma pasta do compartilhamento."""
    with urllib.request.urlopen(req(caminho, 'PROPFIND', {'Depth': '1'}), timeout=120) as r:
        xml = r.read().decode('utf-8', 'ignore')
    out = []
    for bloco in re.findall(r'<d:response>(.*?)</d:response>', xml, re.S):
        h = re.search(r'<d:href>/public\.php/webdav/([^<]*)</d:href>', bloco)
        t = re.search(r'<d:getcontentlength>(\d+)</d:getcontentlength>', bloco)
        if h:
            out.append((h.group(1), int(t.group(1)) if t else 0))
    return out


def zip_ok(arquivo):
    try:
        with zipfile.ZipFile(arquivo) as z:
            z.namelist()
        return True
    except (zipfile.BadZipFile, OSError):
        return False


def baixar(caminho, destino, tamanho):
    """Baixa em PARTES faixas paralelas (Range) e junta; repete a parte que falhar."""
    if os.environ.get('CNPJ_MANTER') and os.path.exists(destino) and zip_ok(destino):
        return destino   # testes locais: reaproveita o que já baixou
    n = PARTES if tamanho > 50 * 2 ** 20 else 1
    passo = tamanho // n + 1

    def parte(i):
        a, b = i * passo, min(tamanho, (i + 1) * passo) - 1
        arq = '%s.p%d' % (destino, i)
        falhas = 0   # só conta tentativa que não avançou nada: servidor lento, mas andando, não desiste
        while falhas < 8:
            feito = os.path.getsize(arq) if os.path.exists(arq) else 0
            if a + feito > b:
                return arq
            erro = ''
            try:
                r = urllib.request.urlopen(req(caminho, cabecalhos={'Range': 'bytes=%d-%d' % (a + feito, b)}), timeout=180)
                with r, open(arq, 'ab') as f:
                    while True:
                        x = r.read(1 << 20)
                        if not x:
                            break
                        f.write(x)
            except Exception as e:
                erro = str(e)
            agora = os.path.getsize(arq) if os.path.exists(arq) else 0
            if agora == b - a + 1:
                return arq
            if agora > feito:
                falhas = 0
            else:
                falhas += 1
                print('  %s parte %d sem avanço (%d): %s' % (caminho, i, falhas, erro or 'resposta vazia'), flush=True)
                time.sleep(10 * falhas)
        raise RuntimeError('Não foi possível baixar %s (parte %d)' % (caminho, i))

    with ThreadPoolExecutor(max_workers=n) as pool:
        arqs = list(pool.map(parte, range(n)))
    with open(destino, 'wb') as out:
        for arq in arqs:
            with open(arq, 'rb') as f:
                while True:
                    x = f.read(1 << 24)
                    if not x:
                        break
                    out.write(x)
            os.remove(arq)
    if not zip_ok(destino):
        os.remove(destino)
        raise RuntimeError('Arquivo corrompido: ' + caminho)
    return destino


def linhas_zip(arquivo):
    with zipfile.ZipFile(arquivo) as z:
        with z.open(z.namelist()[0]) as fh:
            for l in io.BufferedReader(fh, 1 << 22):
                yield l


def tabela(arquivo, chave_zfill=0):
    out = {}
    for l in linhas_zip(arquivo):
        p = l.decode('latin-1').strip().strip('"').split('";"')
        if len(p) == 2:
            out[p[0].zfill(chave_zfill) if chave_zfill else p[0]] = p[1].strip()
    return out


# ---------------- Nomes ----------------
def norm(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode().upper()
    return re.sub(r'[^A-Z0-9]+', ' ', s).strip()


def titulo(s):
    pequenas = {'de', 'da', 'do', 'das', 'dos', 'e'}
    return ' '.join(w.lower() if i and w.lower() in pequenas else w.capitalize() for i, w in enumerate(s.split()))


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


# ---------------- Amostra (Exportar) ----------------
def mascarar_contato(i, v):
    """Contatos de MEI costumam ser dados pessoais: e-mail e telefones/fax saem mascarados (DDDs ficam)."""
    if not v:
        return v
    if i == 27 and '@' in v:
        u, d = v.split('@', 1)
        return u[:2] + '***@' + d
    if i in (22, 24, 26):
        return '*' * max(0, len(v) - 2) + v[-2:]
    return v


def mascarar_cpf(t):
    """Razão social de MEI termina com o CPF do titular: mostra só os 3 dígitos do meio."""
    return re.sub(r'\b(\d{3})(\d{3})(\d{3})(\d{2})\b', r'***.\2.***-**', t)


def setor_painel(cnae):
    d = int(cnae[:2]) if cnae[:2].isdigit() else 0
    return ('Agropecuária' if 1 <= d <= 3 else 'Indústria' if 5 <= d <= 39 else 'Construção' if 41 <= d <= 43
            else 'Comércio' if 45 <= d <= 47 else 'Serviços' if d >= 49 else '')


def campos(l):
    return [x.decode('latin-1').strip().strip('"') for x in l.split(b'";"')]


def mes_idx(d):
    """b'20250315' -> meses desde 1900 (0 = sem data)."""
    if len(d) < 6 or d[:4] == b'0000':
        return 0
    try:
        return (int(d[:4]) - 1900) * 12 + int(d[4:6])
    except ValueError:
        return 0


def main():
    pastas = sorted(p.strip('/') for p, _ in listar() if re.fullmatch(r'\d{4}-\d{2}/', p))
    if not pastas:
        sys.exit('Nenhuma pasta mensal encontrada no compartilhamento da Receita.')
    edicao = pastas[-1]
    if os.path.exists(SAIDA) and ('"edicao":"%s"' % edicao) in open(SAIDA, encoding='utf-8').read(2000) \
            and not os.environ.get('CNPJ_FORCAR'):
        print('Sem mudanças (edição %s já processada).' % edicao)
        return
    tam = {p.split('/')[-1]: t for p, t in listar(edicao + '/')}
    estabs = sorted(a for a in tam if re.fullmatch(r'Estabelecimentos\d\.zip', a))
    empresas = sorted(a for a in tam if re.fullmatch(r'Empresas\d\.zip', a))
    aux = ['Municipios.zip', 'Cnaes.zip', 'Naturezas.zip', 'Simples.zip']
    if len(estabs) < 10 or len(empresas) < 10 or any(a not in tam for a in aux):
        sys.exit('Edição %s incompleta.' % edicao)
    os.makedirs(TMP, exist_ok=True)
    t0 = time.time()
    caminho = lambda a: os.path.join(TMP, a)

    # Período: ano anterior + ano atual, até o último mês completo (o anterior ao da edição).
    a, m = int(edicao[:4]), int(edicao[5:])
    a, m = (a, m - 1) if m > 1 else (a - 1, 12)
    meses = ['%04d-%02d' % (y, k) for y in (a - 1, a) for k in range(1, 13) if (y, k) <= (a, m)]
    im = {mm.replace('-', '').encode(): i for i, mm in enumerate(meses)}
    ini = ('%04d0101' % (a - 1)).encode()
    fim = ('%04d%02d31' % (a, m)).encode()
    ultimo = meses[-1].replace('-', '').encode()

    # Downloads: dois arquivos por vez (cada um em PARTES), na ordem em que serão lidos.
    ordem = aux + empresas + estabs
    pool = ThreadPoolExecutor(max_workers=2)
    fut = {arq: pool.submit(baixar, '%s/%s' % (edicao, arq), caminho(arq), tam[arq]) for arq in ordem}
    pronto = lambda arq: fut[arq].result()

    cnae_nome = tabela(pronto('Cnaes.zip'), 7)
    nat_nome = tabela(pronto('Naturezas.zip'), 4)
    mun_rfb = {k.encode(): v for k, v in tabela(pronto('Municipios.zip')).items()}

    # ---- Simples: regime vigente por mês (datas de opção/exclusão) e regime atual ----
    print('Lendo Simples.zip (%.0fs)...' % (time.time() - t0), flush=True)
    mei_ini, mei_fim, sn_ini, sn_fim = (array('H', bytes(2 * MAX_CNPJ)) for _ in range(4))
    reg_atual = bytearray(MAX_CNPJ)   # 0 não optante · 1 Simples · 2 MEI
    for l in linhas_zip(pronto('Simples.zip')):
        c = l.split(b'";"')
        if len(c) < 7:
            continue
        cb = int(c[0].strip(b'"'))
        if c[4] == b'S' or c[5] != b'00000000':
            mei_ini[cb] = mes_idx(c[5]); mei_fim[cb] = mes_idx(c[6])
        if c[1] == b'S' or c[2] != b'00000000':
            sn_ini[cb] = mes_idx(c[2]); sn_fim[cb] = mes_idx(c[3])
        reg_atual[cb] = 2 if c[4] == b'S' else 1 if c[1] == b'S' else 0

    def regime(cb, mm):
        """Índice em REGIMES vigente no mês mm (meses desde 1900)."""
        x = mei_ini[cb]
        if x and x <= mm and (not mei_fim[cb] or mei_fim[cb] >= mm):
            return 0
        x = sn_ini[cb]
        if x and x <= mm and (not sn_fim[cb] or sn_fim[cb] >= mm):
            return 1
        return 2

    # ---- Empresas: porte ----
    porte = bytearray(MAX_CNPJ)
    for arq in empresas:
        print('Lendo %s (%.0fs)...' % (arq, time.time() - t0), flush=True)
        for l in linhas_zip(pronto(arq)):
            c = l.split(b'";"')
            if len(c) >= 6:
                porte[int(c[0].strip(b'"'))] = PORTE_COD.get(c[5], 4)

    # ---- Estabelecimentos ----
    ufs, cnaes, muns = {}, {}, {}
    mun_uf = {}
    f, e0, fm, em0, pr, at, prm, atm = {}, {}, {}, {}, {}, {}, {}, {}
    amostra, reserva = [], []

    def idx(d, k):
        i = d.get(k)
        if i is None:
            i = d[k] = len(d)
        return i

    def soma(d, k, j):
        v = d.get(k)
        if v is None:
            v = d[k] = [0, 0]
        v[j] += 1

    total = 0
    for arq in estabs:
        print('Lendo %s (%.0fs)...' % (arq, time.time() - t0), flush=True)
        n = 0
        for l in linhas_zip(pronto(arq)):
            n += 1
            c = l.split(b'";"')
            if len(c) < 21:
                continue
            uf = c[19]
            if len(uf) != 2 or uf == b'EX':
                continue
            sit, dsit, dini = c[5], c[6], c[10]
            baixada = sit == b'08'
            aberta_antes = dini < ini
            nova = not aberta_antes and dini <= fim
            baixa = baixada and ini <= dsit <= fim
            estoque0 = aberta_antes and not (baixada and dsit < ini)
            ativa = sit == b'02'
            if not (nova or baixa or estoque0 or ativa):
                continue
            cb = int(c[0].strip(b'"'))
            p = (porte[cb] or 4) - 1
            iu = idx(ufs, uf)
            ic = idx(cnaes, c[11].zfill(7))
            imn = idx(muns, c[20])
            mun_uf[imn] = iu
            det = uf == UF_DETALHE
            if ativa:
                r = 2 - reg_atual[cb] if reg_atual[cb] else 2   # 2 MEI → 0 · 1 Simples → 1 · 0 → 2
                k3 = (iu, p, r)
                at[k3] = at.get(k3, 0) + 1
                if det:
                    k3 = (imn, p, r)
                    atm[k3] = atm.get(k3, 0) + 1
            if estoque0:
                e0[(iu, ic)] = e0.get((iu, ic), 0) + 1
                em0[imn] = em0.get(imn, 0) + 1
            if nova:
                k = im.get(dini[:6])
                if k is not None:
                    r = regime(cb, mes_idx(dini))
                    soma(f, (k, iu, ic), 0); soma(fm, (k, imn), 0); soma(pr, (k, iu, p, r), 0)
                    if det:
                        soma(prm, (k, imn, p, r), 0)
                    if dini[:6] == ultimo and len(amostra) < AMOSTRA_MAX:
                        if det:
                            amostra.append(l)
                        elif len(reserva) < AMOSTRA_MAX:
                            reserva.append(l)
            if baixa:
                k = im.get(dsit[:6])
                if k is not None:
                    r = regime(cb, mes_idx(dsit))
                    soma(f, (k, iu, ic), 1); soma(fm, (k, imn), 1); soma(pr, (k, iu, p, r), 1)
                    if det:
                        soma(prm, (k, imn, p, r), 1)
        total += n
        print('  %s: %d linhas (%.0fs)' % (arq, n, time.time() - t0), flush=True)
        if not os.environ.get('CNPJ_MANTER'):
            os.remove(caminho(arq))
    if total < 30_000_000:
        sys.exit('Poucas linhas lidas (%d): edição incompleta?' % total)

    # ---- Amostra consolidada: busca as linhas de Empresas e Simples dos CNPJs escolhidos ----
    escolhidas = (amostra + reserva)[:AMOSTRA_MAX]
    alvo = {campos(l)[0] for l in escolhidas}
    emp_linha, sim_linha = {}, {}
    for arq in empresas:
        for l in linhas_zip(caminho(arq)):
            cb = l[1:9].decode()
            if cb in alvo:
                emp_linha[cb] = campos(l)[1:7]
    for l in linhas_zip(caminho('Simples.zip')):
        cb = l[1:9].decode()
        if cb in alvo:
            sim_linha[cb] = campos(l)[1:7]
    if not os.environ.get('CNPJ_MANTER'):
        for arq in empresas + aux:
            os.remove(caminho(arq))
    pool.shutdown()

    # ---- Saída ----
    uf_ord = sorted(ufs, key=lambda u: u.decode())
    nu = {ufs[u]: i for i, u in enumerate(uf_ord)}
    cn_ord = sorted(cnaes, key=lambda c: c.decode())
    nc = {cnaes[c]: i for i, c in enumerate(cn_ord)}
    ibge = nomes_ibge()
    def nome_mun(cod, iu):
        bruto = mun_rfb.get(cod, cod.decode())
        return ibge.get((uf_ord[nu[iu]].decode(), norm(bruto))) or titulo(bruto)
    mn = sorted(muns, key=lambda c: (uf_ord[nu[mun_uf[muns[c]]]], norm(mun_rfb.get(c, c.decode()))))
    nm = {muns[c]: i for i, c in enumerate(mn)}

    nM = len(meses)
    serie = lambda arr: ','.join('' if x == 0 else str(x) for x in arr).rstrip(',')
    def series(d, chave):
        out = {}
        for k, v in d.items():
            x = out.setdefault(chave(k), [[0] * nM, [0] * nM])
            x[0][k[0]] += v[0]; x[1][k[0]] += v[1]
        return sorted(out.items())
    pares = series(f, lambda k: (nu[k[1]], nc[k[2]]))
    porMun = dict(series(fm, lambda k: nm[k[1]]))
    vazio = [[0] * nM, [0] * nM]

    from caged_extrair import GRP_ASSOC, assoc   # mesmas regras de associação do CAGED/Sefaz
    linhas_am = []
    for l in escolhidas:
        v = (campos(l) + [''] * 30)[:30]
        cb = v[0]
        e = (emp_linha.get(cb) or [''] * 6)
        s = (sim_linha.get(cb) or [''] * 6)
        cnae = v[11].zfill(7)
        mun = mun_rfb.get(v[20].encode(), v[20])
        p_cod = PORTE_COD.get(e[4].encode(), 4) - 1 if e[4] else 3
        mm = mes_idx(v[10].encode())
        cbi = int(cb)
        r = regime(cbi, mm)
        linhas_am.append([mascarar_contato(i, x) for i, x in enumerate(v)]
                         + [mascarar_cpf(e[0])] + e[1:]
                         + s
                         + ['%s.%s.%s/%s-%s' % (cb[:2], cb[2:5], cb[5:8], v[1], v[2]),
                            {'1': 'Matriz', '2': 'Filial'}.get(v[3], v[3]), SITUACAO.get(v[5].zfill(2), v[5]),
                            cnae_nome.get(cnae, ''), ibge.get((v[19], norm(mun))) or titulo(mun),
                            nat_nome.get(e[1].zfill(4), '') if e[1] else '', PORTES[p_cod], REGIMES[r],
                            'MEI' if r == 0 else ('ME' if p_cod == 0 else PORTES[p_cod]),
                            'Abertura em ' + meses[-1], setor_painel(cnae), GRP_ASSOC[assoc(cnae)]])

    dados = {
        'fonte': 'Receita Federal · Cadastro Nacional da Pessoa Jurídica (dados abertos)',
        'edicao': edicao,
        'meses': meses,
        'ufs': [u.decode() for u in uf_ord],
        'cnaes': {'cod': [c.decode() for c in cn_ord], 'nome': [cnae_nome.get(c.decode(), c.decode()) for c in cn_ord]},
        'mun': {'nome': [nome_mun(c, mun_uf[muns[c]]) for c in mn], 'uf': [nu[mun_uf[muns[c]]] for c in mn]},
        'portes': PORTES,
        'regimes': REGIMES,
        'f': [[u, c, serie(v[0]), serie(v[1])] for (u, c), v in pares],
        'e0': sorted([nu[u], nc[c], v] for (u, c), v in e0.items()),
        'fm': [[serie(x[0]), serie(x[1])] for x in (porMun.get(i, vazio) for i in range(len(mn)))],
        'em0': [em0.get(muns[c], 0) for c in mn],
        'pr': [[u, p, r, serie(v[0]), serie(v[1])] for (u, p, r), v in series(pr, lambda k: (nu[k[1]], k[2], k[3]))],
        'at': sorted([nu[u], p, r, v] for (u, p, r), v in at.items()),
        'prm': [[x, p, r, serie(v[0]), serie(v[1])] for (x, p, r), v in series(prm, lambda k: (nm[k[1]], k[2], k[3]))],
        'atm': sorted([nm[x], p, r, v] for (x, p, r), v in atm.items()),
        'amostra': {'colunas': COLUNAS_ESTAB + COLUNAS_EMPRESA + COLUNAS_SIMPLES + COLUNAS_EXTRA, 'linhas': linhas_am},
    }
    corpo = json.dumps(dados, ensure_ascii=False, separators=(',', ':'))
    js = ('// Gerado por scripts/cnpj_extrair.py - não editar à mão.\n'
          '// Extraído em %s da edição %s dos dados abertos do CNPJ (Receita Federal).\n'
          'window.CNPJ_EMPRESAS = %s;\n') % (datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'), edicao, corpo)
    open(SAIDA, 'w', encoding='utf-8').write(js)
    print('Gravado %s: %d KB · %d linhas · %s..%s · %.0fs' % (os.path.relpath(SAIDA, RAIZ), len(js) // 1024, total,
                                                             meses[0], meses[-1], time.time() - t0))


if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
