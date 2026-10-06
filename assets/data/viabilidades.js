// Dashboard › Painel · Viabilidades — impacto do CDLoad na rotina e no financeiro.
// Fonte: planilha de viabilidade do Núcleo de Inteligência (out/2026). Edite aqui e publique.
//
// ferramentas: custo anual = preco × frequencia (mesma conta da coluna VALOR da planilha).
//              preco null = sem custo informado (entra no painel com R$ 0).
// cdload:      prós e contras de cada módulo. Horas salvas por mês =
//              frequencia × horas × (diasUteisMes, se a periodicidade for diária; 1, se mensal).
// planos:      captação anual = preco × quantidade × 12 (mensal) ou × 1 (anual).
window.VIAB_DADOS = {
  atualizado: '2026-10-06',
  diasUteisMes: 22,
  ferramentas: [
    { ferramenta: 'Power BI',      descricao: 'Ferramenta de manipulação e análise de dados', objetivo: '',                              prioridade: 'Alta',  plano: '',                periodicidade: '',       frequencia: 0,  preco: null },
    { ferramenta: 'Survey Monkey', descricao: 'Criação e gestão de formulários',              objetivo: 'Captura de dados do mercado',  prioridade: 'Alta',  plano: 'Plano individual', periodicidade: 'Anual',  frequencia: 12, preco: 100 },
    { ferramenta: 'GisMaps',       descricao: 'Criação de mapas',                             objetivo: 'Criação rápida de mapas',      prioridade: 'Alta',  plano: 'Plano individual', periodicidade: 'Anual',  frequencia: 1,  preco: 120 },
    { ferramenta: 'Canva',         descricao: 'Construção de materiais visuais',              objetivo: 'Layout relatórios / dashboards', prioridade: 'Média', plano: 'Canva Pro',       periodicidade: 'Mensal', frequencia: 12, preco: 35 },
    { ferramenta: 'Claude',        descricao: 'Automatização de processos',                   objetivo: 'Agente de IA – assessoria',    prioridade: 'Média', plano: 'Claude Pro',      periodicidade: 'Mensal', frequencia: 12, preco: 110 }
  ],
  cdload: [
    { modulo: 'Home',       pro: { objetivo: 'Centralização dos painéis', prioridade: 'Alta', periodicidade: 'Diário', frequencia: 2, horas: 0.1 }, contra: { objetivo: 'Nenhum',                    prioridade: 'Baixa' } },
    { modulo: 'Dashboard',  pro: { objetivo: 'Dados online – CAGED',      prioridade: 'Alta', periodicidade: 'Diário', frequencia: 1, horas: 2 },   contra: { objetivo: 'Dados sensíveis não podem', prioridade: 'Baixa' } },
    { modulo: 'Clipping',   pro: { objetivo: 'Pesquisa online',           prioridade: 'Alta', periodicidade: 'Diário', frequencia: 5, horas: 0.5 }, contra: { objetivo: 'Segurança',                 prioridade: 'Média' } },
    { modulo: 'Usuários',   pro: { objetivo: 'Controle de acesso',        prioridade: 'Alta', periodicidade: 'Mensal', frequencia: 2, horas: 0.5 }, contra: { objetivo: 'Alta demanda',              prioridade: 'Baixa' } },
    { modulo: 'Relatórios', pro: { objetivo: 'Gerador automático PDF',    prioridade: 'Alta', periodicidade: 'Diário', frequencia: 1, horas: 2 },   contra: { objetivo: 'Nenhum',                    prioridade: 'Baixa' } }
  ],
  planos: [
    { nome: 'Planos Consultoria', objetivo: 'Prestação de serviço CDLs', prioridade: 'Alta', plano: 'Profissional', periodicidade: 'Mensal', quantidade: 1, preco: 120 }
  ]
};
