"""
Valida asistencias PRESENTES (últimos 60 días) en cr_asistencia_hist_tb
que NO aparecen en marcas MariaDB.

Alcance: instalaciones del diccionario (ACUENTA / LIDER / LIDER EXPRESS / EKONO).

Cruce:
  - RUT: cuerpo sin DV (rutrol vs rutpersona)
  - Fecha: DATE(dia) = DATE(entrada MariaDB)
  - Hora: entrada MariaDB dentro de [her - TOL_ANTES, hsr + TOL_DESPUES]

Uso:
  python validar_asistencias_vs_marcas.py
  python validar_asistencias_vs_marcas.py --tol-antes 90 --tol-despues 90 --load-bq
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

from google.cloud import bigquery

import config

OUT_DIR = Path(__file__).resolve().parent / "validacion"


def build_query(tol_antes: int, tol_despues: int, dias: int) -> str:
    p = config.GCP_PROJECT_ID
    marcas = config.bq_full_table_id()
    return f"""
WITH dic AS (
  SELECT
    empresa,
    cliente_rol,
    instalacion_rol,
    sensorid,
    nombre_local_principal,
    codcecoscr
  FROM `{p}.cr_reportes.diccionario_marcas_instalaciones`
  WHERE estado = 'match'
),

asist AS (
  SELECT
    a.empresa,
    a.cliente_rol,
    a.instalacion_rol,
    a.nombrerol,
    a.rutrol,
    a.cargo,
    a.turno,
    a.dia,
    a.her,
    a.hsr,
    a.entrada,
    a.salida,
    a.fechamarcaentrada,
    a.fechamarcasalida,
    a.asistencia,
    a.asistencia_final,
    a.COB,
    d.sensorid,
    d.nombre_local_principal,
    d.codcecoscr,
    REGEXP_REPLACE(UPPER(TRIM(CAST(a.rutrol AS STRING))), r'[^0-9K]', '') AS rut_raw,
    DATE(a.dia) AS fecha_turno
  FROM `{p}.cr_reportes.cr_asistencia_hist_tb` a
  INNER JOIN dic d
    ON UPPER(TRIM(a.instalacion_rol)) = UPPER(TRIM(d.instalacion_rol))
   AND UPPER(TRIM(a.empresa)) = UPPER(TRIM(d.empresa))
  WHERE DATE(a.dia) >= DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL {int(dias)} DAY)
    AND a.asistencia = 1
),

asist_norm AS (
  -- rutrol en CR suele venir sin DV: usar solo digitos.
  SELECT
    * EXCEPT (rut_raw),
    REGEXP_REPLACE(rut_raw, r'[^0-9]', '') AS rut_body
  FROM asist
  WHERE LENGTH(REGEXP_REPLACE(rut_raw, r'[^0-9]', '')) >= 6
),

marcas AS (
  SELECT
    m.sensorid,
    m.nombre_local,
    m.formato,
    m.rutpersona,
    m.nombrepersona,
    m.fecha,
    m.entrada AS entrada_marca,
    m.salida AS salida_marca,
    DATE(m.entrada) AS fecha_marca,
    REGEXP_REPLACE(UPPER(TRIM(m.rutpersona)), r'[^0-9K]', '') AS rut_raw
  FROM `{marcas}` m
  WHERE DATE(m.entrada) >= DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL {int(dias)} DAY)
),

marcas_norm AS (
  -- rutpersona en MariaDB viene con DV: quitar ultimo caracter.
  SELECT
    * EXCEPT (rut_raw),
    CASE
      WHEN LENGTH(rut_raw) >= 2
        THEN REGEXP_REPLACE(SUBSTR(rut_raw, 1, LENGTH(rut_raw) - 1), r'[^0-9]', '')
      ELSE REGEXP_REPLACE(rut_raw, r'[^0-9]', '')
    END AS rut_body
  FROM marcas
),

cruce AS (
  SELECT
    a.*,
    m.entrada_marca,
    m.salida_marca,
    m.nombre_local AS nombre_local_marca,
    m.formato AS formato_marca,
    m.rutpersona AS rutpersona_marca,
    m.nombrepersona AS nombrepersona_marca,
    TIMESTAMP_DIFF(m.entrada_marca, a.her, MINUTE) AS diff_min_entrada_vs_her
  FROM asist_norm a
  LEFT JOIN marcas_norm m
    ON a.rut_body = m.rut_body
   AND a.fecha_turno = m.fecha_marca
   AND DATETIME(m.entrada_marca) BETWEEN
        DATETIME_SUB(a.her, INTERVAL {int(tol_antes)} MINUTE)
    AND DATETIME_ADD(COALESCE(a.hsr, a.her), INTERVAL {int(tol_despues)} MINUTE)
),

ranked AS (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY c.empresa, c.instalacion_rol, c.rut_body, c.her
      ORDER BY ABS(TIMESTAMP_DIFF(c.entrada_marca, c.her, MINUTE)) ASC NULLS LAST
    ) AS rn
  FROM cruce c
)

SELECT
  empresa,
  cliente_rol,
  instalacion_rol,
  sensorid,
  nombre_local_principal,
  codcecoscr,
  nombrerol,
  rutrol,
  rut_body,
  cargo,
  turno,
  fecha_turno,
  her,
  hsr,
  entrada,
  salida,
  fechamarcaentrada,
  COB,
  entrada_marca,
  salida_marca,
  nombre_local_marca,
  formato_marca,
  rutpersona_marca,
  nombrepersona_marca,
  diff_min_entrada_vs_her,
  CASE WHEN entrada_marca IS NULL THEN TRUE ELSE FALSE END AS sin_marca_mariadb
FROM ranked
WHERE rn = 1
ORDER BY sin_marca_mariadb DESC, fecha_turno DESC, instalacion_rol, her
"""


def summarize(client: bigquery.Client, sql: str) -> dict:
    wrap = f"""
    WITH base AS ({sql})
    SELECT
      COUNT(*) AS turnos_presentes,
      COUNTIF(sin_marca_mariadb) AS sin_marca_mariadb,
      COUNTIF(NOT sin_marca_mariadb) AS con_marca_mariadb,
      ROUND(100 * COUNTIF(sin_marca_mariadb) / COUNT(*), 1) AS pct_sin_marca,
      COUNT(DISTINCT IF(sin_marca_mariadb, instalacion_rol, NULL)) AS instalaciones_con_faltantes,
      COUNT(DISTINCT IF(sin_marca_mariadb, rut_body, NULL)) AS personas_sin_marca
    FROM base
    """
    return dict(list(client.query(wrap).result())[0])


def by_instalacion(client: bigquery.Client, sql: str) -> list[dict]:
    wrap = f"""
    WITH base AS ({sql})
    SELECT
      cliente_rol,
      instalacion_rol,
      sensorid,
      nombre_local_principal,
      COUNT(*) AS presentes,
      COUNTIF(sin_marca_mariadb) AS sin_marca,
      ROUND(100 * COUNTIF(sin_marca_mariadb) / COUNT(*), 1) AS pct_sin_marca
    FROM base
    GROUP BY 1,2,3,4
    ORDER BY sin_marca DESC, presentes DESC
    """
    return [dict(r) for r in client.query(wrap).result()]


def export_faltantes(client: bigquery.Client, sql: str, path: Path) -> int:
    wrap = f"""
    WITH base AS ({sql})
    SELECT *
    FROM base
    WHERE sin_marca_mariadb
    ORDER BY fecha_turno DESC, instalacion_rol, her
    """
    rows = [dict(r) for r in client.query(wrap).result()]
    path.parent.mkdir(exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8-sig")
        return 0
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return len(rows)


def load_bq(client: bigquery.Client, sql: str) -> str:
    table_id = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.validacion_asist_vs_marcas_60d"
    job = client.query(
        f"""
        CREATE OR REPLACE TABLE `{table_id}` AS
        WITH base AS ({sql})
        SELECT * FROM base
        """
    )
    job.result()
    return table_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dias", type=int, default=60)
    parser.add_argument("--tol-antes", type=int, default=90, help="Minutos antes de her")
    parser.add_argument("--tol-despues", type=int, default=90, help="Minutos despues de hsr")
    parser.add_argument("--load-bq", action="store_true")
    args = parser.parse_args()

    client = bigquery.Client(project=config.GCP_PROJECT_ID)
    sql = build_query(args.tol_antes, args.tol_despues, args.dias)

    print(
        f"Ventana: ultimos {args.dias} dias | "
        f"hora [her-{args.tol_antes}min , hsr+{args.tol_despues}min]"
    )
    summary = summarize(client, sql)
    print("Resumen:", summary)

    OUT_DIR.mkdir(exist_ok=True)
    resumen_inst = by_instalacion(client, sql)
    path_inst = OUT_DIR / "resumen_por_instalacion.csv"
    with path_inst.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(resumen_inst[0].keys()) if resumen_inst else [])
        if resumen_inst:
            w.writeheader()
            w.writerows(resumen_inst)
    print(f"Resumen instalaciones: {path_inst}")

    path_falt = OUT_DIR / "presentes_sin_marca_mariadb.csv"
    n = export_faltantes(client, sql, path_falt)
    print(f"Faltantes exportados: {n} -> {path_falt}")

    print("Top instalaciones con mas faltantes:")
    for r in resumen_inst[:15]:
        if r["sin_marca"] == 0:
            continue
        print(
            f"  {r['sin_marca']:4d}/{r['presentes']:4d} ({r['pct_sin_marca']}%) | "
            f"{r['cliente_rol']} | {r['instalacion_rol']} | local={r['nombre_local_principal']}"
        )

    if args.load_bq:
        table_id = load_bq(client, sql)
        print(f"BigQuery: {table_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
