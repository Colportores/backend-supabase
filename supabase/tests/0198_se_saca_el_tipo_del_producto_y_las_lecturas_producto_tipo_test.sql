-- pgTAP · 0198 (backend-supabase#233, seguimiento de #226 / #221; decisión P2 del 29/10, «Categorías»):
-- `producto.tipo` ya no existe, el trigger de transición y sus tres helpers tampoco, y las tres lecturas que devolvían
-- `producto_tipo` (stock_por_ciudad, pedido_lineas, transferencia_lineas) dejan de devolverlo con los mismos permisos.
-- El orden de stock_por_ciudad por categoría está en 0111 (Bonificables y Espirituales juntos, revistas, material,
-- misioneros); las líneas con datos, en 0112 y 0126.
begin;
select * from no_plan();

-- La columna, el trigger y los helpers.
select hasnt_column('public', 'producto', 'tipo', 'producto.tipo ya no existe');
select has_column('public', 'producto', 'categoria', 'la categoría sigue');
select col_not_null('public', 'producto', 'categoria', 'y obligatoria');
select hasnt_trigger('public', 'producto', 'producto_categoria_y_tipo', 'el trigger de transición ya no está');
select is((select count(*)::int from pg_trigger t where t.tgrelid = 'public.producto'::regclass and not t.tgisinternal
              and t.tgname like '%tipo%'), 0, 'ni otro trigger que nombre al tipo');
select hasnt_function('public', 'tg_producto_categoria_y_tipo', 'la función del trigger ya no está');
select hasnt_function('public', 'tipo_de_categoria', array['text'], 'tipo_de_categoria ya no está');
select hasnt_function('public', 'categoria_de_producto', array['text', 'boolean', 'boolean'], 'categoria_de_producto ya no está');
select is((select count(*)::int from pg_constraint c where c.conrelid = 'public.producto'::regclass
              and pg_get_constraintdef(c.oid) like '%tipo%'), 0, 'ninguna restricción de producto nombra al tipo');

-- Las tres lecturas: sin `producto_tipo` y con los permisos de antes (solo authenticated).
select is((select proargnames from pg_proc where oid = 'public.stock_por_ciudad(uuid)'::regprocedure),
          array['p_campania_id','ciudad_id','ciudad_nombre','departamento','colportor_id','nombre','apellido','de_baja',
                'ultimo_dato_at','producto_id','producto_nombre','tiene','por_entregar','entregados','devueltos','por_cobrar'],
          'stock_por_ciudad: las columnas, sin producto_tipo');
select is((select proargnames from pg_proc where oid = 'public.pedido_lineas(uuid)'::regprocedure),
          array['p_pedido_id','producto_id','producto_nombre','cantidad','cantidad_autorizada','precio_unitario',
                'subtotal','subtotal_autorizado','stock'],
          'pedido_lineas: las columnas, sin producto_tipo');
select is((select proargnames from pg_proc where oid = 'public.transferencia_lineas(uuid)'::regprocedure),
          array['p_transferencia_id','producto_id','producto_nombre','cantidad','precio_unitario','subtotal',
                'tiene_quien_da','debe_entregar_quien_recibe','tiene_quien_recibe'],
          'transferencia_lineas: las columnas, sin producto_tipo');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and 'producto_tipo' = any (coalesce(p.proargnames, array[]::text[]))),
          0, 'ninguna función de public devuelve ya producto_tipo');
select is((select bool_and(f.seg and f.vol and f.vacio)
             from (select p.prosecdef as seg, p.provolatile = 'v' as vol, coalesce(p.proconfig @> array['search_path=""'], false) as vacio
                     from pg_proc p
                    where p.oid in ('public.stock_por_ciudad(uuid)'::regprocedure, 'public.pedido_lineas(uuid)'::regprocedure,
                                    'public.transferencia_lineas(uuid)'::regprocedure)) f),
          true, 'siguen siendo SECURITY DEFINER, VOLATILE y de search_path vacío');
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.stock_por_ciudad(uuid)'::regprocedure, 'public.pedido_lineas(uuid)'::regprocedure,
                            'public.transferencia_lineas(uuid)'::regprocedure)
              and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('public', p.oid, 'execute'))),
          0, 'anon ni PUBLIC las ejecutan');
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.stock_por_ciudad(uuid)'::regprocedure, 'public.pedido_lineas(uuid)'::regprocedure,
                            'public.transferencia_lineas(uuid)'::regprocedure)
              and has_function_privilege('authenticated', p.oid, 'execute')
              and not has_function_privilege('service_role', p.oid, 'execute')), 3,
          'las ejecuta authenticated y no service_role, como antes');

-- El catálogo ya no baja `tipo` al teléfono.
select is((select count(*)::int from sync.entidad where nombre = 'producto' and sync.expresion_json(tabla) like '%''tipo''%'), 0,
          'el pull de producto no trae tipo');
select is((select count(*)::int from sync.entidad where nombre = 'producto' and sync.expresion_json(tabla) like '%''categoria''%'), 1,
          'y sí la categoría');

-- Un producto cargado sin categoría no entra: ya no hay quien se la deduzca del tipo.
select throws_ok($$ insert into public.producto (id, nombre) values ('01920000-0000-7000-8000-0000000198a0', 'Sin categoria t198') $$,
                 '23502', null, 'sin categoría: 23502');
select throws_ok($$ insert into public.producto (id, nombre, categoria, tipo) values ('01920000-0000-7000-8000-0000000198a1', 'Con tipo t198', 'MATERIAL', 'LIBRO') $$,
                 '42703', null, 'y escribir el tipo da columna inexistente');

select * from finish();
rollback;
