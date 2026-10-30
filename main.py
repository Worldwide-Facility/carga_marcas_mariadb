"""
Carga API FRAX → BigQuery.

  python main.py sync            # marcas → cr_reportes.marcas_mariadb
  python main.py sync-personas  # nómina → cr_reportes.personas_frax
"""

from __future__ import annotations

import argparse
import json
import sys

import config
from extract import FraxApiError, extract_marcas, extract_personas, preview_table
from load_bq import load_personas_to_bigquery, load_to_bigquery


def cmd_preview(limit: int) -> int:
    result = preview_table(limit=limit)
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    return 0


def cmd_sync() -> int:
    df = extract_marcas()
    result = load_to_bigquery(df)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("success") else 1


def cmd_sync_personas() -> int:
    df = extract_personas()
    result = load_personas_to_bigquery(df)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("success") else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="API FRAX marcas → BigQuery")
    sub = parser.add_subparsers(dest="command", required=True)

    p_preview = sub.add_parser("preview", help="Probar la API y ver una muestra")
    p_preview.add_argument("--limit", type=int, default=5)

    sub.add_parser("sync", help="Descargar marcas de FRAX y cargar en BigQuery")
    sub.add_parser("sync-personas", help="Descargar la nómina y cargar en BigQuery")

    args = parser.parse_args(argv)

    try:
        if args.command == "preview":
            return cmd_preview(args.limit)
        if args.command == "sync":
            return cmd_sync()
        if args.command == "sync-personas":
            return cmd_sync_personas()
        parser.error(f"Comando desconocido: {args.command}")
        return 2
    except ValueError as e:
        print(f"Configuracion: {e}", file=sys.stderr)
        return 2
    except FraxApiError as e:
        print(f"FRAX: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
