"""
Diccionario cr_info_instalaciones  <->  marcas MariaDB (nombre_local / sensorid)

Clientes: ACUENTA, LIDER, LIDER EXPRESS, EKONO.

Orientación: 1 fila por instalación de CR.
Cruce principal: número LOCAL en instalacion_rol == sensorid en marcas.
Overrides manuales para instalaciones sin 'LOCAL N' parseable.

Uso:
  python build_diccionario.py
  python build_diccionario.py --load-bq
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

from google.cloud import bigquery

import config

CLIENTES = ("ACUENTA", "LIDER", "LIDER EXPRESS", "EKONO")
LOCAL_RE = re.compile(r"LOCAL\s*(\d+)", re.I)
OUT_DIR = Path(__file__).resolve().parent / "diccionario"

# instalacion_rol exacta (UPPER) → sensorid forzado
SENSOR_OVERRIDE = {
    "ACUENTA REÑACA": 500,
}


def _norm_key(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().upper())


def fetch_instalaciones(client: bigquery.Client) -> list[dict]:
    job = client.query(
        f"""
        SELECT
          empresa,
          cliente_rol,
          instalacion_rol,
          comuna,
          region,
          codcecoscr,
          codclicr,
          codinscr
        FROM `{config.GCP_PROJECT_ID}.cr_reportes.cr_info_instalaciones`
        WHERE UPPER(TRIM(cliente_rol)) IN UNNEST(@clientes)
        ORDER BY cliente_rol, instalacion_rol
        """,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ArrayQueryParameter("clientes", "STRING", list(CLIENTES))
            ]
        ),
    )
    return [dict(r) for r in job.result()]


def fetch_marcas_by_sensor(client: bigquery.Client) -> dict[int, dict]:
    rows = client.query(
        f"""
        SELECT
          CAST(sensorid AS INT64) AS sensorid,
          ARRAY_AGG(
            STRUCT(
              TRIM(IFNULL(nombre_local, '')) AS nombre_local,
              TRIM(IFNULL(formato, '')) AS formato,
              cnt AS n
            )
            ORDER BY cnt DESC
          ) AS variants,
          SUM(cnt) AS n_marcas
        FROM (
          SELECT
            sensorid,
            nombre_local,
            formato,
            COUNT(*) AS cnt
          FROM `{config.bq_full_table_id()}`
          GROUP BY 1, 2, 3
        )
        GROUP BY 1
        """
    ).result()

    out: dict[int, dict] = {}
    for r in rows:
        variants = list(r["variants"] or [])
        nombres = []
        formatos = []
        for v in variants:
            if v["nombre_local"] and v["nombre_local"] not in nombres:
                nombres.append(v["nombre_local"])
            if v["formato"] and v["formato"] not in formatos:
                formatos.append(v["formato"])
        out[int(r["sensorid"])] = {
            "n_marcas": int(r["n_marcas"]),
            "nombre_local_principal": nombres[0] if nombres else "",
            "nombres_local": nombres,
            "formatos": formatos,
            "variants": variants,
        }
    return out


def resolve_sensorid(instalacion_rol: str) -> int | None:
    key = _norm_key(instalacion_rol)
    if key in SENSOR_OVERRIDE:
        return SENSOR_OVERRIDE[key]
    m = LOCAL_RE.search(instalacion_rol or "")
    return int(m.group(1)) if m else None


def build_dictionary(
    instalaciones: list[dict], marcas_by_sensor: dict[int, dict]
) -> list[dict]:
    rows: list[dict] = []
    for inst in instalaciones:
        sensorid = resolve_sensorid(inst["instalacion_rol"])
        marcas = marcas_by_sensor.get(sensorid) if sensorid is not None else None
        estado = "match" if marcas else "sin_match"
        rows.append(
            {
                "empresa": inst.get("empresa") or "",
                "cliente_rol": inst.get("cliente_rol") or "",
                "instalacion_rol": inst.get("instalacion_rol") or "",
                "codcecoscr": inst.get("codcecoscr") or "",
                "codclicr": inst.get("codclicr") or "",
                "codinscr": inst.get("codinscr") or "",
                "comuna": inst.get("comuna") or "",
                "region": inst.get("region") or "",
                "sensorid": sensorid if sensorid is not None else "",
                "nombre_local_principal": (marcas or {}).get("nombre_local_principal", ""),
                "nombres_local": " | ".join((marcas or {}).get("nombres_local", [])),
                "formatos": " | ".join((marcas or {}).get("formatos", [])),
                "n_marcas": (marcas or {}).get("n_marcas", 0),
                "estado": estado,
            }
        )
    return rows


def write_outputs(rows: list[dict]) -> dict[str, Path]:
    OUT_DIR.mkdir(exist_ok=True)
    csv_path = OUT_DIR / "diccionario_instalacion_rol_marcas.csv"
    json_path = OUT_DIR / "diccionario_instalacion_rol_marcas.json"
    sin_path = OUT_DIR / "instalaciones_sin_match.csv"

    fields = list(rows[0].keys()) if rows else []
    with csv_path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    json_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")

    sin = [r for r in rows if r["estado"] != "match"]
    with sin_path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(sin)

    return {"csv": csv_path, "json": json_path, "sin_match": sin_path}


def load_bq(client: bigquery.Client, rows: list[dict]) -> str:
    # BigQuery JSON load: sensorid vacío -> null
    payload = []
    for r in rows:
        item = dict(r)
        if item.get("sensorid") == "":
            item["sensorid"] = None
        payload.append(item)

    table_id = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.diccionario_marcas_instalaciones"
    job = client.load_table_from_json(
        payload,
        table_id,
        job_config=bigquery.LoadJobConfig(
            write_disposition="WRITE_TRUNCATE",
            autodetect=True,
        ),
    )
    job.result()
    return table_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--load-bq", action="store_true")
    args = parser.parse_args()

    client = bigquery.Client(project=config.GCP_PROJECT_ID)
    instalaciones = fetch_instalaciones(client)
    marcas_by_sensor = fetch_marcas_by_sensor(client)
    rows = build_dictionary(instalaciones, marcas_by_sensor)
    paths = write_outputs(rows)

    n = len(rows)
    matched = sum(1 for r in rows if r["estado"] == "match")
    print(f"Instalaciones CR ({', '.join(CLIENTES)}): {n}")
    print(f"Con match en marcas: {matched}/{n}")
    print(f"Diccionario: {paths['csv']}")
    print(f"JSON: {paths['json']}")
    print(f"Sin match: {paths['sin_match']}")
    for r in rows:
        if r["estado"] != "match":
            print(
                f"  SIN_MATCH | {r['cliente_rol']} | {r['instalacion_rol']} | sensorid={r['sensorid'] or '-'}"
            )

    if args.load_bq:
        table_id = load_bq(client, rows)
        print(f"BigQuery: {table_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
