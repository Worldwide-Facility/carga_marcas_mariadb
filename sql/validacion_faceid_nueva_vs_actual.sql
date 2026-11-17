-- Validación SOLO LECTURA: impacto de la regla nueva (ventana ±3 h + aceptación + Art. 22)
-- vs la línea base materializada del panel Looker.
--
-- Cómo usarla
-- -----------
-- 1) Medir costo sin ejecutar (dry-run):
--      bq query --use_legacy_sql=false --dry_run \
--        --maximum_bytes_billed=209715200 \
--        < sql/validacion_faceid_nueva_vs_actual.sql
--    Revisar "bytes processed" del dry-run. Tope: 200 MiB (209715200).
--
-- 2) Ejecutar en un rango corto (16–17 nov 2026; editar fechas abajo si hace falta):
--      bq query --use_legacy_sql=false --maximum_bytes_billed=209715200 \
--        < sql/validacion_faceid_nueva_vs_actual.sql
--
-- Interpretación
-- --------------
-- * `vista_nueva` = vista `cr_reporte_marcacion_faceid` (tras desplegar el SQL del PR).
-- * `vista_actual` = tabla Looker `cr_reporte_marcacion_faceid_looker` (última
--   materialización con la lógica previa; se refresca ~cada 2 h / ~349 MiB por corrida).
-- * Correr justo después de CREATE OR REPLACE VIEW y ANTES del próximo job Looker
--   para ver el delta de estados. Si ambas ya comparten lógica, el diff de detalle
--   estará vacío (solo quedan totales).
--
-- No modifica datos ni redefine la vista.

WITH rango AS (
  SELECT
    DATE('2026-11-16') AS fecha_desde,
    DATE('2026-11-17') AS fecha_hasta
),

vista_nueva AS (
  SELECT
    DATE(v.dia) AS dia,
    v.empresa,
    v.zona,
    v.estado
  FROM `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` v
  CROSS JOIN rango r
  WHERE DATE(v.dia) BETWEEN r.fecha_desde AND r.fecha_hasta
),

vista_actual AS (
  SELECT
    DATE(v.dia) AS dia,
    v.empresa,
    v.zona,
    v.estado
  FROM `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid_looker` v
  CROSS JOIN rango r
  WHERE DATE(v.dia) BETWEEN r.fecha_desde AND r.fecha_hasta
),

agg_nueva AS (
  SELECT empresa, zona, estado, COUNT(*) AS n
  FROM vista_nueva
  GROUP BY 1, 2, 3
),

agg_actual AS (
  SELECT empresa, zona, estado, COUNT(*) AS n
  FROM vista_actual
  GROUP BY 1, 2, 3
),

comparacion AS (
  SELECT
    COALESCE(n.empresa, a.empresa) AS empresa,
    COALESCE(n.zona, a.zona) AS zona,
    COALESCE(n.estado, a.estado) AS estado,
    IFNULL(a.n, 0) AS n_actual_looker,
    IFNULL(n.n, 0) AS n_nueva_vista,
    IFNULL(n.n, 0) - IFNULL(a.n, 0) AS delta
  FROM agg_nueva n
  FULL OUTER JOIN agg_actual a
    ON n.empresa = a.empresa
   AND ((n.zona IS NULL AND a.zona IS NULL) OR n.zona = a.zona)
   AND ((n.estado IS NULL AND a.estado IS NULL) OR n.estado = a.estado)
),

totales_estado AS (
  SELECT
    'TOTAL_POR_ESTADO' AS seccion,
    CAST(NULL AS STRING) AS empresa,
    CAST(NULL AS STRING) AS zona,
    COALESCE(n.estado, a.estado) AS estado,
    IFNULL(a.n, 0) AS n_actual_looker,
    IFNULL(n.n, 0) AS n_nueva_vista,
    IFNULL(n.n, 0) - IFNULL(a.n, 0) AS delta
  FROM (
    SELECT estado, COUNT(*) AS n FROM vista_nueva GROUP BY 1
  ) n
  FULL OUTER JOIN (
    SELECT estado, COUNT(*) AS n FROM vista_actual GROUP BY 1
  ) a
    ON ((n.estado IS NULL AND a.estado IS NULL) OR n.estado = a.estado)
)

SELECT
  'DETALLE_EMPRESA_ZONA_ESTADO' AS seccion,
  empresa,
  zona,
  estado,
  n_actual_looker,
  n_nueva_vista,
  delta
FROM comparacion
WHERE delta != 0

UNION ALL

SELECT * FROM totales_estado

ORDER BY seccion, empresa, zona, estado
;
