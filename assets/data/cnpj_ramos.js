// Ramos de negócio do indicador EMPRESAS (Dashboard › Panorama › EMPRESAS · filtro "Ramo").
// Cada ramo agrupa subclasses CNAE da Receita Federal por PREFIXO do código (7 dígitos, sem pontuação):
//   '4774100' = uma subclasse · '47717' = uma classe inteira · '86' = uma divisão inteira.
// Quando dois ramos cobrem o mesmo código, vale o prefixo mais longo (ex.: Odontologia '8630504' dentro de '86305').
// sinonimos: palavras que o usuário pode digitar na busca do filtro ("óculos" → Óticas).
// Lido pelo site (filtro, painel e mapa) e por scripts/cnpj_extrair.py (pontos de negócio por CEP no mapa).
// Para criar ou ajustar um ramo: edite aqui e publique; o mapa por ramo se atualiza na próxima extração.
window.CNPJ_RAMOS = {
  "ramos": [
    { "nome": "Supermercados e mercearias", "grupo": "Alimentação", "sinonimos": ["mercado", "supermercado", "mercearia", "minimercado", "hipermercado", "atacarejo", "empório"], "cnaes": ["4711", "4712"] },
    { "nome": "Padarias e confeitarias", "grupo": "Alimentação", "sinonimos": ["padaria", "panificadora", "confeitaria", "bolos", "doceria", "pão"], "cnaes": ["4721102", "4721103", "1091"] },
    { "nome": "Açougues", "grupo": "Alimentação", "sinonimos": ["açougue", "carnes", "frigorífico"], "cnaes": ["4722901"] },
    { "nome": "Hortifrútis", "grupo": "Alimentação", "sinonimos": ["hortifruti", "sacolão", "frutas", "verduras", "legumes", "quitanda"], "cnaes": ["4724"] },
    { "nome": "Distribuidoras de bebidas", "grupo": "Alimentação", "sinonimos": ["bebidas", "adega", "distribuidora", "conveniência", "cerveja"], "cnaes": ["4723"] },
    { "nome": "Restaurantes", "grupo": "Alimentação", "sinonimos": ["restaurante", "almoço", "self-service", "churrascaria", "comida"], "cnaes": ["5611201"] },
    { "nome": "Lanchonetes, pizzarias e sorveterias", "grupo": "Alimentação", "sinonimos": ["lanchonete", "lanches", "hamburgueria", "pizzaria", "açaí", "sorveteria", "pastelaria", "sucos", "cafeteria"], "cnaes": ["5611203"] },
    { "nome": "Bares", "grupo": "Alimentação", "sinonimos": ["bar", "boteco", "pub", "choperia", "petiscaria"], "cnaes": ["5611204", "5611205"] },
    { "nome": "Marmitas, buffets e delivery", "grupo": "Alimentação", "sinonimos": ["marmita", "marmitex", "delivery", "buffet", "refeições", "cozinha industrial"], "cnaes": ["5620"] },

    { "nome": "Farmácias e drogarias", "grupo": "Saúde e bem-estar", "sinonimos": ["farmácia", "drogaria", "remédio", "medicamento", "manipulação"], "cnaes": ["4771"] },
    { "nome": "Óticas", "grupo": "Saúde e bem-estar", "sinonimos": ["ótica", "óptica", "óculos", "lentes", "lentes de contato", "armações"], "cnaes": ["4774"] },
    { "nome": "Clínicas e consultórios médicos", "grupo": "Saúde e bem-estar", "sinonimos": ["clínica", "médico", "consultório", "pediatra", "dermatologista", "ginecologista"], "cnaes": ["86305"] },
    { "nome": "Odontologia", "grupo": "Saúde e bem-estar", "sinonimos": ["dentista", "odontologia", "odontológico", "ortodontia", "implante dentário"], "cnaes": ["8630504"] },
    { "nome": "Laboratórios e exames", "grupo": "Saúde e bem-estar", "sinonimos": ["laboratório", "exames", "análises clínicas", "raio-x", "ultrassom", "diagnóstico"], "cnaes": ["8640"] },
    { "nome": "Fisioterapia, psicologia e nutrição", "grupo": "Saúde e bem-estar", "sinonimos": ["fisioterapia", "psicologia", "psicólogo", "nutricionista", "fonoaudiologia", "terapia"], "cnaes": ["8650"] },
    { "nome": "Academias", "grupo": "Saúde e bem-estar", "sinonimos": ["academia", "ginástica", "musculação", "crossfit", "pilates", "lutas", "dança"], "cnaes": ["9313", "8591"] },
    { "nome": "Salões de beleza e barbearias", "grupo": "Saúde e bem-estar", "sinonimos": ["salão", "salão de beleza", "cabeleireiro", "barbearia", "manicure", "estética", "depilação", "unhas"], "cnaes": ["9602"] },
    { "nome": "Cosméticos e perfumaria", "grupo": "Saúde e bem-estar", "sinonimos": ["cosméticos", "perfumaria", "perfume", "maquiagem", "beleza"], "cnaes": ["4772"] },
    { "nome": "Pet shops e veterinárias", "grupo": "Saúde e bem-estar", "sinonimos": ["pet", "pet shop", "petshop", "veterinário", "veterinária", "ração", "banho e tosa", "animais"], "cnaes": ["4789004", "7500", "9609208"] },

    { "nome": "Vestuário e acessórios", "grupo": "Moda e varejo", "sinonimos": ["roupas", "moda", "boutique", "vestuário", "loja de roupa", "moda feminina", "moda masculina", "lingerie"], "cnaes": ["4781"] },
    { "nome": "Calçados", "grupo": "Moda e varejo", "sinonimos": ["calçados", "sapataria", "sapato", "tênis", "sandálias"], "cnaes": ["4782201"] },
    { "nome": "Bolsas e artigos de viagem", "grupo": "Moda e varejo", "sinonimos": ["bolsas", "malas", "artigos de couro", "carteiras"], "cnaes": ["4782202"] },
    { "nome": "Joalherias e relojoarias", "grupo": "Moda e varejo", "sinonimos": ["joalheria", "joias", "relojoaria", "relógios", "bijuteria", "semijoias"], "cnaes": ["4783"] },
    { "nome": "Artigos esportivos e bicicletas", "grupo": "Moda e varejo", "sinonimos": ["esporte", "artigos esportivos", "bicicleta", "bike", "suplementos"], "cnaes": ["4763602", "4763603"] },
    { "nome": "Brinquedos", "grupo": "Moda e varejo", "sinonimos": ["brinquedos", "jogos", "loja de brinquedos"], "cnaes": ["4763601"] },
    { "nome": "Lojas de departamentos e variedades", "grupo": "Moda e varejo", "sinonimos": ["variedades", "bazar", "utilidades", "presentes", "loja de departamentos", "1,99"], "cnaes": ["4713", "4759899"] },
    { "nome": "Livrarias e papelarias", "grupo": "Moda e varejo", "sinonimos": ["livraria", "papelaria", "material escolar", "livros", "revistaria"], "cnaes": ["4761"] },
    { "nome": "Floriculturas", "grupo": "Moda e varejo", "sinonimos": ["floricultura", "flores", "plantas", "jardinagem"], "cnaes": ["4789002"] },

    { "nome": "Materiais de construção", "grupo": "Casa e construção", "sinonimos": ["material de construção", "materiais de construção", "tintas", "ferragens", "madeireira", "cimento", "vidraçaria", "pisos"], "cnaes": ["4741", "4742", "4743", "4744"] },
    { "nome": "Móveis e decoração", "grupo": "Casa e construção", "sinonimos": ["móveis", "decoração", "colchões", "tapetes", "cortinas", "planejados", "estofados"], "cnaes": ["4754", "4755", "4759801"] },
    { "nome": "Eletrodomésticos e eletrônicos", "grupo": "Casa e construção", "sinonimos": ["eletrodomésticos", "eletrônicos", "televisão", "som", "eletroeletrônicos"], "cnaes": ["4753", "4757"] },
    { "nome": "Informática e celulares", "grupo": "Casa e construção", "sinonimos": ["informática", "computador", "notebook", "celular", "telefonia", "assistência técnica", "acessórios de celular"], "cnaes": ["4751", "4752", "9511", "9512"] },
    { "nome": "Construtoras e reformas", "grupo": "Casa e construção", "sinonimos": ["construtora", "construção civil", "reforma", "obras", "alvenaria", "empreiteira", "pintura"], "cnaes": ["412", "433", "4399103"] },
    { "nome": "Instalações elétricas e hidráulicas", "grupo": "Casa e construção", "sinonimos": ["eletricista", "encanador", "instalação elétrica", "hidráulica", "ar-condicionado", "refrigeração"], "cnaes": ["4321", "4322"] },

    { "nome": "Postos de combustível", "grupo": "Automotivo", "sinonimos": ["posto", "posto de gasolina", "combustível", "gasolina", "etanol"], "cnaes": ["4731"] },
    { "nome": "Autopeças e pneus", "grupo": "Automotivo", "sinonimos": ["autopeças", "peças", "acessórios automotivos", "pneus", "baterias", "motopeças"], "cnaes": ["453"] },
    { "nome": "Oficinas e lava-jatos", "grupo": "Automotivo", "sinonimos": ["oficina", "mecânica", "funilaria", "borracharia", "lava-jato", "lava jato", "auto center", "elétrica automotiva"], "cnaes": ["4520"] },
    { "nome": "Revendas de veículos", "grupo": "Automotivo", "sinonimos": ["concessionária", "revenda de veículos", "carros", "motos", "seminovos", "garagem"], "cnaes": ["451", "4541"] },

    { "nome": "Contabilidade", "grupo": "Serviços profissionais", "sinonimos": ["contador", "contabilidade", "escritório contábil", "contábil"], "cnaes": ["6920"] },
    { "nome": "Advocacia", "grupo": "Serviços profissionais", "sinonimos": ["advogado", "advocacia", "jurídico", "escritório de advocacia"], "cnaes": ["6911"] },
    { "nome": "Imobiliárias", "grupo": "Serviços profissionais", "sinonimos": ["imobiliária", "corretor de imóveis", "aluguel", "imóveis", "administração de condomínios"], "cnaes": ["682"] },
    { "nome": "Marketing e publicidade", "grupo": "Serviços profissionais", "sinonimos": ["marketing", "publicidade", "agência", "propaganda", "mídias sociais"], "cnaes": ["7311", "7312", "7319001", "7319004", "7319099"] },
    { "nome": "Promoção de vendas", "grupo": "Serviços profissionais", "sinonimos": ["promoção de vendas", "promotor", "degustação", "demonstração"], "cnaes": ["7319002"] },
    { "nome": "Consultoria empresarial", "grupo": "Serviços profissionais", "sinonimos": ["consultoria", "gestão empresarial", "assessoria"], "cnaes": ["7020"] },
    { "nome": "Tecnologia e software", "grupo": "Serviços profissionais", "sinonimos": ["software", "tecnologia", "ti", "sistemas", "desenvolvimento", "suporte técnico", "internet"], "cnaes": ["620", "631"] },
    { "nome": "Fotografia e eventos", "grupo": "Serviços profissionais", "sinonimos": ["fotografia", "fotógrafo", "eventos", "festas", "cerimonial", "decoração de festas"], "cnaes": ["742", "823"] },
    { "nome": "Serviços administrativos e despachantes", "grupo": "Serviços profissionais", "sinonimos": ["escritório", "apoio administrativo", "preparação de documentos", "despachante", "cobrança"], "cnaes": ["8211", "8219", "8291"] },

    { "nome": "Escolas e creches", "grupo": "Educação", "sinonimos": ["escola", "colégio", "educação infantil", "creche", "ensino fundamental", "ensino médio"], "cnaes": ["851", "852"] },
    { "nome": "Cursos, idiomas e autoescolas", "grupo": "Educação", "sinonimos": ["curso", "idiomas", "inglês", "preparatório", "treinamento", "autoescola", "reforço escolar", "informática"], "cnaes": ["8592", "8593", "8599"] },
    { "nome": "Ensino superior", "grupo": "Educação", "sinonimos": ["faculdade", "universidade", "pós-graduação", "graduação"], "cnaes": ["853"] },

    { "nome": "Hotéis e pousadas", "grupo": "Turismo", "sinonimos": ["hotel", "pousada", "motel", "hospedagem", "hostel"], "cnaes": ["551", "559"] },
    { "nome": "Agências de viagens", "grupo": "Turismo", "sinonimos": ["agência de viagens", "turismo", "passagens", "excursões"], "cnaes": ["791"] },

    { "nome": "Transporte de cargas", "grupo": "Transporte e logística", "sinonimos": ["transportadora", "frete", "cargas", "caminhão", "mudanças"], "cnaes": ["4930"] },
    { "nome": "Transporte de passageiros", "grupo": "Transporte e logística", "sinonimos": ["táxi", "motorista de aplicativo", "van", "fretamento", "ônibus", "transporte escolar"], "cnaes": ["4921", "4922", "4923", "4924", "4929"] },
    { "nome": "Entregas e motoboys", "grupo": "Transporte e logística", "sinonimos": ["entregas", "motoboy", "courier", "malote"], "cnaes": ["5320"] },

    { "nome": "Agropecuária (produção)", "grupo": "Agro", "sinonimos": ["fazenda", "pecuária", "soja", "milho", "gado", "agricultura", "produtor rural"], "cnaes": ["01", "02", "03"] },
    { "nome": "Insumos e comércio agropecuário", "grupo": "Agro", "sinonimos": ["agropecuária", "insumos", "defensivos", "sementes", "adubo", "fertilizantes", "grãos"], "cnaes": ["4621", "4622", "4623", "4683"] },

    { "nome": "Lavanderias", "grupo": "Outros serviços", "sinonimos": ["lavanderia", "tinturaria", "passadoria"], "cnaes": ["9601"] },
    { "nome": "Gráficas e comunicação visual", "grupo": "Outros serviços", "sinonimos": ["gráfica", "impressão", "comunicação visual", "adesivos", "banners", "copiadora"], "cnaes": ["181", "8219901"] },
    { "nome": "Segurança e vigilância", "grupo": "Outros serviços", "sinonimos": ["segurança", "vigilância", "monitoramento", "alarmes"], "cnaes": ["801", "802"] },
    { "nome": "Limpeza e conservação", "grupo": "Outros serviços", "sinonimos": ["limpeza", "conservação", "faxina", "dedetização", "jardinagem"], "cnaes": ["812", "813"] },
    { "nome": "Igrejas e associações", "grupo": "Outros serviços", "sinonimos": ["igreja", "associação", "sindicato", "organização religiosa", "ong"], "cnaes": ["94"] }
  ]
};
