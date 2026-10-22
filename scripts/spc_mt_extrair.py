"""SPC Mato Grosso (relatório OPERAÇÃO_MT do CESPC) -> assets/data/spc_mt.js (Dashboard › Painel · SPC Mato Grosso).

O arquivo mensal "OPERAÇÃO_MT_<MÊS><AA> - Envio.xlsx" chega sem as abas de base (BASE_*): os dados completos ficam
nos caches das tabelas dinâmicas (xl/pivotCache). Este script lê esses caches e resume, por entidade (CDL):
  fluxos do ano, mês a mês ......... captação, cancelamento e suspensão (BASE_CAP_CANC), consultas (BASE_CONSULTAS,
                                      também por produto) e inclusões de registros (BASE_REGISTROS), com o nº de
                                      associados distintos que consultaram/incluíram no mês;
  retrato na data de referência .... associados ativos (BASE_ATIVOS), faixas de consumo de consultas e de registros
                                      (BASE_CONSUMO ...), registros ativos por tempo de permanência e recuperações.
O painel faz a mesma leitura no navegador (spLerOperacao, index.html) com os arquivos enviados em Documentos › CESPC;
este arquivo é a reserva (sem acesso à pasta ou antes do primeiro envio). Os dois resumos têm de ser iguais.

Uso: python scripts/spc_mt_extrair.py <OPERAÇÃO_MT_....xlsx>
"""
import html, json, os, re, sys, zipfile, datetime
from collections import defaultdict

SAIDA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'data', 'spc_mt.js')
MESES = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']


def caches(caminho):
    """{aba de origem: (campos, linhas)} a partir de xl/pivotCache (definição + registros)."""
    z = zipfile.ZipFile(caminho)
    out = {}
    for n in sorted(z.namelist()):
        m = re.match(r'xl/pivotCache/pivotCacheDefinition(\d+)\.xml$', n)
        if not m or f'xl/pivotCache/pivotCacheRecords{m.group(1)}.xml' not in z.namelist():
            continue
        x = z.read(n).decode('utf-8')
        aba = html.unescape(re.search(r'<worksheetSource[^>]*sheet="([^"]+)"', x).group(1))
        campos, shared = [], []
        for nome, corpo in re.findall(r'<cacheField name="([^"]+)"[^>]*?(?:/>|>(.*?)</cacheField>)', x, re.S):
            campos.append(html.unescape(nome).strip())
            itens = []
            si = re.search(r'<sharedItems[^>]*>(.*?)</sharedItems>', corpo or '', re.S)
            if si:
                for tag, v in re.findall(r'<(s|n|d|b|e|m)(?: v="([^"]*)")?/>', si.group(1)):
                    itens.append(float(v) if tag == 'n' else None if tag == 'm' else html.unescape(v))
            shared.append(itens)
        r = z.read(f'xl/pivotCache/pivotCacheRecords{m.group(1)}.xml').decode('utf-8')
        linhas = []
        for rec in re.finditer(r'<r>(.*?)</r>', r, re.S):
            vals = []
            for k, v in enumerate(re.finditer(r'<(x|n|s|d|m|b|e)(?: v="([^"]*)")?/>', rec.group(1))):
                tag, val = v.group(1), v.group(2)
                vals.append(shared[k][int(val)] if tag == 'x' else float(val) if tag == 'n' else None if tag == 'm' else html.unescape(val))
            linhas.append(vals)
        out[aba.upper()] = (campos, linhas)
    return out


def resumir(caminho):
    C = caches(caminho)
    def base(prefixo):
        k = next((k for k in C if k.startswith(prefixo)), None)
        if not k:
            raise SystemExit(f'Aba de origem {prefixo}* não encontrada nos caches.')
        campos, linhas = C[k]
        idx = {c.upper(): i for i, c in enumerate(campos)}
        return idx, linhas
    ents, nomes = {}, []           # código da entidade -> índice
    def ent(cod, nome):
        cod = int(cod)
        if cod not in ents:
            ents[cod] = len(nomes)
            nomes.append([cod, nome])
        return ents[cod]
    num = lambda v: float(v or 0)
    # Associados: chave (entidade, código do associado); nome sem o "-<código>" do final.
    nomes_a = {}
    def assoc(e, cod, nome):
        k = (e, int(num(cod)))
        nomes_a.setdefault(k, re.sub(r'-\d+$', '', str(nome or '').strip()).strip())
        return k

    # ---- fluxos (ano, mês) ----
    ano = None
    def mes_de(i, l):
        nonlocal ano
        ano = ano or int(l[i['ANO']])
        return MESES.index(str(l[i['MÊS']]).strip()[:3].title())
    cap = defaultdict(float)       # (op, m, e) -> qtd
    i, L = base('BASE_CAP_CANC')
    for l in L:
        op = re.sub(r'[^A-Z]', '', html.unescape(str(l[i['OPERAÇÃO']])).upper().replace('Ã', 'A').replace('Ç', 'C'))
        cap[(op, mes_de(i, l), ent(l[i['COD E']], l[i['ENTIDADE']]))] += num(l[i['QTD']])
    cons, consA, prod = defaultdict(float), defaultdict(set), defaultdict(float)
    acons = defaultdict(lambda: [0.0] * 12)   # (entidade, associado) -> consultas por mês
    produtos = {}
    i, L = base('BASE_CONSULTAS')
    for l in L:
        m, e = mes_de(i, l), ent(l[i['COD E']], l[i['ENTIDADE']])
        q = num(l[i['QTD']]); p = str(l[i['PRODUTO']]).strip()
        produtos.setdefault(p, len(produtos))
        cons[(m, e)] += q; consA[(m, e)].add(l[i['COD A']]); prod[(m, e, produtos[p])] += q
        acons[assoc(e, l[i['COD A']], l[i['ASSOCIADO']])][m] += q
    inc, incA = defaultdict(float), defaultdict(set)
    ainc = defaultdict(lambda: [0.0] * 12)   # (entidade, associado) -> inclusões por mês
    i, L = base('BASE_REGISTROS')
    for l in L:
        m, e = mes_de(i, l), ent(l[i['COD E']], l[i['ENTIDADE']])
        inc[(m, e)] += num(l[i['QTD']]); incA[(m, e)].add(l[i['COD ASSOCIADO']])
        ainc[assoc(e, l[i['COD ASSOCIADO']], l[i['ASSOCIADO']])][m] += num(l[i['QTD']])

    # ---- retratos (data de referência) ----
    ref = None
    def data_iso(v):   # data em texto ("2026-09-30T00:00:00") ou número de série do Excel (46295)
        if isinstance(v, float):
            return (datetime.date(1899, 12, 30) + datetime.timedelta(days=int(v))).isoformat()
        return str(v)[:10]
    def retrato(prefixo, qtd, faixa=None, qtd_assoc=None):
        """Soma por (faixa, entidade); com qtd_assoc, também a soma dessa coluna por associado."""
        nonlocal ref
        i, L = base(prefixo)
        out, por_a = defaultdict(float), defaultdict(float)
        for l in L:
            ref = max(ref or '', data_iso(l[i['DATA REFERENCIA']]))
            e = ent(l[i['COD ENTIDADE']], l[i['ENTIDADE']])
            f = str(l[i[faixa]]).strip().strip("'").strip() if faixa else ''
            out[(f, e)] += num(l[i[qtd]])
            if qtd_assoc:
                por_a[assoc(e, l[i['COD ASSOCIADO']], l[i['NOM ASSOCIADO']])] += num(l[i[qtd_assoc]])
        return (out, por_a) if qtd_assoc else out
    ativos = retrato('BASE_ATIVOS', 'QTD ASSOCIADO')
    usoC, aUsoC = retrato('BASE_CONSUMO CONSULTAS', 'QTD ASSOCIADO', 'USO', 'QTD CONSULTAS')
    usoR, aUsoR = retrato('BASE_CONSUMO REGISTROS', 'QTD ASSOCIADO', 'USO', 'QTD REGISTROS')
    regTP, aReg = retrato('BASE_REG ATIVO', 'QTD. REGISTROS', 'DES FAIXA TEMPO PERMANENCIA', 'QTD. REGISTROS')
    rec, aRec = retrato('BASE_RECUPERA', 'QTD. RECUPERAÇÃO', 'DES FAIXA TEMPO PERMANENCIA', 'QTD. RECUPERAÇÃO')

    nE = len(nomes)
    meses = sorted({k[1] for k in cap} | {k[0] for k in cons} | {k[0] for k in inc})
    nM = max(meses) + 1
    mat = lambda d, f: [[round(f(d, m, e)) for e in range(nE)] for m in range(nM)]
    def faixas(d):
        fx = sorted({f for f, _ in d})
        return {'faixas': fx, 'valores': [[round(d.get((f, e), 0)) for e in range(nE)] for f in fx]}
    prods = sorted(produtos, key=produtos.get)
    # Maiores associados (relatório Dados CESPC): os n maiores de cada entidade + os n maiores de MT (n=None: todos).
    # Empate: nome do associado, depois o código (a leitura do navegador usa a mesma ordem).
    def top(chaves, val, n):
        ordem = lambda ks: sorted(ks, key=lambda k: (-val(k), nomes_a[k], k[1]))
        por_e = defaultdict(list)
        for k in chaves:
            por_e[k[0]].append(k)
        sel = set(ordem(list(chaves))[:n])
        for ks in por_e.values():
            sel.update(ordem(ks)[:n])
        return sorted(sel, key=lambda k: (k[0], -val(k), nomes_a[k], k[1]))
    tot_c = lambda k: sum(acons[k])
    regrec = set(aReg) | set(aRec)
    porE = lambda d: [round(sum(v for (e2, _), v in d.items() if e2 == e)) for e in range(nE)]
    return {
        'arquivo': os.path.basename(caminho), 'ano': ano, 'meses': nM, 'ref': ref,
        'entidades': nomes,
        'captacao': mat(cap, lambda d, m, e: d.get(('CAPTACAO', m, e), 0)),
        'cancelamento': mat(cap, lambda d, m, e: d.get(('CANCELAMENTO', m, e), 0)),
        'suspensao': mat(cap, lambda d, m, e: d.get(('SUSPENSO', m, e), 0)),
        'consultas': mat(cons, lambda d, m, e: d.get((m, e), 0)),
        'consultasAssoc': [[len(consA.get((m, e), ())) for e in range(nE)] for m in range(nM)],
        'inclusao': mat(inc, lambda d, m, e: d.get((m, e), 0)),
        'inclusaoAssoc': [[len(incA.get((m, e), ())) for e in range(nE)] for m in range(nM)],
        'produtos': prods,
        # [mês, entidade, produto, qtd] (só as combinações com consulta)
        'produtoQtd': [v for (m, e, p), q in sorted(prod.items()) for v in (m, e, p, round(q))],
        'ativos': [round(ativos.get(('', e), 0)) for e in range(nE)],
        'usoConsultas': faixas(usoC), 'usoRegistros': faixas(usoR),
        'registrosAtivos': faixas(regTP), 'recuperacao': faixas(rec),
        'consumoConsultas': porE(aUsoC), 'consumoRegistros': porE(aUsoR),
        # [entidade, associado, consultas | inclusões jan..último mês] — todos os associados (rankings e variações do painel)
        'assocConsultas': [[k[0], nomes_a[k], *[round(v) for v in acons[k][:nM]]] for k in top(list(acons), tot_c, None)],
        'assocInclusao': [[k[0], nomes_a[k], *[round(v) for v in ainc[k][:nM]]] for k in top(list(ainc), lambda k: sum(ainc[k]), None)],
        # [entidade, associado, registros ativos, recuperação]
        'assocRegistros': [[k[0], nomes_a[k], round(aReg.get(k, 0)), round(aRec.get(k, 0))] for k in top(list(regrec), lambda k: aReg.get(k, 0), 25)],
        # [entidade, associado, consultas | registros] (base de consumo: página das faixas)
        'assocUsoConsultas': [[k[0], nomes_a[k], round(aUsoC[k])] for k in top(list(aUsoC), lambda k: aUsoC[k], 25)],
        'assocUsoRegistros': [[k[0], nomes_a[k], round(aUsoR[k])] for k in top(list(aUsoR), lambda k: aUsoR[k], 25)],
    }


def main():
    R = resumir(sys.argv[1])
    dados = {'fonte': 'CESPC · Operação Mato Grosso (SPC Brasil)', 'atualizado': datetime.date.today().isoformat(), 'arquivos': [R]}
    cab = ('// Dashboard › Painel · SPC Mato Grosso — reserva gerada por scripts/spc_mt_extrair.py (não editar à mão).\n'
           '// O painel lê sozinho os arquivos OPERAÇÃO_MT enviados em Documentos › CESPC; este resumo vale sem acesso à pasta.\n')
    with open(SAIDA, 'w', encoding='utf-8', newline='\n') as f:
        f.write(cab + 'window.SPC_MT = ' + json.dumps(dados, ensure_ascii=False, separators=(',', ':')) + ';\n')
    tot = lambda k: sum(map(sum, R[k]))
    print(f"{R['arquivo']} · ano {R['ano']} · {R['meses']} meses · ref {R['ref']} · {len(R['entidades'])} entidades · {len(R['produtos'])} produtos")
    print('captação', tot('captacao'), '· cancelamento', tot('cancelamento'), '· suspensão', tot('suspensao'),
          '· consultas', tot('consultas'), '· inclusões', tot('inclusao'), '· ativos', sum(R['ativos']),
          '· registros ativos', sum(map(sum, R['registrosAtivos']['valores'])), '· recuperação', sum(map(sum, R['recuperacao']['valores'])))
    print('->', os.path.normpath(SAIDA), os.path.getsize(SAIDA), 'bytes')


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
