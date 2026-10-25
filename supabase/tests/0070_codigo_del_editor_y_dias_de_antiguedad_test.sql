-- pgTAP · migración 0070 (backend-supabase#137): producto.codigo_editor y los días de antigüedad de los
-- precios como parámetro global (HU-CAT-006; decisiones de Cristian del 23/10).
--   1. producto.codigo_editor: columna opcional, el CHECK (sin espacios ni saltos de línea al borde, de 1 a
--      50 caracteres), que no es único, quién lo escribe y que viaja en el pull.
--   2. parametro_global: la forma (columnas, auditoría, delta, RLS, privilegios), la fila de referencia
--      (15), los CHECK de clave y rango, una sola fila viva por clave y la baja lógica.
--   3. Quién lee y quién escribe: lee todo autenticado (incluidos el tombstone); ningún cliente escribe
--      (ni el ADMIN, hasta que exista audit_log: #136); anon nada; service_role sí.
--   4. El registro en sync.entidad: solo bajada, sin dueño ni campañas.
-- El pull de verdad (delta, push rechazado) está en 0070_parametro_global_pull_test.sql: no va en una
-- transacción.
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;
create or replace function pg_temp.actuar_como_rol(p_rol text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', p_rol, true);
  perform set_config('role', p_rol, true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000070' || p)::uuid;
$$;
-- ¿Cuántas filas toca el UPDATE del código? (un update que la RLS no deja ver no falla: toca 0)
create or replace function pg_temp.poner_codigo(p_id uuid, p_codigo text) returns integer language plpgsql as $$
declare n integer;
begin
  update public.producto set codigo_editor = p_codigo where id = p_id;
  get diagnostics n = row_count;
  return n;
end $$;

-- --- fixtures ------------------------------------------------------------------
-- a1 ADMIN · c1 COORDINADOR · b1 colportor.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'param70-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1', 'c1', 'b1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('a1'), r.id from public.rol r where r.codigo = 'ADMIN';
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('c1'), r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('d1'), 'Libro sin código', 'LIBRO'),
  (pg_temp.u('d2'), 'Libro con código', 'LIBRO');

-- ===============================================================================
-- 1. producto.codigo_editor
-- ===============================================================================
select has_column('public', 'producto', 'codigo_editor', 'producto tiene codigo_editor');
select col_type_is('public', 'producto', 'codigo_editor', 'text', 'es texto (un código puede llevar letras o ceros a la izquierda)');
select col_is_null('public', 'producto', 'codigo_editor', 'es opcional');
select col_hasnt_default('public', 'producto', 'codigo_editor', 'sin valor por defecto: sin código se encuentra por nombre');
select ok(col_description('public.producto'::regclass,
                          (select attnum from pg_attribute where attrelid = 'public.producto'::regclass and attname = 'codigo_editor')) is not null,
          'la columna está documentada');
select is((select codigo_editor from public.producto where id = pg_temp.u('d1')), null,
          'un producto sin código tiene null: los de antes quedan como estaban');

select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), 'ISBN 978-9974-1') $$, 'un código con espacios adentro se acepta');
select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), '00123') $$, 'con ceros a la izquierda');
select is((select codigo_editor from public.producto where id = pg_temp.u('d2')), '00123', 'y se conserva tal cual (texto)');
select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), 'A') $$, 'de un solo carácter');
select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), repeat('x', 50)) $$, 'de 50 caracteres (el tope)');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), repeat('x', 51)) $$, '23514', null, 'de 51 caracteres no');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), '') $$, '23514', null, 'vacío no: sin código es null');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), '   ') $$, '23514', null, 'solo espacios no');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), ' X1') $$, '23514', null, 'con un espacio al principio no');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), 'X1 ') $$, '23514', null, 'ni al final');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), E'X1\n') $$, '23514', null, 'ni un salto de línea al final');
select throws_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), E'\tX1') $$, '23514', null, 'ni un tabulador al principio');
select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), null) $$, 'volver a null (sacar el código) sí');

-- No es único: dos ediciones del mismo título pueden compartirlo.
select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d1'), 'EDI-77') $$, 'p1 toma un código');
select lives_ok($$ select pg_temp.poner_codigo(pg_temp.u('d2'), 'EDI-77') $$, 'p2 toma el mismo: no es único');

-- Alta con el código ya puesto.
select lives_ok($$ insert into public.producto (id, nombre, tipo, codigo_editor)
                   values (pg_temp.u('d3'), 'Libro nuevo con código', 'LIBRO', 'EDI-78') $$,
                'un producto nuevo puede nacer con su código');
select throws_ok($$ insert into public.producto (id, nombre, tipo, codigo_editor)
                    values (pg_temp.u('d4'), 'Libro con código roto', 'LIBRO', ' mal') $$,
                 '23514', null, 'y el CHECK vale también en el alta');

-- Quién lo escribe: el ADMIN, como el resto del producto (política 0001 §10.1).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.poner_codigo(pg_temp.u('d1'), 'ADM-1'), 1, 'el ADMIN cambia el código');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.poner_codigo(pg_temp.u('d1'), 'COO-1'), 0, 'un coordinador no (la RLS no le deja ver la fila para modificarla)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.poner_codigo(pg_temp.u('d1'), 'COL-1'), 0, 'un colportor tampoco');
select is((select codigo_editor from public.producto where id = pg_temp.u('d1')), 'ADM-1',
          'y lo ve: el código llega a todo autenticado, como el resto del producto');
select pg_temp.actuar_como_servidor();

-- La fila de un cambio lleva la versión de sync nueva (el delta la trae).
select is((select sync_version from public.producto where id = pg_temp.u('d1')) >= 1, true,
          'cada cambio sube sync_version (auditoría): el teléfono lo baja en el delta');

-- Viaja en el pull sin tocar nada más: la entidad serializa todas las columnas.
select alike(sync.expresion_json('public.producto'::regclass), '%''codigo_editor'', t.codigo_editor%',
            'sync.expresion_json de producto incluye codigo_editor');

-- ===============================================================================
-- 2. parametro_global: la forma
-- ===============================================================================
select has_table('public', 'parametro_global', 'existe parametro_global');
select col_type_is('public', 'parametro_global', 'id', 'uuid', 'id uuid');
select col_type_is('public', 'parametro_global', 'clave', 'text', 'clave text');
select col_type_is('public', 'parametro_global', 'valor', 'integer', 'valor entero');
select col_not_null('public', 'parametro_global', 'clave', 'clave es obligatoria');
select col_not_null('public', 'parametro_global', 'valor', 'valor es obligatorio');
select col_not_null('public', 'parametro_global', 'xmin_w', 'xmin_w es not null (cursor del delta)');
select col_not_null('public', 'parametro_global', 'sync_version', 'sync_version es not null');
select col_not_null('public', 'parametro_global', 'created_at', 'created_at es not null');
select col_not_null('public', 'parametro_global', 'updated_at', 'updated_at es not null');
select has_column('public', 'parametro_global', 'created_by', 'tiene created_by');
select has_column('public', 'parametro_global', 'deleted_at', 'tiene deleted_at (la baja es lógica)');
select has_pk('public', 'parametro_global', 'tiene clave primaria');
select has_index('public', 'parametro_global', 'parametro_global_delta_idx', array['xmin_w', 'id'], 'índice del delta');
select has_index('public', 'parametro_global', 'parametro_global_clave_viva_idx', array['clave'], 'índice único de la clave viva');
select has_trigger('public', 'parametro_global', 'parametro_global_auditoria_insert', 'trigger de auditoría del alta');
select has_trigger('public', 'parametro_global', 'parametro_global_auditoria_update', 'trigger de auditoría del cambio');
select is((select obj_description('public.parametro_global'::regclass, 'pg_class')) is not null, true, 'la tabla está documentada');

-- La fila de referencia.
select is((select count(*)::int from public.parametro_global), 1, 'hay una sola fila: la de referencia');
select is((select valor from public.parametro_global where clave = 'dias_antiguedad_precios'), 15,
          'los días de antigüedad de los precios valen 15 por defecto');
select is((select deleted_at from public.parametro_global where clave = 'dias_antiguedad_precios'), null,
          'y está viva');

-- ===============================================================================
-- 3. Los CHECK y la unicidad (como el servidor)
-- ===============================================================================
select pg_temp.actuar_como_servidor();
select lives_ok($$ update public.parametro_global set valor = 1 where clave = 'dias_antiguedad_precios' $$, '1 día es el mínimo');
select lives_ok($$ update public.parametro_global set valor = 365 where clave = 'dias_antiguedad_precios' $$, '365 días es el máximo');
select lives_ok($$ update public.parametro_global set valor = 100 where clave = 'dias_antiguedad_precios' $$, 'y uno del medio');
select throws_ok($$ update public.parametro_global set valor = 0 where clave = 'dias_antiguedad_precios' $$,
                 '23514', null, '0 días no: el aviso saltaría siempre');
select throws_ok($$ update public.parametro_global set valor = -3 where clave = 'dias_antiguedad_precios' $$,
                 '23514', null, 'un valor negativo no');
select throws_ok($$ update public.parametro_global set valor = 366 where clave = 'dias_antiguedad_precios' $$,
                 '23514', null, 'más de 365 no');
select throws_ok($$ update public.parametro_global set clave = 'otra_cosa' where clave = 'dias_antiguedad_precios' $$,
                 '23514', null, 'una clave que no existe no');
select throws_ok($$ insert into public.parametro_global (clave, valor) values ('otra_cosa', 5) $$,
                 '23514', null, 'tampoco en el alta');
select throws_ok($$ insert into public.parametro_global (clave, valor) values ('dias_antiguedad_precios', 20) $$,
                 '23505', null, 'una segunda fila viva de la misma clave no: el valor del parámetro es uno');

-- Una baja lógica deja crear la siguiente (el historial de filas no choca con la unicidad).
select lives_ok($$ update public.parametro_global set deleted_at = now() where clave = 'dias_antiguedad_precios' $$,
                'dar de baja la fila');
select lives_ok($$ insert into public.parametro_global (clave, valor) values ('dias_antiguedad_precios', 20) $$,
                'con la anterior dada de baja se puede crear la nueva');
select is((select count(*)::int from public.parametro_global where clave = 'dias_antiguedad_precios'), 2,
          'quedan las dos: la baja como tombstone y la nueva');
select is((select count(*)::int from public.parametro_global where clave = 'dias_antiguedad_precios' and deleted_at is null), 1,
          'y una sola viva');

-- Los tombstones los ve quien lee (el teléfono necesita la baja para borrar su réplica).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.parametro_global), 2, 'un colportor ve la viva y el tombstone');
select pg_temp.actuar_como_servidor();

-- Volver a la fila de referencia: se borra la nueva (el servidor puede) y se revive la original.
delete from public.parametro_global where clave = 'dias_antiguedad_precios' and deleted_at is null;
update public.parametro_global set deleted_at = null, valor = 15 where clave = 'dias_antiguedad_precios';
select is((select valor from public.parametro_global where deleted_at is null), 15, 'de vuelta en 15');

-- ===============================================================================
-- 4. Quién lee y quién escribe
-- ===============================================================================
select is(has_table_privilege('anon', 'public.parametro_global', 'select')
       or has_table_privilege('anon', 'public.parametro_global', 'insert')
       or has_table_privilege('anon', 'public.parametro_global', 'update')
       or has_table_privilege('anon', 'public.parametro_global', 'delete'), false, 'anon no tiene ningún privilegio');
select is(has_table_privilege('authenticated', 'public.parametro_global', 'select'), true, 'authenticated lee');
select is(has_table_privilege('authenticated', 'public.parametro_global', 'insert')
       or has_table_privilege('authenticated', 'public.parametro_global', 'update')
       or has_table_privilege('authenticated', 'public.parametro_global', 'delete')
       or has_table_privilege('authenticated', 'public.parametro_global', 'truncate'), false,
          'y no escribe: hasta que exista audit_log el cambio no tiene quién lo registre (#136)');
select is(has_table_privilege('service_role', 'public.parametro_global', 'select')
      and has_table_privilege('service_role', 'public.parametro_global', 'insert')
      and has_table_privilege('service_role', 'public.parametro_global', 'update'), true,
          'service_role lee y escribe (la guía de carga manual, el servidor)');
select is((select relrowsecurity from pg_class where oid = 'public.parametro_global'::regclass), true, 'RLS habilitada');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'parametro_global'), 1,
          'una sola política');
select is((select cmd collate "C" from pg_policies where schemaname = 'public' and tablename = 'parametro_global'), 'SELECT',
          'y es de lectura: ninguna de escritura para los clientes');

-- Lee todo autenticado, cualquiera sea su rol.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select valor from public.parametro_global where deleted_at is null), 15, 'el ADMIN lo lee');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select valor from public.parametro_global where deleted_at is null), 15, 'un coordinador lo lee');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select valor from public.parametro_global where deleted_at is null), 15,
          'un colportor lo lee, sin estar inscripto en ninguna campaña');

-- Ningún cliente escribe: ni el ADMIN (permission denied, 42501).
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ update public.parametro_global set valor = 30 where clave = 'dias_antiguedad_precios' $$,
                 '42501', null, 'el ADMIN no cambia los días por la API (todavía: falta audit_log)');
select throws_ok($$ insert into public.parametro_global (clave, valor) values ('dias_antiguedad_precios', 30) $$,
                 '42501', null, 'ni inserta');
select throws_ok($$ delete from public.parametro_global $$, '42501', null, 'ni borra');
select pg_temp.actuar_como(pg_temp.u('c1'));
select throws_ok($$ update public.parametro_global set valor = 30 where clave = 'dias_antiguedad_precios' $$,
                 '42501', null, 'un coordinador no cambia los días');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ update public.parametro_global set valor = 1 where clave = 'dias_antiguedad_precios' $$,
                 '42501', null, 'un colportor tampoco');
select throws_ok($$ insert into public.parametro_global (clave, valor) values ('dias_antiguedad_precios', 1) $$,
                 '42501', null, 'ni inserta');
select pg_temp.actuar_como_rol('anon');
select throws_ok($$ select count(*) from public.parametro_global $$, '42501', null, 'anon ni siquiera lo lee');
select pg_temp.actuar_como_servidor();
select is((select valor from public.parametro_global where deleted_at is null), 15, 'y el valor sigue en 15');

-- El servidor sí lo cambia, y el cambio sube la versión de sync (el delta lo lleva).
select pg_temp.actuar_como_rol('service_role');
select lives_ok($$ update public.parametro_global set valor = 20 where clave = 'dias_antiguedad_precios' $$,
                'service_role cambia los días');
select pg_temp.actuar_como_servidor();
select is((select valor from public.parametro_global where deleted_at is null), 20, 'queda en 20');
select is((select sync_version from public.parametro_global where deleted_at is null) >= 1, true,
          'sync_version subió: el teléfono lo baja en el pull siguiente');

-- ===============================================================================
-- 5. El registro en sync.entidad
-- ===============================================================================
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, columna_duenio, sigue_campanias, columna_ubicacion
       from sync.entidad where nombre = 'parametro_global' $$,
  $$ values ('parametro_global'::text, 'parametro_global'::text, 'id'::text, false, null::text, false, null::text) $$,
  'entidad de solo bajada, sin dueño, sin campañas y sin ubicación: el mismo valor para todos');
select alike(sync.expresion_json('public.parametro_global'::regclass), '%''clave'', t.clave%''valor'', t.valor%',
            'el pull serializa clave y valor');
select unalike(sync.expresion_json('public.parametro_global'::regclass), '%xmin_w%', 'y no xmin_w');

select * from finish();
rollback;
