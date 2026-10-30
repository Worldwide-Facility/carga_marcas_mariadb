"""Carga a BigQuery, particionada por DATE(fecha)."""

from __future__ import annotations

import pandas as pd
from google.cloud import bigquery
from google.api_core.exceptions import NotFound

import config


def _time_partitioning() -> bigquery.TimePartitioning:
    return bigquery.TimePartitioning(
        type_=bigquery.TimePartitioningType.DAY,
        field="fecha",
    )


def _is_fecha_day_partitioned(table: bigquery.Table) -> bool:
    part = table.time_partitioning
    if part is None:
        return False
    field = (part.field or "").lower()
    ptype = getattr(part.type_, "name", part.type_) or ""
    return field == "fecha" and str(ptype).upper() == "DAY"


def ensure_fecha_partitioned(client: bigquery.Client, table_id: str) -> bool:
    """Si la tabla existe sin PARTITION BY DATE(fecha), la borra para recrearla."""
    try:
        table = client.get_table(table_id)
    except NotFound:
        return False
    if _is_fecha_day_partitioned(table):
        return False
    print(f"Recreando {table_id} particionada por DATE(fecha)")
    client.delete_table(table_id)
    return True


_PERSONAS_SCHEMA = [
    bigquery.SchemaField("rut_proveedor", "STRING"),
    bigquery.SchemaField("rut_persona", "STRING"),
    bigquery.SchemaField("nombre_completo", "STRING"),
    bigquery.SchemaField("primer_nombre", "STRING"),
    bigquery.SchemaField("apellido_paterno", "STRING"),
    bigquery.SchemaField("apellido_materno", "STRING"),
    bigquery.SchemaField("cargo", "STRING"),
    bigquery.SchemaField("estado", "STRING"),
    bigquery.SchemaField("contrato_vigencia", "STRING"),
    bigquery.SchemaField("contrato_indefinido", "STRING"),
    bigquery.SchemaField("fecha_estado", "DATETIME"),
    bigquery.SchemaField("creado", "DATETIME"),
    bigquery.SchemaField("modificado", "DATETIME"),
]


def _personas_para_bq(df: pd.DataFrame) -> pd.DataFrame:
    """DATETIME en microsegundos. Autodetect guarda datetime64[ns] como INTEGER."""
    out = df.copy()
    for col in ("fecha_estado", "creado", "modificado"):
        out[col] = pd.to_datetime(out[col], errors="coerce").astype("datetime64[us]")
    for col in ("contrato_vigencia", "contrato_indefinido"):
        out[col] = out[col].where(out[col].notna(), None).astype("string")
    return out


def load_snapshot(df: pd.DataFrame, table_id: str, *, schema: list[bigquery.SchemaField] | None = None) -> dict:
    """Reemplaza la tabla completa. La nómina no se particiona: es el estado del día."""
    disposition = config.BQ_WRITE_DISPOSITION
    if df is None or df.empty:
        return {
            "success": True,
            "message": "No hay datos para cargar",
            "records_processed": 0,
            "table": table_id,
        }

    print(f"Cargando {len(df)} filas -> {table_id} ({disposition})")
    client = bigquery.Client(project=config.GCP_PROJECT_ID)
    job_config = bigquery.LoadJobConfig(
        write_disposition=disposition,
        schema=schema,
        autodetect=schema is None,
    )
    job = client.load_table_from_dataframe(df, table_id, job_config=job_config)
    job.result()
    return {
        "success": True,
        "message": "Carga completada",
        "records_processed": len(df),
        "table": table_id,
    }


def load_personas_to_bigquery(df: pd.DataFrame) -> dict:
    prepared = _personas_para_bq(df) if df is not None and not df.empty else df
    return load_snapshot(prepared, config.bq_personas_table_id(), schema=_PERSONAS_SCHEMA)


def load_to_bigquery(df: pd.DataFrame) -> dict:
    table_id = config.bq_full_table_id()
    disposition = config.BQ_WRITE_DISPOSITION

    if df is None or df.empty:
        return {
            "success": True,
            "message": "No hay datos para cargar",
            "records_processed": 0,
            "table": table_id,
        }

    print(f"Cargando {len(df)} filas -> {table_id} ({disposition}, PARTITION BY DATE(fecha))")
    client = bigquery.Client(project=config.GCP_PROJECT_ID)
    recreated = ensure_fecha_partitioned(client, table_id)
    job_config = bigquery.LoadJobConfig(
        write_disposition=disposition,
        autodetect=True,
        time_partitioning=_time_partitioning(),
    )
    job = client.load_table_from_dataframe(df, table_id, job_config=job_config)
    job.result()
    table = client.get_table(table_id)

    return {
        "success": True,
        "message": "Carga completada",
        "records_processed": len(df),
        "table": table_id,
        "partitioned_by": "DATE(fecha)",
        "table_recreated": recreated,
        "num_partitions": getattr(table, "num_partitions", None),
    }
