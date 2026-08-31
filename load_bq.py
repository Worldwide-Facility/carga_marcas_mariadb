"""Carga a BigQuery."""

from __future__ import annotations

import pandas as pd
from google.cloud import bigquery

import config


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

    print(f"Cargando {len(df)} filas -> {table_id} ({disposition})")
    client = bigquery.Client(project=config.GCP_PROJECT_ID)
    job_config = bigquery.LoadJobConfig(
        write_disposition=disposition,
        autodetect=True,
    )
    job = client.load_table_from_dataframe(df, table_id, job_config=job_config)
    job.result()

    return {
        "success": True,
        "message": "Carga completada",
        "records_processed": len(df),
        "table": table_id,
    }
