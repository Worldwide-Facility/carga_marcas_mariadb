"""Extracción desde MariaDB."""

from __future__ import annotations

import pymysql
import pandas as pd

import config


def get_connection(*, dict_cursor: bool = False) -> pymysql.connections.Connection:
    kwargs = {
        "host": config.MARIADB_HOST,
        "port": config.MARIADB_PORT,
        "user": config.MARIADB_USER,
        "password": config.MARIADB_PASSWORD,
        "database": config.MARIADB_DATABASE,
        "charset": "utf8mb4",
        "connect_timeout": 30,
        "read_timeout": 600,
        "write_timeout": 600,
    }
    if dict_cursor:
        kwargs["cursorclass"] = pymysql.cursors.DictCursor
    return pymysql.connect(**kwargs)


def _normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return df
    out = df.copy()
    out.columns = (
        out.columns.astype(str)
        .str.strip()
        .str.lower()
        .str.replace(" ", "_", regex=False)
        .str.replace(".", "", regex=False)
        .str.replace("%", "", regex=False)
        .str.replace("-", "_", regex=False)
        .str.replace("(", "", regex=False)
        .str.replace(")", "", regex=False)
        .str.replace("á", "a", regex=False)
        .str.replace("é", "e", regex=False)
        .str.replace("í", "i", regex=False)
        .str.replace("ó", "o", regex=False)
        .str.replace("ú", "u", regex=False)
        .str.replace("ñ", "n", regex=False)
        .str.replace("°", "", regex=False)
    )
    return out


def preview_table(limit: int = 5) -> dict:
    """Prueba conexión y devuelve columnas + muestra."""
    config.validate_mariadb_credentials()
    query = config.build_extract_query()
    # Cursor por defecto: DictCursor + pandas.read_sql corrompe las filas.
    with get_connection(dict_cursor=False) as conn:
        with conn.cursor() as cur:
            cur.execute(f"SELECT COUNT(*) FROM ({query}) AS _src")
            total = cur.fetchone()[0]
        df = pd.read_sql(f"SELECT * FROM ({query}) AS _src LIMIT {int(limit)}", conn)
    df = _normalize_columns(df)
    return {
        "total_rows": total,
        "columns": list(df.columns),
        "sample": df.to_dict(orient="records"),
    }


def extract_marcas() -> pd.DataFrame:
    config.validate_mariadb_credentials()
    query = config.build_extract_query()
    print(f"Consultando MariaDB: {config.MARIADB_HOST}:{config.MARIADB_PORT}/{config.MARIADB_DATABASE}")
    print(f"Query: {query}")

    # Importante: no usar DictCursor con pandas.read_sql (rellena celdas con nombres de columna).
    with get_connection(dict_cursor=False) as conn:
        df = pd.read_sql(query, conn)

    if df.empty:
        print("La consulta no devolvio filas.")
        return df

    df = _normalize_columns(df)
    print(f"Extraidos {len(df)} registros, {len(df.columns)} columnas.")
    print("Muestra:")
    print(df.head(3).to_string())
    return df
