-- Vista hist con relevos parciales combinados en 1 fila por (rutrol, her).
-- worldwide-470917.cr_vistas_reporte.vw_cr_asistencia_hist_tb_relevos_agg
--
-- Cambio vs hist actual:
--   bases_cover_parcial agrega uncover_time (MIN entrada, MAX salida,
--   STRING_AGG relevo, SUM horas, rutasi del tramo mas largo).
--   TIT vs NOR duplicado: el TIT es el turno original (rutrol = titular,
--   rutasi = quien cubre). El NOR del cubridor en el mismo
--   instalacion+turno+her es la misma fila de planilla. Se conserva el TIT
--   (historia completa) y se omite ese NOR para no duplicar horas.
--   Dummy ControlRoll 90000001/2/9: si el mismo titular tiene persona real
--   (NOR, EXR o TIT) en el slot, el dummy es hueco (atraso o tramo sin cubrir),
--   no turno descubierto. Se conserva la persona real (asistencia=1).
--
-- Desplegar:
--   bq query --use_legacy_sql=false < carga_marcas_mariadb/sql/vw_cr_asistencia_hist_tb_relevos_agg.sql

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.vw_cr_asistencia_hist_tb_relevos_agg` AS
WITH filtered AS (
  SELECT *
  FROM `worldwide-470917.cr_reportes.cr_asistencia_semanal`
  WHERE turno NOT IN (
    '+4x4  ', '+5x2  ', '+6x1  ', '+6x2  ', '+7x7  ',
    'F      ', 'LME    ', 'LMPP   ', 'LMU    ',
    'OS1    ', 'OS2    ', 'OS3    ',
    'P1     ', 'P2     ', 'PL3    ', 'PL4    ', 'PL7    ', 'PNH    ',
    'V1     ', 'IND3   ', 'IND2   ', 'PMA    ', 'PFH    ', 'PL2    ',
    'LMO    ', "IND1    ", "LMM    ", "XP3    ", "PL8    ", "IND14  ", "OS7    ",
    "XP1    ", "XP2    ", "PFP    ", "OS4    ", "LMEP   ", "PL1    ",
    "OS14   ", "XP4    ", "PFHE   ", "IND7   ", "V2     ", "PL14   ",
    "IND9   ", "IND4   ", "XP7    "
  )
  AND hrtotrol > 0
  AND cargo NOT IN (
    'SUPERVISOR', 'SUPERVISOR COW', 'SUPERVISOR III y IV REGION', 'SUPERVISOR UCM',
    'PREVENCIONISTA 2', 'ASISTENTE SELECCION', 'SUPERVISOR RRHH V REGION',
    'ASISTENTE DE RRHH', 'ADMINISTRATIVA V REGION', 'CONDUCTOR', 'JEFE ZONAL',
    'SUPERVISOR ARAUCANIA 600', 'JEFE OPERACIONES VIII-IX-XVI REGION',
    'ADMINISTRATIVO RRHH ZONA TALCA', 'ENCARGADO(A) DE COBRANZA', 'CAPACITADOR',
    'ENCARGADO BODEGA', 'OPERADOR', 'SUPERVISOR V 2', 'SUPERVISOR SUR III',
    'Supervisor Sur II', 'JEFE OPERACIONES PUNTA ARENAS', 'FISCALIZADOR OS10',
    'RECLUTADOR', 'CONTROL OPERACIONES', 'ADMINISTRATIVO PUERTO MONTT',
    'ADMINISTRATIVA TEMUCO', 'SUPERVISORES SUR 2',
    'JEFE OPERACIONES VI y VII REGION', 'SUPERVISOR VI-VII REGION',
    'RECLUTADOR TERRENO', 'SUPERVISOR RRHH RM', 'ENCAR.VUL Y RIESGO',
    'JEFE ZONA SANTIAGO ', 'JEFE OPERACIONES X-XI-XII-XIV REGION',
    'ADMINISTRATIVO CASA CONCEPCION', 'ADMINISTRATIVO', 'PREVENSION DE RIESGO'
  )
),

logic_asistencia AS (
  SELECT
    *,
    (CASE
      WHEN fechamarcaentrada IS NULL THEN entrada
      WHEN DATETIME_DIFF(fechamarcaentrada, entrada, MINUTE) > 120 THEN fechamarcaentrada
      ELSE entrada
    END) AS hr_consi_entrada,
    (CASE
      WHEN fechamarcasalida IS NULL THEN salida
      WHEN DATETIME_DIFF(fechamarcasalida, salida, MINUTE) < -10 THEN fechamarcasalida
      ELSE salida
    END) AS hr_consi_salida
  FROM filtered
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
    a.empresa,
    (CASE WHEN e.instalacion IS NULL THEN FALSE ELSE TRUE END) AS inst_esporadica,
    (CASE WHEN d.equipo_nombre IS NULL THEN a.instalacion_rol ELSE d.equipo_nombre END) AS equip_faceid
  FROM filtered a
  LEFT JOIN `worldwide-470917.mantenedores.zonas_instalaciones` c
    ON a.instalacion_rol = c.instalacion AND a.empresa = c.empresa
  LEFT JOIN `worldwide-470917.mantenedores.asignacion_faceid` d
    ON a.instalacion_rol = d.instalacion AND a.empresa = d.empresa
  LEFT JOIN `worldwide-470917.mantenedores.instalaciones_esporadicas` e
    ON a.instalacion_rol = e.instalacion AND a.empresa = e.empresa
),

bases AS (
  SELECT
    *,
    ROUND(DATETIME_DIFF(hr_consi_salida, hr_consi_entrada, MINUTE) / 60, 2) AS hr_tot_asi_calc
  FROM logic_asistencia
  WHERE Tipo NOT IN ('EXR', 'TIT')
),

real_cover_slots AS (
  SELECT DISTINCT
    empresa,
    instalacion_rol,
    rutrol,
    turno,
    her
  FROM logic_asistencia
  WHERE Tipo IN ('NOR', 'EXR', 'TIT')
    AND rutasi IS NOT NULL
    AND CAST(rutasi AS STRING) NOT IN ('90000001', '90000002', '90000009', '0', '')
    AND NOT REGEXP_CONTAINS(UPPER(IFNULL(relevo, '')), r'APOYO\s+GENERAL|ASISTENCIA\s+GENERAL')
),

cover AS (
  SELECT
    l.*,
    ROUND(DATETIME_DIFF(l.hr_consi_salida, l.hr_consi_entrada, MINUTE) / 60, 2) AS hr_tot_asi_calc
  FROM logic_asistencia l
  LEFT JOIN real_cover_slots r
    ON r.empresa = l.empresa
   AND r.instalacion_rol = l.instalacion_rol
   AND r.rutrol = l.rutrol
   AND r.turno = l.turno
   AND r.her = l.her
  WHERE l.Tipo IN ('EXR', 'TIT')
    AND l.entrada = l.her
    AND l.salida = l.hsr
    AND NOT (
      CAST(l.rutasi AS STRING) IN ('90000001', '90000002', '90000009')
      AND r.rutrol IS NOT NULL
    )
),

uncover_time AS (
  SELECT
    l.*,
    ROUND(DATETIME_DIFF(l.hr_consi_salida, l.hr_consi_entrada, MINUTE) / 60, 2) AS hr_tot_asi_calc
  FROM logic_asistencia l
  LEFT JOIN real_cover_slots r
    ON r.empresa = l.empresa
   AND r.instalacion_rol = l.instalacion_rol
   AND r.rutrol = l.rutrol
   AND r.turno = l.turno
   AND r.her = l.her
  WHERE l.Tipo IN ('EXR', 'TIT')
    AND (l.entrada <> l.her OR l.salida <> l.hsr)
    AND NOT (
      CAST(l.rutasi AS STRING) IN ('90000001', '90000002', '90000009')
      AND r.rutrol IS NOT NULL
    )
),

-- NUEVO: combina N reemplazos parciales en 1 fila por turno planificado
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
    ROUND(SUM(DATETIME_DIFF(hr_consi_salida, hr_consi_entrada, MINUTE)) / 60, 2) AS hr_tot_asi_calc,
    STRING_AGG(relevo, ' || ' ORDER BY entrada, rutasi) AS relevo,
    -- rutasi: prioriza persona real sobre Apoyo General / ruts dummy;
    -- luego el tramo mas largo, luego entrada mas temprana.
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
    STRING_AGG(DISTINCT CAST(rutasi AS STRING), ',' ORDER BY CAST(rutasi AS STRING)) AS rutasi_todos,
    COUNT(*) AS n_tramos_relevo,
    MAX(
      CASE
        WHEN CAST(rutasi AS STRING) NOT IN ('90000001', '90000002', '90000009')
         AND NOT REGEXP_CONTAINS(UPPER(IFNULL(relevo, '')), r'APOYO\s+GENERAL|ASISTENCIA\s+GENERAL')
        THEN 1
        ELSE 0
      END
    ) AS asistencia,
    MIN(fechamarcaentrada) AS fechamarcaentrada,
    MAX(fechamarcasalida) AS fechamarcasalida,
    MIN(hr_consi_entrada) AS hr_consi_entrada,
    MAX(hr_consi_salida) AS hr_consi_salida,
    ANY_VALUE(tvf) AS tvf,
    MAX(valortvf) AS valortvf
  FROM uncover_time
  GROUP BY instalacion_rol, empresa, rutrol, turno, her, hsr
),

bases_cover_full AS (
  SELECT
    a.*,
    b.motivoppc,
    IFNULL(c.rutasi, b.rutasi) AS rutasi,
    CAST(IFNULL(c.rutasi, b.rutasi) AS STRING) AS rutasi_todos,
    1 AS n_tramos_relevo,
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
      THEN 1 ELSE 0
    END) AS asistencia,
    IFNULL(c.hr_tot_asi_calc, b.hr_tot_asi_calc) AS hr_tot_asi_final,
    IFNULL(c.fechamarcaentrada, b.fechamarcaentrada) AS fechamarcaentrada,
    IFNULL(c.fechamarcasalida, b.fechamarcasalida) AS fechamarcasalida,
    IFNULL(c.hr_consi_entrada, b.hr_consi_entrada) AS hr_consi_entrada,
    IFNULL(c.hr_consi_salida, b.hr_consi_salida) AS hr_consi_salida
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
    c.rutasi_todos,
    c.n_tramos_relevo,
    c.entrada,
    c.salida,
    c.relevo,
    c.tipo,
    c.tvf,
    c.valortvf,
    c.asistencia,
    c.hr_tot_asi_calc AS hr_tot_asi_final,
    c.fechamarcaentrada,
    c.fechamarcasalida,
    c.hr_consi_entrada,
    c.hr_consi_salida
  FROM planificado a
  INNER JOIN uncover_agg c
    ON a.instalacion_rol = c.instalacion_rol
   AND a.empresa = c.empresa
   AND a.rutrol = c.rutrol
   AND a.turno = c.turno
   AND a.her = c.her
),

total AS (
  SELECT * FROM bases_cover_full
  WHERE tipo IS NOT NULL AND tipo <> 'NNA'
    AND CONCAT(CAST(rutrol AS STRING), CAST(her AS STRING)) NOT IN (
      SELECT CONCAT(CAST(rutrol AS STRING), CAST(her AS STRING)) FROM bases_cover_parcial
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
      WHEN tipo = 'NOR' AND entrada <= her AND salida >= hsr THEN 'Presente'
      WHEN tipo = '' AND motivoppc <> 'N/A' THEN 'PPC NC'
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc <> 'N/A' AND asistencia = 1 THEN 'PPC C'
      WHEN tipo = '' AND motivoppc = 'N/A' THEN 'Ausente'
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc = 'N/A' AND asistencia = 1 THEN 'Ausente C'
      WHEN tipo = 'NOR' AND entrada IS NULL THEN 'Presente ATR'
      WHEN tipo = 'NOR' AND entrada > her THEN 'Presente ET'
      WHEN tipo = 'NOR' AND salida < hsr THEN 'Presente ST'
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc = 'N/A' AND asistencia = 0 THEN 'Ausente'
      WHEN tipo IN ('EXR', 'TIT') AND motivoppc <> 'N/A' AND asistencia = 0 THEN 'PPC NC'
    END AS COB,
    SUM(hr_tot_asi_final * asistencia) OVER (PARTITION BY rutrol, her) AS horas_entregadas_totales_calc,
    MAX(asistencia) OVER (PARTITION BY rutrol, her) AS asistencia_final_calc,
    ROW_NUMBER() OVER (PARTITION BY rutrol, her ORDER BY asistencia DESC, entrada ASC) AS rn_shift,
    (
      SELECT DATETIME(TIMESTAMP_MILLIS(last_modified_time), 'America/Santiago')
      FROM `worldwide-470917.cr_reportes.__TABLES__`
      WHERE table_id = 'cr_asistencia_semanal'
    ) AS hora_actual_tabla
  FROM total_sin_nor_duplicado a
),

jefes_instalacion AS (
  SELECT
    UPPER(TRIM(ui.instalacion_rol)) AS instalacion_key,
    UPPER(COALESCE(NULLIF(TRIM(ui.empresa), ''), 'Security')) AS empresa_key,
    STRING_AGG(
      DISTINCT COALESCE(NULLIF(TRIM(p.nombre_completo), ''), LOWER(TRIM(p.email_login))),
      ', '
      ORDER BY COALESCE(NULLIF(TRIM(p.nombre_completo), ''), LOWER(TRIM(p.email_login))) ASC
    ) AS jefes_instalacion
  FROM `worldwide-470917.app_clientes.usuario_instalaciones` ui
  INNER JOIN `worldwide-470917.app_clientes.v_permisos_usuarios` p
    ON LOWER(TRIM(ui.email_login)) = LOWER(TRIM(p.email_login))
  WHERE ui.puede_ver = TRUE
    AND p.usuario_activo = TRUE
    AND p.rol_id = 'JEFE_WFSA'
  GROUP BY instalacion_key, empresa_key
)

SELECT
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
  a.zona,
  a.tipo_de_servicio,
  a.empresa,
  a.inst_esporadica,
  a.equip_faceid,
  a.motivoppc,
  a.rutasi,
  a.rutasi_todos,
  a.n_tramos_relevo,
  a.entrada,
  a.salida,
  a.relevo,
  a.tipo,
  a.tvf,
  a.COB,
  a.fechamarcaentrada,
  a.fechamarcasalida,
  a.hr_consi_entrada,
  a.hr_consi_salida,
  a.horas_entregadas_totales_calc AS horas_entregadas_totales,
  a.asistencia_final_calc AS asistencia_final,
  a.hora_actual_tabla AS hora_actual,
  a.asistencia_final_calc AS asistencia,
  (CASE
    WHEN ABS(a.horas_entregadas_totales_calc - a.hrtotrol) * 60 < 10 THEN a.hrtotrol
    ELSE ROUND(a.horas_entregadas_totales_calc, 2)
  END) AS horas_entregadas,
  CONCAT(
    FORMAT_DATE('%d%b', DATE_TRUNC(a.dia, ISOWEEK)),
    '-',
    FORMAT_DATE('%d%b', LAST_DAY(a.dia, ISOWEEK))
  ) AS semana,
  EXTRACT(ISOWEEK FROM a.dia) AS isoweek,
  EXTRACT(MONTH FROM a.dia) AS mes,
  EXTRACT(YEAR FROM a.dia) AS ano,
  a.hrtotrol AS horas_planificadas,
  a.valortvf * a.asistencia_final_calc AS valortvf,
  j.jefes_instalacion
FROM final a
LEFT JOIN jefes_instalacion j
  ON UPPER(TRIM(a.instalacion_rol)) = j.instalacion_key
 AND UPPER(TRIM(a.empresa)) = j.empresa_key
WHERE a.dia >= DATE_ADD(CURRENT_DATE('America/Santiago'), INTERVAL -180 DAY)
  AND a.rn_shift = 1
;
