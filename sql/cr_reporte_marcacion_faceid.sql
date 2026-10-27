-- worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid
-- Turnos del histórico de asistencia cruzados con las marcas FaceID de entrada y salida.
-- jefes_instalacion: jefes (JEFE_WFSA activos) asignados a la instalación en usuario_instalaciones.

CREATE OR REPLACE VIEW `worldwide-470917.cr_vistas_reporte.cr_reporte_marcacion_faceid` AS
with base_marcacion as (
SELECT eq.nombre,eq.ult_conexion,eq.ult_geo_latitud,eq.ult_geo_longitud,marc.tipo,marc.rut,marc.nombre_colaborador,marc.fecha,marc.hora,eq.empresa
FROM `worldwide-470917.cr_reportes.cr_equipos_faceid` eq
left join `worldwide-470917.cr_reportes.cr_marcas_face_id_hist` marc on eq.cod=marc.cod_dispositivo
order by eq.nombre,marc.fecha,marc.hora),



pre_int as (
select hist.dia
,hist.cliente_rol
,hist.instalacion_rol
,hist.rutrol 
,hist.rutasi
, (case when hist.rutrol = hist.rutasi then hist.nombrerol else TRIM(ARRAY_REVERSE(SPLIT(hist.relevo, ' | '))[OFFSET(0)]) end) as nombre_asistente
, (case when hist.rutrol = hist.rutasi then "NO" else "SI" end) as reemplazo
,hist.cargo
,hist.turno
,hist.her
,hist.hsr
,hist.empresa
,(case when e.instalacion is null then false else true end) as inst_esporadica
,(case when d.equipo_nombre is null then hist.instalacion_rol else d.equipo_nombre end) as equip_faceid


from `worldwide-470917.cr_vistas_reporte.cr_asistencia_hist` hist
left join worldwide-470917.mantenedores.asignacion_faceid d on hist.instalacion_rol = d.instalacion and hist.empresa = d.empresa
left join worldwide-470917.mantenedores.instalaciones_esporadicas e on hist.instalacion_rol = e.instalacion and hist.empresa = e.empresa

),



int as (
select hist.dia
,hist.cliente_rol
,hist.instalacion_rol
,eq.ult_conexion
,(case when eq.nombre is not null then 'SI' else 'NO' end) as instalacion_con_faceid
,hist.rutrol 
,hist.rutasi
,nombre_asistente
,reemplazo
,hist.cargo
,hist.turno
,hist.her
,hist.hsr
,hist.empresa
,(case when marc.hora is null then "NO" else "SI" end) as marca_faceid
,marc.tipo as tipo_marca
,marc.hora as hora_marca
,hist.inst_esporadica
,(case when eq_lw.nombre is null and eq.nombre is not null then hist.instalacion_rol else null end) as nuevo_faceid

from pre_int hist

left join base_marcacion marc on  hist.empresa = marc.empresa and hist.rutasi=marc.rut and hist.dia=marc.fecha
left join `worldwide-470917.cr_reportes.cr_equipos_faceid` eq on hist.equip_faceid=eq.nombre and hist.empresa=eq.empresa
left join `worldwide-470917.cr_reportes.cr_equipos_faceid_lw` eq_lw on hist.equip_faceid=eq_lw.nombre and hist.empresa=eq_lw.empresa
where  hist.dia >= '2025-10-01' and  (marc.tipo not in ("Inicio Colación","Término Colación") or marc.tipo is null) and rutasi is not null and rutasi <>"" ),






int2 as (
select 
COALESCE(e.dia,s.dia) as dia
, COALESCE(e.cliente_rol,s.cliente_rol) as cliente_rol
, COALESCE(e.instalacion_rol,s.instalacion_rol) as instalacion_rol
, COALESCE(e.ult_conexion,s.ult_conexion) as ult_conexion
, COALESCE(e.instalacion_con_faceid,s.instalacion_con_faceid) as instalacion_con_faceid
, COALESCE(e.rutrol,s.rutrol) as rutrol 
, COALESCE(e.rutasi,s.rutasi) as rutasi
, COALESCE(e.nombre_asistente,s.nombre_asistente) as nombre_asistente
, COALESCE(e.reemplazo,s.reemplazo) as reemplazo
, COALESCE(e.cargo,s.cargo) as cargo
, COALESCE(e.turno,s.turno) as turno
, datetime(COALESCE(e.her,s.her)) as her
, datetime(COALESCE(e.hsr,s.hsr)) as hsr
, COALESCE(e.empresa,s.empresa) as empresa
, COALESCE(e.inst_esporadica,s.inst_esporadica) as inst_esporadica
, COALESCE(e.nuevo_faceid,s.nuevo_faceid) as nuevo_faceid
, e.tipo_marca as marca_entrada
, e.hora_marca as hora_entrada
, s.tipo_marca as marca_salida
, s.hora_marca as hora_salida

,abs(datetime_diff(datetime(e.her), datetime(date(e.dia),e.hora_marca), second) )as diferencia_entrada
#,abs(datetime_diff(s.her,datetime(  (case when time(COALESCE(e.her,s.her))< time(COALESCE(e.hsr,s.hsr)) then date_add(date(s.dia), interval 1 day) else date(s.dia) end),s.hora_marca), second)) as diferencia_salida
,abs(datetime_diff(datetime(s.hsr), datetime(date(datetime(s.hsr)),s.hora_marca), second) ) as diferencia_salida
from (select * from int where tipo_marca='Entrada Laboral') e
full outer join (select * from int where tipo_marca='Salida Laboral') s
on e.dia=s.dia
and e.cliente_rol=s.cliente_rol
and e.instalacion_rol=s.instalacion_rol
and e.ult_conexion=s.ult_conexion
and e.instalacion_con_faceid=s.instalacion_con_faceid
and e.rutrol=s.rutrol
and e.rutasi=s.rutasi
and e.reemplazo=s.reemplazo
and e.cargo=s.cargo
and e.turno=s.turno
and e.her=s.her
and e.hsr=s.hsr
union all
select dia
, cliente_rol
, instalacion_rol
, ult_conexion
, instalacion_con_faceid
, rutrol 
, rutasi
, nombre_asistente
, reemplazo
, cargo
, turno
, her
, hsr
, empresa
, inst_esporadica
, nuevo_faceid
, null as marca_entrada
, null as hora_entrada
, null as marca_salida
, null as hora_salida
, null as diferencia_entrada
, null as diferencia_salida
from int where tipo_marca is null
),


max_entrada_ints as (select
instalacion_rol,empresa,max(DATETIME(EXTRACT(DATE FROM dia), hora_entrada) ) as ultima_marca_entrada
,max(DATETIME(EXTRACT(DATE FROM dia), hora_salida) ) as ultima_marca_salida
from int2
group by 1,2
),


final as (
select int2.* 
, (case 
when int2.instalacion_con_faceid="SI" and int2.marca_entrada is null and int2.marca_salida is null then "No Marca"
when int2.instalacion_con_faceid="SI" and int2.marca_entrada is not null and int2.marca_salida is not null then "OK"
when int2.instalacion_con_faceid="SI" and int2.marca_entrada is not null and int2.marca_salida is null then "Marca entrada"
when int2.instalacion_con_faceid="SI" and int2.marca_entrada is null and int2.marca_salida is not null then "Marca salida"
when int2.instalacion_con_faceid="NO" and int2.marca_entrada is null and int2.marca_salida is null then "OK"
end) as estado
, row_number() over(partition by dia
, int2.cliente_rol
, int2.instalacion_rol
, int2.ult_conexion
, int2.instalacion_con_faceid
, int2.rutrol 
, int2.rutasi
, int2.reemplazo
, int2.cargo
, int2.turno
, int2.her
, int2.hsr order by diferencia_entrada,diferencia_salida asc) as rn
, b.ultima_marca_entrada
from int2 
left join max_entrada_ints b on int2.instalacion_rol=b.instalacion_rol and int2.empresa=b.empresa),

data_final as (
select a.*,b.zona from final a
left join worldwide-470917.mantenedores.zonas_instalaciones b on a.instalacion_rol=b.instalacion and a.empresa=b.empresa

where a.rn=1 
and (upper(a.cargo) like "%GUARDIA%" 
OR upper(a.cargo) like "%OPERADOR%"
OR upper(a.cargo) like "%RECEPCIONISTA%"
OR upper(a.cargo) like "%JEFE DE GRUPO%"
OR upper(a.cargo) like "%ASEADOR%"
OR upper(a.cargo) like "%JARDINERO%"
OR upper(a.cargo) like "%AUXILIAR%"
)
and a.nombre_asistente not in ("sin cubrir antes","sin cubrir despues")),

cargos as (
select 
 STRING_AGG(a.nombre_completo, ',') as nombre
,a.cargo 
,b.instalacion_rol
,b.empresa
from worldwide-470917.app_clientes.usuario_personas a
left join `worldwide-470917.app_clientes.usuario_instalaciones` b on b.email_login = a.email_login
group by a.cargo ,b.instalacion_rol,b.empresa),

output as (
select a.*
, b.nombre as subgerente
, c.nombre as jefe_zonal
, d.nombre as supervisor
from data_final a
left join cargos b on a.instalacion_rol = b.instalacion_rol and a.empresa=b.empresa and b.cargo="Subgerente"
left join cargos c on a.instalacion_rol = c.instalacion_rol and a.empresa=b.empresa and c.cargo="Jefe Operaciones"
left join cargos d on a.instalacion_rol = d.instalacion_rol and a.empresa=b.empresa and d.cargo="Supervisor"
WHERE upper(A.cliente_rol) not like('%ADMINISTRA%')),

jefes_instalacion as (
  select
    UPPER(TRIM(ui.instalacion_rol)) as instalacion_key,
    UPPER(COALESCE(NULLIF(TRIM(ui.empresa), ''), 'Security')) as empresa_key,
    STRING_AGG(
      DISTINCT COALESCE(NULLIF(TRIM(p.nombre_completo), ''), LOWER(TRIM(p.email_login))),
      ', '
      ORDER BY COALESCE(NULLIF(TRIM(p.nombre_completo), ''), LOWER(TRIM(p.email_login))) ASC
    ) as jefes_instalacion
  from `worldwide-470917.app_clientes.usuario_instalaciones` ui
  inner join `worldwide-470917.app_clientes.v_permisos_usuarios` p
    on LOWER(TRIM(ui.email_login)) = LOWER(TRIM(p.email_login))
  where ui.puede_ver = TRUE
    and p.usuario_activo = TRUE
    and p.rol_id = 'JEFE_WFSA'
  group by instalacion_key, empresa_key
)

select o.*, j.jefes_instalacion
from output o
left join jefes_instalacion j
  on UPPER(TRIM(o.instalacion_rol)) = j.instalacion_key
 and UPPER(COALESCE(NULLIF(TRIM(o.empresa), ''), 'Security')) = j.empresa_key
;
