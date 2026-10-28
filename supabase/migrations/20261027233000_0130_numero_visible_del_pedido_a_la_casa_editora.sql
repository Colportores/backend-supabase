-- ============================================================================
-- 0130 · El número visible del pedido a la casa editora (el «Pedido #231» de la vista 35)
--        (backend-supabase#180, seguimiento de 0112 / #104; reglas R1 y R3 del mapa de decisiones)
--
-- La bandeja de pedidos (0112) no tenía con qué llamar a cada pedido: el panel mostraba un código corto del
-- uuid. El canvas aprobado de la vista 35 dibuja «Pedido #231» en cada fila y en el detalle, y Marta, si Juan
-- la llama por «el pedido 231», lo busca por ese número. Es una columna que solo suma.
--
-- ## Qué cambia
--
--   · `pedido_casa_editora.numero` (bigint, not null, único): una secuencia global, con default. No se
--     reutiliza un número (ni el de un pedido cancelado o dado de baja: la secuencia solo avanza). Puede haber
--     saltos: un reintento del push que ya entró (`INSERT … ON CONFLICT DO NOTHING`) también pide número antes
--     de descubrir el conflicto, y ese número se pierde.
--   · El default pasa por `siguiente_numero_de_pedido()` y no por `nextval(...)` a secas (el test de 0001
--     prohíbe columnas con `nextval` como default; es la regla de las PK, que esta columna no es). Misma
--     solución que `transferencia_stock.numero` (0127). La función es interna: SECURITY DEFINER con
--     `search_path` fijo, y EXECUTE solo para `authenticated` y `service_role` (el push inserta como
--     `authenticated`, y para evaluar el default hace falta poder ejecutarla).
--   · Los pedidos que ya existían se numeran por `fecha_pedido` (el más viejo, el 1; los datos son simulados
--     hasta diciembre). La numeración apaga el trigger de auditoría: ni la versión de sync ni la hora de
--     ningún pedido cambian, así que los teléfonos no se enteran.
--   · `numero` es una columna del SERVIDOR: entra en `sync.entidad.columnas_servidor` de `pedido_casa_editora`
--     (se descarta del payload aunque el teléfono la mande tal como bajó del pull) y los grants por columna de
--     0124 no se la abren. Baja al teléfono por el pull (`sync.expresion_json` baja todas las columnas).
--   · `pedidos_de_campania(p_campania_id)` suma `numero` como segunda columna de salida y `pedido_contexto`
--     como primera. Cambian las columnas de salida: drop + create y se vuelven a dar los permisos (EXECUTE solo
--     para `authenticated`). El resto del cuerpo es el de 0112.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

alter table public.pedido_casa_editora
  add column numero bigint;

-- Los pedidos que ya había se numeran por fecha de pedido (el más viejo, el 1). Sin el trigger de auditoría,
-- ni la versión de sync ni la hora de ninguno cambian.
alter table public.pedido_casa_editora disable trigger pedido_casa_editora_auditoria_update;
update public.pedido_casa_editora p
   set numero = n.orden
  from (select x.id, row_number() over (order by x.fecha_pedido, x.id) as orden
          from public.pedido_casa_editora x) n
 where n.id = p.id;
alter table public.pedido_casa_editora enable trigger pedido_casa_editora_auditoria_update;

create sequence public.pedido_casa_editora_numero_seq as bigint owned by public.pedido_casa_editora.numero;
select setval('public.pedido_casa_editora_numero_seq',
              (select coalesce(max(p.numero), 0) + 1 from public.pedido_casa_editora p), false);

-- El default pasa por una función (y no por `nextval(...)` a secas) porque el test de 0001 prohíbe columnas con
-- `nextval` como default: esa regla es de las PK (uuid, nunca serial) y esta no lo es.
create function public.siguiente_numero_de_pedido()
returns bigint
language sql
volatile
security definer
set search_path = ''
as $$
  select nextval('public.pedido_casa_editora_numero_seq');
$$;

comment on function public.siguiente_numero_de_pedido() is
  'El próximo número visible de pedido_casa_editora (default de la columna numero, 0130). Interna.';

revoke all on function public.siguiente_numero_de_pedido() from public, anon, authenticated, service_role;
grant execute on function public.siguiente_numero_de_pedido() to authenticated, service_role;

alter table public.pedido_casa_editora
  alter column numero set default public.siguiente_numero_de_pedido(),
  alter column numero set not null,
  add constraint pedido_casa_editora_numero_key unique (numero);

comment on column public.pedido_casa_editora.numero is
  'El número visible del pedido (el «Pedido #231» de la vista 35), único y de una secuencia global (0130). Lo '
  'pone el servidor al crearlo; nunca se reutiliza.';

-- Es del servidor: el teléfono no la escribe (no está en los grants por columna de 0124) y, si el payload del
-- push la trae porque bajó del pull, se descarta en vez de rechazar el push.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['numero']
 where nombre = 'pedido_casa_editora';

-- ----------------------------------------------------------------------------
-- La bandeja y el detalle traen el número
-- ----------------------------------------------------------------------------

drop function public.pedidos_de_campania(uuid);

create function public.pedidos_de_campania(p_campania_id uuid)
returns table (pedido_id uuid, numero bigint, colportor_id uuid, nombre text, apellido text,
               ciudad_id uuid, ciudad_nombre text, departamento text, de_baja boolean,
               estado text, origen text, fecha_pedido timestamptz,
               productos integer, unidades integer, unidades_autorizadas integer,
               monto_total bigint, monto_autorizado bigint, excede_limite boolean,
               decidido_en timestamptz, motivo_rechazo text, deshacer_hasta timestamptz)
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
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus pedidos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select pe.id,
           pe.numero,
           i.usuario_id,
           usr.nombre,
           usr.apellido,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           (i.deleted_at is not null),
           pe.estado,
           pe.origen,
           pe.fecha_pedido,
           ln.productos,
           ln.unidades,
           case when pe.monto_autorizado is null then null else ln.unidades_autorizadas end,
           pe.monto_total,
           pe.monto_autorizado,
           pe.excede_limite,
           pe.decidido_en,
           pe.motivo_rechazo,
           case when pe.estado in ('AUTORIZADO', 'RECHAZADO')
                then pe.decidido_en + public.plazo_para_deshacer_pedido() end
      from public.campania_colportor i
      join public.pedido_casa_editora pe
        on pe.colportor_id = i.usuario_id
       and pe.deleted_at is null
       and pe.estado in ('PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'DESPACHADO', 'RECIBIDO', 'RECHAZADO')
       and public.campania_del_ticket(i.usuario_id, pe.fecha_pedido) = i.campania_id
      join public.usuario usr on usr.id = i.usuario_id
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
     cross join lateral (
       select (count(*))::integer as productos,
              (coalesce(sum(it.cantidad), 0))::integer as unidades,
              (coalesce(sum(coalesce(it.cantidad_autorizada, it.cantidad)), 0))::integer as unidades_autorizadas
         from public.pedido_item it
        where it.pedido_id = pe.id and it.deleted_at is null
     ) ln
     where i.campania_id = p_campania_id
     order by pe.fecha_pedido desc, pe.id;
end;
$$;

comment on function public.pedidos_de_campania(uuid) is
  'Vista 35, HU-STK-003 (0112, backend-supabase#104; el número visible, 0130, #180): los pedidos a la casa editora de los colportores de '
  'la campaña (los que hizo dentro de la ventana de su inscripción, hasta 15 días después del fin si no hubo '
  'baja, y que no son de una inscripción más nueva: no los que pidió en la campaña de otro coordinador) en los cinco estados de las pestañas (por autorizar, autorizado, '
  'despachado, recibido, rechazado; sin borradores ni cancelados), el más reciente primero, con la ciudad de la zona actual del '
  'colportor, el número visible («Pedido #231»), lo pedido y lo autorizado, el motivo del rechazo y hasta cuándo se puede deshacer lo '
  'decidido. Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.pedidos_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedidos_de_campania(uuid) to authenticated;

drop function public.pedido_contexto(uuid);

create function public.pedido_contexto(p_pedido_id uuid)
returns table (numero bigint, colportor_id uuid, nombre text, apellido text, estado text,
               monto_total bigint, monto_autorizado bigint,
               deuda_actual bigint, deuda_con_pedido bigint, por_cobrar bigint,
               libros_por_entregar integer,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
begin
  v_pedido := public.pedido_para(p_pedido_id, false);

  return query
    select v_pedido.numero,
           v_pedido.colportor_id,
           usr.nombre,
           usr.apellido,
           v_pedido.estado,
           v_pedido.monto_total,
           v_pedido.monto_autorizado,
           coalesce(cu.deuda_total, 0),
           coalesce(cu.deuda_total, 0)
             + case when v_pedido.estado = 'PENDIENTE_AUTORIZACION' then v_pedido.monto_total else 0 end,
           coalesce(cu.dinero_por_cobrar, 0),
           (select coalesce(sum(en.cantidad), 0)::integer
              from public.venta v
              join public.entrega en on en.venta_id = v.id and en.deleted_at is null and en.pendiente
             where v.colportor_id = v_pedido.colportor_id and v.deleted_at is null),
           dep.fecha,
           dep.monto
      from public.usuario usr
      left join public.cuenta_colportor cu
             on cu.usuario_id = usr.id and cu.deleted_at is null
      left join lateral (
        select d.fecha, d.monto
          from public.deposito d
         where d.colportor_id = usr.id and d.deleted_at is null
           and d.concepto = 'CASA_EDITORA'
         order by d.fecha desc, d.id
         limit 1
      ) dep on true
     where usr.id = v_pedido.colportor_id;
end;
$$;

comment on function public.pedido_contexto(uuid) is
  'Vista 35, HU-STK-003 (0112; el número visible, 0130, #180): la cuenta del colportor para decidir su pedido: número del pedido, deuda actual '
  '(cuenta_colportor.deuda_total), deuda con el pedido (la actual más el pedido mientras está por autorizar), '
  'por cobrar (cuenta_colportor.dinero_por_cobrar), unidades vendidas por entregar y su último depósito. Solo '
  'montos y cantidades: ni clientes ni cobros. Errores: 42501 sin permiso; PE001 si el pedido no existe. '
  'El límite de deuda (backend-supabase#156) se suma cuando exista.';

revoke all on function public.pedido_contexto(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedido_contexto(uuid) to authenticated;
