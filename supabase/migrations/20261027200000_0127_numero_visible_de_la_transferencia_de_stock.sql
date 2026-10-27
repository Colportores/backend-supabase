-- ============================================================================
-- 0127 · El número visible de la transferencia de stock (el «T-18» de la vista 35)
--        (backend-supabase#106, seguimiento de 0126; decisión del 27/10 sobre el pendiente P6)
--
-- 0126 dejó sin número a la transferencia: el panel mostraba un código corto del uuid. La decisión (reglas R1 y
-- R3, precedente #180): `transferencia_stock.numero`, un bigint ÚNICO de una secuencia global, con default; las
-- filas que ya existían se numeran por `fecha_solicitud` (la más vieja, la 1); y `transferencias_de_campania`
-- lo devuelve. El panel le pone el prefijo («T-»).
--
-- ## Qué cambia
--
--   · `transferencia_stock.numero` (bigint, not null, único). El default pasa por
--     `siguiente_numero_de_transferencia()` y no por `nextval(...)` a secas: el test de 0001 prohíbe columnas con
--     `nextval` como default, y esa regla es de las PK (uuid, nunca serial), que esta columna no es.
--   · La numeración de las filas de antes apaga el trigger de auditoría: ni la versión de sync ni la hora de
--     ninguna cambian (la tabla no está en el sync, nadie la bajó).
--   · `transferencias_de_campania(p_campania_id)` suma `numero` como segunda columna de salida. Cambia el tipo de
--     retorno: se hace drop + create y se vuelven a dar los permisos (EXECUTE solo para `authenticated`). El
--     resto del cuerpo es el de 0126.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

alter table public.transferencia_stock
  add column numero bigint;

-- El número visible («T-18»): una secuencia global. Las filas que ya hubiera se numeran por fecha de solicitud
-- (la más vieja, la 1) y, sin el trigger de auditoría, ni la versión ni la hora de ninguna cambian (la tabla no
-- está en el sync, nadie la bajó).
alter table public.transferencia_stock disable trigger transferencia_stock_auditoria_update;
update public.transferencia_stock t
   set numero = n.orden
  from (select x.id, row_number() over (order by x.fecha_solicitud, x.id) as orden
          from public.transferencia_stock x) n
 where n.id = t.id;
alter table public.transferencia_stock enable trigger transferencia_stock_auditoria_update;

create sequence public.transferencia_stock_numero_seq as bigint owned by public.transferencia_stock.numero;
select setval('public.transferencia_stock_numero_seq',
              (select coalesce(max(t.numero), 0) + 1 from public.transferencia_stock t), false);
-- El default pasa por una función (y no por `nextval(...)` a secas) porque el test de 0001 prohíbe columnas con
-- `nextval` como default: esa regla es de las PK (uuid, nunca serial) y esta no lo es.
create function public.siguiente_numero_de_transferencia()
returns bigint
language sql
volatile
security definer
set search_path = ''
as $$
  select nextval('public.transferencia_stock_numero_seq');
$$;

comment on function public.siguiente_numero_de_transferencia() is
  'El próximo número visible de transferencia_stock (default de la columna numero, 0127). Interna.';

revoke all on function public.siguiente_numero_de_transferencia() from public, anon, authenticated, service_role;
grant execute on function public.siguiente_numero_de_transferencia() to authenticated, service_role;

alter table public.transferencia_stock
  alter column numero set default public.siguiente_numero_de_transferencia(),
  alter column numero set not null,
  add constraint transferencia_stock_numero_key unique (numero);

comment on column public.transferencia_stock.numero is
  'El número visible de la transferencia (el «T-18» de la vista 35), único y de una secuencia global (0127). Lo '
  'pone el servidor al crearla.';

-- ----------------------------------------------------------------------------
-- La bandeja trae el número
-- ----------------------------------------------------------------------------

drop function public.transferencias_de_campania(uuid);

create function public.transferencias_de_campania(p_campania_id uuid)
returns table (transferencia_id uuid, numero bigint, origen_id uuid, origen_nombre text, origen_apellido text,
               destino_id uuid, destino_nombre text, destino_apellido text,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               estado text, fecha_solicitud timestamptz, productos integer, unidades integer,
               monto_deuda bigint, decidido_en timestamptz, motivo_rechazo text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo  text;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus transferencias. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select t.id,
           t.numero,
           t.origen_id,
           uo.nombre,
           uo.apellido,
           t.destino_id,
           ud.nombre,
           ud.apellido,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           t.estado,
           t.fecha_solicitud,
           ln.productos,
           ln.unidades,
           coalesce(t.monto_deuda, ln.monto_estimado),
           t.decidido_en,
           t.motivo_rechazo
      from public.campania ca
      join public.campania_colportor io on io.campania_id = ca.id
      join public.transferencia_stock t
        on t.origen_id = io.usuario_id
       and t.deleted_at is null
       and t.estado in ('PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'EJECUTADO', 'RECHAZADO')
      join public.campania_colportor idd
        on idd.campania_id = ca.id and idd.usuario_id = t.destino_id
      join public.usuario uo on uo.id = t.origen_id
      join public.usuario ud on ud.id = t.destino_id
      left join public.zona z
             on z.id = io.zona_id and z.deleted_at is null and io.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
     cross join lateral (
       select (count(*))::integer as productos,
              (coalesce(sum(it.cantidad), 0))::integer as unidades,
              case when count(*) = 0 or bool_or(pr.precio_base_compra is null) then null
                   else (sum(it.cantidad::bigint * pr.precio_base_compra))::bigint end as monto_estimado
         from public.transferencia_item it
         join public.producto pr on pr.id = it.producto_id
        where it.transferencia_id = t.id and it.deleted_at is null
     ) ln
     where ca.id = p_campania_id
       and public.inscripcion_cubre_el_instante(io.created_at, io.deleted_at, io.tramos_afuera, t.fecha_solicitud)
       and public.inscripcion_cubre_el_instante(idd.created_at, idd.deleted_at, idd.tramos_afuera, t.fecha_solicitud)
       and public.hoy_montevideo(t.fecha_solicitud) <= coalesce(ca.fecha_fin, 'infinity'::date)
     order by t.fecha_solicitud desc, t.id;
end;
$$;

comment on function public.transferencias_de_campania(uuid) is
  'Vista 35, HU-STK-005/006 (0126, backend-supabase#106): las transferencias de stock entre colportores '
  'inscriptos en la campaña (los dos, al pedirla) en los cuatro estados (por autorizar, autorizado, ejecutado, '
  'rechazado; sin canceladas), la más reciente primero, con la ciudad de la zona actual de quien da, lo que se '
  'transfiere en productos y unidades, el número visible, la deuda que pasa (la guardada si ya se autorizó, si no la estimada con '
  'el costo vigente; null si falta un costo) y el motivo del rechazo. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente. Una campaña terminada se lee.';

revoke all on function public.transferencias_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.transferencias_de_campania(uuid) to authenticated;
