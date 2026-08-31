"""Configuración desde variables de entorno / archivo .env."""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

_ENV_PATH = Path(__file__).resolve().parent / ".env"
load_dotenv(_ENV_PATH)


def _required(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise ValueError(
            f"Falta {name}. Complétalo en {_ENV_PATH} (copia desde .env.example)."
        )
    return value


# MariaDB
MARIADB_HOST = os.getenv("MARIADB_HOST", "201.236.154.66").strip()
MARIADB_PORT = int(os.getenv("MARIADB_PORT", "65500"))
MARIADB_DATABASE = os.getenv("MARIADB_DATABASE", "worldwide").strip()
MARIADB_USER = os.getenv("MARIADB_USER", "").strip()
MARIADB_PASSWORD = os.getenv("MARIADB_PASSWORD", "")
MARIADB_TABLE = os.getenv("MARIADB_TABLE", "marcas").strip()
MARIADB_QUERY = (os.getenv("MARIADB_QUERY") or "").strip()

# BigQuery
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID", "worldwide-470917").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "cr_reportes").strip()
BQ_TABLE = os.getenv("BQ_TABLE", "marcas_mariadb").strip()
BQ_WRITE_DISPOSITION = os.getenv("BQ_WRITE_DISPOSITION", "WRITE_TRUNCATE").strip()


def validate_mariadb_credentials() -> None:
    _required("MARIADB_USER")
    _required("MARIADB_PASSWORD")


def build_extract_query() -> str:
    if MARIADB_QUERY:
        return MARIADB_QUERY
    # Identificador simple; evita inyección si alguien cambia MARIADB_TABLE en .env
    table = MARIADB_TABLE.replace("`", "")
    if not table or any(c in table for c in (" ", ";", "-", "/", "\\")):
        raise ValueError(f"MARIADB_TABLE inválido: {MARIADB_TABLE!r}")
    return f"SELECT * FROM `{table}`"


def bq_full_table_id() -> str:
    return f"{GCP_PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"
