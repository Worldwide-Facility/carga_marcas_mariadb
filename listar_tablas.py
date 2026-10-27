"""Lista las tablas disponibles en MariaDB.

Si MARIADB_USER / MARIADB_PASSWORD no están en .env, se leen desde Secret Manager
usando las Application Default Credentials o, en su defecto, la sesión de gcloud.
"""

from __future__ import annotations

import base64
import subprocess

import google.auth
import google.auth.exceptions
import google.auth.transport.requests
import requests

import config
from extract import get_connection

_SECRET_USER = "carga-marcas-mariadb-user"
_SECRET_PASSWORD = "carga-marcas-mariadb-password"


def _access_token() -> str:
    try:
        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        creds.refresh(google.auth.transport.requests.Request())
        return creds.token
    except google.auth.exceptions.DefaultCredentialsError:
        out = subprocess.run(
            "gcloud auth print-access-token",
            shell=True, capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()


def _read_secret(token: str, name: str) -> str:
    url = (
        f"https://secretmanager.googleapis.com/v1/projects/{config.GCP_PROJECT_ID}"
        f"/secrets/{name}/versions/latest:access"
    )
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
    resp.raise_for_status()
    return base64.b64decode(resp.json()["payload"]["data"]).decode("utf-8").strip()


def _ensure_credentials() -> None:
    if config.MARIADB_USER and config.MARIADB_PASSWORD:
        return
    token = _access_token()
    config.MARIADB_USER = _read_secret(token, _SECRET_USER)
    config.MARIADB_PASSWORD = _read_secret(token, _SECRET_PASSWORD)


QUERY = """
SELECT table_schema, table_name, table_type, table_rows,
       ROUND((data_length + index_length) / 1024 / 1024, 2) AS mb
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
ORDER BY table_schema, table_name
"""


def main() -> None:
    _ensure_credentials()
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            rows = cur.fetchall()

    print(f"{'schema':<15}{'tabla':<45}{'tipo':<12}{'filas_aprox':>12}{'MB':>10}")
    for schema, table, table_type, n_rows, mb in rows:
        print(f"{schema:<15}{table:<45}{table_type:<12}{(n_rows or 0):>12}{float(mb or 0):>10.2f}")
    print(f"\nTotal: {len(rows)} tablas/vistas")


if __name__ == "__main__":
    main()
