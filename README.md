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
