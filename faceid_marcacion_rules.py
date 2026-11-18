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
