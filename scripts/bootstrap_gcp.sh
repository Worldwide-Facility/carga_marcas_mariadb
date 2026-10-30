#!/usr/bin/env bash
# Crea secretos, IAM y trigger de Cloud Build. No imprime contraseñas.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-worldwide-470917}"
REGION="${REGION:-us-east1}"
SA="cargar-cr@${PROJECT_ID}.iam.gserviceaccount.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Falta .env con FRAX_API_KEY" >&2
  exit 1
fi

python - <<'PY'
from pathlib import Path
from dotenv import dotenv_values
v = dotenv_values(".env")
key = (v.get("FRAX_API_KEY") or "").strip()
if not key.startswith("frx_"):
    raise SystemExit("FRAX_API_KEY vacío o inválido en .env (debe empezar con frx_)")
Path(".secret_frax_key").write_text(key, encoding="utf-8")
PY

ensure_secret() {
  local name="$1"
  local file="$2"
  if gcloud secrets describe "$name" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets versions add "$name" --data-file="$file" --project "$PROJECT_ID" >/dev/null
    echo "Secret $name: nueva versión"
  else
    gcloud secrets create "$name" --data-file="$file" --project "$PROJECT_ID" >/dev/null
    echo "Secret $name: creado"
  fi
  gcloud secrets add-iam-policy-binding "$name" \
    --member="serviceAccount:${SA}" \
    --role="roles/secretmanager.secretAccessor" \
    --project "$PROJECT_ID" \
    --quiet >/dev/null
}

ensure_secret "carga-marcas-frax-api-key" ".secret_frax_key"
rm -f .secret_frax_key

if gcloud builds triggers describe carga-marcas-mariadb --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Trigger Cloud Build ya existe"
else
  gcloud builds triggers create github \
    --name=carga-marcas-mariadb \
    --repo-owner=wwdiegovarela \
    --repo-name=carga_marcas_mariadb \
    --branch-pattern="^main$" \
    --build-config=cloudbuild.yaml \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --description="API FRAX marcas -> BigQuery cada push a main"
fi

echo "Listo. Siguiente: gcloud builds submit --config cloudbuild.yaml"
