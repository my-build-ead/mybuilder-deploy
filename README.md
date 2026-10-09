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
  workspace persiste entre runs;
- o `_work/<repo>` do projeto (checkout, `node_modules`, `dist`,
  `.mybuilder-deploy`) é apagado ao final do job no mini — só a pasta do
  próprio projeto, nunca `_tool`, `_actions`, `_temp` nem os outros repos — e
  só quando ele é o **último** job do repo: o primeiro step registra o job em
  `~/.actions-runner-jobs/<owner>_<repo>/` (fora do `_work`, visível a todas
  as instâncias do runner da máquina) e o último step só limpa se não houver
  outro job do repo vivo ali nem, via API, outro run do repo
  queued/pending/in_progress (dev, qa, sandbox e main disparados juntos: só o
  último limpa). A consulta à API usa o `RUNNERS_READ_TOKEN` e precisa que o
  PAT tenha também a permissão de repositório **Actions: Read-only** nos repos
  da org; sem ela a API devolve 403, o step avisa e decide só pelos jobs da
  máquina (nunca quebra o deploy). Roda com `always()`, então run que falhou
  também libera o disco.
