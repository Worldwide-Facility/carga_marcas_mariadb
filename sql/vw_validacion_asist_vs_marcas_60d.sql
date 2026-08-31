-- Vista: validación asistencias PRESENTES (60d) vs marcas MariaDB
-- worldwide-470917.cr_vistas_reporte.vw_validacion_asist_vs_marcas_60d
--
-- Solo tipo_de_servicio = 1 Servicio (asistencia = 1).
--
-- Cruce por SESIÓN (no por bloque persona-día):
--   - Persona efectiva: PPC C / Ausente C → rutasi; resto → rutrol
--   - RUT cuerpo sin DV (MariaDB trae DV: se recorta el último carácter)
--   - Cada fila de marcas es una sesión. NO se agrega MIN/MAX del día:
--     dos filas el mismo día (~1 min de gap) son dos turnos seguidos, no colación.
--   - Marca sin salida: se cierra con el siguiente evento de la misma persona
--     si cae dentro de 16 h.
--   - Match si solape(sesión, [her−90min, hsr+90min]) >= 20 min
--   - 1:1 greedy (mejor solape) + 2º pase para turnos que perdieron su 1ª marca
--   - Colación no se marca en MariaDB; no entra a este cruce
--   - Se ignoran marcas SPOT y SUPERVISION (nombrecargo)
--
-- Hist: horas_cubiertas_reales excluye Apoyo General (tramos del relevo).
--
-- Desplegar:
--   bq query --use_legacy_sql=false < carga_marcas_mariadb/sql/vw_validacion_asist_vs_marcas_60d.sql

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.vw_validacion_asist_vs_marcas_60d` AS
WITH dic AS (
  SELECT
    empresa,
    cliente_rol,
    instalacion_rol,
    sensorid,
    nombre_local_principal,
    codcecoscr
  FROM `worldwide-470917.cr_reportes.diccionario_marcas_instalaciones`
  WHERE estado = 'match'
),

asist_raw AS (
  SELECT
    a.empresa,
    a.cliente_rol,
    a.instalacion_rol,
    a.nombrerol,
    a.rutrol,
    a.rutasi,
    a.relevo,
    TRIM(ARRAY_REVERSE(SPLIT(IFNULL(a.relevo, ''), ' | '))[SAFE_OFFSET(0)]) AS nombre_quien_cubrio,
    a.cargo,
    a.turno,
    a.tipo,
    a.dia,
    a.her,
    a.hsr,
    a.entrada,
    a.salida,
    a.fechamarcaentrada,
    a.fechamarcasalida,
    a.asistencia,
    a.asistencia_final,
    a.COB,
    a.horas_entregadas,
    a.horas_planificadas,
    d.sensorid,
    d.nombre_local_principal,
    d.codcecoscr,
    DATE(a.dia) AS fecha_turno,
    COALESCE(a.fechamarcasalida, a.salida) AS hora_ref_salida,
    CASE
      WHEN a.fechamarcasalida IS NOT NULL THEN 'fechamarcasalida'
      WHEN a.salida IS NOT NULL THEN 'salida'
      ELSE NULL
    END AS fuente_hora_ref_salida,
    REGEXP_REPLACE(UPPER(TRIM(CAST(a.rutrol AS STRING))), r'[^0-9K]', '') AS rutrol_raw,
    REGEXP_REPLACE(UPPER(TRIM(CAST(a.rutasi AS STRING))), r'[^0-9K]', '') AS rutasi_raw,
    UPPER(TRIM(a.COB)) AS cob_norm
  FROM `worldwide-470917.cr_reportes.cr_asistencia_hist_tb` a
  INNER JOIN dic d
    ON UPPER(TRIM(a.instalacion_rol)) = UPPER(TRIM(d.instalacion_rol))
   AND UPPER(TRIM(a.empresa)) = UPPER(TRIM(d.empresa))
  WHERE DATE(a.dia) >= DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 60 DAY)
    AND a.asistencia = 1
    AND TRIM(CAST(a.tipo_de_servicio AS STRING)) = '1 Servicio'
),

asist_base AS (
  SELECT
    * EXCEPT (rutrol_raw, rutasi_raw),
    REGEXP_REPLACE(rutrol_raw, r'[^0-9]', '') AS rutrol_body,
    REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '') AS rutasi_body,
    CASE
      WHEN cob_norm IN ('PPC C', 'AUSENTE C')
        AND REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '') NOT IN ('', '90000001', '90000002', '90000009')
        AND LENGTH(REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '')) >= 6
        THEN REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '')
      ELSE REGEXP_REPLACE(rutrol_raw, r'[^0-9]', '')
    END AS rut_efectivo_body,
    CASE
      WHEN cob_norm IN ('PPC C', 'AUSENTE C')
        AND REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '') NOT IN ('', '90000001', '90000002', '90000009')
        AND LENGTH(REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '')) >= 6
        THEN 'rutasi'
      ELSE 'rutrol'
    END AS fuente_rut_efectivo,
    REGEXP_CONTAINS(UPPER(IFNULL(relevo, '')), r'APOYO\s+GENERAL|90000009') AS tiene_apoyo_general
  FROM asist_raw
  WHERE LENGTH(REGEXP_REPLACE(rutrol_raw, r'[^0-9]', '')) >= 6
     OR (
          cob_norm IN ('PPC C', 'AUSENTE C')
          AND LENGTH(REGEXP_REPLACE(rutasi_raw, r'[^0-9]', '')) >= 6
        )
),

-- Tramos del relevo: "RUT | H:MMAM / H:MMPM | NOMBRE"
relevo_tramos AS (
  SELECT
    b.empresa,
    b.instalacion_rol,
    b.rutrol_body,
    b.her,
    b.hsr,
    b.rut_efectivo_body,
    b.tiene_apoyo_general,
    REGEXP_REPLACE(REGEXP_EXTRACT(TRIM(seg), r'^([0-9Kk]+)'), r'[^0-9]', '') AS rut_tramo,
    UPPER(TRIM(ARRAY_REVERSE(SPLIT(TRIM(seg), '|'))[SAFE_OFFSET(0)])) AS nombre_tramo,
    UPPER(TRIM(REGEXP_EXTRACT(seg, r'\|\s*([^/]+)'))) AS hora_ini_txt,
    UPPER(TRIM(REGEXP_EXTRACT(seg, r'/\s*([^|]+)'))) AS hora_fin_txt,
    SAFE.PARSE_TIME(
      '%I:%M%p',
      IF(
        LENGTH(REGEXP_EXTRACT(UPPER(TRIM(REGEXP_EXTRACT(seg, r'\|\s*([^/]+)'))), r'^(\d+)')) = 1,
        CONCAT('0', UPPER(TRIM(REGEXP_EXTRACT(seg, r'\|\s*([^/]+)')))),
        UPPER(TRIM(REGEXP_EXTRACT(seg, r'\|\s*([^/]+)')))
      )
    ) AS time_ini,
    SAFE.PARSE_TIME(
      '%I:%M%p',
      IF(
        LENGTH(REGEXP_EXTRACT(UPPER(TRIM(REGEXP_EXTRACT(seg, r'/\s*([^|]+)'))), r'^(\d+)')) = 1,
        CONCAT('0', UPPER(TRIM(REGEXP_EXTRACT(seg, r'/\s*([^|]+)')))),
        UPPER(TRIM(REGEXP_EXTRACT(seg, r'/\s*([^|]+)')))
      )
    ) AS time_fin
  FROM asist_base b
  CROSS JOIN UNNEST(SPLIT(IFNULL(b.relevo, ''), '||')) AS seg
  WHERE TRIM(seg) != ''
),

relevo_tramos_horas AS (
  SELECT
    empresa,
    instalacion_rol,
    rutrol_body,
    her,
    hsr,
    rut_efectivo_body,
    rut_tramo,
    nombre_tramo,
    (
      rut_tramo IN ('90000001', '90000002', '90000009')
      OR REGEXP_CONTAINS(IFNULL(nombre_tramo, ''), r'APOYO\s+GENERAL')
    ) AS es_apoyo,
    DATETIME(DATE(her), time_ini) AS hora_inicio_tramo,
    CASE
      WHEN time_ini IS NULL THEN NULL
      WHEN time_fin IS NULL
        OR REGEXP_CONTAINS(IFNULL(hora_fin_txt, ''), r'^0:00')
        OR time_fin = TIME '00:00:00'
        THEN hsr
      WHEN DATETIME(DATE(her), time_fin) <= DATETIME(DATE(her), time_ini)
        THEN DATETIME_ADD(DATETIME(DATE(her), time_fin), INTERVAL 1 DAY)
      ELSE DATETIME(DATE(her), time_fin)
    END AS hora_fin_tramo
  FROM relevo_tramos
  WHERE time_ini IS NOT NULL
),

relevo_hora_persona AS (
  SELECT
    empresa,
    instalacion_rol,
    rutrol_body,
    her,
    rut_efectivo_body,
    ANY_VALUE(hora_inicio_tramo) AS hora_ref_desde_relevo
  FROM relevo_tramos_horas
  WHERE rut_tramo = rut_efectivo_body
    AND NOT es_apoyo
  GROUP BY 1, 2, 3, 4, 5
),

horas_por_turno AS (
  SELECT
    empresa,
    instalacion_rol,
    rutrol_body,
    her,
    ROUND(SUM(IF(es_apoyo, 0, DATETIME_DIFF(hora_fin_tramo, hora_inicio_tramo, MINUTE) / 60.0)), 2)
      AS horas_cubiertas_reales,
    ROUND(SUM(IF(es_apoyo, DATETIME_DIFF(hora_fin_tramo, hora_inicio_tramo, MINUTE) / 60.0, 0)), 2)
      AS horas_apoyo_excluidas,
    COUNTIF(NOT es_apoyo) AS n_tramos_reales,
    COUNTIF(es_apoyo) AS n_tramos_apoyo
  FROM relevo_tramos_horas
  WHERE hora_fin_tramo IS NOT NULL
    AND hora_fin_tramo > hora_inicio_tramo
  GROUP BY 1, 2, 3, 4
),

asist_norm AS (
  SELECT
    b.* EXCEPT (tiene_apoyo_general),
    CASE
      WHEN b.fechamarcaentrada IS NOT NULL THEN b.fechamarcaentrada
      WHEN b.tiene_apoyo_general AND r.hora_ref_desde_relevo IS NOT NULL THEN r.hora_ref_desde_relevo
      ELSE b.entrada
    END AS hora_ref_entrada,
    CASE
      WHEN b.fechamarcaentrada IS NOT NULL THEN 'fechamarcaentrada'
      WHEN b.tiene_apoyo_general AND r.hora_ref_desde_relevo IS NOT NULL THEN 'relevo_persona'
      WHEN b.entrada IS NOT NULL THEN 'entrada'
      ELSE NULL
    END AS fuente_hora_ref_entrada,
    COALESCE(
      h.horas_cubiertas_reales,
      ROUND(
        DATETIME_DIFF(
          COALESCE(b.fechamarcasalida, b.salida, b.hsr),
          COALESCE(b.fechamarcaentrada, b.entrada, b.her),
          MINUTE
        ) / 60.0,
        2
      )
    ) AS horas_cubiertas_reales,
    IFNULL(h.horas_apoyo_excluidas, 0) AS horas_apoyo_excluidas,
    IFNULL(h.n_tramos_reales, 0) AS n_tramos_reales,
    IFNULL(h.n_tramos_apoyo, 0) AS n_tramos_apoyo
  FROM asist_base b
  LEFT JOIN relevo_hora_persona r
    ON b.empresa = r.empresa
   AND b.instalacion_rol = r.instalacion_rol
   AND b.rutrol_body = r.rutrol_body
   AND b.her = r.her
   AND b.rut_efectivo_body = r.rut_efectivo_body
  LEFT JOIN horas_por_turno h
    ON b.empresa = h.empresa
   AND b.instalacion_rol = h.instalacion_rol
   AND b.rutrol_body = h.rutrol_body
   AND b.her = h.her
),

marcas_raw AS (
  SELECT
    m.sensorid,
    m.nombre_local,
    m.formato,
    m.rutpersona,
    m.nombrepersona,
    m.fecha,
    m.entrada,
    m.salida,
    m.total,
    FARM_FINGERPRINT(
      CONCAT(CAST(m.sensorid AS STRING), '|', IFNULL(m.rutpersona, ''), '|', CAST(m.entrada AS STRING))
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
    END AS horas_fila
  FROM `worldwide-470917.cr_reportes.marcas_mariadb` m
  WHERE DATE(m.entrada) >= DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 60 DAY)
    AND LENGTH(IFNULL(m.rutpersona, '')) >= 6
    AND UPPER(IFNULL(m.nombrecargo, '')) NOT LIKE '%SPOT%'
    AND NOT REGEXP_CONTAINS(UPPER(IFNULL(m.nombrecargo, '')), r'SUPERVISI[OÓ]N')
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

-- Sesión: no compactar el día. Cierra marcas abiertas con el siguiente evento (<= 16 h).
marcas_sesion AS (
  SELECT
    sensorid,
    nombre_local,
    formato,
    rutpersona,
    nombrepersona,
    fecha,
    entrada,
    rut_body,
    marca_id,
    total,
    COALESCE(
      salida,
      IF(
        lead_entrada IS NOT NULL
          AND DATETIME_DIFF(lead_entrada, entrada, HOUR) BETWEEN 0 AND 16,
        lead_entrada,
        NULL
      )
    ) AS salida_eff,
    CASE
      WHEN IFNULL(horas_fila, 0) > 0.02 THEN horas_fila
      WHEN salida IS NOT NULL THEN horas_fila
      WHEN lead_entrada IS NOT NULL
        AND DATETIME_DIFF(lead_entrada, entrada, HOUR) BETWEEN 0 AND 16
        THEN ROUND(DATETIME_DIFF(lead_entrada, entrada, SECOND) / 3600.0, 2)
      ELSE horas_fila
    END AS horas_sesion
  FROM marcas_lead
),

cand AS (
  SELECT
    a.empresa,
    a.instalacion_rol,
    a.rutrol_body,
    a.her,
    a.hsr,
    a.hora_ref_entrada,
    a.hora_ref_salida,
    m.marca_id,
    m.entrada AS entrada_marca,
    m.salida_eff AS salida_marca,
    m.total AS total_marca,
    m.horas_sesion AS horas_marca_mariadb,
    m.sensorid,
    m.nombre_local,
    m.formato,
    m.rutpersona,
    m.nombrepersona,
    DATETIME_DIFF(
      LEAST(
        COALESCE(m.salida_eff, DATETIME_ADD(m.entrada, INTERVAL 1 MINUTE)),
        DATETIME_ADD(a.hsr, INTERVAL 90 MINUTE)
      ),
      GREATEST(m.entrada, DATETIME_SUB(a.her, INTERVAL 90 MINUTE)),
      MINUTE
    ) AS overlap_min,
    TIMESTAMP_DIFF(m.entrada, a.hora_ref_entrada, MINUTE) AS diff_min_entrada_vs_ref,
    TIMESTAMP_DIFF(m.salida_eff, a.hora_ref_salida, MINUTE) AS diff_min_salida_vs_ref
  FROM asist_norm a
  INNER JOIN marcas_sesion m
    ON a.rut_efectivo_body = m.rut_body
   AND m.entrada < DATETIME_ADD(a.hsr, INTERVAL 90 MINUTE)
   AND COALESCE(m.salida_eff, m.entrada) > DATETIME_SUB(a.her, INTERVAL 90 MINUTE)
),

ok AS (
  SELECT *
  FROM cand
  WHERE overlap_min >= 20
     OR (salida_marca IS NULL AND ABS(IFNULL(diff_min_entrada_vs_ref, 9999)) <= 90)
),

p1_t AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY empresa, instalacion_rol, rutrol_body, her
      ORDER BY overlap_min DESC, ABS(IFNULL(diff_min_entrada_vs_ref, 0)) ASC
    ) AS rn_t
  FROM ok
),

p1_m AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY marca_id
      ORDER BY overlap_min DESC, her ASC
    ) AS rn_m
  FROM p1_t
  WHERE rn_t = 1
),

asig1 AS (
  SELECT
    empresa,
    instalacion_rol,
    rutrol_body,
    her,
    marca_id,
    entrada_marca,
    salida_marca,
    total_marca,
    horas_marca_mariadb,
    sensorid,
    nombre_local,
    formato,
    rutpersona,
    nombrepersona,
    overlap_min,
    diff_min_entrada_vs_ref,
    diff_min_salida_vs_ref,
    1 AS pase
  FROM p1_m
  WHERE rn_m = 1
),

t_libres AS (
  SELECT a.*
  FROM asist_norm a
  LEFT JOIN asig1 x
    ON a.empresa = x.empresa
   AND a.instalacion_rol = x.instalacion_rol
   AND a.rutrol_body = x.rutrol_body
   AND a.her = x.her
  WHERE x.marca_id IS NULL
),

m_libres AS (
  SELECT m.*
  FROM marcas_sesion m
  LEFT JOIN asig1 x ON m.marca_id = x.marca_id
  WHERE x.marca_id IS NULL
),

cand2 AS (
  SELECT
    a.empresa,
    a.instalacion_rol,
    a.rutrol_body,
    a.her,
    a.hsr,
    a.hora_ref_entrada,
    a.hora_ref_salida,
    m.marca_id,
    m.entrada AS entrada_marca,
    m.salida_eff AS salida_marca,
    m.total AS total_marca,
    m.horas_sesion AS horas_marca_mariadb,
    m.sensorid,
    m.nombre_local,
    m.formato,
    m.rutpersona,
    m.nombrepersona,
    DATETIME_DIFF(
      LEAST(
        COALESCE(m.salida_eff, DATETIME_ADD(m.entrada, INTERVAL 1 MINUTE)),
        DATETIME_ADD(a.hsr, INTERVAL 90 MINUTE)
      ),
      GREATEST(m.entrada, DATETIME_SUB(a.her, INTERVAL 90 MINUTE)),
      MINUTE
    ) AS overlap_min,
    TIMESTAMP_DIFF(m.entrada, a.hora_ref_entrada, MINUTE) AS diff_min_entrada_vs_ref,
    TIMESTAMP_DIFF(m.salida_eff, a.hora_ref_salida, MINUTE) AS diff_min_salida_vs_ref
  FROM t_libres a
  INNER JOIN m_libres m
    ON a.rut_efectivo_body = m.rut_body
   AND m.entrada < DATETIME_ADD(a.hsr, INTERVAL 90 MINUTE)
   AND COALESCE(m.salida_eff, m.entrada) > DATETIME_SUB(a.her, INTERVAL 90 MINUTE)
),

p2_t AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY empresa, instalacion_rol, rutrol_body, her
      ORDER BY overlap_min DESC, ABS(IFNULL(diff_min_entrada_vs_ref, 0)) ASC
    ) AS rn_t
  FROM cand2
  WHERE overlap_min >= 20
     OR (salida_marca IS NULL AND ABS(IFNULL(diff_min_entrada_vs_ref, 9999)) <= 90)
),

p2_m AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY marca_id
      ORDER BY overlap_min DESC, her ASC
    ) AS rn_m
  FROM p2_t
  WHERE rn_t = 1
),

asig2 AS (
  SELECT
    empresa,
    instalacion_rol,
    rutrol_body,
    her,
    marca_id,
    entrada_marca,
    salida_marca,
    total_marca,
    horas_marca_mariadb,
    sensorid,
    nombre_local,
    formato,
    rutpersona,
    nombrepersona,
    overlap_min,
    diff_min_entrada_vs_ref,
    diff_min_salida_vs_ref,
    2 AS pase
  FROM p2_m
  WHERE rn_m = 1
),

asig AS (
  SELECT * FROM asig1
  UNION ALL
  SELECT * FROM asig2
),

ranked AS (
  SELECT
    a.empresa,
    a.cliente_rol,
    a.instalacion_rol,
    a.sensorid,
    a.nombre_local_principal,
    a.codcecoscr,
    a.nombrerol,
    a.rutrol,
    a.rutrol_body,
    a.rutasi,
    a.rutasi_body,
    a.relevo,
    a.nombre_quien_cubrio,
    a.fuente_rut_efectivo,
    a.rut_efectivo_body,
    a.cargo,
    a.turno,
    a.tipo,
    a.fecha_turno,
    a.her,
    a.hsr,
    a.entrada,
    a.salida,
    a.fechamarcaentrada,
    a.fechamarcasalida,
    a.hora_ref_entrada,
    a.fuente_hora_ref_entrada,
    a.hora_ref_salida,
    a.fuente_hora_ref_salida,
    a.COB,
    a.horas_entregadas,
    a.horas_planificadas,
    a.horas_cubiertas_reales,
    a.horas_apoyo_excluidas,
    a.n_tramos_reales,
    a.n_tramos_apoyo,
    t.entrada_marca,
    t.salida_marca,
    t.total_marca,
    t.horas_marca_mariadb,
    t.sensorid AS sensorid_marca,
    t.nombre_local AS nombre_local_marca,
    t.formato AS formato_marca,
    t.rutpersona AS rutpersona_marca,
    t.nombrepersona AS nombrepersona_marca,
    t.diff_min_entrada_vs_ref,
    t.diff_min_salida_vs_ref,
    t.overlap_min,
    t.pase,
    (
      a.hora_ref_salida IS NOT NULL
      AND t.salida_marca IS NOT NULL
      AND DATETIME(t.salida_marca) BETWEEN
          DATETIME_SUB(a.hora_ref_salida, INTERVAL 90 MINUTE)
      AND DATETIME_ADD(a.hora_ref_salida, INTERVAL 90 MINUTE)
    ) AS match_salida
  FROM asist_norm a
  LEFT JOIN asig t
    ON a.empresa = t.empresa
   AND a.instalacion_rol = t.instalacion_rol
   AND a.rutrol_body = t.rutrol_body
   AND a.her = t.her
)

SELECT
  empresa,
  cliente_rol,
  instalacion_rol,
  sensorid,
  nombre_local_principal,
  codcecoscr,
  nombrerol,
  rutrol,
  rutrol_body,
  rutasi,
  rutasi_body,
  relevo,
  nombre_quien_cubrio,
  fuente_rut_efectivo,
  rut_efectivo_body,
  cargo,
  turno,
  tipo,
  fecha_turno,
  her,
  hsr,
  entrada,
  salida,
  fechamarcaentrada,
  fechamarcasalida,
  hora_ref_entrada,
  fuente_hora_ref_entrada,
  hora_ref_salida,
  fuente_hora_ref_salida,
  COB,
  horas_planificadas,
  horas_entregadas,
  horas_cubiertas_reales,
  horas_apoyo_excluidas,
  n_tramos_reales,
  n_tramos_apoyo,
  entrada_marca,
  salida_marca,
  total_marca,
  horas_marca_mariadb,
  IF(entrada_marca IS NULL, NULL, 1) AS n_eventos_marca_dia,
  CAST(sensorid_marca AS STRING) AS sensores_marca,
  nombre_local_marca,
  formato_marca,
  rutpersona_marca,
  nombrepersona_marca,
  diff_min_entrada_vs_ref,
  diff_min_salida_vs_ref,
  overlap_min,
  pase,
  CASE WHEN entrada_marca IS NOT NULL THEN TRUE ELSE FALSE END AS match_entrada,
  match_salida,
  CASE WHEN entrada_marca IS NULL THEN TRUE ELSE FALSE END AS sin_marca_entrada,
  CASE
    WHEN hora_ref_salida IS NULL THEN NULL
    WHEN entrada_marca IS NULL THEN NULL
    WHEN match_salida THEN FALSE
    ELSE TRUE
  END AS sin_marca_salida,
  CASE WHEN entrada_marca IS NULL THEN TRUE ELSE FALSE END AS sin_marca_mariadb
FROM ranked
;
