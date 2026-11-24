-- worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid
-- Turnos del histórico de asistencia cruzados con las marcas FaceID de entrada y salida.
--
-- DDL aplicado en producción el 24-11-2026 (CREATE OR REPLACE ejecutado por Diego).
-- Este archivo espeja esa vista. Parte de PR #9 (reemplazo) y PR #10
-- ('Sin entrada laboral registrada') y suma tres cambios:
--   (a) Ventana de marca por tramo de cobertura del rutasi, no por her/hsr planificados.
--   (b) Exclusividad: una misma marca aplica como máximo a un turno.
--   (c) Excepción de reemplazo: 7 o más dígitos solo en rutasi (se quita el largo de rutrol).
-- her y hsr se siguen mostrando con el horario planificado completo; la ventana ±3 h
-- usa inicio_marca / fin_marca.
--
-- Regla de cruce (empresa + rutasi):
--   * Entrada laboral: timestamp de la marca dentro de ±3 h de inicio_marca.
--   * Salida laboral: timestamp dentro de ±3 h de fin_marca.
--   * inicio_marca / fin_marca se derivan así (fuente más fiable primero):
--       1) tramo del rutasi en el texto `relevo` (formato 'RUT | 3:00PM / 7:00PM | NOMBRE',
--          tramos unidos por ' || '). Se normaliza '0:xxAM/PM' → '12:xx' (typo 12 h).
--          Se acepta el tramo solo si ambos extremos quedan a ≤ 3 h del her/entrada
--          y del hsr/salida (si no, el parseo typo no se usa).
--       2) Si no hay tramo fiable: entrada y salida de cr_asistencia_hist_tb
--          (ambos presentes). Ojo: esos campos agregan todos los tramos, no solo
--          el del rutasi, por eso el relevo es la fuente preferida.
--       3) Si no hay segmento: her / hsr planificados (si TIME(hsr) <= TIME(her),
--          el fin se calcula al día siguiente).
--   * hr_consi_* no se usa: también vienen agregados y son menos directos que el tramo.
--   * Se excluyen colaciones (Inicio/Término Colación).
--   * Aceptación: revision = 'Correcta' O motivo_no_uso = 'Marca Utilizada Correctamente',
--     excepto revision = 'Objetada' (nunca cuenta). El hist puede repetir el mismo marcaje
--     (empresa, rut, fecha, hora, tipo) con distintas revision: se deduplica y cuenta aceptado
--     si alguna fila no-Objetada cumple la condición.
--   * Excepción Art. 22: si no hay aceptada en la ventana y todas las marcas no-Objetadas de
--     ese lado en la ventana tienen motivo 'Colaborador Art. 22', se cuenta esa marca.
--   * Excepción reemplazo: si rutasi ≠ rutrol y rutasi tiene ≥ 7 dígitos (RUT válido;
--     no se exige largo de rutrol) y no hay aceptada en la ventana, se cuenta una
--     marca no-Objetada de rutasi (nunca de rutrol)
--     aunque esté En Revisión, excepto si el motivo es GPS lejos
--     ('Fuera de tolerancia por GPS', p. ej. 'Está a N mts del punto …') o de centro de
--     costo (texto 'CECOS': 'CECOS (…) sin geolocalización configurada' y
--     'Dispositivo sin CECOS configurado para evaluar uso PPC').
--     'Marcación sin geolocalización obtenida' no se excluye (no es GPS lejos ni CECOS).
--   * Excepción salida 'Sin entrada laboral registrada': si no hay aceptada en la
--     ventana de salida, se cuenta una marca no-Objetada de rutasi (nunca de rutrol)
--     con ese motivo (con o sin punto final) que caiga en ±3 h de fin_marca. Solo aplica
--     en salida_validas, en todos los turnos (no solo reemplazos). No se usa en
--     entrada_validas.
--   * Si hay varias válidas en un turno, se elige la más cercana a inicio_marca / fin_marca.
--   * Exclusividad: una marca (rutasi + empresa + timestamp, por lado) se asigna a un
--     solo turno. Gana el de menor |marca - inicio/fin_marca|; en empate, el turno
--     propio (reemplazo='NO') sobre el reemplazo; luego her, instalacion_rol, rutrol.
--     El perdedor puede usar su siguiente candidata válida, o queda sin marca.
--   * Universo: solo turnos con rutasi no vacío (sin fallback a rutrol) y rutasi
--     fuera de RUT genéricos ControlRoll ('90000001','90000002','90000009').
--
-- Fuente de turnos: cr_reportes.cr_asistencia_hist_tb (materializa
-- vw_cr_asistencia_hist_tb_relevos_agg vía scheduled query 68f108f6: tit_cubre,
-- combina tramos de relevo, prefiere persona real sobre 90000009). Misma fuente
-- que el panel Cobertura. No usar cr_vistas_reporte.cr_asistencia_hist (semanal
-- sin agregar relevos: duplicaba claves rutasi+her+instalacion+empresa).
-- Resguardo: QUALIFY 1 fila por (rutasi, her, instalacion_rol, empresa) preferiendo
-- TIT/EXR sobre NOR, luego hsr más tardío, desempate determinista.
-- nombre_asistente: nombrerol si rutrol=rutasi; si no, nombre del tramo de relevo
-- cuyo RUT coincide con rutasi (no el último texto tras ' || ').
--
-- Complemento en vivo: marcas_raw une el hist diario (carga ~08:00, cubre hasta ayer)
-- con cr_marcas_face_id_24 (cada ~5 min). Solo entran filas de _24 con
-- fecha > MAX(fecha) del hist: el hist tiene precedencia apenas carga un día, y las
-- salidas de turnos nocturnos de hoy no quedan ocultas en el portal hasta mañana.
--
-- Costo: turnos y marcas prefiltrados por fecha_desde del rol; solo columnas necesarias.
-- jefes_instalacion: jefes (JEFE_WFSA activos) asignados a la instalación en usuario_instalaciones.
--
-- Cargos (subgerente / jefe zonal / supervisor):
--   * Un join por cargo contra el CTE `cargos`, siempre con instalacion_rol + empresa + cargo.
--   * Varias personas del mismo cargo en la misma instalación/empresa se agregan con
--     STRING_AGG(DISTINCT nombre ORDER BY nombre) separado por ', ' (una sola fila).
--   * jefes_instalacion ya agrega con STRING_AGG DISTINCT; no multiplica filas.
--
-- Equipos FaceID:
--   * `equipos` = todos los códigos (para marcas_raw por cod_dispositivo). No deduplicar:
--     si hay dos equipos con el mismo nombre (p. ej. 2657 y 2658), las marcas pueden
--     venir de cualquiera y deben seguir entrando.
--   * `cr_equipos_faceid` se trunca y se recarga con el catálogo vigente: un equipo
--     reemplazado (p. ej. 2427→2695) desaparece del catálogo. marcas_raw usa LEFT JOIN
--     y COALESCE(eq.empresa, marc.empresa) para que las marcas históricas del equipo
--     retirado sigan cruzando por RUT + empresa + ventana ±3 h. Se excluyen
--     cod_dispositivo nulo o 0 (nunca aportaban con el INNER JOIN previo).
--   * `equipos_enriq` / `equipos_lw_enriq` = una fila por (nombre, empresa) para el join
--     de turnos (ult_conexion, instalacion_con_faceid, nuevo_faceid). Criterio:
--     ult_conexion más reciente (NULL al final), desempate por cod ASC.

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` AS
WITH params AS (
  SELECT DATE('2025-10-01') AS fecha_desde
),

-- Todos los códigos: LEFT JOIN de marcas por cod_dispositivo (fallback empresa en la marca).
equipos AS (
  SELECT
    eq.nombre,
    eq.ult_conexion,
    eq.empresa,
    eq.cod
  FROM `worldwide-470917.cr_reportes.cr_equipos_faceid` eq
),

-- Una fila por (nombre, empresa) para enriquecer turnos. No usar en marcas_raw.
equipos_enriq AS (
  SELECT
    nombre,
    ult_conexion,
    empresa,
    cod
  FROM equipos
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY nombre, empresa
    ORDER BY ult_conexion DESC NULLS LAST, cod ASC
  ) = 1
),

-- Misma deduplicación en _lw (join solo por nombre+empresa en turnos).
equipos_lw_enriq AS (
  SELECT
    nombre,
    empresa
  FROM `worldwide-470917.cr_reportes.cr_equipos_faceid_lw`
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY nombre, empresa
    ORDER BY ult_conexion DESC NULLS LAST, cod ASC
  ) = 1
),

-- Solo columnas necesarias; rango de fechas del rol ±1 día (entrada temprana / salida nocturna).
-- LEFT JOIN al catálogo: si el dispositivo ya no está (reemplazado), empresa viene de la marca.
marcas_raw AS (
  SELECT
    COALESCE(eq.empresa, marc.empresa) AS empresa,
    marc.rut,
    marc.fecha,
    marc.hora,
    marc.tipo,
    marc.revision,
    marc.motivo_no_uso,
    DATETIME(marc.fecha, marc.hora) AS marca_ts
  FROM (
    SELECT
      cod_dispositivo,
      empresa,
      rut,
      fecha,
      hora,
      tipo,
      revision,
      motivo_no_uso
    FROM `worldwide-470917.cr_reportes.cr_marcas_face_id_hist`
    UNION ALL
    SELECT
      cod_dispositivo,
      empresa,
      rut,
      fecha,
      hora,
      tipo,
      revision,
      motivo_no_uso
    FROM `worldwide-470917.cr_reportes.cr_marcas_face_id_24`
    WHERE fecha > (
      SELECT MAX(fecha)
      FROM `worldwide-470917.cr_reportes.cr_marcas_face_id_hist`
    )
  ) marc
  LEFT JOIN equipos eq
    ON eq.cod = marc.cod_dispositivo
  CROSS JOIN params p
  WHERE marc.fecha >= DATE_SUB(p.fecha_desde, INTERVAL 1 DAY)
    AND marc.tipo IN ('Entrada Laboral', 'Salida Laboral')
    AND marc.cod_dispositivo IS NOT NULL
    AND marc.cod_dispositivo != '0'
    AND COALESCE(eq.empresa, marc.empresa) IS NOT NULL
),

-- Un marcaje físico puede tener varias filas (distinta revision). Deduplicar por clave de marca.
marcas_dedup AS (
  SELECT
    empresa,
    rut,
    fecha,
    hora,
    tipo,
    marca_ts,
    LOGICAL_OR(
      IFNULL(revision, '') != 'Objetada'
      AND (
        IFNULL(revision, '') = 'Correcta'
        OR IFNULL(motivo_no_uso, '') = 'Marca Utilizada Correctamente'
      )
    ) AS aceptada,
    LOGICAL_OR(IFNULL(revision, '') != 'Objetada') AS no_objetada,
    LOGICAL_OR(
      IFNULL(revision, '') != 'Objetada'
      AND IFNULL(motivo_no_uso, '') = 'Colaborador Art. 22'
    ) AS motivo_art22,
    -- GPS lejos o centro de costo (CECOS): no usar en la excepción de reemplazo.
    LOGICAL_OR(
      IFNULL(revision, '') != 'Objetada'
      AND (
        REGEXP_CONTAINS(LOWER(IFNULL(motivo_no_uso, '')), r'fuera de tolerancia por gps')
        OR REGEXP_CONTAINS(UPPER(IFNULL(motivo_no_uso, '')), r'CECOS')
      )
    ) AS excluida_gps_o_cecos,
    -- 'Sin entrada laboral registrada' (con o sin punto): solo se usa en salida_validas.
    LOGICAL_OR(
      IFNULL(revision, '') != 'Objetada'
      AND REGEXP_REPLACE(TRIM(IFNULL(motivo_no_uso, '')), r'\.+$', '')
          = 'Sin entrada laboral registrada'
    ) AS motivo_sin_entrada
  FROM marcas_raw
  GROUP BY empresa, rut, fecha, hora, tipo, marca_ts
),

marcas AS (
  SELECT
    empresa,
    rut,
    fecha,
    hora,
    tipo,
    marca_ts,
    aceptada,
    motivo_art22,
    excluida_gps_o_cecos,
    motivo_sin_entrada
  FROM marcas_dedup
  WHERE no_objetada
),

-- Mapeo desde cr_asistencia_hist_tb (salida de vw_cr_asistencia_hist_tb_relevos_agg):
--   dia, cliente_rol, instalacion_rol, rutrol, rutasi, nombrerol, relevo, cargo,
--   turno, her, hsr, empresa, tipo, equip_faceid, inst_esporadica.
-- instalacion_rol / cliente_rol ya vienen vía instalacion_reporte_emp / cliente_reporte
-- en la vista origen; equip_faceid e inst_esporadica ya calculados sobre el nombre
-- ControlRoll (antes del remap). Validar tipos/tipos en BQ al desplegar.
pre_int AS (
  SELECT
    hist.dia,
    hist.cliente_rol,
    hist.instalacion_rol,
    hist.rutrol,
    hist.rutasi,
    (
      CASE
        WHEN REGEXP_REPLACE(CAST(hist.rutrol AS STRING), r'[^0-9]', '')
           = REGEXP_REPLACE(CAST(hist.rutasi AS STRING), r'[^0-9]', '')
          THEN hist.nombrerol
        ELSE COALESCE(
          (
            SELECT TRIM(ARRAY_REVERSE(SPLIT(TRIM(seg), ' | '))[SAFE_OFFSET(0)])
            FROM UNNEST(SPLIT(IFNULL(hist.relevo, ''), ' || ')) AS seg
            WHERE REGEXP_REPLACE(
                    TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(0)]),
                    r'[^0-9]',
                    ''
                  ) = REGEXP_REPLACE(CAST(hist.rutasi AS STRING), r'[^0-9]', '')
            LIMIT 1
          ),
          hist.nombrerol
        )
      END
    ) AS nombre_asistente,
    (
      CASE
        WHEN REGEXP_REPLACE(CAST(hist.rutrol AS STRING), r'[^0-9]', '')
           = REGEXP_REPLACE(CAST(hist.rutasi AS STRING), r'[^0-9]', '')
          THEN 'NO'
        ELSE 'SI'
      END
    ) AS reemplazo,
    hist.cargo,
    hist.turno,
    hist.her,
    hist.hsr,
    hist.empresa,
    hist.inst_esporadica,
    hist.equip_faceid,
    hist.tipo,
    hist.relevo,
    hist.entrada,
    hist.salida
  FROM `worldwide-470917.cr_reportes.cr_asistencia_hist_tb` hist
  CROSS JOIN params p
  WHERE DATE(hist.dia) >= p.fecha_desde
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY
      CAST(hist.rutasi AS STRING),
      hist.her,
      hist.instalacion_rol,
      hist.empresa
    ORDER BY
      CASE UPPER(TRIM(CAST(hist.tipo AS STRING)))
        WHEN 'TIT' THEN 0
        WHEN 'EXR' THEN 0
        WHEN 'NOR' THEN 1
        ELSE 2
      END ASC,
      hist.hsr DESC NULLS LAST,
      CAST(hist.rutrol AS STRING) ASC,
      hist.turno ASC,
      CAST(hist.dia AS STRING) ASC
  ) = 1
),

-- Tramo de cobertura del rutasi, parseado desde relevo.
-- No se usa como ventana si falla el sanity de ±3 h respecto de her/entrada y hsr/salida.
tramo_rutasi AS (
  SELECT
    p.dia,
    p.instalacion_rol,
    p.empresa,
    p.rutasi,
    p.rutrol,
    p.her,
    p.hsr,
    (SELECT COALESCE(
            SAFE.PARSE_TIME('%I:%M%p', CASE
              WHEN REGEXP_CONTAINS(t, r'^0:') THEN REGEXP_REPLACE(t, r'^0:', '12:')
              WHEN REGEXP_CONTAINS(t, r'^[0-9]:') THEN CONCAT('0', t)
              ELSE t
            END),
            SAFE.PARSE_TIME('%H:%M', TRIM(s)),
            SAFE.PARSE_TIME('%H:%M:%S', TRIM(s))
          )
          FROM (
            SELECT
              TRIM(SPLIT(TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(1)]), '/')[SAFE_OFFSET(0)]) AS s,
              REGEXP_REPLACE(
                UPPER(IFNULL(TRIM(SPLIT(TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(1)]), '/')[SAFE_OFFSET(0)]), '')),
                r'[^0-9APM:]',
                ''
              ) AS t
          )) AS t_ini,
    (SELECT COALESCE(
            SAFE.PARSE_TIME('%I:%M%p', CASE
              WHEN REGEXP_CONTAINS(t, r'^0:') THEN REGEXP_REPLACE(t, r'^0:', '12:')
              WHEN REGEXP_CONTAINS(t, r'^[0-9]:') THEN CONCAT('0', t)
              ELSE t
            END),
            SAFE.PARSE_TIME('%H:%M', TRIM(s)),
            SAFE.PARSE_TIME('%H:%M:%S', TRIM(s))
          )
          FROM (
            SELECT
              TRIM(SPLIT(TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(1)]), '/')[SAFE_OFFSET(1)]) AS s,
              REGEXP_REPLACE(
                UPPER(IFNULL(TRIM(SPLIT(TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(1)]), '/')[SAFE_OFFSET(1)]), '')),
                r'[^0-9APM:]',
                ''
              ) AS t
          )) AS t_fin
  FROM pre_int p
  CROSS JOIN UNNEST(SPLIT(IFNULL(p.relevo, ''), ' || ')) AS seg
  WHERE REGEXP_REPLACE(
          IFNULL(TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(0)]), ''),
          r'[^0-9]',
          ''
        ) = REGEXP_REPLACE(IFNULL(CAST(p.rutasi AS STRING), ''), r'[^0-9]', '')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY p.dia, p.instalacion_rol, p.empresa, p.rutasi, p.rutrol, p.her, p.hsr
    ORDER BY TRIM(SPLIT(TRIM(seg), ' | ')[SAFE_OFFSET(1)])
  ) = 1
),

turnos_base AS (
  SELECT
    hist.dia,
    hist.cliente_rol,
    hist.instalacion_rol,
    eq.ult_conexion,
    (CASE WHEN eq.nombre IS NOT NULL THEN 'SI' ELSE 'NO' END) AS instalacion_con_faceid,
    hist.rutrol,
    hist.rutasi,
    hist.nombre_asistente,
    hist.reemplazo,
    hist.cargo,
    hist.turno,
    DATETIME(hist.her) AS her,
    DATETIME(hist.hsr) AS hsr,
    hist.empresa,
    hist.inst_esporadica,
    hist.entrada,
    hist.salida,
    (
      CASE
        WHEN eq_lw.nombre IS NULL AND eq.nombre IS NOT NULL THEN hist.instalacion_rol
        ELSE NULL
      END
    ) AS nuevo_faceid,
    DATETIME(DATE(hist.dia), TIME(DATETIME(hist.her))) AS inicio_turno,
    (
      CASE
        WHEN TIME(DATETIME(hist.hsr)) <= TIME(DATETIME(hist.her))
          THEN DATETIME(DATE_ADD(DATE(hist.dia), INTERVAL 1 DAY), TIME(DATETIME(hist.hsr)))
        ELSE DATETIME(DATE(hist.dia), TIME(DATETIME(hist.hsr)))
      END
    ) AS fin_turno,
    CASE
      WHEN tr.t_ini IS NOT NULL
        THEN DATETIME(DATE(hist.dia), tr.t_ini)
    END AS tramo_ini,
    CASE
      WHEN tr.t_ini IS NOT NULL AND tr.t_fin IS NOT NULL THEN
        CASE
          WHEN tr.t_fin <= tr.t_ini
            THEN DATETIME(DATE_ADD(DATE(hist.dia), INTERVAL 1 DAY), tr.t_fin)
          ELSE DATETIME(DATE(hist.dia), tr.t_fin)
        END
    END AS tramo_fin
  FROM pre_int hist
  -- Enriquecimiento: una sola fila por (nombre, empresa). Marcas siguen usando `equipos` (todos los cod).
  LEFT JOIN equipos_enriq eq
    ON hist.equip_faceid = eq.nombre
   AND hist.empresa = eq.empresa
  LEFT JOIN equipos_lw_enriq eq_lw
    ON hist.equip_faceid = eq_lw.nombre
   AND hist.empresa = eq_lw.empresa
  LEFT JOIN tramo_rutasi tr
    ON hist.dia = tr.dia
   AND hist.instalacion_rol = tr.instalacion_rol
   AND hist.empresa = tr.empresa
   AND hist.rutasi = tr.rutasi
   AND hist.rutrol = tr.rutrol
   AND hist.her = tr.her
   AND hist.hsr = tr.hsr
  WHERE hist.rutasi IS NOT NULL
    AND CAST(hist.rutasi AS STRING) <> ''
    AND CAST(hist.rutasi AS STRING) NOT IN ('90000001', '90000002', '90000009')
),

-- inicio_marca / fin_marca: ventana de cruce. her / hsr / inicio_turno / fin_turno
-- conservan el horario planificado (lo que se muestra).
turnos AS (
  SELECT
    * EXCEPT (entrada, salida, tramo_ini, tramo_fin),
    CASE
      WHEN tramo_ini IS NOT NULL
       AND tramo_fin IS NOT NULL
       AND (
         ABS(DATETIME_DIFF(tramo_ini, inicio_turno, MINUTE)) <= 180
         OR (entrada IS NOT NULL AND ABS(DATETIME_DIFF(tramo_ini, DATETIME(entrada), MINUTE)) <= 180)
       )
       AND (
         ABS(DATETIME_DIFF(tramo_fin, fin_turno, MINUTE)) <= 180
         OR (salida IS NOT NULL AND ABS(DATETIME_DIFF(tramo_fin, DATETIME(salida), MINUTE)) <= 180)
       )
        THEN tramo_ini
      WHEN entrada IS NOT NULL AND salida IS NOT NULL THEN DATETIME(entrada)
      ELSE inicio_turno
    END AS inicio_marca,
    CASE
      WHEN tramo_ini IS NOT NULL
       AND tramo_fin IS NOT NULL
       AND (
         ABS(DATETIME_DIFF(tramo_ini, inicio_turno, MINUTE)) <= 180
         OR (entrada IS NOT NULL AND ABS(DATETIME_DIFF(tramo_ini, DATETIME(entrada), MINUTE)) <= 180)
       )
       AND (
         ABS(DATETIME_DIFF(tramo_fin, fin_turno, MINUTE)) <= 180
         OR (salida IS NOT NULL AND ABS(DATETIME_DIFF(tramo_fin, DATETIME(salida), MINUTE)) <= 180)
       )
        THEN tramo_fin
      WHEN entrada IS NOT NULL AND salida IS NOT NULL THEN DATETIME(salida)
      ELSE fin_turno
    END AS fin_marca
  FROM turnos_base
),


entrada_cands AS (
  SELECT
    t.dia,
    t.cliente_rol,
    t.instalacion_rol,
    t.ult_conexion,
    t.instalacion_con_faceid,
    t.rutrol,
    t.rutasi,
    t.reemplazo,
    t.cargo,
    t.turno,
    t.her,
    t.hsr,
    t.empresa,
    m.tipo AS tipo_marca,
    m.hora AS hora_marca,
    m.aceptada,
    m.motivo_art22,
    m.excluida_gps_o_cecos,
    m.marca_ts,
    ABS(DATETIME_DIFF(m.marca_ts, t.inicio_marca, SECOND)) AS diferencia
  FROM turnos t
  INNER JOIN marcas m
    ON t.empresa = m.empresa
   AND t.rutasi = m.rut
   AND m.tipo = 'Entrada Laboral'
   AND m.marca_ts BETWEEN DATETIME_SUB(t.inicio_marca, INTERVAL 3 HOUR)
                      AND DATETIME_ADD(t.inicio_marca, INTERVAL 3 HOUR)
),

entrada_flags AS (
  SELECT
    c.*,
    MAX(CAST(c.aceptada AS INT64)) OVER (
      PARTITION BY
        c.dia, c.cliente_rol, c.instalacion_rol, c.ult_conexion, c.instalacion_con_faceid,
        c.rutrol, c.rutasi, c.reemplazo, c.cargo, c.turno, c.her, c.hsr, c.empresa
    ) AS hay_aceptada,
    MIN(CAST(c.motivo_art22 AS INT64)) OVER (
      PARTITION BY
        c.dia, c.cliente_rol, c.instalacion_rol, c.ult_conexion, c.instalacion_con_faceid,
        c.rutrol, c.rutasi, c.reemplazo, c.cargo, c.turno, c.her, c.hsr, c.empresa
    ) AS todas_art22
  FROM entrada_cands c
),

entrada_validas AS (
  SELECT *
  FROM entrada_flags
  WHERE (hay_aceptada = 1 AND aceptada)
     OR (hay_aceptada = 0 AND todas_art22 = 1)
     OR (
          hay_aceptada = 0
          AND reemplazo = 'SI'
          AND LENGTH(REGEXP_REPLACE(IFNULL(CAST(rutasi AS STRING), ''), r'[^0-9]', '')) >= 7
          AND NOT excluida_gps_o_cecos
        )
),

entrada_exclusivas AS (
  SELECT *
  FROM entrada_validas
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY rutasi, empresa, marca_ts
    ORDER BY
      diferencia ASC,
      CASE WHEN reemplazo = 'NO' THEN 0 ELSE 1 END,
      her,
      instalacion_rol,
      CAST(rutrol AS STRING)
  ) = 1
),

entrada_best AS (
  SELECT * EXCEPT (rn, aceptada, motivo_art22, hay_aceptada, todas_art22, excluida_gps_o_cecos, marca_ts)
  FROM (
    SELECT
      v.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          v.dia, v.cliente_rol, v.instalacion_rol, v.ult_conexion, v.instalacion_con_faceid,
          v.rutrol, v.rutasi, v.reemplazo, v.cargo, v.turno, v.her, v.hsr, v.empresa
        ORDER BY v.diferencia ASC
      ) AS rn
    FROM entrada_exclusivas v
  )
  WHERE rn = 1
),

salida_cands AS (
  SELECT
    t.dia,
    t.cliente_rol,
    t.instalacion_rol,
    t.ult_conexion,
    t.instalacion_con_faceid,
    t.rutrol,
    t.rutasi,
    t.reemplazo,
    t.cargo,
    t.turno,
    t.her,
    t.hsr,
    t.empresa,
    m.tipo AS tipo_marca,
    m.hora AS hora_marca,
    m.aceptada,
    m.motivo_art22,
    m.excluida_gps_o_cecos,
    m.motivo_sin_entrada,
    m.marca_ts,
    ABS(DATETIME_DIFF(m.marca_ts, t.fin_marca, SECOND)) AS diferencia
  FROM turnos t
  INNER JOIN marcas m
    ON t.empresa = m.empresa
   AND t.rutasi = m.rut
   AND m.tipo = 'Salida Laboral'
   AND m.marca_ts BETWEEN DATETIME_SUB(t.fin_marca, INTERVAL 3 HOUR)
                      AND DATETIME_ADD(t.fin_marca, INTERVAL 3 HOUR)
),

salida_flags AS (
  SELECT
    c.*,
    MAX(CAST(c.aceptada AS INT64)) OVER (
      PARTITION BY
        c.dia, c.cliente_rol, c.instalacion_rol, c.ult_conexion, c.instalacion_con_faceid,
        c.rutrol, c.rutasi, c.reemplazo, c.cargo, c.turno, c.her, c.hsr, c.empresa
    ) AS hay_aceptada,
    MIN(CAST(c.motivo_art22 AS INT64)) OVER (
      PARTITION BY
        c.dia, c.cliente_rol, c.instalacion_rol, c.ult_conexion, c.instalacion_con_faceid,
        c.rutrol, c.rutasi, c.reemplazo, c.cargo, c.turno, c.her, c.hsr, c.empresa
    ) AS todas_art22
  FROM salida_cands c
),

salida_validas AS (
  SELECT *
  FROM salida_flags
  WHERE (hay_aceptada = 1 AND aceptada)
     OR (hay_aceptada = 0 AND todas_art22 = 1)
     OR (
          hay_aceptada = 0
          AND reemplazo = 'SI'
          AND LENGTH(REGEXP_REPLACE(IFNULL(CAST(rutasi AS STRING), ''), r'[^0-9]', '')) >= 7
          AND NOT excluida_gps_o_cecos
        )
     OR (hay_aceptada = 0 AND motivo_sin_entrada)
),

salida_exclusivas AS (
  SELECT *
  FROM salida_validas
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY rutasi, empresa, marca_ts
    ORDER BY
      diferencia ASC,
      CASE WHEN reemplazo = 'NO' THEN 0 ELSE 1 END,
      her,
      instalacion_rol,
      CAST(rutrol AS STRING)
  ) = 1
),

salida_best AS (
  SELECT * EXCEPT (rn, aceptada, motivo_art22, hay_aceptada, todas_art22, excluida_gps_o_cecos, motivo_sin_entrada, marca_ts)
  FROM (
    SELECT
      v.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          v.dia, v.cliente_rol, v.instalacion_rol, v.ult_conexion, v.instalacion_con_faceid,
          v.rutrol, v.rutasi, v.reemplazo, v.cargo, v.turno, v.her, v.hsr, v.empresa
        ORDER BY v.diferencia ASC
      ) AS rn
    FROM salida_exclusivas v
  )
  WHERE rn = 1
),

int2 AS (
  SELECT
    t.dia,
    t.cliente_rol,
    t.instalacion_rol,
    t.ult_conexion,
    t.instalacion_con_faceid,
    t.rutrol,
    t.rutasi,
    t.nombre_asistente,
    t.reemplazo,
    t.cargo,
    t.turno,
    t.her,
    t.hsr,
    t.empresa,
    t.inst_esporadica,
    t.nuevo_faceid,
    e.tipo_marca AS marca_entrada,
    e.hora_marca AS hora_entrada,
    s.tipo_marca AS marca_salida,
    s.hora_marca AS hora_salida,
    e.diferencia AS diferencia_entrada,
    s.diferencia AS diferencia_salida
  FROM turnos t
  LEFT JOIN entrada_best e
    ON t.dia = e.dia
   AND t.cliente_rol = e.cliente_rol
   AND t.instalacion_rol = e.instalacion_rol
   AND ((t.ult_conexion IS NULL AND e.ult_conexion IS NULL) OR t.ult_conexion = e.ult_conexion)
   AND t.instalacion_con_faceid = e.instalacion_con_faceid
   AND t.rutrol = e.rutrol
   AND t.rutasi = e.rutasi
   AND t.reemplazo = e.reemplazo
   AND t.cargo = e.cargo
   AND t.turno = e.turno
   AND t.her = e.her
   AND t.hsr = e.hsr
   AND t.empresa = e.empresa
  LEFT JOIN salida_best s
    ON t.dia = s.dia
   AND t.cliente_rol = s.cliente_rol
   AND t.instalacion_rol = s.instalacion_rol
   AND ((t.ult_conexion IS NULL AND s.ult_conexion IS NULL) OR t.ult_conexion = s.ult_conexion)
   AND t.instalacion_con_faceid = s.instalacion_con_faceid
   AND t.rutrol = s.rutrol
   AND t.rutasi = s.rutasi
   AND t.reemplazo = s.reemplazo
   AND t.cargo = s.cargo
   AND t.turno = s.turno
   AND t.her = s.her
   AND t.hsr = s.hsr
   AND t.empresa = s.empresa
),

max_entrada_ints AS (
  SELECT
    instalacion_rol,
    empresa,
    MAX(DATETIME(EXTRACT(DATE FROM dia), hora_entrada)) AS ultima_marca_entrada,
    MAX(DATETIME(EXTRACT(DATE FROM dia), hora_salida)) AS ultima_marca_salida
  FROM int2
  GROUP BY 1, 2
),

final AS (
  SELECT
    int2.*,
    (
      CASE
        WHEN int2.instalacion_con_faceid = 'SI'
          AND int2.marca_entrada IS NULL
          AND int2.marca_salida IS NULL THEN 'No Marca'
        WHEN int2.instalacion_con_faceid = 'SI'
          AND int2.marca_entrada IS NOT NULL
          AND int2.marca_salida IS NOT NULL THEN 'OK'
        WHEN int2.instalacion_con_faceid = 'SI'
          AND int2.marca_entrada IS NOT NULL
          AND int2.marca_salida IS NULL THEN 'Marca entrada'
        WHEN int2.instalacion_con_faceid = 'SI'
          AND int2.marca_entrada IS NULL
          AND int2.marca_salida IS NOT NULL THEN 'Marca salida'
        WHEN int2.instalacion_con_faceid = 'NO'
          AND int2.marca_entrada IS NULL
          AND int2.marca_salida IS NULL THEN 'OK'
      END
    ) AS estado,
    1 AS rn,
    b.ultima_marca_entrada
  FROM int2
  LEFT JOIN max_entrada_ints b
    ON int2.instalacion_rol = b.instalacion_rol
   AND int2.empresa = b.empresa
),

data_final AS (
  SELECT
    a.*,
    b.zona
  FROM final a
  LEFT JOIN `worldwide-470917.mantenedores.zonas_instalaciones` b
    ON a.instalacion_rol = b.instalacion
   AND a.empresa = b.empresa
  WHERE a.rn = 1
    AND (
      UPPER(a.cargo) LIKE '%GUARDIA%'
      OR UPPER(a.cargo) LIKE '%OPERADOR%'
      OR UPPER(a.cargo) LIKE '%RECEPCIONISTA%'
      OR UPPER(a.cargo) LIKE '%JEFE DE GRUPO%'
      OR UPPER(a.cargo) LIKE '%ASEADOR%'
      OR UPPER(a.cargo) LIKE '%JARDINERO%'
      OR UPPER(a.cargo) LIKE '%AUXILIAR%'
    )
    AND a.nombre_asistente NOT IN ('sin cubrir antes', 'sin cubrir despues')
),

-- Una fila por (cargo, instalación, empresa). Varios nombres → lista ordenada única.
cargos AS (
  SELECT
    STRING_AGG(DISTINCT a.nombre_completo, ', ' ORDER BY a.nombre_completo) AS nombre,
    a.cargo,
    b.instalacion_rol,
    b.empresa
  FROM `worldwide-470917.app_clientes.usuario_personas` a
  LEFT JOIN `worldwide-470917.app_clientes.usuario_instalaciones` b
    ON b.email_login = a.email_login
  WHERE b.instalacion_rol IS NOT NULL
  GROUP BY a.cargo, b.instalacion_rol, b.empresa
),

output AS (
  SELECT
    a.*,
    b.nombre AS subgerente,
    c.nombre AS jefe_zonal,
    d.nombre AS supervisor
  FROM data_final a
  LEFT JOIN cargos b
    ON a.instalacion_rol = b.instalacion_rol
   AND a.empresa = b.empresa
   AND b.cargo = 'Subgerente'
  -- IMPORTANTE: comparar c.empresa / d.empresa (no b.empresa). Usar b.empresa aquí
  -- era TRUE siempre que hubiera Subgerente y multiplicaba filas (producto cartesiano
  -- de todos los Jefe Operaciones × Supervisor de la instalación, sin filtrar empresa).
  LEFT JOIN cargos c
    ON a.instalacion_rol = c.instalacion_rol
   AND a.empresa = c.empresa
   AND c.cargo = 'Jefe Operaciones'
  LEFT JOIN cargos d
    ON a.instalacion_rol = d.instalacion_rol
   AND a.empresa = d.empresa
   AND d.cargo = 'Supervisor'
  WHERE UPPER(a.cliente_rol) NOT LIKE '%ADMINISTRA%'
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
  o.* REPLACE (
    `worldwide-470917.cr_vistas_reporte.instalacion_reporte_emp`(o.empresa, o.instalacion_rol) AS instalacion_rol,
    `worldwide-470917.cr_vistas_reporte.cliente_reporte`(o.empresa, o.instalacion_rol, o.cliente_rol) AS cliente_rol
  ),
  j.jefes_instalacion
FROM output o
LEFT JOIN jefes_instalacion j
  ON UPPER(TRIM(o.instalacion_rol)) = j.instalacion_key
 AND UPPER(COALESCE(NULLIF(TRIM(o.empresa), ''), 'Security')) = j.empresa_key
;
