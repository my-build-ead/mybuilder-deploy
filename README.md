# mybuilder-deploy

Pipelines reusáveis de deploy das APIs do **mybuildex** (Cloud Functions gen2).
Fork do `kodigilo/kodigilo-deploy` — o original segue servindo os demais
produtos; alterações daqui NÃO voltam pra lá.

## Workflows

| Workflow | Uso |
|---|---|
| `deploy-firebase-api.yml` | padrão (maioria das APIs) |
| `deploy-firebase-api-with-domain-functions.yml` | acls, payments |
| `deploy-firebase-api-with-siteid.yml` | core |
| `deploy-firebase-api-with-redis.yml` | settings |
| `deploy-firebase-api-4gb.yml` | variante 4GB (DATABASE_URL por TCP) |

## Diferenças em relação ao kodigilo-deploy

Pool de banco enxuto para serverless — conexão vive só enquanto a function
precisa dela:

- `connection_limit` na `DATABASE_URL` vem do input `dbConnLimit` (**default 2**;
  era fixo 5);
- env `DB_IDLE_TIMEOUT` (input `dbIdleTimeout`, **default 60s**) e
  `DB_MIN_IDLE=0` — lidos pelo pool do `@mybuildex/pkg` >= 0.3.2, que fecha
  conexões ociosas em vez de segurá-las por 30 min (default do driver mariadb).

APIs que geram arquivo/relatório e precisem de mais folga sobem os inputs no
`firebase.yml` delas:

```yaml
    with:
      nomeDaFuncao: v1_templates
      dbConnLimit: "4"
      dbIdleTimeout: "300"
```

> **Atenção:** para os repos da org usarem estes workflows, em
> Settings → Actions → General → Access deste repo deve estar
> "Accessible from repositories owned by the organization".

## Runner self-hosted (Mac mini `mac03`)

Todos os workflows têm um job `probe` (ubuntu-latest, segundos) que consulta a
API de runners da org `my-build-ead` e decide onde o `build_and_deploy` roda:

- alguma instância `macOS` online e **livre** → `[self-hosted, macOS, ARM64]`;
- todas online mas **ocupadas** → `ubuntu-latest` na hora (não espera fila);
- nenhuma online → espera até 2 min o mini aparecer, depois `ubuntu-latest`.

Requisitos:

- secret `RUNNERS_READ_TOKEN` na org: PAT fine-grained com resource owner
  `my-build-ead` e permissão de organização **Self-hosted runners: Read-only**.
  O caller repassa junto com os `FIREBASE_*`:

  ```yaml
      secrets:
        FIREBASE_DEV: ${{ secrets.FIREBASE_DEV }}
        FIREBASE_QA: ${{ secrets.FIREBASE_QA }}
        FIREBASE_SANDBOX: ${{ secrets.FIREBASE_SANDBOX }}
        FIREBASE: ${{ secrets.FIREBASE }}
        RUNNERS_READ_TOKEN: ${{ secrets.RUNNERS_READ_TOKEN }}
  ```

  (com `secrets: inherit` vai automaticamente). Sem o secret tudo roda no
  GitHub, com warning na sonda — nunca quebra o deploy;
- o Mac mini não precisa de gcloud instalado: o `setup-gcloud` baixa o SDK
  para o tool cache do runner (só o primeiro run paga o download);
- os scripts em `scripts/` são bash 3.2/BSD-compatíveis (macOS); o `sed -i`
  nos workflows usa sufixo `.bak` pelo mesmo motivo;
- `env.yaml` e `firebase.json` são apagados ao final no self-hosted, já que o
  workspace persiste entre runs.
