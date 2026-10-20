#!/usr/bin/env bash
# Usado pelo workflow .github/workflows/abve-diario.yml: commita os arquivos de dados que mudaram e dispara o deploy.
# Uso: scripts/commitar_dados.sh "mensagem do commit" arquivo1 arquivo2 ...
# Sem mudança nos arquivos, não faz nada.
set -u
MSG="$1"; shift
if [ -z "$(git status --porcelain "$@")" ]; then
  echo "Sem mudanças."
  exit 0
fi
git config user.name "abve-bot"
git config user.email "abve-bot@users.noreply.github.com"
git add $(ls "$@" 2>/dev/null)   # só os que existem (alguns surgem na 1ª extração)
git commit -m "$MSG"
# Se a main recebeu commits durante a execução, o push simples é recusado: traz os commits novos
# (só mexem em outros arquivos) e tenta de novo. --autostash: arquivo fora da lista alterado pelos
# scripts não pode travar o rebase (e perder o commit).
enviado=""
for i in 1 2 3; do
  git pull --rebase --autostash origin main && git push && enviado=1 && break
  sleep 10
done
[ -n "$enviado" ] || { echo "::error::Não foi possível enviar os dados gerados (push recusado 3 vezes)."; exit 1; }
# Commits feitos pelo GITHUB_TOKEN não disparam o deploy sozinhos.
gh workflow run deploy.yml
