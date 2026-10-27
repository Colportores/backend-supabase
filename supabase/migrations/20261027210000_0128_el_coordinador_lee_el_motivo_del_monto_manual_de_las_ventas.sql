-- ============================================================================
-- 0128 · El coordinador lee el motivo del monto manual junto al total de la venta
--        (backend-supabase#154, seguimiento de #138 / 0071, «Monto manual»)
--
-- Marta, coordinadora, abre un reporte del panel. Junto al total de una venta que Ana cambió a
-- mano (de $ 8.900 a $ 8.500) lee el motivo que escribió Ana: «descuento por pago en efectivo».
--
-- Decisión de Cristian (23/10), «Monto manual» (front-colportores-mobile#158): el motivo sube con
-- la venta (0071, `venta.motivo_monto_manual`) y el coordinador lo lee; es una excepción explícita
-- a «Justificar», solo para este campo. Decisión del agente de decisiones (25/10, R7): si el
-- coordinador lo lee junto al total, el servidor necesita una lectura que se lo dé. Hoy `venta` la
-- lee solo su dueño (`venta_propio`) y la única lectura de ventas del coordinador,
-- `ventas_por_ciudad_y_colportor()` (0061), da totales por colportor y período.
--
--   ventas_con_motivo_de_campania(p_campania_id, p_desde, p_hasta, p_ciudad_id, p_colportor_ids)
--     -> (venta_id, colportor_id, nombre, apellido, ciudad_id, ciudad_nombre, fecha,
--         monto_total, suma_items, motivo)
--
-- ## Qué devuelve
--
-- Una fila por venta CON motivo (las que no lo tienen no salen: no hay nada que leer). Orden:
-- la más reciente primero.
--
--   venta_id                  la clave de la fila (un uuid generado por el teléfono; no dice nada
--                             del cliente). El panel no la necesita para nada más.
--   colportor_id, nombre,
--   apellido                  quien hizo la venta (sin email ni nada más de la persona).
--   ciudad_id, ciudad_nombre  la ciudad de la zona que el colportor tenía en el INSTANTE de la venta,
--                             según `campania_colportor_zona_historial` (0022; desde <= fecha <
--                             hasta), como decidió Cristian el 23/10 en «Horas y zona» (#141; R7
--                             del 25/10: vale también si después se dio de baja; R4 del 26/10: las
--                             ventas cuentan en la zona de su instante). Sin tramo ese día: ambos
--                             null («sin zona asignada»). Un reporte de un mes cerrado no cambia
--                             aunque después lo muevan, ni aunque la zona o la ciudad de la
--                             campaña se den de baja. Es dónde trabaja el colportor, no dónde
--                             fue la venta: la venta no dice nada de eso.
--   fecha                     el instante de la venta (timestamptz); el panel lo formatea en
--                             America/Montevideo.
--   monto_total               `venta.monto_total`, en CENTAVOS (bigint): lo que Ana dejó a mano.
--   suma_items                la suma de los subtotales de los ítems vivos de la venta, en CENTAVOS
--                             (bigint; 0 si no tiene ninguno). Con los dos, el panel muestra la
--                             diferencia ($ 8.900 -> $ 8.500). El descuento informal no se ata a la
--                             suma (0001): puede darse cualquier relación entre los dos.
--   motivo                    `venta.motivo_monto_manual` tal cual (texto libre de hasta 500
--                             caracteres, sin espacios ni saltos al borde: lo garantiza el CHECK de
--                             0071). La app avisó antes de guardar que el coordinador lo lee y que
--                             no ponga datos del cliente; el servidor no puede revisarlo.
--
-- NADA del cliente ni de dónde fue: ni `espacio_persona_id`, ni el espacio, ni la ubicación, ni el
-- talonario (`numero_talonario`), ni los ítems uno por uno, ni medios de pago ni cobros. Columnas
-- explícitas, nunca `to_jsonb`. Sin política SELECT nueva sobre `venta`: el coordinador sigue sin
-- poder leerla, la lectura la hace esta función con SECURITY DEFINER.
--
-- ## Qué cuenta
--
--   · De la campaña: ventas de los colportores INSCRIPTOS en p_campania_id, hechas dentro de la
--     ventana de su inscripción (`inscripcion_cubre_el_instante`, 0100: desde el alta, antes de la
--     baja si la hubo y fuera de los huecos de `tramos_afuera`) y entre fecha_inicio y fecha_fin de
--     la campaña (días de Montevideo, ambos incluidos). Es la ventana decidida el 26/10 para las
--     lecturas por campaña; 0061 tiene la anterior, por día de alta y sin huecos (pendiente de esa
--     migración, no de esta).
--   · El día es el de la `fecha` de la venta en America/Montevideo (hoy_montevideo(timestamptz), 0024).
--   · No cuentan las ventas ni los ítems dados de baja (deleted_at).
--
-- ## Los filtros, el permiso y los errores
--
-- El diseño del reporte que lo muestre todavía no existe (la vista 32 no trae el motivo), así que
-- los filtros son los de `ventas_por_ciudad_y_colportor()` (0061): período, ciudad y colportores.
-- Las columnas y los filtros finales siguen al diseño cuando llegue (pendiente de esta entrega).
--   · p_desde y p_hasta son días (ambos incluidos), obligatorios. Tope de 366 días: un rango más
--     largo es un error (22023), no se recorta en silencio. p_ciudad_id y p_colportor_ids filtran
--     como en 0061 (un colportor sin ciudad solo sale sin filtro de ciudad).
--   · Sin JWT, colportor, sin rol, rol vencido o coordinador de otra campaña: 42501, antes de mirar
--     nada más. ADMIN: cualquier campaña. Campaña inexistente o dada de baja: CZ001. Una campaña
--     terminada se lee (el reporte se pide al cierre). Una fecha nula, p_desde > p_hasta o más de
--     366 días: 22023.
--   · SECURITY DEFINER con search_path vacío. VOLATILE (llama a lanzar_motivo_mapa()): supabase-js
--     la manda por POST. EXECUTE solo para `authenticated`.
--
-- ## Para otros repos
--   · front-coordinadores-web (reportes): POST /rest/v1/rpc/ventas_con_motivo_de_campania con
--     p_campania_id, p_desde, p_hasta y, si filtra, p_ciudad_id y p_colportor_ids.
--   · docs-organizacion: `esquema-datos.md` (lecturas del panel) y la HU del reporte
--     (HU-REP-002): ver el issue de docs de esta entrega.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create function public.ventas_con_motivo_de_campania(p_campania_id uuid, p_desde date, p_hasta date,
                                                     p_ciudad_id uuid default null,
                                                     p_colportor_ids uuid[] default null)
returns table (venta_id uuid, colportor_id uuid, nombre text, apellido text,
               ciudad_id uuid, ciudad_nombre text, fecha timestamptz,
               monto_total bigint, suma_items bigint, motivo text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo     text;
  v_campania   public.campania;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee (un reporte se pide al
  -- cierre); lo demás es lo de siempre de las lecturas del panel.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus reportes. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  if p_desde is null or p_hasta is null or p_desde > p_hasta then
    raise exception 'Elegí un rango de fechas: la fecha de inicio no puede ser posterior a la de fin.'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_hasta - p_desde + 1 > 366 then
    raise exception 'El rango es demasiado largo: pedí hasta 366 días por vez.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  return query
    select v.id,
           v.colportor_id,
           usr.nombre,
           usr.apellido,
           zd.ciudad_id,
           ciu.nombre,
           v.fecha,
           v.monto_total::bigint,
           coalesce((select sum(vi.subtotal)
                       from public.venta_item vi
                      where vi.venta_id = v.id
                        and vi.deleted_at is null), 0)::bigint,
           v.motivo_monto_manual
      from public.campania_colportor i
      join public.venta v on v.colportor_id = i.usuario_id
      join public.usuario usr on usr.id = i.usuario_id
      -- La ciudad sale del tramo del historial de zonas que cubre el instante de la venta (como
      -- 0106: desde <= fecha < hasta, hasta null = vigente). Una zona o una ciudad de campaña dadas
      -- de baja DESPUÉS no cambian el pasado; sin tramo, sin ciudad.
      left join lateral (
        select ci.ciudad_id
          from public.campania_colportor_zona_historial h
          join public.zona z on z.id = h.zona_id
          join public.campania_ciudad ci on ci.id = z.campania_ciudad_id
         where h.campania_colportor_id = i.id
           and h.deleted_at is null
           and h.desde <= v.fecha
           and (h.hasta is null or v.fecha < h.hasta)
         order by h.desde desc
         limit 1
      ) zd(ciudad_id) on true
      left join public.ciudad ciu on ciu.id = zd.ciudad_id
     where i.campania_id = p_campania_id
       and (p_colportor_ids is null or i.usuario_id = any (p_colportor_ids))
       and v.deleted_at is null
       and v.motivo_monto_manual is not null
       and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, v.fecha)
       and public.hoy_montevideo(v.fecha) >= v_campania.fecha_inicio
       and public.hoy_montevideo(v.fecha) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
       and public.hoy_montevideo(v.fecha) between p_desde and p_hasta
       and (p_ciudad_id is null or zd.ciudad_id = p_ciudad_id)
     order by v.fecha desc, usr.apellido, usr.nombre, v.id;
end;
$$;

comment on function public.ventas_con_motivo_de_campania(uuid, date, date, uuid, uuid[]) is
  'Reportes del panel (0128, backend-supabase#154): una fila por venta de la campaña CON motivo del monto '
  'manual (0071): colportor y su ciudad (la de su zona ese día, por el historial de zonas), fecha, monto_total y suma de los ítems (centavos) '
  'y el motivo, entre p_desde y p_hasta (hasta 366 días). Nada del cliente ni de dónde fue ni el talonario. '
  'Ventana de inscripción de 0100. Errores: 42501 sin permiso; CZ001 campaña inexistente; 22023 fechas o '
  'rango inválidos. Una campaña terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.ventas_con_motivo_de_campania(uuid, date, date, uuid, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.ventas_con_motivo_de_campania(uuid, date, date, uuid, uuid[])
  to authenticated;
