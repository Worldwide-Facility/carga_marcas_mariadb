-- Validación SOLO LECTURA de casos esperados FaceID (tras desplegar la vista del PR).
--
--   bq query --use_legacy_sql=false --dry_run --maximum_bytes_billed=209715200 \
--     < sql/validacion_faceid_casos_esperados.sql
--   bq query --use_legacy_sql=false --maximum_bytes_billed=209715200 \
--     < sql/validacion_faceid_casos_esperados.sql
--
-- Casos unitarios adicionales (sin BQ): python -m unittest test_faceid_marcacion_rules.py
--   - En Revisión + Marca Utilizada Correctamente → aceptada
--   - Objetada → no cuenta
--   - Duplicado Correcta + En Revisión → una aceptada
--   - Salida 3+ h antes del fin → fuera de ventana
--   - N5 00:00 con entrada 20:00 día anterior → fuera de ventana
--   - Complemento _24: turno nocturno con salida solo en _24 y día ausente del hist
--     → marca_salida poblada; si el día ya está en hist → se ignora _24

WITH martabid_vista AS (
  SELECT
    '1_VISTA_MARTABID_N2_ART22' AS seccion,
    v.estado,
    v.marca_entrada,
    CAST(v.hora_entrada AS STRING) AS hora_entrada,
    v.marca_salida,
    CAST(v.hora_salida AS STRING) AS hora_salida,
    v.instalacion_rol,
    v.turno,
    v.empresa,
    CAST(v.rutasi AS STRING) AS rutasi,
    CAST(DATE(v.dia) AS STRING) AS dia,
    CASE
      WHEN v.estado = 'OK'
       AND v.marca_entrada IS NOT NULL
       AND v.marca_salida IS NOT NULL THEN TRUE
      ELSE FALSE
    END AS ok_esperado
  FROM `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` v
  WHERE v.empresa = 'Security'
    AND CAST(v.rutasi AS STRING) = '21253355'
    AND DATE(v.dia) = DATE('2026-11-16')
  QUALIFY ROW_NUMBER() OVER (ORDER BY v.her, v.hsr) = 1
),

martabid_fuentes AS (
  SELECT
    '2_FUENTES_MARTABID_MARCAS' AS seccion,
    CAST(NULL AS STRING) AS estado,
    marc.tipo AS marca_entrada,
    CAST(marc.hora AS STRING) AS hora_entrada,
    marc.revision AS marca_salida,
    CAST(NULL AS STRING) AS hora_salida,
    marc.motivo_no_uso AS instalacion_rol,
    CAST(marc.fecha AS STRING) AS turno,
    eq.empresa,
    CAST(marc.rut AS STRING) AS rutasi,
    CAST(marc.fecha AS STRING) AS dia,
    CAST(NULL AS BOOL) AS ok_esperado
  FROM `worldwide-470917.cr_reportes.cr_marcas_face_id_hist` marc
  INNER JOIN `worldwide-470917.cr_reportes.cr_equipos_faceid` eq
    ON eq.cod = marc.cod_dispositivo
  WHERE eq.empresa = 'Security'
    AND CAST(marc.rut AS STRING) = '21253355'
    AND marc.fecha BETWEEN DATE('2026-11-16') AND DATE('2026-11-17')
    AND marc.tipo IN ('Entrada Laboral', 'Salida Laboral')
)

SELECT * FROM martabid_vista
UNION ALL
SELECT * FROM martabid_fuentes
ORDER BY seccion, dia, hora_entrada
;
