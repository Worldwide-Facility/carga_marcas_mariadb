"""Casos de prueba de la regla FaceID (ventana ±3 h, aceptación, Art. 22)."""

from __future__ import annotations

import unittest
from datetime import date, datetime, time

from faceid_marcacion_rules import (
    FilaMarca,
    deducir_marca,
    deducir_marcas,
    elegir_marca_lado,
    en_ventana,
    estado_faceid,
    fin_turno,
    inicio_turno,
)


def fila(
    *,
    empresa: str = "Security",
    rut: str = "21253355",
    fecha: date,
    hora: time,
    tipo: str,
    revision: str | None,
    motivo: str | None = None,
) -> FilaMarca:
    return FilaMarca(
        empresa=empresa,
        rut=rut,
        fecha=fecha,
        hora=hora,
        tipo=tipo,
        revision=revision,
        motivo_no_uso=motivo,
    )


class VentanaTurnoTest(unittest.TestCase):
    def test_nocturno_n2_fin_al_dia_siguiente(self) -> None:
        dia = date(2026, 11, 16)
        her = time(20, 0)
        hsr = time(8, 0)
        self.assertEqual(inicio_turno(dia, her), datetime(2026, 11, 16, 20, 0))
        self.assertEqual(fin_turno(dia, her, hsr), datetime(2026, 11, 17, 8, 0))

    def test_diurno_mismo_dia(self) -> None:
        dia = date(2026, 11, 16)
        self.assertEqual(fin_turno(dia, time(8, 0), time(17, 0)), datetime(2026, 11, 16, 17, 0))

    def test_n5_entrada_dia_anterior_fuera_de_ventana(self) -> None:
        # N5 00:00-08:00; entrada 20:00 del día anterior → fuera de ±3 h.
        inicio = inicio_turno(date(2026, 11, 17), time(0, 0))
        marca = datetime(2026, 11, 16, 20, 0)
        self.assertFalse(en_ventana(marca, inicio))

    def test_salida_diurna_3h_antes_no_cuenta(self) -> None:
        # Fin 17:00; salida ~12:00-15:00 → fuera / borde.
        fin = fin_turno(date(2026, 11, 16), time(8, 0), time(17, 0))
        self.assertFalse(en_ventana(datetime(2026, 11, 16, 12, 0), fin))
        self.assertFalse(en_ventana(datetime(2026, 11, 16, 13, 59), fin))
        self.assertTrue(en_ventana(datetime(2026, 11, 16, 14, 0), fin))  # exactamente −3 h
        self.assertTrue(en_ventana(datetime(2026, 11, 16, 15, 0), fin))


class AceptacionTest(unittest.TestCase):
    def test_en_revision_con_marca_utilizada_correctamente_cuenta(self) -> None:
        d = deducir_marca(
            [
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 50, 7),
                    tipo="Entrada Laboral",
                    revision="En Revisión",
                    motivo="Marca Utilizada Correctamente",
                )
            ]
        )
        self.assertTrue(d.aceptada)
        self.assertTrue(d.no_objetada)

    def test_objetada_nunca_cuenta(self) -> None:
        d = deducir_marca(
            [
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 50, 7),
                    tipo="Entrada Laboral",
                    revision="Objetada",
                    motivo="Marca Utilizada Correctamente",
                )
            ]
        )
        self.assertFalse(d.aceptada)
        self.assertFalse(d.no_objetada)
        self.assertEqual(deducir_marcas([fila(
            fecha=date(2026, 11, 16),
            hora=time(19, 50, 7),
            tipo="Entrada Laboral",
            revision="Objetada",
            motivo="Marca Utilizada Correctamente",
        )]), [])

    def test_duplicado_correcta_y_en_revision_cuenta_una_vez(self) -> None:
        marcas = deducir_marcas(
            [
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 50, 7),
                    tipo="Entrada Laboral",
                    revision="Correcta",
                ),
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 50, 7),
                    tipo="Entrada Laboral",
                    revision="En Revisión",
                    motivo="Otro",
                ),
            ]
        )
        self.assertEqual(len(marcas), 1)
        self.assertTrue(marcas[0].aceptada)


class Art22YCasoMartabidTest(unittest.TestCase):
    def test_martabid_n2_art22_ok(self) -> None:
        """
        MARTABID Security, N2 16/11/2026 20:00 -> 17/11 08:00, rutasi 21253355:
        entrada 16/11 19:50:07 y salida 17/11 08:02:17, ambas En Revisión + Art. 22 → OK.
        """
        dia = date(2026, 11, 16)
        her, hsr = time(20, 0), time(8, 0)
        inicio = inicio_turno(dia, her)
        fin = fin_turno(dia, her, hsr)

        filas = [
            fila(
                rut="21253355",
                fecha=date(2026, 11, 16),
                hora=time(19, 50, 7),
                tipo="Entrada Laboral",
                revision="En Revisión",
                motivo="Colaborador Art. 22",
            ),
            fila(
                rut="21253355",
                fecha=date(2026, 11, 17),
                hora=time(8, 2, 17),
                tipo="Salida Laboral",
                revision="En Revisión",
                motivo="Colaborador Art. 22",
            ),
        ]
        marcas = deducir_marcas(filas)
        self.assertEqual(len(marcas), 2)
        self.assertFalse(any(m.aceptada for m in marcas))
        self.assertTrue(all(m.motivo_art22 for m in marcas))

        ent_cands = [
            m
            for m in marcas
            if m.tipo == "Entrada Laboral" and en_ventana(m.marca_ts, inicio)
        ]
        sal_cands = [
            m
            for m in marcas
            if m.tipo == "Salida Laboral" and en_ventana(m.marca_ts, fin)
        ]
        entrada = elegir_marca_lado(ent_cands, inicio)
        salida = elegir_marca_lado(sal_cands, fin)
        self.assertIsNotNone(entrada)
        self.assertIsNotNone(salida)
        self.assertEqual(
            estado_faceid(True, entrada is not None, salida is not None),
            "OK",
        )

    def test_art22_no_aplica_si_hay_otra_marca_no_art22_en_ventana(self) -> None:
        inicio = inicio_turno(date(2026, 11, 16), time(20, 0))
        candidatas = deducir_marcas(
            [
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 50),
                    tipo="Entrada Laboral",
                    revision="En Revisión",
                    motivo="Colaborador Art. 22",
                ),
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(20, 10),
                    tipo="Entrada Laboral",
                    revision="En Revisión",
                    motivo="Otro motivo",
                ),
            ]
        )
        candidatas = [m for m in candidatas if en_ventana(m.marca_ts, inicio)]
        self.assertIsNone(elegir_marca_lado(candidatas, inicio))

    def test_aceptada_gana_sobre_art22(self) -> None:
        inicio = inicio_turno(date(2026, 11, 16), time(20, 0))
        candidatas = deducir_marcas(
            [
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 55),
                    tipo="Entrada Laboral",
                    revision="En Revisión",
                    motivo="Colaborador Art. 22",
                ),
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(20, 5),
                    tipo="Entrada Laboral",
                    revision="Correcta",
                ),
            ]
        )
        candidatas = [m for m in candidatas if en_ventana(m.marca_ts, inicio)]
        elegida = elegir_marca_lado(candidatas, inicio)
        assert elegida is not None
        self.assertTrue(elegida.aceptada)
        self.assertEqual(elegida.hora, time(20, 5))


class CercaniaTest(unittest.TestCase):
    def test_elige_la_mas_cercana_al_inicio(self) -> None:
        inicio = inicio_turno(date(2026, 11, 16), time(20, 0))
        candidatas = deducir_marcas(
            [
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 0),
                    tipo="Entrada Laboral",
                    revision="Correcta",
                ),
                fila(
                    fecha=date(2026, 11, 16),
                    hora=time(19, 50),
                    tipo="Entrada Laboral",
                    revision="Correcta",
                ),
            ]
        )
        elegida = elegir_marca_lado(candidatas, inicio)
        assert elegida is not None
        self.assertEqual(elegida.hora, time(19, 50))


if __name__ == "__main__":
    unittest.main()
