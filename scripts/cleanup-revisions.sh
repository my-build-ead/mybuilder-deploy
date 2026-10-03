#!/usr/bin/env bash
# Limpeza de REVISÕES do Cloud Run da function (gen2).
#
# O cleanup-artifacts.sh só apaga IMAGENS no Artifact Registry; as revisões do
# serviço Cloud Run nunca eram tocadas e acumulam a cada deploy. Com Direct VPC
# egress cada revisão existente pesa no provisionamento de rede — foi o suspeito
# do deploy preso em "Provisioning revision instances" por mais de 10 minutos
# (diagnosticado no gestio-school-deploy, 08/09/2026).
#
# Regras:
#   1. Mantém as KEEP revisões mais novas (padrão 3).
#   2. NUNCA apaga revisão que recebe tráfego, nem a latestReady/latestCreated
#      (o Cloud Run recusa e, mais importante, ninguém pode cair).
#   3. Tolerante: serviço inexistente ou falha numa revisão não derruba o job.
#   4. DRY_RUN=1 só lista o que seria apagado.
#
# Uso: cleanup-revisions.sh <PROJECT_ID> <FUNCTION_NAME> [REGION] [KEEP]
set -euo pipefail

PROJECT_ID="${1:?Uso: $0 <PROJECT_ID> <FUNCTION_NAME> [REGION] [KEEP]}"
FUNCTION_NAME="${2:?Uso: $0 <PROJECT_ID> <FUNCTION_NAME> [REGION] [KEEP]}"
REGION="${3:-us-central1}"
KEEP="${4:-3}"
DRY_RUN="${DRY_RUN:-0}"

# Function gen2 "v3_peoples" vira o serviço Cloud Run "v3-peoples".
SERVICE="${FUNCTION_NAME//_/-}"

echo "🧹 Revisões de '$SERVICE' ($PROJECT_ID/$REGION) — mantendo as $KEEP mais novas"

# O python3 decide as revisões protegidas. No macOS (runner self-hosted) o
# /usr/bin/python3 só funciona com as Command Line Tools instaladas; sem ele,
# pula a limpeza com aviso em vez de marcar como falho um deploy que já deu certo.
if ! python3 -c 'import json' >/dev/null 2>&1; then
  echo "::warning::python3 indisponível no runner ($(uname -s)) — limpeza de revisões pulada."
  exit 0
fi

SERVICE_JSON=$(gcloud run services describe "$SERVICE" --region="$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null || true)
if [ -z "$SERVICE_JSON" ]; then
  echo "  🚫 Serviço inexistente — nada a fazer."
  exit 0
fi

# Revisões intocáveis: com tráfego, latestReady e latestCreated.
PROTECTED=$(echo "$SERVICE_JSON" | python3 -c '
import sys, json
s = json.load(sys.stdin)
st = s.get("status", {})
keep = {t.get("revisionName") for t in st.get("traffic", []) if t.get("revisionName")}
keep.add(st.get("latestReadyRevisionName"))
keep.add(st.get("latestCreatedRevisionName"))
print("\n".join(sorted(k for k in keep if k)))
')

# Mais nova primeiro.
ALL=$(gcloud run revisions list --service="$SERVICE" --region="$REGION" --project="$PROJECT_ID" \
  --limit=1000 --sort-by="~metadata.creationTimestamp" --format="value(name)" 2>/dev/null || true)
TOTAL=$(echo "$ALL" | grep -c . || true)
echo "  📊 $TOTAL revisão(ões) existentes · protegidas: $(echo "$PROTECTED" | tr '\n' ' ')"

DELETED=0
echo "$ALL" | tail -n +$((KEEP + 1)) | while read -r REV; do
  [ -z "$REV" ] && continue
  if echo "$PROTECTED" | grep -qx "$REV"; then
    echo "  🔒 Protegida (tráfego/latest): $REV"
    continue
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "  👀 [dry-run] apagaria: $REV"
    continue
  fi
  echo "  🗑️  Apagando revisão antiga: $REV"
  gcloud run revisions delete "$REV" --region="$REGION" --project="$PROJECT_ID" --quiet \
    || echo "  ⚠️  Falha ao apagar $REV (segue o baile)"
done

echo "🎉 Limpeza de revisões concluída para '$SERVICE'."
