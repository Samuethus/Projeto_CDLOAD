# CDLoad · Núcleo de Inteligência

Painel web estático (HTML único, sem build) com Campanhas, Clipping News, Relatórios, Usuários e Estoque, usando o Supabase (Auth + banco com RLS + Storage).

O Clipping News é alimentado automaticamente pelo Google Notícias e pelo site oficial da CDL, comparando dois players (CDL Cuiabá e Fecomércio MT), com a coleta rodando no próprio Supabase: ver [supabase/schema_clipping.sql](supabase/schema_clipping.sql). O Dashboard traz o painel "Clipping News" com os principais indicadores dessa comparação.

## Antes de publicar

1. Siga [supabase/LEIA-ME.md](supabase/LEIA-ME.md): configurar o Auth e rodar [supabase/seguranca_rls.sql](supabase/seguranca_rls.sql). **Sem isso o banco continua aberto.**
2. Leia [SECURITY.md](SECURITY.md).

## Requisitos

- [Git](https://git-scm.com/)
- [Python 3.8+](https://www.python.org/) (gera a configuração e serve o app localmente)
- Um projeto [Supabase](https://supabase.com/) com as tabelas do app

## Configurar as chaves (uso local)

Nada de chave no código. Elas ficam no `.env` (ignorado pelo Git) e viram um `config.js` local.

```bash
copy .env.example .env      # macOS/Linux: cp .env.example .env
```

| Variável | O que é |
|---|---|
| `SUPABASE_URL` | URL do projeto (Supabase > Project Settings > API) |
| `SUPABASE_ANON_KEY` | Chave **anon/publishable** (nunca a `service_role`: o script recusa) |
| `ADMIN_EMAIL` | E-mail do administrador principal |

```bash
python scripts/gerar_config.py
python -m http.server 8080
```

Abra <http://localhost:8080/> (o app precisa de HTTP; `localhost` permite a câmera do leitor de código de barras). Sem `config.js`, o app roda em **modo demonstração** (dados em memória; login `admin@example.com` / `demo1234`).

## Login

Supabase Auth: senha com hash e sessão por token. O administrador cadastra a pessoa em **Usuários** (nome, e-mail, perfil, seções); ela então clica em **Primeiro acesso** na tela de login, define a senha e confirma o e-mail.

## Publicar no GitHub Pages

1. Crie o repositório e envie o código (`git init`, confira com `git status --ignored` que `.env` e `config.js` **não** aparecem, e faça o commit/push na branch `main`).
2. No GitHub: **Settings > Secrets and variables > Actions** > crie `SUPABASE_URL`, `SUPABASE_ANON_KEY` (só a anon/publishable) e `ADMIN_EMAIL`.
3. **Settings > Pages > Source: GitHub Actions**.
4. Cada push em `main` roda [.github/workflows/deploy.yml](.github/workflows/deploy.yml), que publica só o `index.html`, as pastas `assets/` e `landing/`, os modelos dos relatórios em PDF (`report/*/branding/`) e o `config.js` gerado. Scripts, SQL e docs não vão para o site.
5. Coloque o endereço do Pages em Supabase > Authentication > URL Configuration.

A câmera ao vivo exige HTTPS, que o GitHub Pages já fornece.

## Estrutura

```
index.html               o app
config.js                gerado pelo script (ignorado pelo Git)
scripts/gerar_config.py  gera o config.js (.env ou variáveis de ambiente)
supabase/                SQL de segurança (RLS) e passo a passo
.github/workflows/       deploy no GitHub Pages
.env.example             modelo das variáveis
SECURITY.md              riscos e limitações
```

## Modelos de landing page para o projeto
https://dribbble.com/shots/27591382-Fintech-Landing-Page-Design
https://dribbble.com/shots/27604108-Nodeword-AI-Agent-Platform-Landing-Page