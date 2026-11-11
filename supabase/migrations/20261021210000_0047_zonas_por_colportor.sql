-- ============================================================================
-- 0047 · Las zonas de cada colportor para Equipo: la actual y las anteriores, con sus fechas
--        (backend-supabase#98, HU-CAM-006, vista 33 «Equipo»)
--
-- Origen: el cambio de requisitos del 21/10 (reunión del 05/10, docs#69). La vista 33 muestra, junto
-- a la zona de cada colportor, sus «Zonas anteriores» con las fechas («Bisso · 01/09 a 05/10»). El
-- historial ya se guarda (0022, campania_colportor_zona_historial: un tramo por zona con desde,
-- hasta y quién), pero ninguna lectura del panel lo devolvía: colportores_de_campania() trae solo la
-- zona de hoy y la 0022 dejó el historial «solo para auditoría». Esta migración agrega la lectura.
--
--   zonas_por_colportor(p_campania_id)
--     -> (colportor_id, nombre, apellido, ciudad_id, ciudad_nombre, zona_id, zona_nombre,
--         zona_desde, zona_desde_inicial, zonas_anteriores)
--
-- Una fila por inscripto vivo de la campaña (los mismos de colportores_de_campania(): inscripción
-- viva y cuenta no dada de baja), tenga zona o no, por apellido, nombre. Sin tablas ni columnas
-- nuevas: todo sale de campania_colportor y de su historial.
--
-- ## Qué trae cada fila
--
--   · zona_id, zona_nombre   la zona de hoy (null = «Sin zona»). ciudad_id y ciudad_nombre son los
--                            de ESA zona, como en acompaniamientos_por_colportor() (0043, decisión
--                            del 21/10 «Ciudad colp.»): con ellos el panel agrupa por ciudad.
--   · zona_desde             desde qué día (Montevideo) tiene la zona de hoy: el desde del tramo
--                            abierto. null si no tiene zona.
--   · zona_desde_inicial     true si ese tramo ya existía cuando se activó el historial (0022): su
--                            desde es el de esa migración y no el de la asignación real, que no se
--                            puede reconstruir («No se inventa una fecha: se marca»). El panel
--                            decide cómo mostrarlo. null si no tiene zona.
--   · zonas_anteriores       jsonb, un renglón por cada tramo YA CERRADO de esta inscripción, del más
--                            viejo al más nuevo (desde, id): [{zona_id, nombre, ciudad_id,
--                            ciudad_nombre, desde, hasta, inicial, eliminada}]. [] si nunca tuvo
--                            otra. Las fechas son el día de Montevideo del cambio (no la hora): el
--                            panel muestra «01/09 a 05/10» sin depender de la zona horaria del
--                            navegador. Un tramo cierra donde abre el siguiente (0022): el «hasta»
--                            de uno y el «desde» del siguiente caen el mismo día. La misma zona
--                            puede aparecer dos veces (la tuvo, la perdió y volvió).
--                              eliminada  true si la zona se dio de baja después (sigue figurando:
--                                         el historial no se borra y el nombre es el que tenía);
--                                         el panel no ofrece abrirla en el editor.
--                              inicial    como zona_desde_inicial, para ese tramo.
--
-- ## La inscripción de baja y el que vuelve
--
-- Solo se leen las inscripciones VIVAS. Dar de baja la inscripción cierra el tramo (0022) y, cuando
-- el colportor vuelve (HU-CAM-004, 0028 reactiva la misma fila), vuelve sin zona: el tramo de antes
-- aparece como zona anterior, con el día de la baja como «hasta», y el colportor figura en
-- «Sin zona» hasta que le asignen una.
--
-- ## Regla del diseño: las casas siguen contando
--
-- «Las casas registradas en una zona vieja siguen contando para el colportor» (vista 33). Esta
-- lectura no cuenta casas ni mira ubicaciones: la ubicación no guarda zona ni campaña (R-UB06), así
-- que ningún dato de acá le resta casas a nadie por haber cambiado de zona. La columna «Casas
-- registradas» de la tabla necesita una definición que ni la HU ni el canvas dan (qué se cuenta y
-- desde cuándo): quedó como pendiente del PR (pendientes/backend-supabase-98-impl-261021-2125.md),
-- no se inventó.
--
-- ## Permiso
--
-- Igual que acompaniamientos_por_colportor() (0043), la otra lectura de la misma tabla de Equipo: el
-- permiso primero (42501 sin sesión, sin el rol o campaña ajena), CZ001 si la campaña no existe, y
-- una campaña por empezar o TERMINADA se lee (el historial se consulta también al cierre; si una
-- de las dos lecturas diera CZ011 la pestaña entera fallaría). Solo el ADMIN y el coordinador de la
-- campaña. Sin email ni datos de clientes: nombre, apellido, zonas y fechas.
-- VOLATILE porque llama a lanzar_motivo_mapa() (supabase-js la manda por POST).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create function public.zonas_por_colportor(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, ciudad_id uuid, ciudad_nombre text,
               zona_id uuid, zona_nombre text, zona_desde date, zona_desde_inicial boolean,
               zonas_anteriores jsonb)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee; una por empezar, también.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver las zonas de su equipo. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select i.usuario_id,
           usr.nombre,
           usr.apellido,
           ci.ciudad_id,
           ciu.nombre,
           z.id,
           z.nombre,
           public.hoy_montevideo(actual.desde),
           actual.inicial,
           coalesce((select jsonb_agg(jsonb_build_object(
                               'zona_id', zz.id,
                               'nombre', zz.nombre,
                               'ciudad_id', cia.ciudad_id,
                               'ciudad_nombre', ciua.nombre,
                               'desde', public.hoy_montevideo(h.desde),
                               'hasta', public.hoy_montevideo(h.hasta),
                               'inicial', h.inicial,
                               'eliminada', zz.deleted_at is not null)
                             order by h.desde, h.id)
                       from public.campania_colportor_zona_historial h
                       join public.zona zz on zz.id = h.zona_id
                       left join public.campania_ciudad cia on cia.id = zz.campania_ciudad_id
                       left join public.ciudad ciua on ciua.id = cia.ciudad_id
                      where h.campania_colportor_id = i.id
                        and h.hasta is not null
                        and h.deleted_at is null),
                    '[]'::jsonb)
      from public.campania_colportor i
      join public.usuario usr on usr.id = i.usuario_id
      -- La zona de hoy, y su ciudad (decisión del 21/10, «Ciudad colp.»); sin zona, todo null.
      left join public.zona z on z.id = i.zona_id and z.deleted_at is null
      left join public.campania_ciudad ci on ci.id = z.campania_ciudad_id and ci.deleted_at is null
      left join public.ciudad ciu on ciu.id = ci.ciudad_id
      -- El tramo abierto de esa zona (a lo sumo uno por inscripción: índice único parcial de 0022).
      left join lateral (select h.desde, h.inicial
                           from public.campania_colportor_zona_historial h
                          where h.campania_colportor_id = i.id
                            and h.zona_id = z.id
                            and h.hasta is null
                            and h.deleted_at is null
                          limit 1) actual on true
     where i.campania_id = p_campania_id
       and i.deleted_at is null
       and usr.deleted_at is null
     order by usr.apellido, usr.nombre, i.usuario_id;
end;
$$;

comment on function public.zonas_por_colportor(uuid) is
  'Vista 33 «Equipo», HU-CAM-006 (0047, backend-supabase#98): por inscripto vivo de la campaña, su '
  'zona de hoy (con la ciudad y desde qué día; zona_desde_inicial = el día es una cota, no la '
  'asignación real) y sus zonas_anteriores con las fechas (jsonb [{zona_id, nombre, ciudad_id, '
  'ciudad_nombre, desde, hasta, inicial, eliminada}], del más viejo al más nuevo; día de Montevideo). '
  'Sale del historial de la 0022. Una campaña por empezar o terminada se lee. Errores: 42501 sin '
  'permiso; CZ001 campaña inexistente. Sin email ni clientes. No cuenta casas.';

revoke all on function public.zonas_por_colportor(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.zonas_por_colportor(uuid) to authenticated;
