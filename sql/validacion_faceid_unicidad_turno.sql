-- Validación SOLO LECTURA: unicidad y universo de cr_reporte_marcacion_faceid.
--
-- Tras leer turnos desde cr_reportes.cr_asistencia_hist_tb (relevos agregados) +
-- QUALIFY 1 fila por (rutasi, her, instalacion_rol, empresa) y exclusión de RUT
-- genéricos 90000001/2/9:
--   * n_filas debe igualar n_turnos_unicos
--   * no debe haber rutasi genérico en el universo
--   * casos conocidos (TIT vs NOR / relevo partido / dos PPC) ≤1 fila por clave
--
-- Cómo usarla
-- -----------
--   bq query --use_legacy_sql=false --maximum_bytes_billed=209715200 \
--     < sql/validacion_faceid_unicidad_turno.sql
--
-- Editar fechas abajo si hace falta. No modifica datos ni redefine la vista.

WITH rango AS (
  SELECT
    DATE('2026-11-17') AS fecha_desde,
    DATE('2026-11-17') AS fecha_hasta
),

base AS (
  SELECT
    v.rutasi,
    v.her,
    v.instalacion_rol,
    v.empresa,
    v.cliente_rol,
    v.ult_conexion,
    v.rutrol,
    v.reemplazo,
    v.nombre_asistente
  FROM `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` v
  CROSS JOIN rango r
  WHERE DATE(v.dia) BETWEEN r.fecha_desde AND r.fecha_hasta
),

totales AS (
  SELECT
    'TOTAL' AS seccion,
    CAST(NULL AS STRING) AS instalacion_rol,
    CAST(NULL AS STRING) AS empresa,
    CAST(NULL AS STRING) AS detalle,
    COUNT(*) AS n_filas,
    COUNT(DISTINCT CONCAT(
      CAST(rutasi AS STRING), '|',
      CAST(her AS STRING), '|',
      CAST(instalacion_rol AS STRING), '|',
      CAST(empresa AS STRING)
    )) AS n_turnos_unicos
  FROM base
),

por_instalacion AS (
  SELECT
    'POR_INSTALACION' AS seccion,
    instalacion_rol,
    empresa,
    CAST(NULL AS STRING) AS detalle,
    COUNT(*) AS n_filas,
    COUNT(DISTINCT CONCAT(
      CAST(rutasi AS STRING), '|',
      CAST(her AS STRING), '|',
      CAST(instalacion_rol AS STRING), '|',
      CAST(empresa AS STRING)
    )) AS n_turnos_unicos
  FROM base
  GROUP BY instalacion_rol, empresa
  HAVING COUNT(*) != COUNT(DISTINCT CONCAT(
    CAST(rutasi AS STRING), '|',
    CAST(her AS STRING), '|',
    CAST(instalacion_rol AS STRING), '|',
    CAST(empresa AS STRING)
  ))
),

-- Diagnóstico: distintas ult_conexion por la misma clave de turno (síntoma del × equipos).
ult_conexion_por_turno AS (
  SELECT
    'ULT_CONEXION_MULTI' AS seccion,
    instalacion_rol,
    empresa,
    CAST(rutasi AS STRING) AS detalle,
    COUNT(*) AS n_filas,
    1 AS n_turnos_unicos
  FROM base
  GROUP BY rutasi, her, instalacion_rol, empresa
  HAVING COUNT(DISTINCT IFNULL(CAST(ult_conexion AS STRING), '<NULL>')) > 1
),

-- Universo: no deben aparecer RUT genéricos ControlRoll.
ruts_genericos AS (
  SELECT
    'RUT_GENERICO' AS seccion,
    instalacion_rol,
    empresa,
    CAST(rutasi AS STRING) AS detalle,
    COUNT(*) AS n_filas,
    0 AS n_turnos_unicos
  FROM base
  WHERE CAST(rutasi AS STRING) IN ('90000001', '90000002', '90000009')
  GROUP BY instalacion_rol, empresa, rutasi
),

-- Casos espejo (ajustar fechas/ruts si el día de validación cambia):
-- 1) INACAP Iquique / rutasi 15685810 → ≤1 fila por clave
-- 2) nombre_asistente no debe contener ' || ' (persona elegida, no concat relevo)
-- 3) UST / rutasi 13665558 → ≤1 fila por clave
casos_conocidos AS (
  SELECT
    'CASO_CLAVE' AS seccion,
    instalacion_rol,
    empresa,
    CONCAT(
      'rutasi=', CAST(rutasi AS STRING),
      ' her=', CAST(her AS STRING)
    ) AS detalle,
    COUNT(*) AS n_filas,
    1 AS n_turnos_unicos
  FROM base
  WHERE CAST(rutasi AS STRING) IN ('15685810', '13665558')
  GROUP BY rutasi, her, instalacion_rol, empresa
  HAVING COUNT(*) > 1
),

nombre_concat_relevo AS (
  SELECT
    'NOMBRE_CONCAT' AS seccion,
    instalacion_rol,
    empresa,
    CAST(rutasi AS STRING) AS detalle,
    COUNT(*) AS n_filas,
    0 AS n_turnos_unicos
  FROM base
  WHERE IFNULL(nombre_asistente, '') LIKE '%||%'
  GROUP BY instalacion_rol, empresa, rutasi
)

SELECT
  seccion,
  instalacion_rol,
  empresa,
  detalle,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM totales

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  detalle,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM por_instalacion

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  detalle,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM ult_conexion_por_turno

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  detalle,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM ruts_genericos

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  detalle,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM casos_conocidos

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  detalle,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM nombre_concat_relevo

ORDER BY seccion, n_duplicadas DESC, empresa, instalacion_rol
;
