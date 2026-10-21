"""Pesquisa de Intenção de Compra (CDL Cuiabá) -> assets/data/intencao_compra.js (Dashboard › Painel · Intenção de Compra).

Fonte oficial: aba "Painel" da planilha consolidada do ano (pasta "2. Pesquisa CDL/1. Intenção Compra/<ano>").
O Painel é feito de tabelas dinâmicas filtradas por segmentação (data comemorativa); aqui cada data é recalculada
a partir da aba "Sheet" (Tabela1) com o mesmo filtro e a mesma conta do Painel:
  - região de Cuiabá: "Cidade Rezo" em Cuiabá, Várzea Grande ou 0 (sem cidade informada) — segmentação do Painel;
  - intenção = participação de "Completo - Sim" no total de entrevistados (Status/Intenção);
  - ticket médio = média de "Ticket Médio (R$)" de quem respondeu "Sim";
  - consumidores = intenção × 477.531 (população de referência do Painel); movimentação = consumidores × ticket;
  - perguntas de múltipla escolha (produtos, motivos, serviços): contagem de menções e % sobre o total de menções;
  - escolha única (planejamento, gastos, presentes, local, pagamento, perfil): % sobre quem respondeu.
Histórico (comparação): aba "Historico 2025" (intenção, ticket, população e movimentação de cada data de 2025).
Conferido contra o Painel do Dia das Crianças 2026 (420 entrevistas, 65% de intenção, ticket R$ 390,81).

Uso: python scripts/intencao_extrair.py [planilha_consolidada.xlsx]
A planilha costuma estar aberta no Excel: o script lê uma cópia temporária.
"""
import json, os, shutil, subprocess, sys, tempfile, datetime
import pandas as pd
import openpyxl

BASE = r'C:\Users\matheus.costa\OneDrive - CDL\Área de Trabalho\NÚCLEO DE INTELIGÊNCIA\1. PAINÉIS\2. Pesquisa CDL\1. Intenção Compra'
PADRAO = os.path.join(BASE, '2026', 'PESQUISA DE INTENÇÃO - CDL Cuiabá CONSOLIDADO.xlsx')
SAIDA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'data', 'intencao_compra.js')
POPULACAO = 477531
CIDADES = {'Cuiabá', 'Várzea Grande', '0'}
# Mês da data comemorativa (ordena as edições e alimenta os filtros Mês/Ano do painel).
DATAS = {'Páscoa': 4, 'Dia das Mães': 5, 'Dia dos Namorados': 6, 'Dia dos Pais': 8, 'Dia das Crianças': 10, 'Black Friday': 11, 'Natal': 12}
ANO_ATUAL = 2026

PLANEJAMENTO = {   # opções mudaram entre as pesquisas: mesma escala
    'Planejada (Mais de 15 dias antes)': 'Planejada (mais de 15 dias antes)',
    'Antecedência (7 dias antes da data)': 'Na semana da data',
    'Semana do evento (Segunda a Quinta)': 'Na semana da data',
    'Véspera (1 ou 2 dias antes da data)': 'Véspera',
    'Véspera (Sexta ou Sábado)': 'Véspera',
    'Última hora (No dia da data comemorativa)': 'No dia da data',
    'Última hora (No próprio domingo)': 'No dia da data',
}
LOCAL = {'Lojas físicas': 'Lojas físicas', 'Internet': 'Internet', 'Mídias sociais': 'Mídias sociais'}
RENDA = lambda s: s.split(' (')[0]


def ler_copia(caminho):
    tmp = os.path.join(tempfile.gettempdir(), 'intencao_consolidado.xlsx')
    try:
        shutil.copyfile(caminho, tmp)
    except PermissionError:
        # Aberta no Excel: o Python não abre, mas a cópia do Windows (com o arquivo em uso) funciona.
        subprocess.run(['powershell', '-NoProfile', '-Command', 'Copy-Item -LiteralPath $env:IC_ORIGEM -Destination $env:IC_DESTINO -Force'],
                       check=True, env={**os.environ, 'IC_ORIGEM': caminho, 'IC_DESTINO': tmp})
    return tmp


def rot(col):
    """'6.Falta de orçamento.' -> 'Falta de orçamento'."""
    t = col.split('.', 1)[1] if col[:2].rstrip('.').isdigit() else col
    return t.strip().rstrip('.').strip()


def contagem(serie, mapa=None):
    out = {}
    for v, n in serie.dropna().value_counts().items():
        k = str(v)
        if mapa:
            k = next((m for a, m in mapa.items() if k.startswith(a)), k) if not callable(mapa) else mapa(k)
        out[k] = out.get(k, 0) + int(n)
    return out


def multipla(df, prefixo):
    """Menções por opção (sem as zeradas). Pergunta que não existia na pesquisa da data fica vazia e sai do arquivo."""
    return {rot(c): n for c in df.columns if c.startswith(prefixo) and (n := int(df[c].notna().sum()))}


def edicoes_atuais(df):
    df = df[df['Cidade Rezo'].astype(str).isin(CIDADES)]
    out = []
    for nome, d in df.groupby('Nome Pesquisa'):
        sim, nao = d[d['Você pretende comprar?'] == 'Sim'], d[d['Você pretende comprar?'] == 'Não']
        status = contagem(d['Status/Intenção'])
        intencao = status.get('Completo - Sim', 0) / len(d)
        ticket = float(sim['Ticket Médio (R$)'].mean())
        cons = intencao * POPULACAO
        datas = pd.to_datetime(d['date_created'])
        out.append({
            'data': nome, 'ano': ANO_ATUAL, 'mes': f'{ANO_ATUAL}-{DATAS[nome]:02d}',
            'coleta': [datas.min().strftime('%Y-%m-%d'), datas.max().strftime('%Y-%m-%d')],
            'amostra': int(len(d)), 'intencao': round(intencao, 6), 'ticket': round(ticket, 2),
            'consumidores': round(cons), 'movimentacao': round(cons * ticket, 2),
            'detalhe': {
                'respostas': int(d['Com que antecedência você costuma realizar a compra do presente?'].notna().sum()),
                'status': status,
                'motivosNao': multipla(nao, '6.'),
                'planejamento': contagem(d['Com que antecedência você costuma realizar a compra do presente?'], PLANEJAMENTO),
                'gastos': contagem(d['Comparado a 2025, seus gastos com a comemoração nessa data foram:']),
                'presentes': contagem(d['Quantos presentes comprou ou tem intenção de comprar esse ano?']),
                'local': contagem(d['Qual seu local de preferência para realizar suas compras?'], LOCAL),
                'motivoLocal': multipla(sim, '5.'),
                'motivoCompra': multipla(sim, '3.'),
                'produtos': multipla(sim, '1.'),
                'pagamento': contagem(d['Qual método de pagamento você tem preferência?']),
                'servicos': multipla(sim, '4.'),
                'genero': contagem(d['Qual gênero você se identica?']),
                'faixaEtaria': contagem(d['Qual faixa etária você pertence?']),
                'renda': contagem(d['Qual faixa salarial você pertence?'], RENDA),
            },
        })
        out[-1]['detalhe'] = {k: v for k, v in out[-1]['detalhe'].items() if v}
    return out


def historico(caminho):
    """Aba "Historico 2025": linhas Sim/Não por data (intenção, ticket, população, movimentação)."""
    wb = openpyxl.load_workbook(caminho, data_only=True, read_only=True)
    ws = wb['Historico 2025']
    linhas = [r for r in ws.iter_rows(min_row=4, values_only=True) if r[0] and r[0] != 'Total Geral']
    out = []
    for nome in DATAS:
        sim = next((r for r in linhas if r[0] == nome and r[1] == 'Sim'), None)
        nao = next((r for r in linhas if r[0] == nome and r[1] == 'Não'), None)
        if not sim:
            continue
        intencao, ticket = float(sim[3]), float(sim[4])
        cons = intencao * POPULACAO
        out.append({'data': nome, 'ano': ANO_ATUAL - 1, 'mes': f'{ANO_ATUAL - 1}-{DATAS[nome]:02d}',
                    'amostra': int(sim[2] + (nao[2] if nao else 0)), 'intencao': round(intencao, 6), 'ticket': round(ticket, 2),
                    'consumidores': round(cons), 'movimentacao': round(cons * ticket, 2)})
    return out


def main():
    origem = sys.argv[1] if len(sys.argv) > 1 else PADRAO
    copia = ler_copia(origem)
    df = pd.read_excel(copia, sheet_name='Sheet')
    eds = sorted(edicoes_atuais(df) + historico(copia), key=lambda e: e['mes'])
    for e in eds:
        e['id'] = f"{e['ano']}-{DATAS[e['data']]:02d}"
    dados = {'fonte': 'Pesquisa de Intenção de Compra · CDL Cuiabá', 'regiao': 'Região de Cuiabá (Cuiabá e Várzea Grande)',
             'populacao': POPULACAO, 'atualizado': datetime.date.today().isoformat(), 'planilha': os.path.basename(origem),
             'datas': list(DATAS), 'edicoes': eds}
    cab = ('// Dashboard › Painel · Intenção de Compra — gerado por scripts/intencao_extrair.py (não editar à mão).\n'
           '// Fonte: aba "Painel" da planilha consolidada da pesquisa (recalculada por data) + aba "Historico 2025".\n')
    with open(SAIDA, 'w', encoding='utf-8', newline='\n') as f:
        f.write(cab + 'window.INTENCAO_COMPRA = ' + json.dumps(dados, ensure_ascii=False, separators=(',', ':')) + ';\n')
    for e in eds:
        print(f"{e['id']} {e['data']:<18} n={e['amostra']:>4} intenção={e['intencao']:.2%} ticket=R$ {e['ticket']:.2f} "
              f"mov=R$ {e['movimentacao'] / 1e6:.1f} mi{'' if 'detalhe' in e else ' (histórico)'}")
    print('->', os.path.normpath(SAIDA))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
