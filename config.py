"""Configuración desde variables de entorno / archivo .env."""

from __future__ import annotations

import os
from datetime import date
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv

_ENV_PATH = Path(__file__).resolve().parent / ".env"
load_dotenv(_ENV_PATH)

_SANTIAGO = ZoneInfo("America/Santiago")
# La API de FRAX publica histórico desde agosto 2024.
HISTORICO_DESDE = date(2024, 8, 1)


def _required(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise ValueError(
            f"Falta {name}. Complétalo en {_ENV_PATH} (copia desde .env.example)."
        )
    return value


def _optional_date(name: str) -> date | None:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return None
    try:
        return date.fromisoformat(raw)
    except ValueError as exc:
        raise ValueError(f"{name} inválida: usa YYYY-MM-DD") from exc


# MariaDB (solo listar_tablas.py; el job ya no lo usa)
MARIADB_HOST = os.getenv("MARIADB_HOST", "201.236.154.66").strip()
MARIADB_PORT = int(os.getenv("MARIADB_PORT", "65500"))
MARIADB_DATABASE = os.getenv("MARIADB_DATABASE", "worldwide").strip()
MARIADB_USER = os.getenv("MARIADB_USER", "").strip()
MARIADB_PASSWORD = os.getenv("MARIADB_PASSWORD", "")
MARIADB_TABLE = os.getenv("MARIADB_TABLE", "marcas").strip()
MARIADB_QUERY = (os.getenv("MARIADB_QUERY") or "").strip()

# API FRAX (origen de marcas)
FRAX_API_BASE = os.getenv(
    "FRAX_API_BASE", "https://frax.controltienda.com/api/v1"
).strip().rstrip("/")
FRAX_API_BASE_FALLBACK = os.getenv(
    "FRAX_API_BASE_FALLBACK", "https://frax2.controltienda.com/api/v1"
).strip().rstrip("/")
FRAX_API_KEY = os.getenv("FRAX_API_KEY", "").strip()
FRAX_DESDE = _optional_date("FRAX_DESDE") or HISTORICO_DESDE
FRAX_HASTA = _optional_date("FRAX_HASTA")
FRAX_PAGE_LIMIT = int(os.getenv("FRAX_PAGE_LIMIT", "10000"))
FRAX_PERSONAS_PAGE_LIMIT = int(os.getenv("FRAX_PERSONAS_PAGE_LIMIT", "5000"))
FRAX_PAGE_INTERVAL_SEC = float(os.getenv("FRAX_PAGE_INTERVAL_SEC", "2.1"))
FRAX_RUT_PROVEEDOR = os.getenv("FRAX_RUT_PROVEEDOR", "").strip()
FRAX_ALLOW_PARTIAL_TRUNCATE = os.getenv(
    "FRAX_ALLOW_PARTIAL_TRUNCATE", ""
).strip() in {"1", "true", "TRUE", "yes", "YES"}

# BigQuery
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID", "worldwide-470917").strip()
BQ_DATASET = os.getenv("BQ_DATASET", "cr_reportes").strip()
BQ_TABLE = os.getenv("BQ_TABLE", "marcas_mariadb").strip()
BQ_TABLE_PERSONAS = os.getenv("BQ_TABLE_PERSONAS", "personas_frax").strip()
BQ_WRITE_DISPOSITION = os.getenv("BQ_WRITE_DISPOSITION", "WRITE_TRUNCATE").strip()


def validate_frax_credentials() -> None:
    key = _required("FRAX_API_KEY")
    if not key.startswith("frx_"):
        raise ValueError("FRAX_API_KEY debe empezar con frx_.")
    if not (1 <= FRAX_PAGE_LIMIT <= 10000):
        raise ValueError("FRAX_PAGE_LIMIT debe estar entre 1 y 10000.")
    if not (1 <= FRAX_PERSONAS_PAGE_LIMIT <= 5000):
        raise ValueError("FRAX_PERSONAS_PAGE_LIMIT debe estar entre 1 y 5000.")
    hasta = FRAX_HASTA or date.today()
    if FRAX_DESDE > hasta:
        raise ValueError(f"FRAX_DESDE ({FRAX_DESDE}) es posterior a hasta ({hasta}).")


def ventana_es_historico_completo(hoy: date | None = None) -> bool:
    """True si el rango cubre desde el inicio publicado por FRAX hasta hoy."""
    hoy = hoy or datetime_hoy()
    hasta = FRAX_HASTA or hoy
    return FRAX_DESDE <= HISTORICO_DESDE and hasta >= hoy


def datetime_hoy() -> date:
    from datetime import datetime

    return datetime.now(_SANTIAGO).date()


def assert_truncate_seguro() -> None:
    """WRITE_TRUNCATE con una ventana corta borraría el histórico de BigQuery."""
    if BQ_WRITE_DISPOSITION != "WRITE_TRUNCATE":
        return
    if FRAX_ALLOW_PARTIAL_TRUNCATE or ventana_es_historico_completo():
        return
    hasta = FRAX_HASTA.isoformat() if FRAX_HASTA else "hoy"
    raise ValueError(
        "BQ_WRITE_DISPOSITION=WRITE_TRUNCATE y la ventana "
        f"{FRAX_DESDE.isoformat()}..{hasta} no es el histórico completo. "
        "Eso reemplazaría marcas_mariadb y perdería el resto de los días. "
        "Deja FRAX_HASTA vacío y FRAX_DESDE en 2024-08-01, "
        "o define FRAX_ALLOW_PARTIAL_TRUNCATE=1 si de verdad quieres recortar."
    )


def bq_full_table_id() -> str:
    return f"{GCP_PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"


def bq_personas_table_id() -> str:
    return f"{GCP_PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE_PERSONAS}"
