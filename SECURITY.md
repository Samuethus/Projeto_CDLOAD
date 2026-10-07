# Segurança

App **100% front-end**: tudo o que está no HTML/JS chega ao navegador de qualquer visitante. Nenhuma chave "escondida" no código é realmente secreta. O que protege os dados é o **banco (RLS do Supabase)**, não o repositório.

## Estado atual

| Item | Situação |
|---|---|
| Chave anon fora do código | Feito: `.env` / secrets do GitHub → `config.js` (fora do Git) |
| Senha de admin/bootstrap removida do código e do `config.js` | Feito |
| Login com Supabase Auth (hash + token) | Feito no código |
| Policies de RLS por seção/perfil, sem acesso `anon` | Pronto em `supabase/schema_seguranca_rls.sql`, **precisa ser executado por você** |
| Remover produto/movimentação do Estoque | Restrito a Administrador (policy + botão só aparece para admin) |
| Editar e excluir dados em qualquer seção | Só Administrador (policies em `supabase/schema_somente_admin_edita.sql` + botões só aparecem para admin). Demais perfis, mesmo com todas as seções, só leem e criam |
| Coluna `usuarios.senha` | Removida pelo mesmo SQL |
| Escape de HTML nos dados exibidos (XSS) | Feito (inclusive nos templates, que ainda são só locais) |
| Bibliotecas de CDN fixadas com SRI, CSP no `<meta>` | Feito |
| Fonte carregada do Google Fonts (o antigo `./css2` local não existe no site publicado) | Feito |
| Deploy sem publicar `.env`, scripts, SQL | Feito (workflow publica só `index.html` + `config.js`) |

## Obrigatório antes de publicar

1. Executar, nesta ordem, `supabase/schema_estoque.sql`, `supabase/schema_relatorios.sql` e depois o passo a passo de [supabase/LEIA-ME.md](supabase/LEIA-ME.md) (Auth com confirmação de e-mail + `schema_seguranca_rls.sql`). Rodar só os schemas deixa Estoque e Relatórios sem nenhum acesso, nem do `anon` — proposital, até o RLS ser aplicado.
2. **Trocar as senhas antigas** (as de `usuarios.senha` e `cdload2026`), pois foram expostas.
3. Cadastrar os secrets no GitHub (só a chave anon/publishable).
4. Em Authentication > Providers > Email, considere desativar "Allow new users to sign up" (ou usar apenas **Invite user**) — o cadastro aberto não dá acesso a dados, mas permite criar contas descartáveis e disparar e-mails de confirmação para terceiros.

## Como a proteção funciona

- O `config.js` publicado expõe URL e chave anon. Isso é normal: sem sessão, o papel `anon` não tem acesso a nenhuma tabela.
- Cada consulta exige usuário logado, com e-mail confirmado, cadastrado como **Ativo** em `usuarios` e com a **seção** liberada (ou Administrador).
- Só Administrador cria, altera ou remove usuários e locais.
- Só Administrador **edita ou exclui** qualquer dado (campanhas, notícias, produtos, movimentações, relatórios), mesmo que outro perfil tenha todas as seções liberadas.
- Criar conta sozinho não dá acesso: o e-mail precisa já estar em `usuarios`. A **confirmação de e-mail** impede que alguém tome o cadastro de outra pessoa (mantenha-a ativada).
- Movimentações de estoque são imutáveis e o autor (`usuario_email`) não pode ser forjado.

## Limitações conhecidas

- **CSP com `'unsafe-inline'`:** o HTML tem scripts e estilos embutidos. Para endurecer, extraia JS/CSS e use nonces/hashes.
- **Cabeçalhos HTTP:** o GitHub Pages não permite configurá-los, então `frame-ancestors`/HSTS customizados não se aplicam (o Pages já serve HTTPS). Cloudflare Pages ou Netlify permitem.
- **Sem tela de "esqueci a senha":** reset pelo painel do Supabase.
- **Repositório público:** o código é visível, o que é aceitável porque não há segredos nele. Não coloque `.env`, `config.js`, chave `service_role` ou dados reais no repositório.
- Se a chave anon vazar em contexto indevido, rotacione em Supabase > Project Settings > API e atualize o secret.

## Segredos

- Nunca faça commit de `.env` ou `config.js` (estão no `.gitignore`).
- Nunca use a chave `service_role`/`secret` no front-end (`gerar_config.py` a recusa).

## Antes do primeiro commit

```bash
git init && git status --ignored
```

Confira que `.env`, `config.js` e `.claude/` aparecem só como ignorados. Se algum segredo já foi commitado em outro repositório, use `git filter-repo` e rotacione a chave.
