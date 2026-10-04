# Prompt — performance de deploy e cold start das APIs TypeScript

Cole o bloco abaixo numa sessão aberta no projeto de destino. Ele descreve o
que foi feito no MyBuilder (piloto na `v3_peoples`, 03–04/10/2026), o que foi
medido, as armadilhas encontradas e onde está a implementação de referência.

---

Quero aplicar neste projeto as otimizações de deploy e cold start que já estão
validadas no MyBuilder. A arquitetura é a mesma: APIs Fastify 4 + TypeScript em
Cloud Functions gen2 (Cloud Run por baixo), `@fastify/autoload` carregando
`src/modules`, Prisma com client gerado, um pacote npm de infra compartilhada
e workflows reutilizáveis de deploy num repositório próprio.

## Resultado medido no piloto (para saber o que esperar)

| Métrica | Antes | Depois |
|---|---|---|
| Primeiro GET em instância fria | 4,6 s | 0,79 s |
| Boot do código da API (carga + Fastify) | 4,8 s | 1,45 s |
| Container até a porta pronta | 3,8 s | 1,8–2,7 s |
| Imagem | 211 MB | 115 MB |
| Workflow de deploy | 380 s | 205–281 s |
| Requests simultâneas por instância | 1 | 20 |

## Restrições

- NÃO usar `min-instances` nem nada com custo fixo de instância ligada.
- Não mexer em região, credenciais versionadas nem em comportamento de rotas.
- Toda mudança compartilhada entra como opt-in, com default igual ao
  comportamento atual: uma API só muda quando o repositório dela pede.
- Fazer um piloto em UMA API, medir online em dev e só então replicar.
- Não afirmar ganho sem medir. O boot local caiu 57% e isso NÃO apareceu no
  Cloud Run; só a instrumentação lá dentro mostrou o gargalo real.

## Implementação de referência (ler antes de escrever)

- Pacote compartilhado: `/Users/gabrielalencar/Documents/custom/mybuilder-typescript-pkg`
  - `src/build/` — comando `mybuildex-bundle` (bundle, autoload estático, verificação de rotas)
  - `src/http/gcf-handler.ts` — opção `eagerBoot`
  - `src/redis/client.ts` — `redis` carregado sob demanda
  - `src/tenant/permissions.ts` — `memoryCacheTtlMs`
  - `README.md`, seções 0.9.0 e 0.10.0
- Deploy: `/Users/gabrielalencar/Documents/custom/mybuilder-deploy/.github/workflows/deploy-firebase-api.yml`
  (inputs `prebuild` e `vpcUpdate`)
- API piloto: `/Users/gabrielalencar/Documents/custom/mybuilder-typescript-v3-peoples`
  (`package.json`, `tsconfig.json`, `src/index.ts`, `src/config/infra.ts`, `.github/workflows/firebase.yml`)

## Ordem do trabalho

1. Medir o baseline da API piloto (seção "Como medir").
2. Workflow de deploy compartilhado.
3. Pacote compartilhado, e publicar a versão nova ANTES de tocar nas APIs
   (o lock da API só pode ser gerado com a versão já no registro; depois de
   publicar, o registro pode levar 1–2 minutos para mostrar a versão). A tag
   de publicação tem que apontar para o commit que JÁ tem a versão nova no
   `package.json` — commit primeiro, tag depois.
4. API piloto, deploy em dev, medição.
5. Demais APIs.

## 1. Workflow de deploy (dois inputs opt-in)

**`prebuild: "true"`** — o runner compila e sobe só o pacote pronto, em vez de
o Cloud Build instalar devDependencies, rodar `tsc` e `npm prune` (eram ~140 s
dos ~270 s de build). Passos, depois de escrever `firebase.json` e de trocar o
placeholder do nome da função:

- `actions/setup-node` com Node igual ao runtime;
- `npm ci` e `npm run build`;
- montar `.deploy/` com `dist/`, `package-lock.json`, `firebase.json` e um
  `package.json` SEM `scripts` e SEM `devDependencies`;
- refazer o lock só de produção: `(cd .deploy && npm install --package-lock-only --ignore-scripts)`;
- remover do lock toda entrada marcada `peer` + `optional` (ver armadilha abaixo);
- `gcloud functions deploy ... --source=.deploy`;
- apagar `.deploy` no fim em runner self-hosted (ele carrega o `firebase.json`).

**`vpcUpdate: "if-needed"`** — a revisão criada pelo `functions deploy` herda
rede (Direct VPC) e Cloud SQL da anterior. O passo que reaplica isso com
`gcloud run services update` cria uma segunda revisão a cada deploy (15–60 s).
Ler as anotações da revisão nova (`network-interfaces`, `vpc-access-egress`,
`cloudsql-instances`, `vpc-access-connector`) e só rodar o update se diferirem.
Comparar rede/subnet pelo último segmento (o secret pode ter nome curto ou
caminho completo); qualquer falha de leitura cai no update.

Armadilhas:
- `npm ci --omit=dev` NÃO remove devDependency que também é peer opcional de
  uma dependência de produção (o lock marca `devOptional`). Era isso que
  mantinha a CLI do Prisma (~250 MB com Studio, pglite, effect) e o typescript
  na imagem. Por isso o `package.json` do pacote sai sem devDependencies e o
  lock é refeito.
- npm 10 e npm 11 divergem nesse re-lock: o npm 10 mantém os pacotes
  alcançados só por peer opcional. O filtro `peer && optional` iguala os dois.
  Validar simulando com a MESMA versão de npm do runner (`npx npm@<versão>`).
- Scripts do workflow precisam rodar em bash 3.2 se houver runner macOS.

## 2. Pacote compartilhado

- **CLI do Prisma fora das `dependencies`.** Ela só serve para `generate`; como
  dependência de produção do pacote, vai para a imagem de toda API. Cada API
  passa a declarar `prisma` como devDependency, na mesma versão do
  `@prisma/client` do pacote. É quebra de instalação: subir o minor.
- **`redis` sob demanda.** `require("redis")` só dentro da função que conecta,
  depois de saber que há configuração. Eram ~480 módulos no boot de API sem Redis.
- **Cache de permissões em memória, opt-in.** Sem Redis a consulta de
  permissões rodava em toda request autenticada. TTL curto por `escola:usuário`,
  ignorado quando há Redis, erro nunca é guardado.
- **Comando de bundle** (ver seção 4) e **`eagerBoot`** no handler.
- O index do pacote NÃO pode importar as ferramentas de build; o esbuild é
  peer opcional (devDependency da API).

## 3. Cada API

Com o pacote novo publicado:

1. `npm i <pacote>@^<versão>` e `npm i -D prisma@<versão do client> esbuild`.
2. `package.json`:
   - `"main": "dist/bundle.js"`;
   - `"build": "tsc && mybuildex-bundle"`, `"gcp-build": "npm run build"`;
   - o script `test` passa a chamar `npm run build` (a verificação de rotas roda junto);
   - `"mybuildex": {"bundle": {"external": [...]}}` com as libs que a API só carrega sob demanda.
3. `tsconfig.json`: `"declaration": false`, `"sourceMap": false` (ninguém
   consome; o client Prisma gerava 22 MB de `.d.ts`).
4. `src/index.ts`: `createGcfHandler({server, eagerBoot: true})`.
5. Imports pesados: medir quais pacotes carregam no boot (contar
   `require.cache` por pacote depois do `ready()`). Trocar barrel por subpath
   (`date-fns` → `date-fns/format`: 302 arquivos viram 36) e usar
   `await import("lib")` dentro do método para lib usada em poucas rotas
   (exceljs, pdf-lib). Constantes de módulo que dependem da lib viram
   inicialização no primeiro uso.
6. Dependências: remover as que não têm nenhum import em `src` e `test`
   (conferir cada uma com grep) e mover para dev as que só servem no build
   (`dotenv` do `prisma.config.ts`, `fastify-cli`). Rodar `npm install` para
   sincronizar o lock.
7. Onde o resolver de permissões é criado sem Redis: `memoryCacheTtlMs: 60_000`.
8. `firebase.yml`: `prebuild: "true"`, `vpcUpdate: "if-needed"`.
   `concurrency: "20"` com `dbConnLimit: "5"` SÓ se todos os controllers usam
   `requestScoped(Service, fastify)`. Com `new XService(fastify)` +
   `setRequest`, concorrência > 1 mistura dados entre escolas — não subir.
9. `.nvmrc` igual ao runtime.

Não fazer nesta rodada: trocar o SDK client `firebase` pelo admin (muda o
comportamento do upload) e reduzir memória (o bundle usa ~27 MB a mais de RSS).

## 4. O bundle e o conflito com o `@fastify/autoload`

Por quê: no Cloud Run cada `require()` custa ~3 ms. Eram ~1.280 arquivos e 79%
do boot era `require`. Tamanho de imagem não afeta cold start; número de
arquivos lidos afeta.

O conflito: o autoload varre a pasta de módulos em runtime e carrega cada
arquivo pelo caminho; dentro de um bundle isso não existe. Solução:

- no build, fazer a MESMA varredura do autoload e gerar um plugin com um
  `require()` fixo por arquivo, aplicando as regras dele para decidir o que é
  plugin e o prefixo (`autoPrefix`, `prefixOverride`, `autoConfig`,
  `autoload: false`, objeto de rota, pasta com `index`);
- no esbuild, `alias` de `@fastify/autoload` para esse plugin;
- `app.ts` não muda; dev e teste seguem no autoload de verdade.

Fora do bundle: `@fastify/swagger-ui` (serve arquivos da própria pasta),
`firebase-admin`, o WASM do Prisma (`@prisma/client/runtime/*.wasm-base64.js`,
só usado na primeira query) e tudo que só carrega sob demanda.

Trava obrigatória: subir a entrada original e o bundle em processos separados,
com banco falso (porta morta), comparar o JSON do swagger e quebrar o build se
diferir; conferir também que o bundle não leu arquivo solto de `dist/`.

Armadilhas:
- A ordem das rotas no swagger não é estável nem entre duas execuções do
  próprio autoload: comparar com as chaves ordenadas.
- `process.exit()` logo depois de `process.stdout.write()` trunca a saída em
  pipe: sair no callback do write.
- Dentro do Vitest o autoload detecta as envs `VITEST*` e usa `import()` em vez
  de `require()`; o que ele considera plugin muda. Testar em processo filho
  sem essas envs.
- O build passa a executar a API: precisa do que ela precisa para carregar
  (ex.: `firebase.json`).

## 5. Boot antecipado

`eagerBoot` chama o `ready()` no `nextTick` depois da carga do módulo, com a
rejeição já tratada (sem isso um boot que falha vira `unhandledRejection` e o
functions-framework mata a instância). Fora de request o boot em segundo plano
anda devagar — no piloto levou 4–5 minutos para terminar sozinho — mas a
instância que sobe antes do tráfego chega pronta ou quase.

## 6. O que NÃO funciona (não repetir)

- Compile cache do Node (`NODE_COMPILE_CACHE`) gerado no build: o Node separa o
  cache por flags do V8 e por usuário; o runtime define `--max-old-space-size`
  e roda com outro uid. Testado: 0 de 1.539 entradas reaproveitadas.
- `min-instances`: vetado por custo.

## Como medir

- Deploy: tempo de cada passo do run (`gh run view <id> --json jobs`) e fases
  do Cloud Build (`gcloud logging read 'resource.type="build" AND resource.labels.build_id="<id>"'`).
- Cold start: nos logs do Cloud Run, parear `Starting new instance` com
  `STARTUP TCP probe succeeded` por `instanceId`; primeira request de cada
  instância pelo log de requests.
- Onde o boot gasta tempo: instrumentação temporária que marca cada fase
  (carga do módulo, plugins, autoload, `ready`) com número de módulos em
  `require.cache` e tempo acumulado em `require()` (wrapper em `Module._load`
  somando só a chamada mais externa), logando uma linha JSON por instância.
  Remover depois de medir.
- Um cold start real exige a function ~15 minutos sem tráfego; conferir no log
  se a instância que atendeu nasceu por causa da request.
- Validar localmente antes de subir: build, testes, e um teste HTTP no pacote
  de deploy montado, só com as dependências de produção instaladas.
