# Integração CDLoad × WhatsApp (UAZAPI)

Tudo o que é da automação do WhatsApp fica nesta pasta. O planejamento completo, com as etapas, está em [whatsapp_uazapi_etapas.md](whatsapp_uazapi_etapas.md).

## Arquivos

| Arquivo | Para quê | Onde aplicar |
|---|---|---|
| [whatsapp_uazapi_etapas.md](whatsapp_uazapi_etapas.md) | Planejamento: arquitetura, endpoints, modelo de dados e etapas | — |
| [schema_secao_whatsapp.sql](schema_secao_whatsapp.sql) | Renomeia a seção `disparo` para `whatsapp` nas permissões | Supabase > SQL Editor |
| [schema_whatsapp.sql](schema_whatsapp.sql) | Tabelas `wa_*`, RLS e tempo real (Etapa 1) | Supabase > SQL Editor |
| [schema_whatsapp_disparos.sql](schema_whatsapp_disparos.sql) | Colunas de templates, view `wa_campanhas_resumo` e índice de envios (Etapas 4 a 6) | Supabase > SQL Editor, depois do anterior |
| [functions/whatsapp-api/index.ts](functions/whatsapp-api/index.ts) | Edge Function que fala com a UAZAPI | Supabase > Edge Functions |

A tela fica na seção **WhatsApp** do [index.html](../index.html) (aba Instâncias).

## Secrets (Supabase > Edge Functions > Secrets)

`UAZAPI_URL`, `UAZAPI_ADMIN_TOKEN`, `WHATSAPP_WEBHOOK_SEGREDO`.

## Publicar a função `whatsapp-api`

1. Abra [functions/whatsapp-api/index.ts](functions/whatsapp-api/index.ts) e copie todo o conteúdo.
2. Supabase > **Edge Functions** > `whatsapp-api` > **Code**: substitua o código e clique em **Deploy**. Mantenha **Verify JWT** ligado: a função exige login.

A CLI (`npx supabase functions deploy`) só procura funções em `supabase/functions/`. Para publicar por ela, copie antes a pasta para lá:

```powershell
Copy-Item -Recurse -Force whatsapp\functions\whatsapp-api supabase\functions\whatsapp-api
npx supabase functions deploy whatsapp-api
Remove-Item -Recurse -Force supabase\functions\whatsapp-api
```

## Templates e disparos (Etapas 4 a 6)

- **Templates:** variáveis no formato `{{nome}}`, `{{primeiro_nome}}`, `{{telefone}}` ou qualquer coluna extra da lista (ex.: `{{empresa}}`). O cabeçalho vai em negrito no início da mensagem. **Enviar teste** manda o template, com dados de exemplo, para um número informado.
- **Listas:** importadas no assistente de disparo (colar ou CSV, separador `;`, `,` ou tab). Telefones são normalizados para `55 + DDD + número`; inválidos e duplicados são ignorados.
- **Opt-out:** botão na aba Disparos. Esses números nunca entram na fila. A resposta "SAIR" automática depende do webhook (Etapa 3).
- **Disparo:** sai da fila quem está em opt-out, quem é duplicado e quem não tem WhatsApp (`/chat/check`). A fila vai para `/sender/advanced` com intervalo aleatório e agendamento opcional. Pausar, Retomar, Enviar agora e Cancelar usam `/sender/edit`.
- **Status de cada envio:** enquanto o webhook (Etapa 3) não existe, o botão **Atualizar** confere na UAZAPI (`/sender/listmessages`). As respostas brutas da UAZAPI ficam em `wa_eventos` (`tipo` começando com `api:`), para conferência.

## Instâncias (servidor de demonstração)

No servidor de demonstração da UAZAPI, o `/instance/all` está desligado. Crie a instância no painel da UAZAPI, copie o **token** dela e use **WhatsApp > Instâncias > Registrar instância**. No servidor do plano, basta **Sincronizar**: as instâncias entram sozinhas.
