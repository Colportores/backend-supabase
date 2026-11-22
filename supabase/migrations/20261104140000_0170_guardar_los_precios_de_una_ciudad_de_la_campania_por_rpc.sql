-- ============================================================================
-- 0170 · La coordinadora guarda los precios de una ciudad de su campaña por RPC
--        (backend-supabase#248, HU-CAT-005; ADR-013; seguimiento de front-coordinadores-web#64)
--
-- La vista 27 del panel (Stock > Precios, una pestaña por ciudad) lee con precios_de_la_ciudad()
-- (0037) pero no podía escribir: ADR-013 no deja a los clientes insertar ni actualizar tablas, y la
-- 0037 dejó anotado que la escritura del modificado faltaba. Decisión P1 del agente de decisiones
-- (04/11), por la regla R7 y los precedentes «Precio gral.» (backend-supabase#66) y «Audit log»
-- (backend-supabase#97): la escritura va por una RPC de backend.
--
--   guardar_precios_de_la_ciudad(p_campania_ciudad_id uuid, p_cambios jsonb)
--     -> (tipo, id, accion)
--
-- ## Qué recibe
--
-- p_cambios es una LISTA JSON no vacía (hasta 500) de cambios:
--
--   [{"tipo": "PRODUCTO", "id": "<uuid>", "precio": 12500}, {"tipo": "COLECCION", "id": "<uuid>", "precio": null}]
--
--   · tipo: 'PRODUCTO' o 'COLECCION'. id: el del producto o de la colección (vivos del catálogo).
--   · precio: ENTERO POSITIVO en centavos (la misma validación que la UI: nada de decimales, de 0, de
--     negativos, de textos ni de más de 2147483647). `null` QUITA la excepción de esa ciudad: vuelve a
--     regir el general. La clave `precio` es obligatoria aunque valga null: un cambio sin ella es un
--     error de tipeo y no puede quitar una excepción en silencio. Tampoco se aceptan otras claves.
--   · Un mismo producto o colección no puede aparecer dos veces en la lista.
--
-- ## Todo o nada
--
-- Primero se valida la lista ENTERA (permiso, ciudad, forma de cada cambio, existencia en el
-- catálogo) y recién después se escribe. Cualquier error aborta la función y no queda nada: ni
-- filas de precio ni eventos de auditoría. Un advisory lock por ciudad serializa dos guardados a la
-- vez de la misma ciudad (el segundo espera al primero y lee su resultado).
--
-- ## Quién la llama (sin ampliar el permiso de las políticas)
--
-- Lo mismo que hoy dan `precio_por_ciudad_insert_staff` y `precio_por_ciudad_update_staff` (0027):
-- el ADMIN, o el COORDINADOR de la campaña de esa ciudad. Es SECURITY DEFINER (escribe sin pasar por
-- la RLS, con search_path vacío, como la 0037), así que el permiso lo decide la función, y es lo
-- PRIMERO, antes de mirar una sola fila (el orden es el de precios_de_la_ciudad()):
--
--   1. 42501  sin sesión.
--   2. 42501  sin el rol ADMIN ni COORDINADOR (colportor, sin rol, rol vencido o dado de baja).
--   3. CZ012  la ciudad de la campaña no existe.
--   4. 42501  existe y la campaña es de OTRO coordinador (el ADMIN pasa siempre).
--      CZ001  su campaña no existe o está dada de baja.
--   5. CZ012  la ciudad existe pero se quitó de la campaña.
--
-- Una campaña terminada se puede corregir, como lo permiten las políticas (que no miran la fecha
-- de fin); no se agrega una restricción nueva acá.
--
-- ## Códigos propios (los avisos dicen qué pasó y qué hacer)
--
--   PP001  p_cambios no es una lista, está vacía o tiene más de 500 cambios.
--   PP002  un cambio está mal formado: no es un objeto, le falta tipo, id o precio, trae otra clave,
--          el tipo no es PRODUCTO ni COLECCION o el id no es un uuid.
--   PP003  el precio no es un entero positivo (ni null) o es mayor que 2147483647.
--   PP004  el mismo producto o colección aparece dos veces en la lista.
--   PP005  el producto o la colección no existe o está dado de baja.
--
-- ## Las vigencias (el modelo de `precio_por_ciudad`, sin borrar filas)
--
-- «Hoy» es el día de Montevideo (hoy_montevideo()). Para cada cambio se mira el tramo VIGENTE hoy
-- del producto o colección en esa ciudad (a lo sumo uno: las restricciones de no solapamiento de la
-- 0027 lo garantizan):
--
--   · precio con valor, SIN tramo vigente  -> CREADA: tramo nuevo desde hoy, sin fin (o hasta el día antes
--     del primer tramo futuro, si hay).
--   · precio con valor, igual al vigente   -> SIN_CAMBIO: no se escribe ni se audita nada.
--   · precio con valor, distinto, y el tramo vigente empezó ANTES de hoy -> CAMBIADA: el vigente se
--     cierra ayer (valido_hasta = hoy - 1) y entra un tramo nuevo desde hoy que termina donde terminaba
--     el vigente o, si es antes, el día antes del primer tramo futuro (sin fin si no hay ninguno de los
--     dos). La historia queda en las filas.
--   · precio con valor, distinto, y el tramo vigente empezó HOY -> CAMBIADA: se corrige el importe de
--     esa fila (cerrarla ayer dejaría valido_hasta < valido_desde). Hoy hubo un solo precio; el
--     anterior queda en audit_log.
--   · null, con tramo vigente que empezó antes de hoy -> QUITADA: se cierra ayer; rige el general.
--   · null, con tramo vigente que empezó hoy -> QUITADA: la fila se da de baja (deleted_at, la baja
--     lógica del modelo; el teléfono recibe el tombstone por el sync). Nada se borra.
--   · null, sin tramo vigente -> SIN_CAMBIO.
--   · Un tramo FUTURO (valido_desde > hoy) cargado por Administración no se toca; el tramo nuevo
--     termina el día anterior al primero de ellos para no pisarlo (23P01), y «quitar» solo cierra el
--     vigente.
--   · Un tramo cerrado o futuro nunca es «el vigente»; los dados de baja no cuentan.
--
-- Cada fila que cambia sube su `sync_version` por el trigger de auditoría de la tabla, y el pull del
-- teléfono la baja como cualquier otra (0027): un precio nuevo vale para las ventas siguientes;
-- venta_item guarda el suyo.
--
-- ## Audit log (decisión «Audit log», backend-supabase#97)
--
-- Cada cambio EFECTIVO (no el SIN_CAMBIO) escribe un evento `precio_de_ciudad_guardado` con
-- auditoria.registrar() en la misma transacción: tabla `precio_por_ciudad`, fila_id = la fila que
-- quedó con el precio (o la que se cerró/dio de baja al quitar) y el detalle con ids, la acción y los
-- importes en centavos (precio_anterior y precio_nuevo, null si no había / se quitó), la campaña, la
-- ciudad y el día. Sin texto libre ni datos de personas (RA-SE05). El actor es auth.uid().
--
-- ## Lo que devuelve
--
-- Una fila por cada cambio de la lista, en el mismo orden: (tipo, id, accion) con accion en
-- CREADA | CAMBIADA | QUITADA | SIN_CAMBIO. El panel vuelve a pedir precios_de_la_ciudad() para
-- mostrar el resultado.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 27; front-coordinadores-web#139): `guardarPrecios` llama a
--     POST /rest/v1/rpc/guardar_precios_de_la_ciudad con el JWT de la coordinadora y los parámetros
--     por nombre: {"p_campania_ciudad_id": "<id de la pestaña>", "p_cambios": [{"tipo": "PRODUCTO",
--     "id": "…", "precio": 12500}, …]}. Manda solo lo que cambió. Errores que traduce (ADR-013):
--     42501, CZ001, CZ012 y PP001..PP005. Un error no guardó NADA.
--   · front-colportores-mobile y el motor de sync: no cambia nada (misma tabla, mismo pull).
--   · docs-organizacion: HU-CAT-005 puede apuntar a guardar_precios_de_la_ciudad() como la escritura
--     de la vista 27; la lista de códigos suma PP001..PP005.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create function public.guardar_precios_de_la_ciudad(
  p_campania_ciudad_id  uuid,
  p_cambios             jsonb
)
returns table (
  tipo    text,
  id      uuid,
  accion  text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cc        public.campania_ciudad;
  v_motivo    text;
  v_hoy       date := public.hoy_montevideo();
  v_n         integer;
  v_c         jsonb;
  v_p         jsonb;
  v_num       numeric;
  v_i         integer;
  v_tipo      text;
  v_item      uuid;
  v_precio    integer;
  v_tipos     text[] := array[]::text[];
  v_items     uuid[] := array[]::uuid[];
  v_precios   integer[] := array[]::integer[];
  v_vistos    text[] := array[]::text[];
  v_vig       public.precio_por_ciudad;
  v_hay_vig   boolean;
  v_hasta     date;
  v_accion    text;
  v_fila_id   uuid;
  v_antes     integer;
  v_prod      uuid;
  v_colec     uuid;
begin
  -- El permiso primero: antes de mirar ningún dato.
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Esta cuenta no es de coordinador. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if not found then
    raise exception 'La ciudad no está en una campaña o ya se quitó de ella. Recargá las ciudades de la campaña.'
      using errcode = 'CZ012';
  end if;

  -- ADMIN o coordinador de ESA campaña (lo que dan las políticas de precio_por_ciudad). La campaña
  -- terminada se puede corregir: se ignora su motivo.
  v_motivo := public.motivo_mapa_de_campania(v_cc.campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña puede cambiar sus precios. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_INEXISTENTE' then
    raise exception 'La campaña no existe. Elegí otra campaña.'
      using errcode = 'CZ001';
  end if;

  if v_cc.deleted_at is not null then
    raise exception 'La ciudad no está en una campaña o ya se quitó de ella. Recargá las ciudades de la campaña.'
      using errcode = 'CZ012';
  end if;

  -- ---- Se valida la lista ENTERA antes de escribir una sola fila ----------------------------------
  if jsonb_typeof(p_cambios) is distinct from 'array' or jsonb_array_length(p_cambios) = 0 then
    raise exception 'No hay precios para guardar. Cambiá al menos un precio y tocá «Guardar cambios».'
      using errcode = 'PP001';
  end if;
  v_n := jsonb_array_length(p_cambios);
  if v_n > 500 then
    raise exception 'Son demasiados precios juntos (más de 500). Guardalos en tandas más chicas.'
      using errcode = 'PP001';
  end if;

  for v_i in 1 .. v_n loop
    v_c := p_cambios -> (v_i - 1);

    if jsonb_typeof(v_c) is distinct from 'object'
       or not (v_c ? 'tipo' and v_c ? 'id' and v_c ? 'precio')
       or exists (select 1 from jsonb_object_keys(v_c) k where k not in ('tipo', 'id', 'precio')) then
      raise exception 'El cambio % no tiene la forma esperada (tipo, id y precio). Recargá la pantalla y volvé a intentarlo.', v_i
        using errcode = 'PP002';
    end if;

    if jsonb_typeof(v_c -> 'tipo') is distinct from 'string'
       or (v_c ->> 'tipo') not in ('PRODUCTO', 'COLECCION') then
      raise exception 'El cambio % tiene un tipo que no existe (tiene que ser PRODUCTO o COLECCION). Recargá la pantalla y volvé a intentarlo.', v_i
        using errcode = 'PP002';
    end if;
    v_tipo := v_c ->> 'tipo';

    if jsonb_typeof(v_c -> 'id') is distinct from 'string'
       or (v_c ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'El cambio % no trae un libro o combo válido. Recargá la pantalla y volvé a intentarlo.', v_i
        using errcode = 'PP002';
    end if;
    v_item := (v_c ->> 'id')::uuid;

    -- El precio: entero positivo en centavos, o null para quitar la excepción.
    v_p := v_c -> 'precio';
    if jsonb_typeof(v_p) = 'null' then
      v_precio := null;
    elsif jsonb_typeof(v_p) = 'number' then
      v_num := (v_p #>> '{}')::numeric;
      if v_num <> trunc(v_num) or v_num < 1 or v_num > 2147483647 then
        raise exception 'El precio del cambio % tiene que ser un número entero mayor que cero. Corregilo, o dejalo vacío para volver al precio general.', v_i
          using errcode = 'PP003';
      end if;
      v_precio := v_num::integer;
    else
      raise exception 'El precio del cambio % tiene que ser un número entero mayor que cero. Corregilo, o dejalo vacío para volver al precio general.', v_i
        using errcode = 'PP003';
    end if;

    if (v_tipo || ':' || v_item::text) = any (v_vistos) then
      raise exception 'El cambio % repite un libro o combo que ya está en la lista. Mandá un solo precio por cada uno.', v_i
        using errcode = 'PP004';
    end if;
    v_vistos := v_vistos || (v_tipo || ':' || v_item::text);

    if v_tipo = 'PRODUCTO' then
      if not exists (select 1 from public.producto pr where pr.id = v_item and pr.deleted_at is null) then
        raise exception 'El cambio % es de un libro que no existe o está dado de baja. Recargá los precios de la ciudad.', v_i
          using errcode = 'PP005';
      end if;
    else
      if not exists (select 1 from public.coleccion co where co.id = v_item and co.deleted_at is null) then
        raise exception 'El cambio % es de un combo que no existe o está dado de baja. Recargá los precios de la ciudad.', v_i
          using errcode = 'PP005';
      end if;
    end if;

    v_tipos := v_tipos || v_tipo;
    v_items := v_items || v_item;
    v_precios := v_precios || v_precio;
  end loop;

  -- ---- Se escribe: dos guardados a la vez de la misma ciudad se ponen en fila ----------------------
  perform pg_advisory_xact_lock(hashtextextended('precio_por_ciudad:' || v_cc.id::text, 0));

  for v_i in 1 .. v_n loop
    v_tipo := v_tipos[v_i];
    v_item := v_items[v_i];
    v_precio := v_precios[v_i];
    v_prod := case when v_tipo = 'PRODUCTO' then v_item end;
    v_colec := case when v_tipo = 'COLECCION' then v_item end;
    v_accion := 'SIN_CAMBIO';
    v_fila_id := null;
    v_antes := null;

    -- El tramo vigente hoy de este producto o colección en esta ciudad.
    select * into v_vig
      from public.precio_por_ciudad p
     where p.campania_ciudad_id = v_cc.id
       and p.producto_id is not distinct from v_prod
       and p.coleccion_id is not distinct from v_colec
       and p.deleted_at is null
       and daterange(p.valido_desde, p.valido_hasta, '[]') @> v_hoy
     order by p.valido_desde desc, p.id
     limit 1
       for update;
    v_hay_vig := found;

    if v_precio is null then
      if v_hay_vig then
        v_antes := v_vig.precio_venta;
        v_fila_id := v_vig.id;
        v_accion := 'QUITADA';
        if v_vig.valido_desde < v_hoy then
          update public.precio_por_ciudad p set valido_hasta = v_hoy - 1 where p.id = v_vig.id;
        else
          -- Empezó hoy: cerrarlo ayer dejaría valido_hasta < valido_desde. Baja lógica del modelo.
          update public.precio_por_ciudad p set deleted_at = now() where p.id = v_vig.id;
        end if;
      end if;
    elsif v_hay_vig and v_vig.precio_venta = v_precio then
      null; -- SIN_CAMBIO
    else
      v_antes := case when v_hay_vig then v_vig.precio_venta end;
      v_accion := case when v_hay_vig then 'CAMBIADA' else 'CREADA' end;

      if v_hay_vig and v_vig.valido_desde >= v_hoy then
        -- El vigente empezó hoy: se corrige su importe.
        update public.precio_por_ciudad p set precio_venta = v_precio where p.id = v_vig.id;
        v_fila_id := v_vig.id;
      else
        if v_hay_vig then
          update public.precio_por_ciudad p set valido_hasta = v_hoy - 1 where p.id = v_vig.id;
        end if;

        -- El tramo nuevo no pisa uno futuro que Administración haya cargado.
        select min(p.valido_desde) - 1 into v_hasta
          from public.precio_por_ciudad p
         where p.campania_ciudad_id = v_cc.id
           and p.producto_id is not distinct from v_prod
           and p.coleccion_id is not distinct from v_colec
           and p.deleted_at is null
           and p.valido_desde > v_hoy;

        -- Y tampoco se pasa del fin que ya tenía el vigente que reemplaza: si terminaba antes (hasta
        -- un tramo futuro, o a secas), el nuevo termina ahí y el hueco sigue siendo del general.
        -- `least` ignora los null: sin fin en ninguno de los dos, el tramo nuevo queda sin fin.
        if v_hay_vig then
          v_hasta := least(v_hasta, v_vig.valido_hasta);
        end if;

        insert into public.precio_por_ciudad
          (producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta, created_by)
        values
          (v_prod, v_colec, v_cc.id, v_precio, v_hoy, v_hasta, auth.uid())
        returning precio_por_ciudad.id into v_fila_id;
      end if;
    end if;

    if v_accion <> 'SIN_CAMBIO' then
      perform auditoria.registrar(
        'precio_de_ciudad_guardado', 'precio_por_ciudad', v_fila_id, null,
        jsonb_build_object(
          'campania_id', v_cc.campania_id,
          'campania_ciudad_id', v_cc.id,
          'tipo', v_tipo,
          'item_id', v_item,
          'accion', v_accion,
          'precio_anterior', v_antes,
          'precio_nuevo', v_precio,
          'dia', v_hoy));
    end if;

    tipo := v_tipo;
    id := v_item;
    accion := v_accion;
    return next;
  end loop;
end;
$$;

comment on function public.guardar_precios_de_la_ciudad(uuid, jsonb) is
  'Vista 27 del panel (0170, backend-supabase#248, HU-CAT-005, ADR-013): guarda de una vez, todo o '
  'nada, los precios de una ciudad de la campaña. p_cambios = lista de {tipo PRODUCTO|COLECCION, id, '
  'precio}: precio entero positivo en centavos, o null para quitar la excepción (vuelve a regir el '
  'general). Vigencias de precio_por_ciudad sin borrar filas: el tramo vigente se cierra ayer y entra '
  'uno desde hoy (si el vigente empezó hoy se corrige o se da de baja). Cada cambio efectivo queda en '
  'audit_log (precio_de_ciudad_guardado). Devuelve (tipo, id, accion) por cada cambio: CREADA, '
  'CAMBIADA, QUITADA o SIN_CAMBIO. Pueden llamarla el ADMIN y el coordinador de la campaña (el mismo '
  'permiso de las políticas de precio_por_ciudad). Errores: 42501 sin sesión, sin rol o campaña de '
  'otro coordinador; CZ012 la ciudad no existe o se quitó; CZ001 la campaña no existe; PP001 lista '
  'vacía o de más de 500; PP002 cambio mal formado; PP003 precio inválido; PP004 repetido; PP005 el '
  'producto o la colección no existe o está de baja. SECURITY DEFINER.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.guardar_precios_de_la_ciudad(uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.guardar_precios_de_la_ciudad(uuid, jsonb)
  to authenticated;
