-- Vista: jornadas reconstruidas desde marcas MariaDB
-- worldwide-470917.cr_vistas_reporte.vw_marcas_mariadb_jornada
--
-- Una fila = una sesión/jornada de MariaDB (no se compacta el día).
-- Se conservan TODAS las filas, incluidas marcas intermedias (punches cortos
-- entre dos turnos, p.ej. 15:30–15:31).
-- Dos filas el mismo día (~1 min de gap) son dos turnos seguidos, no colación.
--
--   - Incluye permanente, SPOT y SUPERVISION (columna tipo_cargo)
--   - tipo_marca: jornada | intermedia | abierta
--       intermedia = salida real y duración < 15 min (punch extra / handover)
--   - RUT cuerpo sin DV (MariaDB trae DV: se recorta el último carácter)
--   - Marca sin salida: se cierra con el siguiente evento de la misma persona
--     si cae dentro de 16 h (la fila intermedia siguiente sigue visible)
--   - Diccionario (LEFT JOIN): empresa / instalación CR cuando hay match
--   - nombre_local y formato: campos de la tabla marcas MariaDB (sin catálogo extra)
--
-- Desplegar:
--   bq query --use_legacy_sql=false < carga_marcas_mariadb/sql/vw_marcas_mariadb_jornada.sql

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.vw_marcas_mariadb_jornada` AS
WITH dic AS (
  SELECT
    CAST(sensorid AS INT64) AS sensorid,
    empresa,
    cliente_rol,
    instalacion_rol,
    nombre_local_principal,
    codcecoscr,
    comuna,
    region
  FROM `worldwide-470917.cr_reportes.diccionario_marcas_instalaciones`
  WHERE estado = 'match'
),

marcas_raw AS (
  SELECT
    m.fecha,
    CAST(m.sensorid AS INT64) AS sensorid,
    m.rutpersona,
    m.entrada,
    m.salida,
    m.total,
    m.rutproveedor,
    m.nombreproveedor,
    m.nombrecargo,
    m.nombrepersona,
    NULLIF(TRIM(m.nombre_local), '') AS nombre_local,
    NULLIF(TRIM(m.formato), '') AS formato,
    FARM_FINGERPRINT(
      CONCAT(
        CAST(m.sensorid AS STRING),
        '|',
        IFNULL(m.rutpersona, ''),
        '|',
        CAST(m.entrada AS STRING)
      )
    ) AS marca_id,
    REGEXP_REPLACE(UPPER(TRIM(m.rutpersona)), r'[^0-9K]', '') AS rut_raw,
    CASE
      WHEN m.total IS NOT NULL AND TRIM(m.total) != ''
        AND REGEXP_CONTAINS(TRIM(m.total), r'^\d{1,2}:\d{2}(:\d{2})?$')
        THEN ROUND(
          (
            CAST(SPLIT(TRIM(m.total), ':')[SAFE_OFFSET(0)] AS INT64) * 3600
            + CAST(SPLIT(TRIM(m.total), ':')[SAFE_OFFSET(1)] AS INT64) * 60
            + IFNULL(CAST(SPLIT(TRIM(m.total), ':')[SAFE_OFFSET(2)] AS INT64), 0)
          ) / 3600.0,
          2
        )
      WHEN m.entrada IS NOT NULL AND m.salida IS NOT NULL
        THEN ROUND(DATETIME_DIFF(m.salida, m.entrada, SECOND) / 3600.0, 2)
      ELSE 0
    END AS horas_fila,
    CASE
      WHEN UPPER(IFNULL(m.nombrecargo, '')) LIKE '%SPOT%' THEN 'spot'
      WHEN REGEXP_CONTAINS(UPPER(IFNULL(m.nombrecargo, '')), r'SUPERVISI[OÓ]N') THEN 'supervision'
      WHEN UPPER(IFNULL(m.nombrecargo, '')) LIKE '%PERMANENTE%' THEN 'permanente'
      ELSE 'otro'
    END AS tipo_cargo
  FROM `worldwide-470917.cr_reportes.marcas_mariadb` m
  WHERE LENGTH(IFNULL(m.rutpersona, '')) >= 6
),

marcas_norm AS (
  SELECT
    * EXCEPT (rut_raw),
    CASE
      WHEN LENGTH(rut_raw) >= 2
        THEN REGEXP_REPLACE(SUBSTR(rut_raw, 1, LENGTH(rut_raw) - 1), r'[^0-9]', '')
      ELSE REGEXP_REPLACE(rut_raw, r'[^0-9]', '')
    END AS rut_body
  FROM marcas_raw
),

marcas_lead AS (
  SELECT
    *,
    LEAD(entrada) OVER (PARTITION BY rut_body ORDER BY entrada) AS lead_entrada
  FROM marcas_norm
),

jornada AS (
  SELECT
    marca_id,
    sensorid,
    nombre_local,
    formato,
    rutpersona,
    rut_body,
    nombrepersona,
    nombrecargo,
    tipo_cargo,
    rutproveedor,
    nombreproveedor,
    fecha,
    DATE(entrada) AS fecha_jornada,
    entrada,
    salida,
    COALESCE(
      salida,
      IF(
        lead_entrada IS NOT NULL
          AND DATETIME_DIFF(lead_entrada, entrada, HOUR) BETWEEN 0 AND 16,
        lead_entrada,
        NULL
      )
    ) AS salida_efectiva,
    (salida IS NULL) AS jornada_abierta,
    (
      salida IS NULL
      AND lead_entrada IS NOT NULL
      AND DATETIME_DIFF(lead_entrada, entrada, HOUR) BETWEEN 0 AND 16
    ) AS cierre_por_siguiente_evento,
    total,
    CASE
      WHEN IFNULL(horas_fila, 0) > 0.02 THEN horas_fila
      WHEN salida IS NOT NULL THEN horas_fila
      WHEN lead_entrada IS NOT NULL
        AND DATETIME_DIFF(lead_entrada, entrada, HOUR) BETWEEN 0 AND 16
        THEN ROUND(DATETIME_DIFF(lead_entrada, entrada, SECOND) / 3600.0, 2)
      ELSE horas_fila
    END AS horas_jornada,
    CASE
      WHEN salida IS NOT NULL
        AND DATETIME_DIFF(salida, entrada, SECOND) < 15 * 60
        THEN 'intermedia'
      WHEN salida IS NULL THEN 'abierta'
      ELSE 'jornada'
    END AS tipo_marca
  FROM marcas_lead
),

jornada_dia AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY rut_body, fecha_jornada
      ORDER BY entrada
    ) AS orden_jornada_dia,
    COUNT(*) OVER (PARTITION BY rut_body, fecha_jornada) AS n_jornadas_persona_dia
  FROM jornada
)

SELECT
  j.marca_id,
  j.sensorid,
  d.empresa,
  d.cliente_rol,
  d.instalacion_rol,
  d.nombre_local_principal,
  d.codcecoscr,
  d.comuna,
  d.region,
  j.nombre_local,
  j.formato,
  j.rutpersona,
  j.rut_body,
  j.nombrepersona,
  j.nombrecargo,
  j.tipo_cargo,
  j.tipo_marca,
  j.orden_jornada_dia,
  j.n_jornadas_persona_dia,
  (j.tipo_marca = 'intermedia') AS es_marca_intermedia,
  j.rutproveedor,
  j.nombreproveedor,
  j.fecha,
  j.fecha_jornada,
  j.entrada,
  j.salida,
  j.salida_efectiva,
  j.jornada_abierta,
  j.cierre_por_siguiente_evento,
  j.total,
  j.horas_jornada,
  (d.instalacion_rol IS NOT NULL) AS en_diccionario
FROM jornada_dia j
LEFT JOIN dic d
  ON j.sensorid = d.sensorid
;
