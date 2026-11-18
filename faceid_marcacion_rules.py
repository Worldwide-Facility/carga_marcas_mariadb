"""
Reglas puras del cruce FaceID ↔ turno (espejo de sql/cr_reporte_marcacion_faceid.sql).

No habla con BigQuery: sirve para documentar y testear aceptación, ventana ±3 h y Art. 22.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, time
from typing import Iterable, Sequence


VENTANA = timedelta(hours=3)

MOTIVO_OK = "Marca Utilizada Correctamente"
MOTIVO_ART22 = "Colaborador Art. 22"
REVISION_CORRECTA = "Correcta"
REVISION_OBJETADA = "Objetada"
TIPO_ENTRADA = "Entrada Laboral"
TIPO_SALIDA = "Salida Laboral"


@dataclass(frozen=True)
class FilaMarca:
    """Una fila de hist o _24 (puede haber varias por el mismo marcaje físico)."""

    empresa: str
    rut: str
    fecha: date
    hora: time
    tipo: str
    revision: str | None
    motivo_no_uso: str | None

    @property
    def marca_ts(self) -> datetime:
        return datetime.combine(self.fecha, self.hora)

    @property
    def clave(self) -> tuple:
        return (self.empresa, self.rut, self.fecha, self.hora, self.tipo)


def combinar_hist_y_24(
    hist: Sequence[FilaMarca],
    live_24: Sequence[FilaMarca],
) -> list[FilaMarca]:
    """
    Espejo del UNION ALL en marcas_raw: todo el hist más filas de _24 con
    fecha > MAX(fecha) del hist (hist tiene precedencia al cargar un día).
    """
    out = list(hist)
    if not hist:
        return out
    max_fecha_hist = max(f.fecha for f in hist)
    for f in live_24:
        if f.fecha > max_fecha_hist:
            out.append(f)
    return out


@dataclass(frozen=True)
class MarcaDedup:
    empresa: str
    rut: str
    fecha: date
    hora: time
    tipo: str
    marca_ts: datetime
    aceptada: bool
    no_objetada: bool
    motivo_art22: bool


def _norm(value: str | None) -> str:
    return (value or "").strip()


def deducir_marca(filas: Sequence[FilaMarca]) -> MarcaDedup:
    """Deduplica filas del mismo marcaje y calcula flags de aceptación / Art. 22."""
    if not filas:
        raise ValueError("filas vacías")
    base = filas[0]
    for f in filas[1:]:
        if f.clave != base.clave:
            raise ValueError("todas las filas deben compartir clave de marcaje")

    aceptada = False
    no_objetada = False
    motivo_art22 = False
    for f in filas:
        rev = _norm(f.revision)
        mot = _norm(f.motivo_no_uso)
        if rev == REVISION_OBJETADA:
            continue
        no_objetada = True
        if rev == REVISION_CORRECTA or mot == MOTIVO_OK:
            aceptada = True
        if mot == MOTIVO_ART22:
            motivo_art22 = True

    return MarcaDedup(
        empresa=base.empresa,
        rut=base.rut,
        fecha=base.fecha,
        hora=base.hora,
        tipo=base.tipo,
        marca_ts=base.marca_ts,
        aceptada=aceptada,
        no_objetada=no_objetada,
        motivo_art22=motivo_art22,
    )


def deducir_marcas(filas: Iterable[FilaMarca]) -> list[MarcaDedup]:
    por_clave: dict[tuple, list[FilaMarca]] = {}
    for f in filas:
        if f.tipo not in (TIPO_ENTRADA, TIPO_SALIDA):
            continue
        por_clave.setdefault(f.clave, []).append(f)
    out: list[MarcaDedup] = []
    for group in por_clave.values():
        d = deducir_marca(group)
        if d.no_objetada:
            out.append(d)
    return out


def inicio_turno(dia: date, her: time) -> datetime:
    return datetime.combine(dia, her)


def fin_turno(dia: date, her: time, hsr: time) -> datetime:
    """Si hsr <= her el turno cruza medianoche: fin al día siguiente."""
    if hsr <= her:
        return datetime.combine(dia + timedelta(days=1), hsr)
    return datetime.combine(dia, hsr)


def en_ventana(marca_ts: datetime, referencia: datetime, ventana: timedelta = VENTANA) -> bool:
    return referencia - ventana <= marca_ts <= referencia + ventana


def elegir_marca_lado(
    candidatas: Sequence[MarcaDedup],
    referencia: datetime,
) -> MarcaDedup | None:
    """
    candidatas: marcas no-Objetadas del tipo correcto ya filtradas por ventana.
    Prioridad: aceptadas; si ninguna, Art. 22 solo si TODAS tienen motivo Art. 22.
    Entre válidas, la más cercana a referencia.
    """
    if not candidatas:
        return None

    aceptadas = [m for m in candidatas if m.aceptada]
    if aceptadas:
        pool = aceptadas
    elif all(m.motivo_art22 for m in candidatas):
        pool = list(candidatas)
    else:
        return None

    return min(pool, key=lambda m: (abs((m.marca_ts - referencia).total_seconds()), m.marca_ts))


def estado_faceid(
    instalacion_con_faceid: bool,
    tiene_entrada: bool,
    tiene_salida: bool,
) -> str:
    if not instalacion_con_faceid:
        if not tiene_entrada and not tiene_salida:
            return "OK"
        # Misma convención que la vista: sin FaceID solo se contempla el caso sin marcas.
        return "OK"
    if tiene_entrada and tiene_salida:
        return "OK"
    if tiene_entrada and not tiene_salida:
        return "Marca entrada"
    if not tiene_entrada and tiene_salida:
        return "Marca salida"
    return "No Marca"


# --- Universo de turnos (espejo de pre_int / turnos desde cr_asistencia_hist_tb) ---

RUTS_GENERICOS = frozenset({"90000001", "90000002", "90000009"})


def _rut_digitos(value: object | None) -> str:
    return "".join(ch for ch in str(value or "") if ch.isdigit())


def es_rut_generico(rutasi: object | None) -> bool:
    """True si rutasi es hueco ControlRoll (excluido del universo FaceID)."""
    return _rut_digitos(rutasi) in RUTS_GENERICOS


def en_universo_faceid(rutasi: object | None) -> bool:
    """Espejo del filtro de turnos: rutasi no vacío y no genérico."""
    digits = _rut_digitos(rutasi)
    return bool(digits) and digits not in RUTS_GENERICOS


def nombre_asistente_desde_hist(
    rutrol: object | None,
    rutasi: object | None,
    nombrerol: str | None,
    relevo: str | None,
) -> str | None:
    """
    Espejo de nombre_asistente en pre_int:
    - mismo rutrol/rutasi → nombrerol
    - si no, nombre del tramo de relevo cuyo RUT coincide con rutasi
      (tramos separados por ' || '; cada tramo 'RUT | horario | NOMBRE')
    - fallback: nombrerol
    """
    if _rut_digitos(rutrol) == _rut_digitos(rutasi) and _rut_digitos(rutasi):
        return (nombrerol or "").strip() or None

    rutasi_n = _rut_digitos(rutasi)
    for seg in (relevo or "").split(" || "):
        parts = [p.strip() for p in seg.split(" | ")]
        if not parts:
            continue
        if _rut_digitos(parts[0]) == rutasi_n and rutasi_n:
            nombre = parts[-1].strip() if parts else ""
            return nombre or None
    return (nombrerol or "").strip() or None


@dataclass(frozen=True)
class FilaTurnoHist:
    """Fila mínima de cr_asistencia_hist_tb para unicidad / nombre FaceID."""

    rutasi: str
    her: datetime
    hsr: datetime
    instalacion_rol: str
    empresa: str
    tipo: str
    rutrol: str
    turno: str = ""
    dia: date | None = None
    nombrerol: str | None = None
    relevo: str | None = None

    @property
    def clave_unicidad(self) -> tuple:
        return (str(self.rutasi), self.her, self.instalacion_rol, self.empresa)

    @property
    def nombre_asistente(self) -> str | None:
        return nombre_asistente_desde_hist(
            self.rutrol, self.rutasi, self.nombrerol, self.relevo
        )


def _prioridad_tipo_turno(tipo: str | None) -> int:
    t = (tipo or "").strip().upper()
    if t in ("TIT", "EXR"):
        return 0
    if t == "NOR":
        return 1
    return 2


def elegir_turno_unicidad(filas: Sequence[FilaTurnoHist]) -> FilaTurnoHist | None:
    """
    Espejo del QUALIFY en pre_int: una fila por (rutasi, her, instalacion_rol, empresa).
    Prefiere TIT/EXR sobre NOR, luego hsr más tardío; desempate rutrol, turno, dia.
    """
    if not filas:
        return None
    claves = {f.clave_unicidad for f in filas}
    if len(claves) != 1:
        raise ValueError("todas las filas deben compartir la clave de unicidad FaceID")
    return min(
        filas,
        key=lambda f: (
            _prioridad_tipo_turno(f.tipo),
            # hsr más tardío → ordenar por −timestamp; None al final
            f.hsr is None,
            -(f.hsr.timestamp()) if f.hsr is not None else 0.0,
            str(f.rutrol),
            f.turno or "",
            str(f.dia or ""),
        ),
    )


def deduplicar_turnos_faceid(
    filas: Sequence[FilaTurnoHist],
    *,
    excluir_genericos: bool = True,
) -> list[FilaTurnoHist]:
    """Aplica filtro de universo + QUALIFY de unicidad (espejo pre_int→turnos)."""
    buckets: dict[tuple, list[FilaTurnoHist]] = {}
    for f in filas:
        if excluir_genericos and not en_universo_faceid(f.rutasi):
            continue
        buckets.setdefault(f.clave_unicidad, []).append(f)
    out: list[FilaTurnoHist] = []
    for group in buckets.values():
        elegido = elegir_turno_unicidad(group)
        if elegido is not None:
            out.append(elegido)
    return out


# --- Cargos / enriquecimiento (espejo del CTE output; no toca marcas) ---

CARGO_SUBGERENTE = "Subgerente"
CARGO_JEFE_ZONAL = "Jefe Operaciones"
CARGO_SUPERVISOR = "Supervisor"


@dataclass(frozen=True)
class CargoAsignacion:
    """Fila del CTE `cargos`: persona con cargo en una instalación/empresa."""

    nombre_completo: str
    cargo: str
    instalacion_rol: str
    empresa: str


@dataclass(frozen=True)
class TurnoClave:
    """Clave de unicidad de un turno en el reporte FaceID."""

    rutasi: str
    her: datetime
    instalacion_rol: str
    empresa: str


def agregar_nombres_cargo(nombres: Iterable[str]) -> str | None:
    """
    Espejo de STRING_AGG(DISTINCT nombre, ', ' ORDER BY nombre) en el CTE cargos.
    Varias personas del mismo cargo → una sola celda; sin nombres → None.
    """
    unicos = sorted({(n or "").strip() for n in nombres if (n or "").strip()})
    if not unicos:
        return None
    return ", ".join(unicos)


def _indice_cargos(
    asignaciones: Sequence[CargoAsignacion],
) -> dict[tuple[str, str, str], str | None]:
    """(instalacion, empresa, cargo) → nombres agregados."""
    buckets: dict[tuple[str, str, str], list[str]] = {}
    for a in asignaciones:
        if not a.instalacion_rol:
            continue
        key = (a.instalacion_rol, a.empresa, a.cargo)
        buckets.setdefault(key, []).append(a.nombre_completo)
    return {k: agregar_nombres_cargo(v) for k, v in buckets.items()}


def enriquecer_turno_cargos(
    turno: TurnoClave,
    asignaciones: Sequence[CargoAsignacion],
    *,
    join_jefe_supervisor_via_subgerente_empresa: bool = False,
) -> list[dict]:
    """
    Espejo del CTE `output`: adjunta subgerente / jefe_zonal / supervisor.

    Por defecto compara empresa del propio cargo (correcto: ≤1 fila por turno).
    Si `join_jefe_supervisor_via_subgerente_empresa=True` reproduce el bug histórico
    (`a.empresa = b.empresa` al joinear c/d): producto cartesiano de jefes × supervisores
    de la instalación sin filtrar por empresa del cargo.
    """
    idx = _indice_cargos(asignaciones)
    inst, emp = turno.instalacion_rol, turno.empresa
    subgerente = idx.get((inst, emp, CARGO_SUBGERENTE))

    if join_jefe_supervisor_via_subgerente_empresa:
        # Bug: si hay Subgerente, la condición de empresa queda siempre TRUE y se
        # cruzan todos los Jefe Operaciones × Supervisor de esa instalación.
        if subgerente is None:
            return [
                {
                    "turno": turno,
                    "subgerente": None,
                    "jefe_zonal": None,
                    "supervisor": None,
                }
            ]
        jefes = [
            nombre
            for (i, _e, cargo), nombre in idx.items()
            if i == inst and cargo == CARGO_JEFE_ZONAL and nombre is not None
        ]
        supers = [
            nombre
            for (i, _e, cargo), nombre in idx.items()
            if i == inst and cargo == CARGO_SUPERVISOR and nombre is not None
        ]
        if not jefes and not supers:
            return [
                {
                    "turno": turno,
                    "subgerente": subgerente,
                    "jefe_zonal": None,
                    "supervisor": None,
                }
            ]
        jefes = jefes or [None]
        supers = supers or [None]
        return [
            {
                "turno": turno,
                "subgerente": subgerente,
                "jefe_zonal": j,
                "supervisor": s,
            }
            for j in jefes
            for s in supers
        ]

    return [
        {
            "turno": turno,
            "subgerente": subgerente,
            "jefe_zonal": idx.get((inst, emp, CARGO_JEFE_ZONAL)),
            "supervisor": idx.get((inst, emp, CARGO_SUPERVISOR)),
        }
    ]


def contar_filas_vs_turnos_unicos(
    filas: Sequence[TurnoClave],
) -> tuple[int, int]:
    """(n_filas, n_turnos_unicos) por (rutasi, her, instalacion_rol, empresa)."""
    unicos = {(f.rutasi, f.her, f.instalacion_rol, f.empresa) for f in filas}
    return len(filas), len(unicos)


# --- Equipos FaceID (espejo de equipos vs equipos_enriq / equipos_lw_enriq) ---


@dataclass(frozen=True)
class EquipoFaceid:
    """Fila de cr_equipos_faceid o cr_equipos_faceid_lw."""

    nombre: str
    empresa: str
    cod: int
    ult_conexion: datetime | None = None


def elegir_equipo_enriquecimiento(
    equipos: Sequence[EquipoFaceid],
) -> EquipoFaceid | None:
    """
    Espejo de QUALIFY ROW_NUMBER() en equipos_enriq / equipos_lw_enriq:
    una fila por (nombre, empresa) con ult_conexion más reciente (NULL al final)
    y desempate determinista por cod ASC.
    """
    if not equipos:
        return None
    # Misma clave: el caller debe pasar solo equipos del mismo (nombre, empresa).
    nombres = {(e.nombre, e.empresa) for e in equipos}
    if len(nombres) != 1:
        raise ValueError("todos los equipos deben compartir (nombre, empresa)")
    return min(
        equipos,
        key=lambda e: (
            e.ult_conexion is None,  # NULLS LAST
            -(e.ult_conexion.timestamp()) if e.ult_conexion is not None else 0.0,
            e.cod,
        ),
    )


def deduplicar_equipos_enriq(
    equipos: Sequence[EquipoFaceid],
) -> list[EquipoFaceid]:
    """Una fila por (nombre, empresa) con el criterio de elegir_equipo_enriquecimiento."""
    buckets: dict[tuple[str, str], list[EquipoFaceid]] = {}
    for e in equipos:
        buckets.setdefault((e.nombre, e.empresa), []).append(e)
    out: list[EquipoFaceid] = []
    for group in buckets.values():
        elegido = elegir_equipo_enriquecimiento(group)
        if elegido is not None:
            out.append(elegido)
    return out


def codigos_equipos_para_marcas(equipos: Sequence[EquipoFaceid]) -> set[int]:
    """
    Espejo del CTE `equipos` en marcas_raw: TODOS los cod (sin deduplicar).
    Las marcas pueden venir de cualquier dispositivo del mismo nombre.
    """
    return {e.cod for e in equipos}


def enriquecer_turno_por_equipos(
    turno: TurnoClave,
    equipos: Sequence[EquipoFaceid],
    equipos_lw: Sequence[EquipoFaceid] | None = None,
    *,
    dedupe_enriquecimiento: bool = True,
) -> list[dict]:
    """
    Espejo del join en `turnos` por nombre+empresa (ult_conexion / faceid / nuevo_faceid).

    Con dedupe_enriquecimiento=True (fix): ≤1 fila por turno.
    Con False: reproduce el bug (producto cartesiano eq × eq_lw por nombre+empresa).
    """
    nombre = turno.instalacion_rol
    emp = turno.empresa
    eq_match = [e for e in equipos if e.nombre == nombre and e.empresa == emp]
    lw_src = equipos_lw if equipos_lw is not None else []
    lw_match = [e for e in lw_src if e.nombre == nombre and e.empresa == emp]

    if dedupe_enriquecimiento:
        eq_rows = deduplicar_equipos_enriq(eq_match) or [None]
        lw_rows = deduplicar_equipos_enriq(lw_match) or [None]
    else:
        eq_rows = eq_match or [None]
        lw_rows = lw_match or [None]

    filas: list[dict] = []
    for eq in eq_rows:
        for lw in lw_rows:
            instalacion_con_faceid = eq is not None
            nuevo_faceid = (
                turno.instalacion_rol
                if lw is None and eq is not None
                else None
            )
            filas.append(
                {
                    "turno": turno,
                    "ult_conexion": eq.ult_conexion if eq is not None else None,
                    "cod_enriq": eq.cod if eq is not None else None,
                    "instalacion_con_faceid": instalacion_con_faceid,
                    "nuevo_faceid": nuevo_faceid,
                }
            )
    return filas
