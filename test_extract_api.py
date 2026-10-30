"""Mapeo API FRAX → columnas de marcas_mariadb. Sin red."""

from __future__ import annotations

import unittest
from datetime import date, datetime

import config
from extract import filas_a_dataframe, map_marca, map_persona, parse_datetime, personas_a_dataframe


class MapMarcaTest(unittest.TestCase):
    def test_fila_api_queda_como_la_tabla_actual(self) -> None:
        raw = {
            "ID": 6543210,
            "Local": "248",
            "Nombre_Local": "QUILICURA",
            "Formato": "EXPRESS",
            "RutPersona": "19.280.614-3",
            "NombrePersona": "JUAN PEREZ",
            "UserId": 99,
            "NombreCargo": "SEGURIDAD - PERMANENTE",
            "Entrada": "2026-10-29 22:00:40",
            "Salida": "2026-10-30T09:46:28",
            "Total": "11:45:48",
            "TOTAL_TIME": "11:45:48",
            "TIEMPO_NUM": 11.76,
            "RutProveedor": "76.195.703-K",
            "NombreProveedor": "WORLDWIDE",
        }
        mapped = map_marca(raw)
        self.assertIsNotNone(mapped)
        assert mapped is not None
        self.assertEqual(mapped["sensorid"], 248)
        self.assertEqual(mapped["rutpersona"], "192806143")
        self.assertEqual(mapped["rutproveedor"], "76195703")
        self.assertEqual(mapped["fecha"], datetime(2026, 10, 29, 22, 0, 40))
        self.assertEqual(mapped["entrada"], mapped["fecha"])
        self.assertEqual(mapped["salida"], datetime(2026, 10, 30, 9, 46, 28))
        self.assertEqual(mapped["total"], "11:45:48")
        self.assertEqual(mapped["nombre_local"], "QUILICURA")
        self.assertNotIn("userid", mapped)

    def test_salida_vacia_queda_nula(self) -> None:
        mapped = map_marca({"Local": 89, "Entrada": "2026-10-30 11:21:38", "Salida": ""})
        assert mapped is not None
        self.assertIsNone(mapped["salida"])
        self.assertEqual(mapped["fecha"], mapped["entrada"])

    def test_sin_entrada_o_sin_local_se_omite(self) -> None:
        self.assertIsNone(map_marca({"Local": 1, "Entrada": ""}))
        self.assertIsNone(map_marca({"Entrada": "2026-10-30 11:21:38"}))
        df = filas_a_dataframe([{"Local": 1, "Entrada": ""}, {"Local": 2, "Entrada": "2026-01-02 03:04:05"}])
        self.assertEqual(len(df), 1)
        self.assertEqual(list(df.columns), [
            "fecha", "sensorid", "rutpersona", "entrada", "salida", "total",
            "rutproveedor", "nombreproveedor", "nombrecargo", "nombrepersona",
            "nombre_local", "formato",
        ])

    def test_parse_datetime_recorta_fraccion(self) -> None:
        self.assertEqual(
            parse_datetime("2026-08-01T00:00:01.123Z"),
            datetime(2026, 8, 1, 0, 0, 1),
        )

    def test_persona_guarda_fechas_y_proveedor(self) -> None:
        raw = {
            "rut_persona": "19.280.614-3",
            "nombre_completo": "JUAN PEREZ SOTO",
            "primer_nombre": "",
            "apellido_paterno": None,
            "apellido_materno": "",
            "cargo": "SEGURIDAD - PERMANENTE",
            "estado": "HABILITADO",
            "contrato_vigencia": None,
            "contrato_indefinido": "0",
            "fecha_estado": "2026-01-14 09:59:29",
            "creado": "2026-01-14 09:59:29",
            "modificado": "2026-01-14 09:59:29",
        }
        mapped = map_persona(raw, rut_proveedor="76195703")
        self.assertEqual(mapped["rut_persona"], "192806143")
        self.assertEqual(mapped["rut_proveedor"], "76195703")
        self.assertEqual(mapped["estado"], "HABILITADO")
        self.assertIsNone(mapped["primer_nombre"])
        self.assertEqual(mapped["creado"], datetime(2026, 1, 14, 9, 59, 29))
        df = personas_a_dataframe([raw], rut_proveedor="76195703")
        self.assertEqual(len(df), 1)
        self.assertIn("cargo", df.columns)

    def test_truncate_parcial_se_rechaza(self) -> None:
        original = (config.FRAX_DESDE, config.FRAX_HASTA, config.BQ_WRITE_DISPOSITION, config.FRAX_ALLOW_PARTIAL_TRUNCATE)
        try:
            config.FRAX_DESDE = date(2026, 10, 1)
            config.FRAX_HASTA = date(2026, 10, 2)
            config.BQ_WRITE_DISPOSITION = "WRITE_TRUNCATE"
            config.FRAX_ALLOW_PARTIAL_TRUNCATE = False
            with self.assertRaises(ValueError):
                config.assert_truncate_seguro()
            config.FRAX_DESDE = date(2024, 8, 1)
            config.FRAX_HASTA = None
            config.assert_truncate_seguro()
        finally:
            (
                config.FRAX_DESDE,
                config.FRAX_HASTA,
                config.BQ_WRITE_DISPOSITION,
                config.FRAX_ALLOW_PARTIAL_TRUNCATE,
            ) = original


if __name__ == "__main__":
    unittest.main()
