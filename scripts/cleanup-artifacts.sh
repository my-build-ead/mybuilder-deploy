#!/usr/bin/env bash
# Limpeza SEGURA de artefatos da function no Artifact Registry.
# Substitui o google.sh que vivia em cada repo de API.
#
# Diferenças de propósito em relação ao antigo:
#   1. NUNCA apaga a versão mais recente de cada pacote — a imagem da revision
#      atual continua existindo (rollback e `gcloud run services update`
#      voltam a funcionar; deploy concorrente não perde a imagem em uso).
#   2. Só toca no repositório gcf-artifacts (onde o build das functions grava)
#      e nos pacotes EXATOS da function ("{proj}__{region}__{fn}" e o "/cache")
#      — nada de varrer todos os repositórios com filtro por substring.
#   3. Idempotente e tolerante: pacote inexistente não é erro.
#
# Uso: cleanup-artifacts.sh <PROJECT_ID> <FUNCTION_NAME> [REGION]
set -euo pipefail

PROJECT_ID="${1:?Uso: $0 <PROJECT_ID> <FUNCTION_NAME> [REGION]}"
FUNCTION_NAME="${2:?Uso: $0 <PROJECT_ID> <FUNCTION_NAME> [REGION]}"
REGION="${3:-us-central1}"
REPO="gcf-artifacts"
KEEP=1  # versões mais recentes preservadas por pacote

# gcf-artifacts codifica "_" como "__" e "-" do projeto como "--"
FN_ENC="${FUNCTION_NAME//_/__}"
PROJ_ENC="${PROJECT_ID//-/--}"
BASE_PKG="${PROJ_ENC}__${REGION//-/--}__${FN_ENC}"

for PKG in "$BASE_PKG" "$BASE_PKG/cache"; do
  echo "📦 Pacote: $PKG"
  VERSIONS=$(gcloud artifacts versions list \
    --package="$PKG" --project="$PROJECT_ID" --location="$REGION" \
    --repository="$REPO" --sort-by="~createTime" --format="value(name)" 2>/dev/null || true)

  if [ -z "$VERSIONS" ]; then
    echo "  🚫 Pacote inexistente ou vazio — nada a fazer."
    continue
  fi

  echo "$VERSIONS" | tail -n +$((KEEP + 1)) | while read -r VERSION; do
    [ -z "$VERSION" ] && continue
    echo "  🗑️  Excluindo versão antiga: $VERSION"
    gcloud artifacts versions delete "$VERSION" \
      --package="$PKG" --project="$PROJECT_ID" --location="$REGION" \
      --repository="$REPO" --quiet || echo "  ⚠️  Falha ao excluir $VERSION (segue o baile)"
  done
  echo "  ✅ Mantida(s) a(s) $KEEP versão(ões) mais recente(s)."
done

echo "🎉 Limpeza concluída para '$FUNCTION_NAME' em $REGION (a imagem atual foi preservada)."
