-- Impacto: hist actual vs vista con relevos agregados (ultimos 60 dias).
-- worldwide-470917.cr_vistas_reporte.vw_cr_asistencia_hist_impacto_relevos_agg
--
-- Desplegar:
--   bq query --use_legacy_sql=false < carga_marcas_mariadb/sql/vw_cr_asistencia_hist_impacto_relevos_agg.sql

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.vw_cr_asistencia_hist_impacto_relevos_agg` AS
WITH actual AS (
  SELECT
    empresa,
    cliente_rol,
    instalacion_rol,
    rutrol,
    nombrerol,
    turno,
    dia,
    her,
    hsr,
    rutasi AS rutasi_actual,
    relevo AS relevo_actual,
    entrada AS entrada_actual,
    salida AS salida_actual,
    COB AS cob_actual,
    asistencia AS asistencia_actual,
    horas_entregadas AS horas_entregadas_actual,
    fechamarcaentrada AS fme_actual,
    fechamarcasalida AS fms_actual
  FROM `worldwide-470917.cr_reportes.cr_asistencia_hist_tb`
  WHERE DATE(dia) >= DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 60 DAY)
),

nuevo AS (
  SELECT
    empresa,
    cliente_rol,
    instalacion_rol,
    rutrol,
    nombrerol,
    turno,
    dia,
    her,
    hsr,
    rutasi AS rutasi_nuevo,
    rutasi_todos,
    n_tramos_relevo,
    relevo AS relevo_nuevo,
    entrada AS entrada_nuevo,
    salida AS salida_nuevo,
    COB AS cob_nuevo,
    asistencia AS asistencia_nuevo,
    horas_entregadas AS horas_entregadas_nuevo,
    fechamarcaentrada AS fme_nuevo,
    fechamarcasalida AS fms_nuevo
  FROM `worldwide-470917.cr_vistas_reporte.vw_cr_asistencia_hist_tb_relevos_agg`
  WHERE DATE(dia) >= DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 60 DAY)
),

joined AS (
  SELECT
    COALESCE(a.empresa, n.empresa) AS empresa,
    COALESCE(a.cliente_rol, n.cliente_rol) AS cliente_rol,
    COALESCE(a.instalacion_rol, n.instalacion_rol) AS instalacion_rol,
    COALESCE(a.rutrol, n.rutrol) AS rutrol,
    COALESCE(a.nombrerol, n.nombrerol) AS nombrerol,
    COALESCE(a.turno, n.turno) AS turno,
    COALESCE(a.dia, n.dia) AS dia,
    COALESCE(a.her, n.her) AS her,
    COALESCE(a.hsr, n.hsr) AS hsr,
    a.rutasi_actual,
    n.rutasi_nuevo,
    n.rutasi_todos,
    n.n_tramos_relevo,
    a.relevo_actual,
    n.relevo_nuevo,
    a.entrada_actual,
    n.entrada_nuevo,
    a.salida_actual,
    n.salida_nuevo,
    a.cob_actual,
    n.cob_nuevo,
    a.asistencia_actual,
    n.asistencia_nuevo,
    a.horas_entregadas_actual,
    n.horas_entregadas_nuevo,
    a.fme_actual,
    n.fme_nuevo,
    a.fms_actual,
    n.fms_nuevo,
    CASE
      WHEN a.rutrol IS NULL THEN 'solo_nuevo'
      WHEN n.rutrol IS NULL THEN 'solo_actual'
      WHEN IFNULL(a.rutasi_actual, '') != IFNULL(n.rutasi_nuevo, '')
        OR IFNULL(a.relevo_actual, '') != IFNULL(n.relevo_nuevo, '')
        OR a.entrada_actual != n.entrada_nuevo
        OR a.salida_actual != n.salida_nuevo
        OR IFNULL(a.cob_actual, '') != IFNULL(n.cob_nuevo, '')
        OR IFNULL(a.asistencia_actual, -1) != IFNULL(n.asistencia_nuevo, -1)
        OR ABS(IFNULL(a.horas_entregadas_actual, 0) - IFNULL(n.horas_entregadas_nuevo, 0)) > 0.01
      THEN 'cambio'
      ELSE 'igual'
    END AS tipo_impacto,
    CASE
      WHEN a.rutrol IS NULL THEN 'aparece_en_vista_nueva'
      WHEN n.rutrol IS NULL THEN 'desaparece_en_vista_nueva'
      WHEN IFNULL(n.n_tramos_relevo, 1) > 1 THEN 'relevos_combinados'
      WHEN IFNULL(a.rutasi_actual, '') != IFNULL(n.rutasi_nuevo, '') THEN 'cambia_rutasi'
      WHEN IFNULL(a.relevo_actual, '') != IFNULL(n.relevo_nuevo, '') THEN 'cambia_relevo'
      WHEN a.entrada_actual != n.entrada_nuevo OR a.salida_actual != n.salida_nuevo THEN 'cambia_horario_cobertura'
      WHEN ABS(IFNULL(a.horas_entregadas_actual, 0) - IFNULL(n.horas_entregadas_nuevo, 0)) > 0.01 THEN 'cambia_horas'
      WHEN IFNULL(a.cob_actual, '') != IFNULL(n.cob_nuevo, '') THEN 'cambia_cob'
      ELSE 'sin_cambio'
    END AS motivo_cambio
  FROM actual a
  FULL OUTER JOIN nuevo n
    ON a.empresa = n.empresa
   AND a.instalacion_rol = n.instalacion_rol
   AND CAST(a.rutrol AS STRING) = CAST(n.rutrol AS STRING)
   AND a.her = n.her
   AND DATE(a.dia) = DATE(n.dia)
)

SELECT *
FROM joined
WHERE tipo_impacto != 'igual' OR IFNULL(n_tramos_relevo, 1) > 1
;
