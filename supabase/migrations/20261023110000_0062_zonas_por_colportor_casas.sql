-- ============================================================================
-- 0062 · zonas_por_colportor() suma `casas_registradas` (backend-supabase#98, HU-CAM-006, vista 33)
--
-- La 0047 (PR #118) trajo la zona de hoy y las zonas anteriores de cada colportor para la pestaña
-- Zonas de Equipo, pero dejó afuera la columna «Casas registradas» del canvas: ni la HU ni el canvas
-- decían qué se cuenta. La decisión llegó después del merge (orquestador, 21/10, por el mapa de
-- decisiones: gana el canvas 33, «las casas registradas en una zona vieja siguen contando»;
-- pendientes/backend-supabase-98-impl-261021-2125.md, P1; comentario en el PR #118). La 0047 ya está
-- aplicada y no se edita: esta migración recrea la función con una columna más al final (cambia el
-- tipo de retorno, así que `drop` y `create`). Las demás columnas quedan iguales y en el mismo orden.
--
-- ## casas_registradas: las casas de una zona anterior siguen contando
--
-- Un número, sin direcciones: las ubicaciones VIVAS cuyo `created_by` es el colportor, de una ciudad
-- VIVA de esta campaña (`campania_ciudad`), creadas desde el comienzo de su inscripción
-- (`campania_colportor.created_at`, el mismo inicio que usan los acompañamientos, 0043; el límite es
-- inclusivo) y hasta el último día de la campaña (día de Montevideo de `ubicacion.created_at` <=
-- `campania.fecha_fin`, también inclusivo; sin fecha de fin, sin tope: el mismo corte que la 0043).
-- Sin ese tope, lo que el colportor carga hoy para la campaña siguiente, en la misma ciudad, subiría
-- el número de una campaña ya terminada (la ubicación no guarda campaña). Consecuencia: lo cargado
-- en los días de gracia de escritura después del cierre no cuenta, igual que en los acompañamientos.
-- Si dos inscripciones vivas del colportor tienen campañas que se superponen en la misma ciudad, las
-- mismas casas figuran en las dos: es el caso de «campañas superpuestas» que la 0043 ya deja como
-- decisión pendiente, y esta lectura queda atada a lo que se decida allá. No mira la zona: la ubicación no guarda zona ni campaña (R-UB06), así que cambiar de
-- zona, quitársela o que la zona se dé de baja no le resta casas a nadie. No cuentan una ubicación
-- dada de baja (p. ej. la B de una unión de duplicados), lo cargado antes de inscribirse a ESTA
-- campaña ni lo de una ciudad que no es de ella.
--
-- Permiso, errores, orden y privilegios: los de la 0047.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

drop function public.zonas_por_colportor(uuid);

create function public.zonas_por_colportor(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, ciudad_id uuid, ciudad_nombre text,
               zona_id uuid, zona_nombre text, zona_desde date, zona_desde_inicial boolean,
               zonas_anteriores jsonb, casas_registradas integer)
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
                    '[]'::jsonb),
           (select count(*)::integer
              from public.ubicacion ub
             where ub.created_by = i.usuario_id
               and ub.deleted_at is null
               and ub.created_at >= i.created_at
               and public.hoy_montevideo(ub.created_at) <= coalesce(camp.fecha_fin, 'infinity'::date)
               and exists (select 1
                             from public.campania_ciudad cx
                            where cx.campania_id = p_campania_id
                              and cx.ciudad_id = ub.ciudad_id
                              and cx.deleted_at is null))
      from public.campania_colportor i
      join public.campania camp on camp.id = i.campania_id
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
  'Vista 33 «Equipo», HU-CAM-006 (0047 y 0062, backend-supabase#98): por inscripto vivo de la campaña, su '
  'zona de hoy (con la ciudad y desde qué día; zona_desde_inicial = el día es una cota, no la '
  'asignación real) y sus zonas_anteriores con las fechas (jsonb [{zona_id, nombre, ciudad_id, '
  'ciudad_nombre, desde, hasta, inicial, eliminada}], del más viejo al más nuevo; día de Montevideo). '
  'Sale del historial de la 0022. casas_registradas: ubicaciones vivas que creó el colportor en las '
  'ciudades vivas de la campaña desde que se inscribió y hasta el último día de la campaña, sin mirar '
  'la zona (las de una zona anterior siguen contando). Una campaña por empezar o terminada se lee. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente. Sin email ni clientes.';

revoke all on function public.zonas_por_colportor(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.zonas_por_colportor(uuid) to authenticated;
