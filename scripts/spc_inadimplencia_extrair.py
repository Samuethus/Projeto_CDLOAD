"""Lê os relatórios do SPC Brasil anexados na seção Inadimplência e atualiza o indicador INADIMPLÊNCIA do Dashboard.

Fonte: PDFs que os usuários enviam pela plataforma (tabela inadimplencia_arquivos + bucket PRIVADO "inadimplencia",
supabase/schema_inadimplencia.sql). O bucket só abre para usuário logado com a seção liberada, então o script
entra como o usuário leitor (supabase/schema_inadimplencia_leitor.sql: só a seção Inadimplência, sem Edição)
e baixa os documentos pelas mesmas regras de acesso (RLS) do app — sem a chave service_role.

Cada PDF ainda não lido vai para a API da Anthropic (Claude), que devolve os números no formato do painel
(saída estruturada por JSON Schema). O script confere os totais (participações somando ~100%, listas com o
tamanho certo) antes de aceitar; o que não passa fica marcado como "revisar" e não entra no painel.

Gera assets/data/spc_inadimplencia.js (window.SPC_INAD), carregado sob demanda pelo Dashboard, e registra cada
documento processado em scripts/cache/spc_inadimplencia_lidos.tsv (caminho, situação, mês, abrangência, data,
motivo). Para ler de novo um documento, apague a linha dele nesse arquivo. Falhas de rede/API não são
registradas: o documento é tentado de novo na próxima execução.

Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml; também dá para disparar na aba Actions
logo depois de anexar um relatório) e só regrava o arquivo se algo mudou.

Variáveis de ambiente (secrets do repositório):
  SUPABASE_URL, SUPABASE_ANON_KEY ...... as mesmas do deploy
  SPC_LEITOR_EMAIL, SPC_LEITOR_SENHA ... usuário leitor (supabase/schema_inadimplencia_leitor.sql)
  ANTHROPIC_API_KEY .................... API da Anthropic (leitura dos PDFs)
"""
import base64
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, 'assets', 'data', 'spc_inadimplencia.js')
LIDOS = os.path.join(RAIZ, 'scripts', 'cache', 'spc_inadimplencia_lidos.tsv')
BUCKET = 'inadimplencia'
MODELO = 'claude-opus-5-5'
LOCAL = {'Cuiabá': 'cuiaba', 'Mato Grosso': 'mt', 'Brasil': 'br'}
SETORES = ['Bancos', 'Comércio', 'Água e Luz', 'Comunicação', 'Outros']
ORDEM_CAMPOS = ['arquivo', 'devedores', 'dividas', 'dividaMedia', 'dividasPorDevedor', 'atrasoMeses', 'idadeMedia',
                'sexo', 'faixaEtaria', 'valor', 'atraso', 'atrasoAnual', 'setor', 'setorAnual', 'comparativo',
                'regioes', 'estimativa', 'historico']


# ---------------------------------------------------------------- Supabase (como usuário leitor)

def _http(metodo, url, cabecalhos, corpo=None, tempo=60):
    dados = json.dumps(corpo).encode('utf-8') if corpo is not None else None
    req = urllib.request.Request(url, data=dados, method=metodo, headers=cabecalhos)
    if dados is not None:
        req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, timeout=tempo) as r:
        return r.read()


def entrar(base, anon, email, senha):
    r = _http('POST', f'{base}/auth/v1/token?grant_type=password', {'apikey': anon}, {'email': email, 'password': senha})
    return json.loads(r)['access_token']


def listar_documentos(base, anon, token):
    cab = {'apikey': anon, 'Authorization': f'Bearer {token}'}
    sel = 'id,titulo,abrangencia,referencia,arquivo_nome,arquivo_path,created_at'
    r = _http('GET', f'{base}/rest/v1/inadimplencia_arquivos?select={sel}&order=created_at.asc', cab)
    return json.loads(r)


def baixar(base, anon, token, caminho):
    cab = {'apikey': anon, 'Authorization': f'Bearer {token}'}
    return _http('GET', f'{base}/storage/v1/object/authenticated/{BUCKET}/{urllib.parse.quote(caminho)}', cab, tempo=180)


# ---------------------------------------------------------------- Leitura do PDF (Claude, saída estruturada)

def _obj(props):
    return {'type': 'object', 'properties': props, 'required': list(props), 'additionalProperties': False}


def _nulo(esquema):
    return {'anyOf': [esquema, {'type': 'null'}]}


_N = {'type': 'number'}
_LISTA_N = {'type': 'array', 'items': _N}
_SETOR = {'type': 'array', 'items': _obj({'nome': {'type': 'string', 'enum': SETORES}, 'valor': _N})}
ESQUEMA = _obj({
    'eh_relatorio_spc': {'type': 'boolean'},
    'motivo': {'type': 'string'},
    'referencia': {'type': 'string'},
    'abrangencia': {'type': 'string', 'enum': ['cuiaba', 'mt', 'br']},
    'devedores': _obj({'anual': _N, 'mensal': _N}),
    'dividas': _obj({'anual': _N, 'mensal': _N}),
    'dividaMedia': _N,
    'dividasPorDevedor': _N,
    'atrasoMeses': _N,
    'idadeMedia': _N,
    'sexo': _obj({'homens': _N, 'mulheres': _N}),
    'faixaEtaria': _LISTA_N,
    'valor': _LISTA_N,
    'atraso': _LISTA_N,
    'atrasoAnual': _nulo(_LISTA_N),
    'setor': _SETOR,
    'setorAnual': _nulo(_SETOR),
    'comparativo': _nulo({'type': 'array', 'items': _obj({
        'nome': {'type': 'string'}, 'devedoresAnual': _N, 'devedoresMensal': _N,
        'dividasAnual': _N, 'dividasMensal': _N, 'dividasPorDevedor': _N})}),
    'regioes': _nulo({'type': 'array', 'items': _obj({
        'nome': {'type': 'string', 'enum': ['Norte', 'Nordeste', 'Centro-Oeste', 'Sudeste', 'Sul']},
        'devedoresMensal': _N, 'devedoresAnual': _N, 'dividasMensal': _N, 'dividasAnual': _N,
        'negativadosMi': _N, 'popAdulta': _N})}),
    'estimativa': _nulo(_obj({'negativadosMi': _N, 'popAdulta': _N,
                              'faixaEtaria': {'type': 'array', 'items': _obj({'milhoes': _N, 'pct': _N})}})),
    'historico': _nulo(_obj({'meses': {'type': 'array', 'items': {'type': 'string'}},
                             'devedores': _LISTA_N, 'dividas': _LISTA_N})),
})

SISTEMA = """Você transcreve relatórios de inadimplência do SPC Brasil (PDF) para um painel de indicadores.
Copie os números exatamente como estão no relatório; não calcule nem estime o que não estiver escrito.

Formato:
- Percentuais como número em pontos percentuais: "7,61%" -> 7.61; "-0,10%" -> -0.1. Valores em R$ como número: "R$ 5.514,01" -> 5514.01.
- referencia: mês de referência dos dados (não a data de publicação), no formato AAAA-MM.
- abrangencia: "mt" (Mato Grosso), "br" (Brasil / Brasil e regiões) ou "cuiaba" (município de Cuiabá).
- devedores: variação do número de consumidores inadimplentes (negativados) — anual (contra o mesmo mês do ano anterior) e mensal (contra o mês anterior).
- dividas: a mesma coisa para o número de dívidas em atraso.
- dividaMedia: valor médio devido por consumidor inadimplente (soma das dívidas de cada um), em R$.
- dividasPorDevedor: dívidas em atraso por inadimplente; nos relatórios do Brasil, "empresas credoras por inadimplente".
- atrasoMeses: tempo médio de atraso em meses. idadeMedia: idade média dos inadimplentes em anos.
- sexo: participação de homens e mulheres nos inadimplentes (%).
- faixaEtaria: 7 participações (%) na ordem 18–24, 25–29, 30–39, 40–49, 50–64, 65–84, 85 anos ou mais.
- valor: 5 participações (%) por valor total devido: até R$ 500; R$ 500,01–1.000; R$ 1.000,01–2.500; R$ 2.500,01–7.500; acima de R$ 7.500.
- atraso: 5 participações (%) por tempo de atraso: até 90 dias; 91 dias a 1 ano; 1 a 3 anos; 3 a 4 anos; 4 a 5 anos.
- atrasoAnual: variação anual (%) de cada faixa de atraso, na mesma ordem — só quando o relatório traz; senão null.
- setor: participação (%) no número de dívidas por setor credor, com os nomes Bancos, Comércio, Água e Luz, Comunicação, Outros
  (bancos/financeiro -> Bancos; água e energia/luz -> Água e Luz; telefonia/TV/internet -> Comunicação).
- setorAnual: variação anual (%) das dívidas por setor credor — só quando o relatório traz; senão null.
- comparativo: (relatórios de Mato Grosso ou Cuiabá) outras abrangências citadas no mesmo mês, com nome "Centro-Oeste", "Brasil" ou "Mato Grosso"; senão null.
- regioes: (relatório do Brasil) as cinco regiões com variações, negativados em milhões e % da população adulta; senão null.
- estimativa: (relatório do Brasil) total de negativados no país em milhões, % da população adulta e, para cada uma das 7 faixas etárias, milhões e % da população da faixa; senão null.
- historico: (relatório do Brasil) série da variação mensal do mesmo mês nos últimos anos: meses (AAAA-MM), devedores e dividas; senão null.
Se o documento não for um relatório de inadimplência do SPC Brasil, ou faltar a maior parte dos números, responda eh_relatorio_spc = false,
explique em motivo e preencha os demais campos com zero/listas vazias/null. Em motivo, cite também qualquer número que você não encontrou."""


def ler_pdf(cliente, pdf, doc):
    pedido = (f'Documento "{doc["arquivo_nome"]}", cadastrado como abrangência {doc["abrangencia"]} '
              f'e mês {str(doc["referencia"])[:7]} (confirme pelo conteúdo). Transcreva os números.')
    resp = cliente.beta.messages.create(
        model=MODELO,
        max_tokens=16000,
        betas=['server-side-fallback-2026-07-01'],
        fallbacks='default',
        output_config={'effort': 'high', 'format': {'type': 'json_schema', 'schema': ESQUEMA}},
        system=SISTEMA,
        messages=[{'role': 'user', 'content': [
            {'type': 'document', 'source': {'type': 'base64', 'media_type': 'application/pdf',
                                            'data': base64.standard_b64encode(pdf).decode('ascii')}},
            {'type': 'text', 'text': pedido}]}],
    )
    if resp.stop_reason == 'refusal':
        raise RuntimeError(f'leitura recusada pela API ({getattr(resp.stop_details, "category", None)})')
    if resp.stop_reason == 'max_tokens':
        raise RuntimeError('resposta cortada (max_tokens)')
    return json.loads(next(b.text for b in resp.content if b.type == 'text'))


# ---------------------------------------------------------------- Conferência e formato do painel

def conferir(r):
    """Lista de problemas (vazia = aceito)."""
    p = []
    if not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])', r['referencia'] or ''):
        p.append(f'mês de referência inválido ({r["referencia"]!r})')
    for campo, n in (('faixaEtaria', 7), ('valor', 5), ('atraso', 5)):
        lista = r[campo] or []
        if len(lista) != n:
            p.append(f'{campo} com {len(lista)} itens (esperado {n})')
        elif not 97 <= sum(lista) <= 103:
            p.append(f'{campo} soma {sum(lista):.2f}%')
    setor = r['setor'] or []
    if len(setor) < 3 or not 97 <= sum(s['valor'] for s in setor) <= 103:
        p.append(f'setor credor incompleto ({sum(s["valor"] for s in setor):.2f}%)')
    if not 98 <= r['sexo']['homens'] + r['sexo']['mulheres'] <= 102:
        p.append('participação por sexo não soma 100%')
    if not r['dividaMedia'] > 0 or not r['dividasPorDevedor'] > 0 or not r['atrasoMeses'] > 0 or not r['idadeMedia'] > 0:
        p.append('dívida média, dívidas por devedor, atraso ou idade média zerados')
    est = r['estimativa']
    if est and len(est['faixaEtaria']) != 7:
        p.append('estimativa por faixa etária sem as 7 faixas')
    hist = r['historico']
    if hist and not len(hist['meses']) == len(hist['devedores']) == len(hist['dividas']):
        p.append('histórico com séries de tamanhos diferentes')
    return p


def para_painel(r, arquivo):
    x = {'arquivo': arquivo}
    for c in ('devedores', 'dividas', 'dividaMedia', 'dividasPorDevedor', 'atrasoMeses', 'idadeMedia',
              'sexo', 'faixaEtaria', 'valor', 'atraso', 'atrasoAnual'):
        if r[c] is not None:
            x[c] = r[c]
    x['setor'] = {s['nome']: s['valor'] for s in sorted(r['setor'], key=lambda s: -s['valor'])}
    if r['setorAnual']:
        x['setorAnual'] = {s['nome']: s['valor'] for s in r['setorAnual']}
    if r['comparativo']:
        x['comparativo'] = {c['nome']: {k: v for k, v in c.items() if k != 'nome'} for c in r['comparativo']}
    if r['regioes']:
        x['regioes'] = {g['nome']: {k: v for k, v in g.items() if k != 'nome'} for g in r['regioes']}
    if r['estimativa']:
        e = r['estimativa']
        x['estimativa'] = {'negativadosMi': e['negativadosMi'], 'popAdulta': e['popAdulta'],
                           'faixaEtaria': [[f['milhoes'], f['pct']] for f in e['faixaEtaria']]}
    if r['historico']:
        x['historico'] = r['historico']
    return x


# ---------------------------------------------------------------- Arquivo do painel e registro

def ler_saida():
    with open(SAIDA, encoding='utf-8') as f:
        txt = f.read()
    m = re.search(r'window\.SPC_INAD\s*=\s*', txt)
    return txt[:m.start()], json.loads(txt[m.end():].rstrip().rstrip(';'))


def gravar_saida(cabecalho, d):
    j = lambda v: json.dumps(v, ensure_ascii=False, separators=(', ', ': '))
    sep = lambda i, n: ',' if i < n - 1 else ''
    linhas = ['window.SPC_INAD = {']
    linhas += [f'  {j(k)}: {j(v)},' for k, v in d.items() if k != 'edicoes']
    linhas.append('  "edicoes": {')
    refs = sorted(d['edicoes'])
    for i, ref in enumerate(refs):
        ed = d['edicoes'][ref]
        locs = sorted(ed, key=lambda l: (['cuiaba', 'mt', 'br'] + [l]).index(l))
        linhas.append(f'    {j(ref)}: {{')
        for k, loc in enumerate(locs):
            campos = sorted(ed[loc].items(), key=lambda kv: (ORDEM_CAMPOS + [kv[0]]).index(kv[0]))
            linhas.append(f'      {j(loc)}: {{')
            linhas += [f'        {j(c)}: {j(v)}{sep(n, len(campos))}' for n, (c, v) in enumerate(campos)]
            linhas.append(f'      }}{sep(k, len(locs))}')
        linhas.append(f'    }}{sep(i, len(refs))}')
    linhas += ['  }', '};', '']
    with open(SAIDA, 'w', encoding='utf-8', newline='\n') as f:
        f.write(cabecalho + '\n'.join(linhas))


def ler_registro():
    if not os.path.exists(LIDOS):
        return {}
    with open(LIDOS, encoding='utf-8') as f:
        return {l.split('\t')[0]: l.rstrip('\n') for l in f if l.strip() and not l.startswith('#')}


def gravar_registro(reg):
    os.makedirs(os.path.dirname(LIDOS), exist_ok=True)
    with open(LIDOS, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# caminho\tsituação\tmês\tabrangência\tlido em\tmotivo  (apague a linha para ler o documento de novo)\n')
        f.writelines(l + '\n' for _, l in sorted(reg.items()))


def main():
    env = {k: os.environ.get(k, '').strip() for k in
           ('SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SPC_LEITOR_EMAIL', 'SPC_LEITOR_SENHA', 'ANTHROPIC_API_KEY')}
    faltam = [k for k, v in env.items() if not v]
    if faltam:
        print(f'::warning::Leitura dos relatórios do SPC desativada: faltam os secrets {", ".join(faltam)} '
              '(veja supabase/schema_inadimplencia_leitor.sql).')
        return 0
    import anthropic

    base, anon = env['SUPABASE_URL'].rstrip('/'), env['SUPABASE_ANON_KEY']
    token = entrar(base, anon, env['SPC_LEITOR_EMAIL'], env['SPC_LEITOR_SENHA'])
    docs = listar_documentos(base, anon, token)
    cabecalho, dados = ler_saida()
    registro = ler_registro()
    ja_no_painel = {x.get('arquivo') for ed in dados['edicoes'].values() for x in ed.values()}
    pendentes = [d for d in docs if d['arquivo_path'] not in registro and d['arquivo_nome'] not in ja_no_painel]
    print(f'{len(docs)} documento(s) na seção Inadimplência; {len(pendentes)} para ler.')
    if not pendentes:
        return 0

    cliente = anthropic.Anthropic(api_key=env['ANTHROPIC_API_KEY'])
    hoje = datetime.date.today().isoformat()
    mudou = falhas = 0
    for doc in pendentes:
        nome = doc['arquivo_nome']
        try:
            r = ler_pdf(cliente, baixar(base, anon, token, doc['arquivo_path']), doc)
        except (urllib.error.URLError, anthropic.APIError, RuntimeError, ValueError, StopIteration) as e:
            print(f'::warning::{nome}: não foi possível ler agora ({e}); tenta de novo na próxima execução.')
            falhas += 1
            continue
        loc_cad = LOCAL.get(doc['abrangencia'])
        if not r['eh_relatorio_spc']:
            situacao, problemas = 'ignorado', [r['motivo'] or 'não é relatório do SPC']
        else:
            problemas = conferir(r)
            if r['abrangencia'] != loc_cad:
                problemas.append(f'abrangência lida ({r["abrangencia"]}) diferente da cadastrada ({loc_cad})')
            situacao = 'revisar' if problemas else 'ok'
        if situacao == 'ok':
            dados['edicoes'].setdefault(r['referencia'], {})[loc_cad] = para_painel(r, nome)
            mudou += 1
        motivo = '; '.join(problemas).replace('\t', ' ').replace('\n', ' ')
        registro[doc['arquivo_path']] = '\t'.join([doc['arquivo_path'], situacao, r['referencia'] or '', loc_cad or '', hoje, motivo])
        print(f'{nome}: {situacao} · {r["referencia"]} · {loc_cad}' + (f' · {motivo}' if motivo else ''))

    if mudou:
        dados['meses'] = sorted(dados['edicoes'])
        dados['atualizado'] = hoje
        gravar_saida(cabecalho, dados)
        print(f'{SAIDA}: {mudou} edição(ões) nova(s).')
    gravar_registro(registro)
    return 1 if falhas and not mudou else 0


if __name__ == '__main__':
    sys.exit(main())
