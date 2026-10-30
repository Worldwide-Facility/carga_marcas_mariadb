"""Extracción de marcas desde la API FRAX (reemplaza MariaDB)."""

from __future__ import annotations

import time
from datetime import date, datetime
from typing import Any

import pandas as pd
import requests

import config

BQ_COLUMNS = [
    "fecha",
    "sensorid",
    "rutpersona",
    "entrada",
    "salida",
    "total",
    "rutproveedor",
    "nombreproveedor",
    "nombrecargo",
    "nombrepersona",
    "nombre_local",
    "formato",
]

_DT_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M",
    "%d-%m-%Y %H:%M:%S",
    "%d/%m/%Y %H:%M:%S",
    "%d-%m-%Y %H:%M",
    "%d/%m/%Y %H:%M",
)

_MAX_PAGES = 500
_RETRY_STATUSES = {429, 503}


class FraxApiError(RuntimeError):
    def __init__(self, message: str, *, status: int | None = None, retryable: bool = False):
        super().__init__(message)
        self.status = status
        self.retryable = retryable


def _index(row: dict) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in row.items():
        norm = str(key).strip().lower().replace(" ", "_")
        out[norm] = value
    return out


def _pick(row: dict[str, Any], *names: str) -> Any:
    for name in names:
        if name in row and row[name] not in (None, ""):
            return row[name]
    return None


def _text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _rut_persona(value: Any) -> str | None:
    """Deja el RUT como en MariaDB: dígitos + DV, sin puntos ni guión."""
    text = _text(value)
    if text is None:
        return None
    cleaned = (
        text.upper()
        .replace(".", "")
        .replace("-", "")
        .replace(" ", "")
    )
    return cleaned or None


def _rut_proveedor(value: Any) -> str | None:
    """Cuerpo del RUT de empresa, sin DV. En BigQuery hoy va sin dígito verificador."""
    text = _text(value)
    if text is None:
        return None
    body = text.split("-", 1)[0]
    cleaned = body.upper().replace(".", "").replace(" ", "")
    return cleaned or None


def parse_datetime(value: Any) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.replace(tzinfo=None)
    if isinstance(value, date) and not isinstance(value, datetime):
        return datetime(value.year, value.month, value.day)
    text = str(value).strip()
    if not text or text.lower() in {"null", "none", "nat"}:
        return None
    text = text.replace("Z", "").replace("z", "")
    if "." in text:
        text = text.split(".", 1)[0]
    text = text.strip()
    for fmt in _DT_FORMATS:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    raise ValueError(f"Fecha no reconocida: {value!r}")


def _sensorid(value: Any) -> int | None:
    text = _text(value)
    if text is None:
        return None
    try:
        return int(float(text))
    except ValueError:
        return None


def map_marca(raw: dict) -> dict[str, Any] | None:
    """Traduce una fila de la API al esquema de cr_reportes.marcas_mariadb.

    En la tabla actual, fecha es exactamente entrada y sensorid es el número de local.
    """
    row = _index(raw)
    try:
        entrada = parse_datetime(_pick(row, "entrada"))
    except ValueError:
        return None
    if entrada is None:
        return None
    sensorid = _sensorid(_pick(row, "local", "sensorid"))
    if sensorid is None:
        return None
    try:
        salida = parse_datetime(_pick(row, "salida"))
    except ValueError:
        salida = None
    total = _text(_pick(row, "total", "total_time"))
    return {
        "fecha": entrada,
        "sensorid": sensorid,
        "rutpersona": _rut_persona(_pick(row, "rutpersona", "rut_persona")),
        "entrada": entrada,
        "salida": salida,
        "total": total,
        "rutproveedor": _rut_proveedor(_pick(row, "rutproveedor", "rut_proveedor")),
        "nombreproveedor": _text(_pick(row, "nombreproveedor", "nombre_proveedor")),
        "nombrecargo": _text(_pick(row, "nombrecargo", "nombre_cargo")),
        "nombrepersona": _text(_pick(row, "nombrepersona", "nombre_persona")),
        "nombre_local": _text(_pick(row, "nombre_local")),
        "formato": _text(_pick(row, "formato")),
    }


def filas_a_dataframe(filas: list[dict]) -> pd.DataFrame:
    records: list[dict[str, Any]] = []
    omitidas = 0
    for raw in filas:
        mapped = map_marca(raw)
        if mapped is None:
            omitidas += 1
            continue
        records.append(mapped)
    if omitidas:
        print(f"Omitidas {omitidas} filas sin entrada, sin local o con fecha ilegible.")
    df = pd.DataFrame.from_records(records, columns=BQ_COLUMNS)
    if df.empty:
        return df
    for col in ("fecha", "entrada", "salida"):
        df[col] = pd.to_datetime(df[col], errors="coerce")
    df["sensorid"] = pd.to_numeric(df["sensorid"], errors="coerce").astype("Int64")
    return df


def _sleep_rate_limit(last_request_at: float | None) -> float:
    if last_request_at is None:
        return time.monotonic()
    wait = config.FRAX_PAGE_INTERVAL_SEC - (time.monotonic() - last_request_at)
    if wait > 0:
        time.sleep(wait)
    return time.monotonic()


def _get_page(
    session: requests.Session,
    base: str,
    params: dict[str, Any],
    *,
    endpoint: str = "marcas.php",
) -> dict:
    url = f"{base}/{endpoint}"
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            response = session.get(url, params=params, timeout=120)
        except requests.RequestException as exc:
            last_error = exc
            time.sleep(min(2 ** attempt, 30))
            continue
        if response.status_code in _RETRY_STATUSES:
            retry_after = response.headers.get("Retry-After")
            try:
                delay = float(retry_after) if retry_after else min(2 ** attempt, 60)
            except ValueError:
                delay = min(2 ** attempt, 60)
            print(f"FRAX respondió {response.status_code}; reintento en {delay:.0f}s")
            time.sleep(delay)
            last_error = FraxApiError(
                f"HTTP {response.status_code}",
                status=response.status_code,
                retryable=True,
            )
            continue
        if response.status_code in {401, 403}:
            server = (response.headers.get("server") or "").lower()
            if "cloudflare" in server or "acceso bloqueado" in response.text.lower():
                raise FraxApiError(
                    "Cloudflare bloqueó la salida del job (HTTP 403). "
                    "Hay que ejecutarlo en southamerica-west1.",
                    status=response.status_code,
                )
            raise FraxApiError(
                f"FRAX rechazó la API key (HTTP {response.status_code}).",
                status=response.status_code,
            )
        if response.status_code >= 400:
            raise FraxApiError(
                f"FRAX HTTP {response.status_code}: {response.text[:300]}",
                status=response.status_code,
                retryable=response.status_code >= 500,
            )
        try:
            body = response.json()
        except ValueError as exc:
            raise FraxApiError("FRAX no devolvió JSON.") from exc
        if not isinstance(body, dict):
            raise FraxApiError("FRAX devolvió un JSON que no es un objeto.")
        if body.get("ok") is False:
            codigo = body.get("error") or "error"
            mensaje = body.get("mensaje") or ""
            raise FraxApiError(f"FRAX {codigo}: {mensaje}".strip())
        return body
    raise FraxApiError(f"FRAX no respondió tras reintentos: {last_error}", retryable=True)


def _descargar(session: requests.Session, base: str, params: dict[str, Any], *, una_pagina: bool) -> list[dict]:
    filas: list[dict] = []
    cursor: str | None = None
    vistos: set[str] = set()
    last_request_at: float | None = None
    for page in range(1, _MAX_PAGES + 1):
        last_request_at = _sleep_rate_limit(last_request_at)
        query = dict(params)
        if cursor:
            query["cursor"] = cursor
        body = _get_page(session, base, query)
        chunk = body.get("data") or []
        if not isinstance(chunk, list):
            raise FraxApiError("FRAX devolvió data que no es una lista.")
        filas.extend(item for item in chunk if isinstance(item, dict))
        siguiente = body.get("siguiente_cursor") or body.get("siguiente cursor")
        print(f"Página {page}: {len(chunk)} filas (acumuladas {len(filas)})")
        if una_pagina or not siguiente:
            return filas
        cursor = str(siguiente)
        if cursor in vistos:
            raise FraxApiError("FRAX repitió el cursor de paginación.")
        vistos.add(cursor)
    raise FraxApiError(f"FRAX superó {_MAX_PAGES} páginas; se aborta para no ciclar.")


def _params(*, limit: int) -> dict[str, Any]:
    hasta = config.FRAX_HASTA or config.datetime_hoy()
    params: dict[str, Any] = {
        "desde": config.FRAX_DESDE.isoformat(),
        "hasta": hasta.isoformat(),
        "limit": limit,
    }
    if config.FRAX_RUT_PROVEEDOR:
        params["rut_proveedor"] = config.FRAX_RUT_PROVEEDOR
    return params


def _session() -> requests.Session:
    session = requests.Session()
    session.headers["X-API-Key"] = config.FRAX_API_KEY
    session.headers["Accept"] = "application/json"
    return session


def descargar_marcas(*, limit: int | None = None, una_pagina: bool = False) -> list[dict]:
    config.validate_frax_credentials()
    page_limit = limit if limit is not None else config.FRAX_PAGE_LIMIT
    params = _params(limit=page_limit)
    print(
        "Consultando FRAX "
        f"{params['desde']}..{params['hasta']} limit={page_limit}"
    )
    session = _session()
    try:
        return _descargar(session, config.FRAX_API_BASE, params, una_pagina=una_pagina)
    except (FraxApiError, requests.RequestException) as exc:
        retryable = isinstance(exc, FraxApiError) and exc.retryable
        connection_error = isinstance(exc, requests.RequestException)
        fallback = config.FRAX_API_BASE_FALLBACK
        if not (retryable or connection_error) or not fallback or fallback == config.FRAX_API_BASE:
            raise
        print(f"Base primaria no disponible ({exc}). Probando {fallback}")
        return _descargar(session, fallback, params, una_pagina=una_pagina)


def preview_table(limit: int = 5) -> dict:
    filas = descargar_marcas(limit=max(1, limit), una_pagina=True)
    df = filas_a_dataframe(filas[:limit])
    return {
        "filas_pagina": len(filas),
        "columns": list(df.columns),
        "sample": df.head(limit).to_dict(orient="records"),
    }


PERSONAS_COLUMNS = [
    "rut_proveedor",
    "rut_persona",
    "nombre_completo",
    "primer_nombre",
    "apellido_paterno",
    "apellido_materno",
    "cargo",
    "estado",
    "contrato_vigencia",
    "contrato_indefinido",
    "fecha_estado",
    "creado",
    "modificado",
]


def map_persona(raw: dict, *, rut_proveedor: str | None) -> dict[str, Any]:
    """Una fila de personas.php. La API entrega una fila por persona y cargo."""
    row = _index(raw)

    def momento(name: str) -> datetime | None:
        try:
            return parse_datetime(_pick(row, name))
        except ValueError:
            return None

    return {
        "rut_proveedor": _rut_proveedor(rut_proveedor),
        "rut_persona": _rut_persona(_pick(row, "rut_persona", "rutpersona")),
        "nombre_completo": _text(_pick(row, "nombre_completo")),
        "primer_nombre": _text(_pick(row, "primer_nombre")),
        "apellido_paterno": _text(_pick(row, "apellido_paterno")),
        "apellido_materno": _text(_pick(row, "apellido_materno")),
        "cargo": _text(_pick(row, "cargo")),
        "estado": _text(_pick(row, "estado")),
        "contrato_vigencia": _text(_pick(row, "contrato_vigencia")),
        "contrato_indefinido": _text(_pick(row, "contrato_indefinido")),
        "fecha_estado": momento("fecha_estado"),
        "creado": momento("creado"),
        "modificado": momento("modificado"),
    }


def personas_a_dataframe(filas: list[dict], *, rut_proveedor: str | None) -> pd.DataFrame:
    records = [map_persona(row, rut_proveedor=rut_proveedor) for row in filas]
    df = pd.DataFrame.from_records(records, columns=PERSONAS_COLUMNS)
    if df.empty:
        return df
    for col in ("fecha_estado", "creado", "modificado"):
        df[col] = pd.to_datetime(df[col], errors="coerce")
    return df


def _descargar_personas(session: requests.Session, base: str) -> tuple[list[dict], str | None]:
    limit = config.FRAX_PERSONAS_PAGE_LIMIT
    filas: list[dict] = []
    offset = 0
    rut_proveedor: str | None = None
    last_request_at: float | None = None
    for page in range(1, _MAX_PAGES + 1):
        last_request_at = _sleep_rate_limit(last_request_at)
        body = _get_page(
            session,
            base,
            {"limit": limit, "offset": offset},
            endpoint="personas.php",
        )
        chunk = body.get("data") or []
        if not isinstance(chunk, list):
            raise FraxApiError("FRAX devolvió data que no es una lista.")
        if rut_proveedor is None:
            rut_proveedor = _text(body.get("proveedor"))
        filas.extend(item for item in chunk if isinstance(item, dict))
        total = body.get("total")
        print(f"Personas página {page}: {len(chunk)} filas (acumuladas {len(filas)})")
        offset += len(chunk)
        if not chunk:
            return filas, rut_proveedor
        if total is not None and offset >= int(total):
            return filas, rut_proveedor
        if len(chunk) < limit:
            return filas, rut_proveedor
    raise FraxApiError(f"FRAX personas superó {_MAX_PAGES} páginas.")


def descargar_personas() -> tuple[list[dict], str | None]:
    config.validate_frax_credentials()
    print("Consultando FRAX personas.php")
    session = _session()
    try:
        return _descargar_personas(session, config.FRAX_API_BASE)
    except (FraxApiError, requests.RequestException) as exc:
        retryable = isinstance(exc, FraxApiError) and exc.retryable
        connection_error = isinstance(exc, requests.RequestException)
        fallback = config.FRAX_API_BASE_FALLBACK
        if not (retryable or connection_error) or not fallback or fallback == config.FRAX_API_BASE:
            raise
        print(f"Base primaria no disponible ({exc}). Probando {fallback}")
        return _descargar_personas(session, fallback)


def extract_personas() -> pd.DataFrame:
    filas, rut_proveedor = descargar_personas()
    df = personas_a_dataframe(filas, rut_proveedor=rut_proveedor)
    if df.empty:
        print("La API de personas no devolvió filas.")
        return df
    print(f"Extraídas {len(df)} personas, {len(df.columns)} columnas.")
    return df


def extract_marcas() -> pd.DataFrame:
    config.assert_truncate_seguro()
    filas = descargar_marcas()
    df = filas_a_dataframe(filas)
    if df.empty:
        print("La API no devolvió filas utilizables.")
        return df
    print(f"Extraídos {len(df)} registros, {len(df.columns)} columnas.")
    print("Muestra:")
    print(df.head(3).to_string())
    return df
