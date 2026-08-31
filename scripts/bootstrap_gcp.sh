#!/usr/bin/env bash
# Crea secretos, IAM y trigger de Cloud Build. No imprime contraseñas.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-worldwide-470917}"
REGION="${REGION:-us-east1}"
SA="cargar-cr@${PROJECT_ID}.iam.gserviceaccount.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Falta .env con MARIADB_USER y MARIADB_PASSWORD" >&2
  exit 1
fi

python - <<'PY'
from pathlib import Path
from dotenv import dotenv_values
v = dotenv_values(".env")
user = (v.get("MARIADB_USER") or "").strip()
password = v.get("MARIADB_PASSWORD") or ""
if not user or not password:
    raise SystemExit("MARIADB_USER / MARIADB_PASSWORD vacíos en .env")
Path(".secret_user").write_text(user, encoding="utf-8")
Path(".secret_pass").write_text(password, encoding="utf-8")
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

ensure_secret "carga-marcas-mariadb-user" ".secret_user"
ensure_secret "carga-marcas-mariadb-password" ".secret_pass"
rm -f .secret_user .secret_pass

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
    --description="MariaDB marcas -> BigQuery cada push a main"
fi

echo "Listo. Siguiente: gcloud builds submit --config cloudbuild.yaml"
