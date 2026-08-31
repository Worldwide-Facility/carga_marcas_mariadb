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
