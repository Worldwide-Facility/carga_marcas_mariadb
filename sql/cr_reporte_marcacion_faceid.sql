-- worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid
-- Turnos del histórico de asistencia cruzados con las marcas FaceID de entrada y salida.
--
-- Regla de cruce (empresa + rutasi):
--   * Entrada laboral: timestamp de la marca dentro de ±3 h del inicio del turno (her en fecha dia).
--   * Salida laboral: timestamp dentro de ±3 h del fin del turno (hsr); si TIME(hsr) <= TIME(her)
--     el fin se calcula al día siguiente (turno nocturno que cruza medianoche).
--   * Se excluyen colaciones (Inicio/Término Colación).
--   * Aceptación: revision = 'Correcta' O motivo_no_uso = 'Marca Utilizada Correctamente',
--     excepto revision = 'Objetada' (nunca cuenta). El hist puede repetir el mismo marcaje
--     (empresa, rut, fecha, hora, tipo) con distintas revision: se deduplica y cuenta aceptado
--     si alguna fila no-Objetada cumple la condición.
--   * Excepción Art. 22: si no hay aceptada en la ventana y todas las marcas no-Objetadas de
--     ese lado en la ventana tienen motivo 'Colaborador Art. 22', se cuenta esa marca.
--   * Si hay varias válidas, se elige la más cercana a la hora de referencia (inicio/fin).
--   * Universo: solo turnos con rutasi no vacío (sin fallback a rutrol).
--
-- Complemento en vivo: marcas_raw une el hist diario (carga ~08:00, cubre hasta ayer)
-- con cr_marcas_face_id_24 (cada ~5 min). Solo entran filas de _24 con
-- fecha > MAX(fecha) del hist: el hist tiene precedencia apenas carga un día, y las
-- salidas de turnos nocturnos de hoy no quedan ocultas en el portal hasta mañana.
--
-- Costo: marcas prefiltradas por fecha_desde del rol (−1/+1 día) y solo columnas necesarias.
-- jefes_instalacion: jefes (JEFE_WFSA activos) asignados a la instalación en usuario_instalaciones.
--
-- Cargos (subgerente / jefe zonal / supervisor):
--   * Un join por cargo contra el CTE `cargos`, siempre con instalacion_rol + empresa + cargo.
--   * Varias personas del mismo cargo en la misma instalación/empresa se agregan con
--     STRING_AGG(DISTINCT nombre ORDER BY nombre) separado por ', ' (una sola fila).
--   * jefes_instalacion ya agrega con STRING_AGG DISTINCT; no multiplica filas.

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` AS
WITH params AS (
  SELECT DATE('2025-10-01') AS fecha_desde
),

equipos AS (
  SELECT
    eq.nombre,
    eq.ult_conexion,
    eq.empresa,
    eq.cod
  FROM `worldwide-470917.cr_reportes.cr_equipos_faceid` eq
),

-- Solo columnas necesarias; rango de fechas del rol ±1 día (entrada temprana / salida nocturna).
marcas_raw AS (
  SELECT
    eq.empresa,
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
  INNER JOIN equipos eq
    ON eq.cod = marc.cod_dispositivo
  CROSS JOIN params p
  WHERE marc.fecha >= DATE_SUB(p.fecha_desde, INTERVAL 1 DAY)
    AND marc.tipo IN ('Entrada Laboral', 'Salida Laboral')
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
    ) AS motivo_art22
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
    motivo_art22
  FROM marcas_dedup
  WHERE no_objetada
),

pre_int AS (
  SELECT
    hist.dia,
    hist.cliente_rol,
    hist.instalacion_rol,
    hist.rutrol,
    hist.rutasi,
    (
      CASE
        WHEN hist.rutrol = hist.rutasi THEN hist.nombrerol
        ELSE TRIM(ARRAY_REVERSE(SPLIT(hist.relevo, ' | '))[OFFSET(0)])
      END
    ) AS nombre_asistente,
    (CASE WHEN hist.rutrol = hist.rutasi THEN 'NO' ELSE 'SI' END) AS reemplazo,
    hist.cargo,
    hist.turno,
    hist.her,
    hist.hsr,
    hist.empresa,
    (CASE WHEN e.instalacion IS NULL THEN FALSE ELSE TRUE END) AS inst_esporadica,
    (CASE WHEN d.equipo_nombre IS NULL THEN hist.instalacion_rol ELSE d.equipo_nombre END) AS equip_faceid
  FROM `worldwide-470917.cr_vistas_reporte.cr_asistencia_hist` hist
  LEFT JOIN `worldwide-470917.mantenedores.asignacion_faceid` d
    ON hist.instalacion_rol = d.instalacion
   AND hist.empresa = d.empresa
  LEFT JOIN `worldwide-470917.mantenedores.instalaciones_esporadicas` e
    ON hist.instalacion_rol = e.instalacion
   AND hist.empresa = e.empresa
),

turnos AS (
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
    ) AS fin_turno
  FROM pre_int hist
  CROSS JOIN params p
  LEFT JOIN equipos eq
    ON hist.equip_faceid = eq.nombre
   AND hist.empresa = eq.empresa
  LEFT JOIN `worldwide-470917.cr_reportes.cr_equipos_faceid_lw` eq_lw
    ON hist.equip_faceid = eq_lw.nombre
   AND hist.empresa = eq_lw.empresa
  WHERE DATE(hist.dia) >= p.fecha_desde
    AND hist.rutasi IS NOT NULL
    AND hist.rutasi <> ''
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
    ABS(DATETIME_DIFF(m.marca_ts, t.inicio_turno, SECOND)) AS diferencia
  FROM turnos t
  INNER JOIN marcas m
    ON t.empresa = m.empresa
   AND t.rutasi = m.rut
   AND m.tipo = 'Entrada Laboral'
   AND m.marca_ts BETWEEN DATETIME_SUB(t.inicio_turno, INTERVAL 3 HOUR)
                      AND DATETIME_ADD(t.inicio_turno, INTERVAL 3 HOUR)
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
),

entrada_best AS (
  SELECT * EXCEPT (rn, aceptada, motivo_art22, hay_aceptada, todas_art22)
  FROM (
    SELECT
      v.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          v.dia, v.cliente_rol, v.instalacion_rol, v.ult_conexion, v.instalacion_con_faceid,
          v.rutrol, v.rutasi, v.reemplazo, v.cargo, v.turno, v.her, v.hsr, v.empresa
        ORDER BY v.diferencia ASC
      ) AS rn
    FROM entrada_validas v
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
    ABS(DATETIME_DIFF(m.marca_ts, t.fin_turno, SECOND)) AS diferencia
  FROM turnos t
  INNER JOIN marcas m
    ON t.empresa = m.empresa
   AND t.rutasi = m.rut
   AND m.tipo = 'Salida Laboral'
   AND m.marca_ts BETWEEN DATETIME_SUB(t.fin_turno, INTERVAL 3 HOUR)
                      AND DATETIME_ADD(t.fin_turno, INTERVAL 3 HOUR)
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
),

salida_best AS (
  SELECT * EXCEPT (rn, aceptada, motivo_art22, hay_aceptada, todas_art22)
  FROM (
    SELECT
      v.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          v.dia, v.cliente_rol, v.instalacion_rol, v.ult_conexion, v.instalacion_con_faceid,
          v.rutrol, v.rutasi, v.reemplazo, v.cargo, v.turno, v.her, v.hsr, v.empresa
        ORDER BY v.diferencia ASC
      ) AS rn
    FROM salida_validas v
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
