-- Validación SOLO LECTURA: filas vs turnos únicos en cr_reporte_marcacion_faceid.
--
-- Tras los fixes de:
--   * joins de cargos (empresa de c/d, no de b)
--   * dedupe de equipos_enriq / equipos_lw_enriq (1 fila por nombre+empresa;
--     marcas_raw sigue usando todos los cod)
-- n_filas debe igualar n_turnos_unicos para (rutasi, her, instalacion_rol, empresa).
--
-- Cómo usarla
-- -----------
--   bq query --use_legacy_sql=false --maximum_bytes_billed=209715200 \
--     < sql/validacion_faceid_unicidad_turno.sql
--
-- Editar fechas abajo si hace falta. No modifica datos ni redefine la vista.
-- Caso conocido pre-fix equipos: INACAP COPIAPO Security N2 17/11 → ×4 por
-- (eq × eq_lw) con 2 equipos cada uno (p. ej. 2657 ult_conexion NULL, 2658 reciente).

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
    v.ult_conexion
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
),

-- Diagnóstico: distintas ult_conexion por la misma clave de turno (síntoma del × equipos).
-- IFNULL: COUNT DISTINCT en BQ ignora NULL; sin eso NULL+timestamp contaría como 1.
ult_conexion_por_turno AS (
  SELECT
    'ULT_CONEXION_MULTI' AS seccion,
    instalacion_rol,
    empresa,
    COUNT(*) AS n_filas,
    1 AS n_turnos_unicos
  FROM base
  GROUP BY rutasi, her, instalacion_rol, empresa
  HAVING COUNT(DISTINCT IFNULL(CAST(ult_conexion AS STRING), '<NULL>')) > 1
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

UNION ALL

SELECT
  seccion,
  instalacion_rol,
  empresa,
  n_filas,
  n_turnos_unicos,
  n_filas - n_turnos_unicos AS n_duplicadas
FROM ult_conexion_por_turno

ORDER BY seccion, n_duplicadas DESC, empresa, instalacion_rol
;
