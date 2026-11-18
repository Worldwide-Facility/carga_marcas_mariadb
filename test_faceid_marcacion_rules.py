"""Casos de prueba de la regla FaceID (ventana ±3 h, aceptación, Art. 22)."""

from __future__ import annotations

import unittest
from datetime import date, datetime, time

from faceid_marcacion_rules import (
    CargoAsignacion,
    EquipoFaceid,
    FilaMarca,
    FilaTurnoHist,
    TurnoClave,
    agregar_nombres_cargo,
    codigos_equipos_para_marcas,
    combinar_hist_y_24,
    contar_filas_vs_turnos_unicos,
    deducir_marca,
    deducir_marcas,
    deduplicar_equipos_enriq,
    deduplicar_turnos_faceid,
    elegir_equipo_enriquecimiento,
    elegir_marca_lado,
    elegir_turno_unicidad,
    en_universo_faceid,
    en_ventana,
    enriquecer_turno_cargos,
    enriquecer_turno_por_equipos,
    es_rut_generico,
    estado_faceid,
    fin_turno,
    inicio_turno,
    nombre_asistente_desde_hist,
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


class Complemento24Test(unittest.TestCase):
    """Hist diario (~08:00 hasta ayer) + _24 en vivo; hist precede al cargar el día."""

    def test_nocturno_salida_solo_en_24_dia_ausente_hist_pobla_salida(self) -> None:
        # N2 17/11 20:00 -> 18/11 08:00. Hist cargó hasta 17/11; salida de hoy solo en _24.
        dia = date(2026, 11, 17)
        her, hsr = time(20, 0), time(8, 0)
        inicio = inicio_turno(dia, her)
        fin = fin_turno(dia, her, hsr)

        hist = [
            fila(
                fecha=date(2026, 11, 17),
                hora=time(19, 55),
                tipo="Entrada Laboral",
                revision="Correcta",
            ),
        ]
        live_24 = [
            fila(
                fecha=date(2026, 11, 18),
                hora=time(8, 2),
                tipo="Salida Laboral",
                revision="Correcta",
            ),
        ]
        marcas = deducir_marcas(combinar_hist_y_24(hist, live_24))
        sal_cands = [
            m
            for m in marcas
            if m.tipo == "Salida Laboral" and en_ventana(m.marca_ts, fin)
        ]
        salida = elegir_marca_lado(sal_cands, fin)
        self.assertIsNotNone(salida)
        self.assertEqual(salida.hora, time(8, 2))
        ent_cands = [
            m
            for m in marcas
            if m.tipo == "Entrada Laboral" and en_ventana(m.marca_ts, inicio)
        ]
        entrada = elegir_marca_lado(ent_cands, inicio)
        self.assertIsNotNone(entrada)
        self.assertEqual(
            estado_faceid(True, entrada is not None, salida is not None),
            "OK",
        )

    def test_dia_presente_en_hist_ignora_24(self) -> None:
        # Mismo turno; el hist ya incluye el 18/11 (aunque sin esa salida) → _24 no aporta.
        dia = date(2026, 11, 17)
        her, hsr = time(20, 0), time(8, 0)
        fin = fin_turno(dia, her, hsr)

        hist = [
            fila(
                fecha=date(2026, 11, 17),
                hora=time(19, 55),
                tipo="Entrada Laboral",
                revision="Correcta",
            ),
            # Día de la salida ya presente en hist (otra marca / otro rut basta para MAX(fecha)).
            fila(
                rut="99999999",
                fecha=date(2026, 11, 18),
                hora=time(7, 0),
                tipo="Entrada Laboral",
                revision="Correcta",
            ),
        ]
        live_24 = [
            fila(
                fecha=date(2026, 11, 18),
                hora=time(8, 2),
                tipo="Salida Laboral",
                revision="Correcta",
            ),
        ]
        marcas = deducir_marcas(combinar_hist_y_24(hist, live_24))
        sal_cands = [
            m
            for m in marcas
            if m.tipo == "Salida Laboral"
            and m.rut == "21253355"
            and en_ventana(m.marca_ts, fin)
        ]
        self.assertIsNone(elegir_marca_lado(sal_cands, fin))
        self.assertFalse(any(m.fecha == date(2026, 11, 18) and m.tipo == "Salida Laboral" for m in marcas))


class CargosJoinUnicidadTest(unittest.TestCase):
    """
    Espejo del CTE output: joins de Subgerente / Jefe Operaciones / Supervisor.
    El bug histórico usaba a.empresa = b.empresa al joinear c/d y multiplicaba filas.
    """

    def setUp(self) -> None:
        self.turno = TurnoClave(
            rutasi="11111111",
            her=datetime(2026, 11, 17, 20, 0),
            instalacion_rol="INACAP COPIAPO",
            empresa="Security",
        )
        # 1 Subgerente Security + 2 jefes (2 empresas) + 4 supervisores (4 empresas)
        # → bug sin filtrar empresa de c/d: 2×4 = 8 filas; fix: 1 fila (solo Security).
        # Dos supervisores Security para probar STRING_AGG DISTINCT.
        self.asignaciones = [
            CargoAsignacion("Sub A", "Subgerente", "INACAP COPIAPO", "Security"),
            CargoAsignacion("Jefe Sec", "Jefe Operaciones", "INACAP COPIAPO", "Security"),
            CargoAsignacion("Jefe Otra", "Jefe Operaciones", "INACAP COPIAPO", "Otra"),
            CargoAsignacion("Sup 1", "Supervisor", "INACAP COPIAPO", "Security"),
            CargoAsignacion("Sup 2", "Supervisor", "INACAP COPIAPO", "Security"),
            CargoAsignacion("Sup 3", "Supervisor", "INACAP COPIAPO", "Emp3"),
            CargoAsignacion("Sup 4", "Supervisor", "INACAP COPIAPO", "Emp4"),
            CargoAsignacion("Sup 5", "Supervisor", "INACAP COPIAPO", "Emp5"),
        ]

    def test_bug_join_via_subgerente_multiplica_8x(self) -> None:
        filas = enriquecer_turno_cargos(
            self.turno,
            self.asignaciones,
            join_jefe_supervisor_via_subgerente_empresa=True,
        )
        # 2 jefes (empresas distintas) × 4 grupos supervisor (Security/Emp3/Emp4/Emp5)
        self.assertEqual(len(filas), 8)

    def test_fix_una_fila_por_turno_agrega_nombres(self) -> None:
        filas = enriquecer_turno_cargos(self.turno, self.asignaciones)
        self.assertEqual(len(filas), 1)
        f = filas[0]
        self.assertEqual(f["subgerente"], "Sub A")
        self.assertEqual(f["jefe_zonal"], "Jefe Sec")
        # Varios supervisores Security → STRING_AGG DISTINCT ordenado
        self.assertEqual(f["supervisor"], "Sup 1, Sup 2")

    def test_sin_subgerente_igual_resuelve_jefe_y_supervisor(self) -> None:
        asign = [a for a in self.asignaciones if a.cargo != "Subgerente"]
        filas = enriquecer_turno_cargos(self.turno, asign)
        self.assertEqual(len(filas), 1)
        self.assertIsNone(filas[0]["subgerente"])
        self.assertEqual(filas[0]["jefe_zonal"], "Jefe Sec")
        self.assertEqual(filas[0]["supervisor"], "Sup 1, Sup 2")

    def test_agregar_nombres_distinct_ordenado(self) -> None:
        self.assertEqual(agregar_nombres_cargo(["Zoe", "Ana", "Ana", ""]), "Ana, Zoe")
        self.assertIsNone(agregar_nombres_cargo(["", None]))  # type: ignore[list-item]

    def test_contar_filas_vs_turnos_detecta_duplicados(self) -> None:
        # 4 personas N2 × 8 filas bug = 32; 4 turnos únicos.
        turnos = [
            TurnoClave(f"rut{i}", datetime(2026, 11, 17, 20, 0), "INACAP COPIAPO", "Security")
            for i in range(4)
        ]
        filas_bug: list[TurnoClave] = []
        for t in turnos:
            enriquecidas = enriquecer_turno_cargos(
                t,
                self.asignaciones,
                join_jefe_supervisor_via_subgerente_empresa=True,
            )
            filas_bug.extend([e["turno"] for e in enriquecidas])
        n_filas, n_unicos = contar_filas_vs_turnos_unicos(filas_bug)
        self.assertEqual(n_filas, 32)
        self.assertEqual(n_unicos, 4)

        filas_ok: list[TurnoClave] = []
        for t in turnos:
            enriquecidas = enriquecer_turno_cargos(t, self.asignaciones)
            filas_ok.extend([e["turno"] for e in enriquecidas])
        n_filas_ok, n_unicos_ok = contar_filas_vs_turnos_unicos(filas_ok)
        self.assertEqual(n_filas_ok, n_unicos_ok)
        self.assertEqual(n_filas_ok, 4)


class EquiposEnriqUnicidadTest(unittest.TestCase):
    """
    Espejo de equipos vs equipos_enriq / equipos_lw_enriq.
    Bug: join de turnos por nombre+empresa contra ambas tablas con 2 equipos cada una → ×4.
    Fix: dedupe enriquecimiento; marcas_raw sigue aceptando todos los cod.
    """

    def setUp(self) -> None:
        # INACAP COPIAPO Security: 2657 sin conexión, 2658 con ult_conexion reciente.
        self.eq_2657 = EquipoFaceid(
            "INACAP COPIAPO", "Security", 2657, ult_conexion=None
        )
        self.eq_2658 = EquipoFaceid(
            "INACAP COPIAPO",
            "Security",
            2658,
            ult_conexion=datetime(2026, 11, 17, 17, 32),
        )
        self.equipos = [self.eq_2657, self.eq_2658]
        # Misma duplicación en _lw (códigos distintos solo para el espejo).
        self.equipos_lw = [
            EquipoFaceid("INACAP COPIAPO", "Security", 2657, ult_conexion=None),
            EquipoFaceid(
                "INACAP COPIAPO",
                "Security",
                2658,
                ult_conexion=datetime(2026, 11, 17, 17, 32),
            ),
        ]
        self.turno = TurnoClave(
            rutasi="11111111",
            her=datetime(2026, 11, 17, 20, 0),
            instalacion_rol="INACAP COPIAPO",
            empresa="Security",
        )

    def test_elige_ult_conexion_reciente_nulls_last_desempate_cod(self) -> None:
        elegido = elegir_equipo_enriquecimiento(self.equipos)
        assert elegido is not None
        self.assertEqual(elegido.cod, 2658)
        # Dos con misma ult_conexion → gana el cod menor.
        empate = [
            EquipoFaceid("X", "Security", 10, datetime(2026, 11, 17, 12, 0)),
            EquipoFaceid("X", "Security", 9, datetime(2026, 11, 17, 12, 0)),
        ]
        self.assertEqual(elegir_equipo_enriquecimiento(empate).cod, 9)

    def test_bug_eq_x_eq_lw_multiplica_4x(self) -> None:
        filas = enriquecer_turno_por_equipos(
            self.turno,
            self.equipos,
            self.equipos_lw,
            dedupe_enriquecimiento=False,
        )
        self.assertEqual(len(filas), 4)
        # 4 personas N2 → 16 filas (caso reportado).
        turnos = [
            TurnoClave(f"rut{i}", datetime(2026, 11, 17, 20, 0), "INACAP COPIAPO", "Security")
            for i in range(4)
        ]
        filas_bug: list[TurnoClave] = []
        for t in turnos:
            enriquecidas = enriquecer_turno_por_equipos(
                t, self.equipos, self.equipos_lw, dedupe_enriquecimiento=False
            )
            filas_bug.extend([e["turno"] for e in enriquecidas])
        n_filas, n_unicos = contar_filas_vs_turnos_unicos(filas_bug)
        self.assertEqual(n_filas, 16)
        self.assertEqual(n_unicos, 4)

    def test_fix_una_fila_con_ult_conexion_del_equipo_reciente(self) -> None:
        filas = enriquecer_turno_por_equipos(
            self.turno, self.equipos, self.equipos_lw
        )
        self.assertEqual(len(filas), 1)
        f = filas[0]
        self.assertEqual(f["cod_enriq"], 2658)
        self.assertEqual(f["ult_conexion"], datetime(2026, 11, 17, 17, 32))
        self.assertTrue(f["instalacion_con_faceid"])
        self.assertIsNone(f["nuevo_faceid"])  # está en _lw tras dedupe

        dedup = deduplicar_equipos_enriq(self.equipos)
        self.assertEqual(len(dedup), 1)
        self.assertEqual(dedup[0].cod, 2658)

    def test_marcas_raw_acepta_todos_los_cod_no_pierde_marcas(self) -> None:
        # Enriquecimiento deja 1 equipo; marcas_raw debe seguir viendo 2657 y 2658.
        self.assertEqual(codigos_equipos_para_marcas(self.equipos), {2657, 2658})
        self.assertEqual(len(deduplicar_equipos_enriq(self.equipos)), 1)
        # Marca en el dispositivo "viejo" (2657) sigue siendo válida vía todos los cod.
        marca_en_2657 = fila(
            fecha=date(2026, 11, 17),
            hora=time(19, 55),
            tipo="Entrada Laboral",
            revision="Correcta",
        )
        cods = codigos_equipos_para_marcas(self.equipos)
        self.assertIn(2657, cods)
        marcas = deducir_marcas([marca_en_2657])
        self.assertEqual(len(marcas), 1)


class HistTbUnicidadYNombreTest(unittest.TestCase):
    """
    Espejo de pre_int desde cr_asistencia_hist_tb:
    1) TIT vs NOR mismo (rutasi, her, instalacion, empresa) → queda TIT
    2) relevo partido con 90000009 + persona real → excluye genérico; nombre = persona
    3) misma persona en dos puestos PPC (mismo her/instalacion) → 1 fila
    """

    def test_excluye_ruts_genericos_del_universo(self) -> None:
        self.assertTrue(es_rut_generico("90000009"))
        self.assertTrue(es_rut_generico(90000001))
        self.assertFalse(es_rut_generico("15685810"))
        self.assertFalse(en_universo_faceid("90000002"))
        self.assertFalse(en_universo_faceid(""))
        self.assertTrue(en_universo_faceid("15685810"))

    def test_caso1_titular_nor_y_tit_mismo_turno_prefiere_tit(self) -> None:
        # INACAP Iquique 17/11 NN6, rut 15685810: NOR en su puesto + TIT cubriendo.
        her = datetime(2026, 11, 17, 20, 0)
        hsr = datetime(2026, 11, 18, 8, 0)
        nor = FilaTurnoHist(
            rutasi="15685810",
            her=her,
            hsr=hsr,
            instalacion_rol="INACAP IQUIQUE",
            empresa="Security",
            tipo="NOR",
            rutrol="15685810",
            turno="NN6",
            dia=date(2026, 11, 17),
            nombrerol="GUARDIA TITULAR",
            relevo=None,
        )
        tit = FilaTurnoHist(
            rutasi="15685810",
            her=her,
            hsr=hsr,
            instalacion_rol="INACAP IQUIQUE",
            empresa="Security",
            tipo="TIT",
            rutrol="99990001",
            turno="NN6",
            dia=date(2026, 11, 17),
            nombrerol="PUESTO CUBIERTO",
            relevo="15685810 | 8:00PM / 8:00AM | GUARDIA TITULAR",
        )
        elegido = elegir_turno_unicidad([nor, tit])
        assert elegido is not None
        self.assertEqual(elegido.tipo, "TIT")
        self.assertEqual(elegido.rutrol, "99990001")
        dedup = deduplicar_turnos_faceid([nor, tit])
        self.assertEqual(len(dedup), 1)
        self.assertEqual(dedup[0].tipo, "TIT")
        self.assertEqual(dedup[0].nombre_asistente, "GUARDIA TITULAR")

    def test_caso2_relevo_partido_excluye_90000009_nombre_persona_real(self) -> None:
        # Lider Lo Barnechea 443 24/09 T90: primera parte Apoyo General 90000009.
        her = datetime(2026, 9, 24, 8, 0)
        hsr = datetime(2026, 9, 24, 20, 0)
        relevo = (
            "90000009 | 8:00AM / 2:00PM | Apoyo General || "
            "16105422 | 2:00PM / 8:00PM | JUAN PEREZ"
        )
        # hist_tb ya eligió rutasi=persona real; FaceID excluye la fila genérica.
        fila_dummy = FilaTurnoHist(
            rutasi="90000009",
            her=her,
            hsr=datetime(2026, 9, 24, 14, 0),
            instalacion_rol="LIDER LO BARNECHEA 443",
            empresa="Security",
            tipo="EXR",
            rutrol="161054",
            turno="T90",
            dia=date(2026, 9, 24),
            nombrerol="PUESTO PPC",
            relevo=relevo,
        )
        fila_real = FilaTurnoHist(
            rutasi="16105422",
            her=her,
            hsr=hsr,
            instalacion_rol="LIDER LO BARNECHEA 443",
            empresa="Security",
            tipo="EXR",
            rutrol="162576",
            turno="T90",
            dia=date(2026, 9, 24),
            nombrerol="PUESTO PPC",
            relevo=relevo,
        )
        self.assertEqual(
            nombre_asistente_desde_hist(
                "162576", "16105422", "PUESTO PPC", relevo
            ),
            "JUAN PEREZ",
        )
        # No debe quedarse con el último texto a ciegas si rutasi es el del primer tramo.
        self.assertEqual(
            nombre_asistente_desde_hist(
                "161054", "90000009", "PUESTO PPC", relevo
            ),
            "Apoyo General",
        )
        dedup = deduplicar_turnos_faceid([fila_dummy, fila_real])
        self.assertEqual(len(dedup), 1)
        self.assertEqual(dedup[0].rutasi, "16105422")
        self.assertEqual(dedup[0].nombre_asistente, "JUAN PEREZ")

    def test_caso3_misma_persona_dos_puestos_ppc_una_fila(self) -> None:
        # UST Ejército rutasi 13665558 en puestos 160624 y 162666, mismo her/instalacion.
        her = datetime(2026, 11, 17, 8, 0)
        hsr_a = datetime(2026, 11, 17, 16, 0)
        hsr_b = datetime(2026, 11, 17, 20, 0)  # tramo más largo / hsr más tarde
        a = FilaTurnoHist(
            rutasi="13665558",
            her=her,
            hsr=hsr_a,
            instalacion_rol="UST EJERCITO",
            empresa="Security",
            tipo="EXR",
            rutrol="160624",
            turno="D1",
            dia=date(2026, 11, 17),
            nombrerol="PUESTO A",
            relevo="13665558 | 8:00AM / 4:00PM | ANA LOPEZ",
        )
        b = FilaTurnoHist(
            rutasi="13665558",
            her=her,
            hsr=hsr_b,
            instalacion_rol="UST EJERCITO",
            empresa="Security",
            tipo="EXR",
            rutrol="162666",
            turno="D1",
            dia=date(2026, 11, 17),
            nombrerol="PUESTO B",
            relevo="13665558 | 8:00AM / 8:00PM | ANA LOPEZ",
        )
        elegido = elegir_turno_unicidad([a, b])
        assert elegido is not None
        self.assertEqual(elegido.rutrol, "162666")
        self.assertEqual(elegido.hsr, hsr_b)
        dedup = deduplicar_turnos_faceid([a, b])
        self.assertEqual(len(dedup), 1)
        n_filas, n_unicos = contar_filas_vs_turnos_unicos(
            [
                TurnoClave(f.rutasi, f.her, f.instalacion_rol, f.empresa)
                for f in dedup
            ]
        )
        self.assertEqual(n_filas, n_unicos)
        self.assertEqual(n_filas, 1)


if __name__ == "__main__":
    unittest.main()
