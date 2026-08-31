-- Vista: worldwide-470917.cr_vistas_reporte.cr_asistencia_hist_48
-- Hist de asistencia últimos 2 días (fuente cr_asistencia_semanal).
--
-- Relevos parciales: uncover_agg compacta N coberturas EXR/TIT del mismo
-- turno en 1 fila (MIN entrada, MAX salida, STRING_AGG relevo).
-- TIT vs NOR duplicado: se conserva el TIT (puesto original + cubridor en rutasi)
-- y se omite el NOR del cubridor en el mismo instalacion+turno+her.
-- Dummy ControlRoll 90000001/2/9: si el mismo titular tiene persona real
-- (NOR, EXR o TIT) en el slot, el dummy es hueco (atraso o tramo sin cubrir),
-- no turno descubierto. Se conserva la persona real (asistencia=1).
--
-- Desplegar:
--   bq query --use_legacy_sql=false < carga_marcas_mariadb/sql/cr_asistencia_hist_48.sql

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.cr_asistencia_hist_48` AS
WITH filtered AS (
  SELECT *
  FROM `worldwide-470917.cr_reportes.cr_asistencia_semanal`
  WHERE turno NOT IN (
    '+4x4   ', '+5x2   ', '+6x1   ', '+6x2   ', '+7x7   ',
    'F      ', 'LME    ', 'LMPP   ', 'LMU    ',
    'OS1    ', 'OS2    ', 'OS3    ',
    'P1     ', 'P2     ', 'PL3    ', 'PL4    ', 'PL7    ', 'PNH    ',
    'V1     ', 'IND3   ', 'IND2   ', 'PMA    ', 'PFH    ', 'PL2    ',
    'LMO    ', "IND1   ", "LMM    ", "XP3    ", "PL8    ", "IND14  ", "OS7    ",
    "XP1    ", "XP2    ", "PFP    ", "OS4    ", "LMEP   ", "PL1    ",
    "OS14   ", "XP4    ", "PFHE   ", "IND7   ", "V2     ", "PL14   ",
    "IND9   ", "IND4   ", "XP7    "
  )
  AND cargo NOT IN (
    'SUPERVISOR', 'SUPERVISOR COW', 'SUPERVISOR III y IV REGION', 'SUPERVISOR UCM',
    'PREVENCIONISTA 2', 'PREVENCIONISTA 2', 'ASISTENTE SELECCION', 'SUPERVISOR RRHH V REGION',
    'ASISTENTE DE RRHH', 'ADMINISTRATIVA V REGION', 'CONDUCTOR', 'JEFE ZONAL',
    'SUPERVISOR ARAUCANIA 600', 'JEFE OPERACIONES VIII-IX-XVI REGION',
    'ADMINISTRATIVO RRHH ZONA TALCA', 'ENCARGADO(A) DE COBRANZA', 'CAPACITADOR',
    'ENCARGADO BODEGA', 'OPERADOR', 'SUPERVISOR V 2', 'SUPERVISOR SUR III',
    'Supervisor Sur II', 'JEFE OPERACIONES PUNTA ARENAS', 'FISCALIZADOR OS10',
    'RECLUTADOR', 'CONTROL OPERACIONES', 'ADMINISTRATIVO PUERTO MONTT',
    'ADMINISTRATIVA TEMUCO', 'SUPERVISORES SUR 2',
    'JEFE OPERACIONES VI y VII REGION', 'SUPERVISOR VI-VII REGION',
    'RECLUTADOR TERRENO', 'SUPERVISOR RRHH RM', 'ENCAR.VUL Y RIESGO',
    'JEFE ZONA SANTIAGO ', 'JEFE OPERACIONES X-XI-XII-XIV REGION',
    'ADMINISTRATIVO CASA CONCEPCION', 'ADMINISTRATIVO', 'PREVENSION DE RIESGO'
  )
),

planificado AS (
  SELECT DISTINCT
    a.cliente_rol,
    a.instalacion_rol,
    a.nombrerol,
    a.rutrol,
    a.cargo,
    a.turno,
    a.her,
    a.hsr,
    a.dia,
    a.hrtotrol,
    c.zona,
    a.tipo_de_servicio,
    a.empresa
  FROM filtered a
  LEFT JOIN `worldwide-470917.mantenedores.zonas_instalaciones` c
    ON a.instalacion_rol = c.instalacion AND a.empresa = c.empresa
),

bases AS (
  SELECT * FROM filtered
  WHERE Tipo NOT IN ('EXR', 'TIT')
),

real_cover_slots AS (
  SELECT DISTINCT
    empresa,
    instalacion_rol,
    rutrol,
    turno,
    her
  FROM filtered
  WHERE Tipo IN ('NOR', 'EXR', 'TIT')
    AND rutasi IS NOT NULL
    AND CAST(rutasi AS STRING) NOT IN ('90000001', '90000002', '90000009', '0', '')
    AND NOT REGEXP_CONTAINS(UPPER(IFNULL(relevo, '')), r'APOYO\s+GENERAL|ASISTENCIA\s+GENERAL')
),

cover AS (
  SELECT f.*
  FROM filtered f
  LEFT JOIN real_cover_slots r
    ON r.empresa = f.empresa
   AND r.instalacion_rol = f.instalacion_rol
   AND r.rutrol = f.rutrol
   AND r.turno = f.turno
   AND r.her = f.her
  WHERE f.Tipo IN ('EXR', 'TIT')
    AND f.entrada = f.her
    AND f.salida = f.hsr
    AND NOT (
      CAST(f.rutasi AS STRING) IN ('90000001', '90000002', '90000009')
      AND r.rutrol IS NOT NULL
    )
),

uncover_time AS (
  SELECT f.*
  FROM filtered f
  LEFT JOIN real_cover_slots r
    ON r.empresa = f.empresa
   AND r.instalacion_rol = f.instalacion_rol
   AND r.rutrol = f.rutrol
   AND r.turno = f.turno
   AND r.her = f.her
  WHERE f.Tipo IN ('EXR', 'TIT')
    AND (f.entrada <> f.her OR f.salida <> f.hsr)
    AND NOT (
      CAST(f.rutasi AS STRING) IN ('90000001', '90000002', '90000009')
      AND r.rutrol IS NOT NULL
    )
),

-- Combina N reemplazos parciales en 1 fila por turno planificado.
uncover_agg AS (
  SELECT
    instalacion_rol,
    empresa,
    rutrol,
    turno,
    her,
    hsr,
    ANY_VALUE(motivoppc) AS motivoppc,
    ANY_VALUE(Tipo) AS tipo,
    MIN(entrada) AS entrada,
    MAX(salida) AS salida,
    ROUND(SUM(DATETIME_DIFF(salida, entrada, MINUTE)) / 60, 2) AS hr_tot_asi,
    STRING_AGG(relevo, ' || ' ORDER BY entrada, rutasi) AS relevo,
    ARRAY_AGG(
      rutasi
      ORDER BY
        CASE
          WHEN CAST(rutasi AS STRING) IN ('90000001', '90000002', '90000009') THEN 1
          WHEN REGEXP_CONTAINS(UPPER(IFNULL(relevo, '')), r'APOYO\s+GENERAL|ASISTENCIA\s+GENERAL') THEN 1
          ELSE 0
        END ASC,
        DATETIME_DIFF(salida, entrada, MINUTE) DESC,
        entrada,
        rutasi
      LIMIT 1
    )[OFFSET(0)] AS rutasi,
    ANY_VALUE(tvf) AS tvf,
    MAX(valortvf) AS valortvf,
    MAX(
      CASE
        WHEN CAST(rutasi AS STRING) NOT IN ('90000001', '90000002', '90000009')
         AND NOT REGEXP_CONTAINS(UPPER(IFNULL(relevo, '')), r'APOYO\s+GENERAL|ASISTENCIA\s+GENERAL')
        THEN 1
        ELSE 0
      END
    ) AS asistencia
  FROM uncover_time
  GROUP BY instalacion_rol, empresa, rutrol, turno, her, hsr
),

bases_cover_full AS (
  SELECT
    a.*,
    b.motivoppc,
    IFNULL(c.rutasi, b.rutasi) AS rutasi,
    IFNULL(c.entrada, b.entrada) AS entrada,
    IFNULL(c.salida, b.salida) AS salida,
    IFNULL(c.relevo, b.relevo) AS relevo,
    IFNULL(c.tipo, b.tipo) AS tipo,
    IFNULL(c.tvf, b.tvf) AS tvf,
    IFNULL(c.valortvf, b.valortvf) AS valortvf,
    (CASE
      WHEN IFNULL(c.entrada, b.entrada) IS NOT NULL
        AND IFNULL(c.rutasi, b.rutasi) NOT IN ('90000001', '90000002', '90000009')
        AND NOT REGEXP_CONTAINS(
          UPPER(IFNULL(IFNULL(c.relevo, b.relevo), '')),
          r'APOYO\s+GENERAL|ASISTENCIA\s+GENERAL'
        )
      THEN 1
      ELSE 0
    END) AS asistencia,
    IFNULL(c.hr_tot_asi, b.hr_tot_asi) AS hr_tot_asi
  FROM planificado a
  LEFT JOIN bases b
    ON a.instalacion_rol = b.instalacion_rol
   AND a.rutrol = b.rutrol
   AND a.turno = b.turno
   AND a.her = b.her
  LEFT JOIN cover c
    ON a.instalacion_rol = c.instalacion_rol
   AND a.rutrol = c.rutrol
   AND a.turno = c.turno
   AND a.her = c.her
   AND b.entrada = c.entrada
   AND b.salida = c.salida
),

bases_cover_parcial AS (
  SELECT
    a.*,
    c.motivoppc,
    c.rutasi,
    c.entrada,
    c.salida,
    c.relevo,
    c.tipo,
    c.tvf,
    c.valortvf,
    c.asistencia,
    c.hr_tot_asi
  FROM planificado a
  INNER JOIN uncover_agg c
    ON a.instalacion_rol = c.instalacion_rol
   AND a.empresa = c.empresa
   AND a.rutrol = c.rutrol
   AND a.turno = c.turno
   AND a.her = c.her
),

horas AS (
  SELECT DATETIME_ADD(DATETIME(CURRENT_DATE("America/Santiago")), INTERVAL h HOUR) AS hora
  FROM UNNEST(GENERATE_ARRAY(0, 23)) AS h
),

total AS (
  SELECT * FROM bases_cover_full
  WHERE tipo <> "NNA"
    AND CONCAT(rutrol, CAST(her AS STRING)) NOT IN (
      SELECT CONCAT(rutrol, CAST(her AS STRING)) FROM bases_cover_parcial
    )
  UNION ALL
  SELECT * FROM bases_cover_parcial
),

-- NOR de planilla que es el mismo turno que un TIT (rutasi del TIT = rutrol del NOR).
tit_cubre AS (
  SELECT
    empresa,
    instalacion_rol,
    turno,
    her,
    REGEXP_REPLACE(CAST(rutasi AS STRING), r'[^0-9]', '') AS rutasi_n
  FROM total
  WHERE UPPER(TRIM(CAST(tipo AS STRING))) = 'TIT'
    AND rutasi IS NOT NULL
    AND CAST(rutasi AS STRING) NOT IN ('90000001', '90000002', '90000009', '0', '')
    AND REGEXP_REPLACE(CAST(rutrol AS STRING), r'[^0-9]', '')
        != REGEXP_REPLACE(CAST(rutasi AS STRING), r'[^0-9]', '')
),

total_sin_nor_duplicado AS (
  SELECT t.*
  FROM total t
  LEFT JOIN tit_cubre x
    ON t.empresa = x.empresa
   AND t.instalacion_rol = x.instalacion_rol
   AND t.turno = x.turno
   AND t.her = x.her
   AND UPPER(TRIM(CAST(t.tipo AS STRING))) = 'NOR'
   AND (
        REGEXP_REPLACE(CAST(t.rutrol AS STRING), r'[^0-9]', '') = x.rutasi_n
     OR (
          LENGTH(REGEXP_REPLACE(CAST(t.rutrol AS STRING), r'[^0-9]', ''))
            = LENGTH(x.rutasi_n) + 1
          AND STARTS_WITH(REGEXP_REPLACE(CAST(t.rutrol AS STRING), r'[^0-9]', ''), x.rutasi_n)
        )
     OR (
          LENGTH(x.rutasi_n)
            = LENGTH(REGEXP_REPLACE(CAST(t.rutrol AS STRING), r'[^0-9]', '')) + 1
          AND STARTS_WITH(x.rutasi_n, REGEXP_REPLACE(CAST(t.rutrol AS STRING), r'[^0-9]', ''))
        )
      )
  WHERE x.rutasi_n IS NULL
),

final AS (
  SELECT
    *,
    CASE
      WHEN tipo = 'NOR' AND entrada <= her AND salida >= hsr THEN "Presente"
      WHEN tipo = '' AND motivoppc <> 'N/A' THEN "PPC NC"
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc <> 'N/A' AND asistencia = 1 THEN "PPC C"
      WHEN tipo = '' AND motivoppc = 'N/A' THEN "Ausente"
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc = 'N/A' AND asistencia = 1 THEN "Ausente C"
      WHEN tipo = 'NOR' AND entrada IS NULL THEN "Presente ATR"
      WHEN tipo = 'NOR' AND entrada > her THEN "Presente ET"
      WHEN tipo = 'NOR' AND salida < hsr THEN "Presente ST"
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc = 'N/A' AND asistencia = 0 THEN "Ausente"
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc <> 'N/A' AND asistencia = 0 THEN "PPC NC"
    END AS COB,
    hr_tot_asi * asistencia AS horas_entregadas,
    (
      SELECT DATETIME(TIMESTAMP_MILLIS(last_modified_time), "America/Santiago")
      FROM `worldwide-470917.cr_reportes.__TABLES__`
      WHERE table_id = 'cr_asistencia_semanal'
    ) AS hora_actual,
    ROW_NUMBER() OVER (PARTITION BY rutrol, her) AS rn
  FROM total_sin_nor_duplicado a
)

SELECT
  a.* EXCEPT (valortvf),
  CONCAT(
    FORMAT_DATE("%d%b", DATE_TRUNC(a.dia, ISOWEEK)),
    "-",
    FORMAT_DATE("%d%b", LAST_DAY(a.dia, ISOWEEK))
  ) AS semana,
  EXTRACT(ISOWEEK FROM a.dia) AS isoweek,
  EXTRACT(MONTH FROM a.dia) AS mes,
  EXTRACT(YEAR FROM a.dia) AS ano,
  CASE WHEN a.rn = 1 THEN a.hrtotrol ELSE 0 END AS horas_planificadas,
  a.valortvf * a.asistencia AS valortvf
FROM final a
WHERE a.dia >= DATE_ADD(CURRENT_DATE("America/Santiago"), INTERVAL -2 DAY)
;
