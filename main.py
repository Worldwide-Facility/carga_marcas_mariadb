"""
Carga MariaDB (worldwide.marcas) → BigQuery.

Uso:
  1. Completa usuario/contraseña en .env
  2. pip install -r requirements.txt
  3. python main.py preview     # prueba conexión / muestra columnas
  4. python main.py sync        # extrae y carga a BigQuery
"""

from __future__ import annotations

import argparse
import json
import sys

import config
from extract import extract_marcas, preview_table
from load_bq import load_to_bigquery


def cmd_preview(limit: int) -> int:
    result = preview_table(limit=limit)
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    return 0


def cmd_sync() -> int:
    df = extract_marcas()
    result = load_to_bigquery(df)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("success") else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="MariaDB marcas → BigQuery")
    sub = parser.add_subparsers(dest="command", required=True)

    p_preview = sub.add_parser("preview", help="Probar conexión y ver muestra")
    p_preview.add_argument("--limit", type=int, default=5)

    sub.add_parser("sync", help="Extraer de MariaDB y cargar en BigQuery")

    args = parser.parse_args(argv)

    try:
        if args.command == "preview":
            return cmd_preview(args.limit)
        if args.command == "sync":
            return cmd_sync()
        parser.error(f"Comando desconocido: {args.command}")
        return 2
    except ValueError as e:
        print(f"Configuracion: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
