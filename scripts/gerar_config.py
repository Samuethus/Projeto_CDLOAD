#!/usr/bin/env python3
"""Gera config.js a partir do arquivo .env ou de variáveis de ambiente (sem dependências externas).

O app é um HTML estático, sem build: ele lê a configuração de `config.js`,
que é ignorado pelo Git. Rode este script sempre que editar o .env.
No GitHub Actions as variáveis vêm dos *secrets* (ver .github/workflows/deploy.yml).

Uso:  python scripts/gerar_config.py [pasta_de_saida]
"""
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
ENV = RAIZ / ".env"
CHAVES = ("SUPABASE_URL", "SUPABASE_ANON_KEY", "ADMIN_EMAIL")
OBRIGATORIAS = ("SUPABASE_URL", "SUPABASE_ANON_KEY")
# Uma chave "service_role"/"secret" jamais pode ir para o navegador.
PROIBIDOS = ("service_role", "sb_secret_")


def ler_env(caminho):
    valores = {}
    for linha in caminho.read_text(encoding="utf-8-sig").splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#") or "=" not in linha:
            continue
        chave, _, valor = linha.partition("=")
        valores[chave.strip()] = valor.strip().strip('"').strip("'")
    return valores


def jwt_role(chave):
    """Se a chave for um JWT legado, devolve o claim `role` (ex.: service_role)."""
    import base64

    partes = chave.split(".")
    if len(partes) != 3:
        return None
    try:
        corpo = partes[1] + "=" * (-len(partes[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(corpo)).get("role")
    except Exception:
        return None


def main():
    saida_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else RAIZ
    saida = saida_dir / "config.js"

    env = ler_env(ENV) if ENV.exists() else {}
    for chave in CHAVES:  # variáveis de ambiente (CI) têm prioridade sobre o .env
        if os.environ.get(chave):
            env[chave] = os.environ[chave].strip()
    if not env:
        sys.exit("Sem configuração. Copie .env.example para .env e preencha (ou defina as variáveis de ambiente).")

    faltando = [k for k in OBRIGATORIAS if not env.get(k)]
    if faltando:
        sys.exit("Preencha: " + ", ".join(faltando))
    if not env["SUPABASE_URL"].startswith("https://"):
        sys.exit("SUPABASE_URL deve começar com https://")
    chave = env["SUPABASE_ANON_KEY"]
    if any(p in chave for p in PROIBIDOS) or jwt_role(chave) == "service_role":
        sys.exit("SUPABASE_ANON_KEY parece uma chave secreta/service_role. Use apenas a chave anon/publishable.")

    config = {
        "supabase": {"url": env["SUPABASE_URL"], "anonKey": chave},
        "adminEmail": env.get("ADMIN_EMAIL", ""),
    }
    js = (
        "// GERADO por scripts/gerar_config.py — NÃO edite nem faça commit.\n"
        f"window.APP_CONFIG = {json.dumps(config, ensure_ascii=False, indent=2)};\n"
        "window.SUPABASE_CONFIG = window.APP_CONFIG.supabase;\n"
    )
    saida_dir.mkdir(parents=True, exist_ok=True)
    saida.write_text(js, encoding="utf-8")
    print(f"OK: {saida} gerado.")


if __name__ == "__main__":
    main()
