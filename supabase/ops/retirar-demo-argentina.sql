-- ============================================================================
-- Retira la demo de Argentina (Libertador San Martín) del proyecto de DESARROLLO (issue #216)
--
-- Qué hace: da de baja LÓGICA (deleted_at = now(), nunca DELETE) todo lo que se sembró para probar la app
-- en Argentina el 28/10: el país AR, la ciudad, su campaña, las zonas, las inscripciones, el catálogo, los
-- pedidos y el stock, las ubicaciones y toda la actividad de colportor2.demo (visitas, ventas, entregas,
-- cobranzas, agenda, depósitos), y bloquea el login de colportor2.demo@example.com en Auth. Las bajas
-- lógicas suben sync_version: los teléfonos reciben la baja en su próximo pull. Lo de Uruguay no se toca.
--
-- NO es una migración, a propósito: es una operación de datos de un solo ambiente (el de desarrollo,
-- ohdsavwpasfpapbyutrv). Staging y producción no tienen nada de Argentina y no deben recibir ni este script.
-- Tampoco toca el mapa publicado: ese se retira ANTES, con el publicador (supabase/ops/README.md, paso 1).
--
-- Cómo se corre (detalle en supabase/ops/README.md):
--   · Pegarlo entero en el SQL Editor de Supabase Studio del proyecto de desarrollo (o `psql -f`). Es un
--     solo DO: o aplica todo o no aplica nada.
--   · Sin tocar nada corre en VISTA PREVIA: hace todo, devuelve el conteo por tabla y deshace.
--   · Para aplicarlo de verdad, descomentar la línea `select set_config('retiro.aplicar', 'si', true);`
--     de abajo (va en la misma transacción que el DO; si el editor las separa, queda en vista previa).
--   · Se puede correr dos veces: la segunda no encuentra nada vivo y devuelve todo en cero.
--
-- Cómo sabe qué retirar (no depende de listas de ids de un archivo que no está en el repo):
--   · Por estructura, desde el país: todo país que no sea UY → sus ciudades → las campañas que cuelgan de
--     ellas → zonas, inscripciones, ubicaciones, espacios, personas del espacio, y desde ahí toda la
--     actividad (visitas, ventas, entregas, cobros, agenda). La jornada y los depósitos, que no cuelgan de
--     una ciudad, se identifican por colportor2.demo.
--   · Por id, lo único que no cuelga de nada geográfico: los 9 productos, las 2 colecciones y las 3 carreras
--     de la demo (`dede0000-0000-7000-8005-…01..09`, `…8006-…01..02`, `…801e-…01..03`). De ahí salen sus
--     precios, componentes, metas de beca, pedidos, movimientos y stock.
--   · Por correo: colportor2.demo@example.com (usuario, rol, cuenta de saldo y login). La cuenta de saldo de
--     colportor.demo NO se toca: ese usuario se queda, y mover_deuda_casa_editora() no reactiva una cuenta
--     dada de baja (la deuda nueva se sumaría a una fila oculta y se perdería).
--
-- Se frena (sin cambiar nada) si algo huele a que la demo y lo del dominio comparten filas: una campaña que
-- tiene ciudades de Argentina y de otro país, o una venta de otro lado que usa un producto de la demo. Un
-- depósito ya validado tampoco se da de baja (DP001): se resuelve a mano, nunca se fuerza.
--
-- Al final comprueba los criterios de aceptación de #216: ninguna fila viva de pais, ciudad, campania ni
-- ubicacion con pais.iso_code <> 'UY', y colportor2.demo sin usuario vivo. Si no se cumple, no aplica.
--
-- Lo que NO hace (queda a mano, ver README): volver a armar la demo de Uruguay (reactivar la inscripción de
-- colportor.demo con inscribir_colportor() y devolverle el coordinador a la campaña de Montevideo).
-- ============================================================================

-- select set_config('retiro.aplicar', 'si', true);

create temp table if not exists retiro_resumen (orden serial, que text, filas integer);
truncate retiro_resumen;

do $retiro$
declare
  v_aplicar    boolean := coalesce(current_setting('retiro.aplicar', true), '') = 'si';
  v_demo_u2    constant text := 'colportor2.demo@example.com';

  v_pais       uuid[];
  v_ciudad     uuid[];
  v_cc         uuid[];
  v_campania   uuid[];
  v_inscr      uuid[];
  v_u2         uuid[];
  v_ubic       uuid[];
  v_esp        uuid[];
  v_ep         uuid[];
  v_jornada    uuid[];
  v_visita     uuid[];
  v_venta      uuid[];
  v_entrega    uuid[];
  v_cobranza   uuid[];
  v_deposito   uuid[];
  v_prod       uuid[];
  v_col        uuid[];
  v_carrera    uuid[];
  v_pedido     uuid[];

  v_n          integer;
  v_resumen    jsonb := '[]'::jsonb;
  v_mala       text;
begin
  -- --------------------------------------------------------------------------------------------------
  -- 1. El alcance, de todas las filas (vivas o ya dadas de baja: por eso se puede correr dos veces).
  -- --------------------------------------------------------------------------------------------------
  select coalesce(array_agg(id), '{}') into v_pais from public.pais where iso_code <> 'UY';
  select coalesce(array_agg(id), '{}') into v_ciudad from public.ciudad where pais_id = any (v_pais);
  select coalesce(array_agg(id), '{}') into v_cc from public.campania_ciudad where ciudad_id = any (v_ciudad);
  select coalesce(array_agg(distinct campania_id), '{}') into v_campania
    from public.campania_ciudad where id = any (v_cc);

  -- Una campaña con una ciudad de AR y otra de otro país no es de la demo: se frena.
  select string_agg(c.nombre, ', ') into v_mala
    from public.campania c
   where c.id = any (v_campania)
     and exists (select 1 from public.campania_ciudad cc
                  where cc.campania_id = c.id and cc.deleted_at is null and cc.ciudad_id <> all (v_ciudad));
  if v_mala is not null then
    raise exception 'Retiro frenado, no se cambió nada: la campaña "%" tiene ciudades de Argentina y de otro país a la vez. Decidir a mano qué hacer con ella.', v_mala
      using errcode = 'P0001';
  end if;

  select coalesce(array_agg(id), '{}') into v_inscr from public.campania_colportor where campania_id = any (v_campania);
  select coalesce(array_agg(id), '{}') into v_u2 from public.usuario where lower(email) = v_demo_u2;

  select coalesce(array_agg(id), '{}') into v_ubic from public.ubicacion where ciudad_id = any (v_ciudad);
  select coalesce(array_agg(id), '{}') into v_esp from public.espacio where ubicacion_id = any (v_ubic);
  select coalesce(array_agg(id), '{}') into v_ep from public.espacio_persona where espacio_id = any (v_esp);

  select coalesce(array_agg(id), '{}') into v_jornada from public.jornada where colportor_id = any (v_u2);
  select coalesce(array_agg(id), '{}') into v_visita from public.visita
   where espacio_id = any (v_esp) or espacio_persona_id = any (v_ep) or jornada_id = any (v_jornada);
  select coalesce(array_agg(id), '{}') into v_venta from public.venta
   where espacio_persona_id = any (v_ep) or visita_id = any (v_visita);
  select coalesce(array_agg(id), '{}') into v_entrega from public.entrega where venta_id = any (v_venta);
  select coalesce(array_agg(id), '{}') into v_cobranza from public.cobranza where venta_id = any (v_venta);
  select coalesce(array_agg(id), '{}') into v_deposito from public.deposito
   where colportor_id = any (v_u2) or campania_id = any (v_campania);

  -- Lo único que se identifica por id: el catálogo de la demo.
  select coalesce(array_agg(id), '{}') into v_prod from public.producto
   where id::text ~ '^dede0000-0000-7000-8005-0*[1-9]$';
  select coalesce(array_agg(id), '{}') into v_col from public.coleccion
   where id::text ~ '^dede0000-0000-7000-8006-0*[1-2]$';
  select coalesce(array_agg(id), '{}') into v_carrera from public.carrera
   where id::text ~ '^dede0000-0000-7000-801e-0*[1-3]$';
  select coalesce(array_agg(distinct pedido_id), '{}') into v_pedido from public.pedido_item
   where producto_id = any (v_prod);

  -- Una venta de otro lado que usa un producto o una colección de la demo: se frena (el catálogo se comparte).
  select count(*) into v_n
    from public.venta_item vi
   where vi.deleted_at is null
     and (vi.producto_id = any (v_prod) or vi.coleccion_id = any (v_col))
     and vi.venta_id <> all (v_venta);
  if v_n > 0 then
    raise exception 'Retiro frenado, no se cambió nada: % renglón(es) de ventas ajenas a la demo usan productos o colecciones de la demo de Argentina.', v_n
      using errcode = 'P0001';
  end if;
  select count(*) into v_n
    from public.pedido_item pi
   where pi.deleted_at is null and pi.pedido_id = any (v_pedido) and pi.producto_id <> all (v_prod);
  if v_n > 0 then
    raise exception 'Retiro frenado, no se cambió nada: % renglón(es) de pedidos de la demo traen productos que no son de la demo.', v_n
      using errcode = 'P0001';
  end if;

  -- --------------------------------------------------------------------------------------------------
  -- 2. Las bajas lógicas, de las hojas a la raíz. Todas dentro de un bloque con su propio rollback: la
  --    vista previa lo deshace, y cualquier error lo deshace también.
  -- --------------------------------------------------------------------------------------------------
  begin
    -- Actividad
    update public.deposito set deleted_at = now() where deleted_at is null and id = any (v_deposito);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'deposito', 'filas', v_n);

    update public.agenda set deleted_at = now()
     where deleted_at is null
       and (espacio_persona_id = any (v_ep) or espacio_id = any (v_esp) or venta_id = any (v_venta)
            or entrega_id = any (v_entrega) or visita_id = any (v_visita));
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'agenda', 'filas', v_n);

    update public.cobranza set deleted_at = now() where deleted_at is null and id = any (v_cobranza);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'cobranza', 'filas', v_n);

    update public.entrega set deleted_at = now() where deleted_at is null and id = any (v_entrega);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'entrega', 'filas', v_n);

    update public.venta_item set deleted_at = now() where deleted_at is null and venta_id = any (v_venta);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'venta_item', 'filas', v_n);

    update public.venta set deleted_at = now() where deleted_at is null and id = any (v_venta);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'venta', 'filas', v_n);

    update public.visita set deleted_at = now() where deleted_at is null and id = any (v_visita);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'visita', 'filas', v_n);

    update public.jornada set deleted_at = now() where deleted_at is null and id = any (v_jornada);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'jornada', 'filas', v_n);

    -- Ubicaciones
    update public.espacio_persona set deleted_at = now() where deleted_at is null and id = any (v_ep);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'espacio_persona', 'filas', v_n);

    update public.house_status set deleted_at = now() where deleted_at is null and ubicacion_id = any (v_ubic);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'house_status', 'filas', v_n);

    update public.espacio set deleted_at = now() where deleted_at is null and id = any (v_esp);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'espacio', 'filas', v_n);

    update public.ubicacion set deleted_at = now() where deleted_at is null and id = any (v_ubic);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'ubicacion', 'filas', v_n);

    -- Pedidos y stock
    update public.movimiento_stock set deleted_at = now()
     where deleted_at is null
       and (producto_id = any (v_prod) or pedido_id = any (v_pedido) or entrega_id = any (v_entrega));
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'movimiento_stock', 'filas', v_n);

    update public.stock set deleted_at = now() where deleted_at is null and producto_id = any (v_prod);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'stock', 'filas', v_n);

    update public.pedido_item set deleted_at = now()
     where deleted_at is null and (pedido_id = any (v_pedido) or producto_id = any (v_prod));
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'pedido_item', 'filas', v_n);

    update public.pedido_casa_editora set deleted_at = now() where deleted_at is null and id = any (v_pedido);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'pedido_casa_editora', 'filas', v_n);

    update public.cuenta_colportor set deleted_at = now()
     where deleted_at is null and usuario_id = any (v_u2);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'cuenta_colportor', 'filas', v_n);

    -- Catálogo
    update public.precio_por_ciudad set deleted_at = now()
     where deleted_at is null
       and (campania_ciudad_id = any (v_cc) or producto_id = any (v_prod) or coleccion_id = any (v_col));
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'precio_por_ciudad', 'filas', v_n);

    update public.precio_general set deleted_at = now()
     where deleted_at is null and (producto_id = any (v_prod) or coleccion_id = any (v_col));
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'precio_general', 'filas', v_n);

    update public.producto_coleccion set deleted_at = now()
     where deleted_at is null and (producto_id = any (v_prod) or coleccion_id = any (v_col));
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'producto_coleccion', 'filas', v_n);

    update public.coleccion set deleted_at = now() where deleted_at is null and id = any (v_col);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'coleccion', 'filas', v_n);

    update public.producto set deleted_at = now() where deleted_at is null and id = any (v_prod);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'producto', 'filas', v_n);

    update public.meta_beca set deleted_at = now() where deleted_at is null and carrera_id = any (v_carrera);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'meta_beca', 'filas', v_n);

    update public.carrera set deleted_at = now() where deleted_at is null and id = any (v_carrera);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'carrera', 'filas', v_n);

    -- Campaña: cuentas de alquiler, inscripciones (y su historial de zonas), zonas, ciudad de la campaña
    update public.cuenta_alquiler set deleted_at = now() where deleted_at is null and campania_id = any (v_campania);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'cuenta_alquiler', 'filas', v_n);

    update public.campania_colportor set deleted_at = now() where deleted_at is null and id = any (v_inscr);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'campania_colportor', 'filas', v_n);

    update public.campania_colportor_zona_historial set deleted_at = now()
     where deleted_at is null and campania_colportor_id = any (v_inscr);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'campania_colportor_zona_historial', 'filas', v_n);

    update public.zona set deleted_at = now() where deleted_at is null and campania_ciudad_id = any (v_cc);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'zona', 'filas', v_n);

    update public.campania_ciudad set deleted_at = now() where deleted_at is null and id = any (v_cc);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'campania_ciudad', 'filas', v_n);

    update public.campania set deleted_at = now() where deleted_at is null and id = any (v_campania);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'campania', 'filas', v_n);

    update public.ciudad set deleted_at = now() where deleted_at is null and id = any (v_ciudad);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'ciudad', 'filas', v_n);

    update public.pais set deleted_at = now() where deleted_at is null and id = any (v_pais);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'pais', 'filas', v_n);

    -- La cuenta de colportor2.demo: usuario, rol y login
    update public.usuario_rol set deleted_at = now() where deleted_at is null and usuario_id = any (v_u2);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'usuario_rol', 'filas', v_n);

    update public.usuario set deleted_at = now() where deleted_at is null and id = any (v_u2);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'usuario', 'filas', v_n);

    -- Auth: el login queda bloqueado (la fila no se borra). En un Postgres sin la columna de Supabase Auth
    -- (la base local de CI) este paso no tiene qué bloquear.
    if exists (select 1 from information_schema.columns
                where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until') then
      execute 'update auth.users set banned_until = timestamptz ''2999-12-31 00:00:00+00'''
              ' where lower(email) = $1 and (banned_until is null or banned_until < timestamptz ''2999-12-31 00:00:00+00'')'
        using v_demo_u2;
      get diagnostics v_n = row_count;
    else
      v_n := 0;
    end if;
    v_resumen := v_resumen || jsonb_build_object('que', 'auth.users (login bloqueado)', 'filas', v_n);

    -- --------------------------------------------------------------------------------------------------
    -- 3. Criterios de aceptación de #216
    -- --------------------------------------------------------------------------------------------------
    select count(*) into v_n from public.pais where deleted_at is null and iso_code <> 'UY';
    if v_n > 0 then
      raise exception 'Quedan % país(es) vivos que no son UY.', v_n using errcode = 'P0001';
    end if;
    select count(*) into v_n from public.ciudad c join public.pais p on p.id = c.pais_id
     where c.deleted_at is null and p.iso_code <> 'UY';
    if v_n > 0 then
      raise exception 'Quedan % ciudad(es) vivas de un país que no es UY.', v_n using errcode = 'P0001';
    end if;
    select count(distinct ca.id) into v_n
      from public.campania ca
      join public.campania_ciudad cc on cc.campania_id = ca.id and cc.deleted_at is null
      join public.ciudad c on c.id = cc.ciudad_id
      join public.pais p on p.id = c.pais_id
     where ca.deleted_at is null and p.iso_code <> 'UY';
    if v_n > 0 then
      raise exception 'Quedan % campaña(s) vivas con una ciudad de un país que no es UY.', v_n using errcode = 'P0001';
    end if;
    select count(*) into v_n from public.ubicacion u join public.ciudad c on c.id = u.ciudad_id
      join public.pais p on p.id = c.pais_id
     where u.deleted_at is null and p.iso_code <> 'UY';
    if v_n > 0 then
      raise exception 'Quedan % ubicación(es) vivas en un país que no es UY.', v_n using errcode = 'P0001';
    end if;
    select count(*) into v_n from public.usuario where id = any (v_u2) and deleted_at is null;
    if v_n > 0 then
      raise exception 'colportor2.demo sigue vivo.' using errcode = 'P0001';
    end if;

    if not v_aplicar then
      raise exception 'vista previa' using errcode = 'RT001';
    end if;
  exception when sqlstate 'RT001' then
    null;  -- vista previa: se deshace el bloque, que es lo que se quería
  end;

  insert into retiro_resumen (que, filas)
  values (case when v_aplicar then 'APLICADO' else 'VISTA PREVIA (no se cambió nada)' end, 0);
  insert into retiro_resumen (que, filas)
  select e ->> 'que', (e ->> 'filas')::integer
    from jsonb_array_elements(v_resumen) with ordinality as t(e, n)
   order by n;
end
$retiro$;

select que, filas from retiro_resumen order by orden;
