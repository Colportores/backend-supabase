-- ============================================================================
-- Retira los datos de DEMO simulados que cargó supabase/seed-demo/demo-datos.sql
--
-- Qué hace: da de baja LÓGICA (deleted_at = now(), nunca DELETE) todas las filas cuyo id empieza con
-- 5eed0000-0000-7000-8 (el prefijo de la demo) y las que cuelgan de los usuarios de la demo sin llevar ese
-- prefijo (cuenta_alquiler, movimientos de stock, historial de zona), y bloquea el login de los usuarios de la demo
-- en Auth. Las bajas lógicas suben sync_version: los teléfonos las reciben en su próximo pull. No toca lo que no
-- sea de la demo (ni el catálogo, ni los usuarios, ni las campañas reales).
--
-- NO es una migración, a propósito: es una operación de datos de un solo ambiente.
--
-- Cómo se corre: `scripts/db-seed-demo.sh --retirar` (o pegarlo entero en el SQL Editor / `psql -f`). Es un solo DO:
-- o aplica todo o no aplica nada. Sin tocar nada corre en VISTA PREVIA: hace todo, devuelve el conteo por tabla y
-- deshace. Para aplicarlo de verdad, cambiar `v_aplicar boolean := false;` por `true` en el DO de abajo (el script lo hace
-- con --aplicar, sobre una copia). No depende de la transacción: sirve con `psql -f`, con el CLI y con el SQL Editor.
-- Se puede correr dos veces: la segunda no encuentra nada vivo.
--
-- Los depósitos YA VALIDADOS no se pueden dar de baja (trigger DP001: «una corrección es un movimiento nuevo», vale
-- también para el servidor): quedan vivos y el resumen los cuenta. Quitarlos del todo es una decisión de dominio de
-- Cristian (ver el archivo de pendientes del PR); este script no desactiva ese trigger.
--
-- Para volver a cargar la demo después de retirarla hay que borrar las filas a mano: el generador se detiene si ve
-- la campaña de la demo (aunque esté dada de baja), a propósito, para no resucitar datos retirados.
-- ============================================================================

create temp table if not exists retiro_demo_resumen (orden serial, que text, filas integer);
truncate retiro_demo_resumen;

do $retiro$
declare
  v_aplicar boolean := false;  -- retiro:aplicar (el script cambia este false por true con --aplicar)
  v_pre     constant text := '5eed0000-0000-7000-8%';
  v_usr     uuid[];
  v_n       integer;
  v_resumen jsonb := '[]'::jsonb;
  t         record;
begin
  -- Los tests pueden activar el retiro con la marca de transacción `retiro.aplicar`.
  v_aplicar := v_aplicar or coalesce(current_setting('retiro.aplicar', true), '') = 'si';

  select coalesce(array_agg(id), '{}') into v_usr from public.usuario where id::text like v_pre;

  begin
    -- De las hojas a la raíz. (tabla, condición): la condición usa los usuarios de la demo cuando la fila no lleva
    -- el prefijo por sí misma.
    for t in
      select * from (values
        (1,  'deposito',                          'id::text like $1 and validado_en is null'),
        (2,  'agenda',                            'id::text like $1'),
        (3,  'cobranza',                          'id::text like $1'),
        (4,  'ticket',                            'id::text like $1'),
        (5,  'entrega',                           'id::text like $1'),
        (6,  'venta_item',                        'id::text like $1'),
        (7,  'venta',                             'id::text like $1'),
        (8,  'visita',                            'id::text like $1'),
        (9,  'jornada',                           'id::text like $1'),
        (10, 'espacio_persona',                   'id::text like $1'),
        (11, 'house_status',                      'ubicacion_id::text like $1'),
        (12, 'espacio',                           'id::text like $1'),
        (13, 'ubicacion',                         'id::text like $1'),
        (14, 'movimiento_stock',                  'usuario_id = any ($2)'),
        (15, 'stock',                             'id::text like $1'),
        (16, 'pedido_item',                       'id::text like $1'),
        (17, 'pedido_casa_editora',               'id::text like $1'),
        (18, 'campania_coordinador',              'campania_id::text like $1'),
        (19, 'cuenta_colportor',                  'id::text like $1'),
        -- Después de la cuenta: darla de baja escribe otra fila de historial (trigger), sin el prefijo.
        (19.5, 'cuenta_deuda_historial',          'id::text like $1 or usuario_id = any ($2)'),
        (20, 'cuenta_alquiler',                   'usuario_id = any ($2)'),
        (21, 'precio_por_ciudad',                 'id::text like $1'),
        (22, 'precio_general',                    'id::text like $1'),
        (23, 'producto_coleccion',                'id::text like $1'),
        (24, 'coleccion',                         'id::text like $1'),
        (25, 'producto',                          'id::text like $1'),
        (26, 'meta_beca',                         'id::text like $1'),
        (27, 'campania_colportor_zona_historial', 'campania_colportor_id::text like $1'),
        (28, 'campania_colportor',                'id::text like $1'),
        (29, 'zona',                              'id::text like $1'),
        (30, 'campania_ciudad',                   'id::text like $1'),
        (31, 'campania',                          'id::text like $1'),
        (32, 'ciudad',                            'id::text like $1'),
        (33, 'pais',                              'id::text like $1'),
        (34, 'usuario_rol',                       'usuario_id = any ($2)'),
        (35, 'carrera',                           'id::text like $1')
      ) v(o, tabla, cond) order by o
    loop
      if to_regclass('public.' || t.tabla) is null then
        continue;  -- tabla que esta versión del esquema no tiene
      end if;
      execute format('update public.%I set deleted_at = now() where deleted_at is null and (%s)', t.tabla, t.cond)
        using v_pre, v_usr;
      get diagnostics v_n = row_count;
      v_resumen := v_resumen || jsonb_build_object('que', t.tabla, 'filas', v_n);
    end loop;

    -- Un depósito validado no se da de baja ni siquiera desde el servidor (DP001, migración 0129): queda vivo y se informa.
    select count(*) into v_n from public.deposito where id::text like v_pre and deleted_at is null;
    v_resumen := v_resumen || jsonb_build_object('que', 'AVISO: depósitos validados que NO se pueden dar de baja (DP001)', 'filas', v_n);

    -- Los usuarios se dan de baja al final (otras filas los referencian).
    update public.usuario set deleted_at = now() where deleted_at is null and id = any (v_usr);
    get diagnostics v_n = row_count; v_resumen := v_resumen || jsonb_build_object('que', 'usuario', 'filas', v_n);

    -- Auth: el login queda bloqueado (la fila no se borra). Sin la columna de Supabase Auth (base local de CI) no hay qué bloquear.
    if exists (select 1 from information_schema.columns
                where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until') then
      execute 'update auth.users set banned_until = timestamptz ''2999-12-31 00:00:00+00'''
              ' where id = any ($1) and (banned_until is null or banned_until < timestamptz ''2999-12-31 00:00:00+00'')'
        using v_usr;
      get diagnostics v_n = row_count;
    else
      v_n := 0;
    end if;
    v_resumen := v_resumen || jsonb_build_object('que', 'auth.users (login bloqueado)', 'filas', v_n);

    if not v_aplicar then
      raise exception 'vista previa' using errcode = 'RT001';
    end if;
  exception when sqlstate 'RT001' then
    null;  -- vista previa: se deshace el bloque, que es lo que se quería
  end;

  insert into retiro_demo_resumen (que, filas)
  values (case when v_aplicar then 'APLICADO' else 'VISTA PREVIA (no se cambió nada)' end, 0);
  insert into retiro_demo_resumen (que, filas)
  select e ->> 'que', (e ->> 'filas')::integer
    from jsonb_array_elements(v_resumen) with ordinality as t2(e, n)
   order by n;
end
$retiro$;

select que, filas from retiro_demo_resumen order by orden;
