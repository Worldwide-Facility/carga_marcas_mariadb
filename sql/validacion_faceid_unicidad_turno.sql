-- Validación SOLO LECTURA: filas vs turnos únicos en cr_reporte_marcacion_faceid.
--
-- Tras el fix de joins de cargos (empresa de c/d, no de b), n_filas debe igualar
-- n_turnos_unicos para la clave (rutasi, her, instalacion_rol, empresa).
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
    v.cliente_rol
  FROM `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` v
  CROSS JOIN rango r
  WHERE DATE(v.dia) BETWEEN r.fecha_desde AND r.fecha_hasta
),

totales AS (
  SELECT
    'TOTAL' AS seccion,
    CAST(NULL AS STRING) AS instalacion_rol,
    CAST(NULL AS STRING) AS empresa,
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
)

SELECT
  seccion,
  instalacion_rol,
  empresa,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM totales

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM por_instalacion

ORDER BY seccion, n_duplicadas DESC, empresa, instalacion_rol
;
