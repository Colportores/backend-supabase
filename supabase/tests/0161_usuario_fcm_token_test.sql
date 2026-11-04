-- pgTAP · migración 0161 (backend-supabase#237, HU-NOT-001 y HU-NOT-003, ADR-014): usuario.fcm_token.
--   1. La forma: columna de texto opcional, vacía en todas las filas que ya había; sin trigger de sync
--      (usuario no es entidad del motor).
--   2. Cada usuario escribe SOLO el suyo (política usuario_update_propio) y lo borra con null.
--   3. La forma del token: entre 1 y 4096 caracteres, sin espacios ni saltos de línea.
--   4. Un token es de un solo usuario: guardarlo en otra cuenta se lo quita a la anterior, también si
--      quien lo guarda es una cuenta sin permiso sobre la otra fila.
--   5. Quién lo lee: el propio usuario y el ADMIN; el coordinador y otra colportora, no.
-- Va en una transacción.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000161' || p)::uuid;
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Lo que guarda el servidor en la fila de un usuario.
create or replace function pg_temp.token_de(p text) returns text language sql as $$
  select fcm_token from public.usuario where id = pg_temp.u(p);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 y a2 colportoras, c1 coordinadora (con su rol), ad ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'fcm161-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('c1'), r.id from public.rol r where r.codigo = 'COORDINADOR'
union all
select pg_temp.u('ad'), r.id from public.rol r where r.codigo = 'ADMIN';

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'usuario', 'fcm_token', 'text', 'usuario.fcm_token es texto');
select col_is_null('public', 'usuario', 'fcm_token', 'y opcional');
select is((select count(*)::int from public.usuario where fcm_token is not null), 0,
          'ninguna fila existente tiene token: la columna solo suma');
select ok(not exists (select 1 from sync.entidad where tabla = 'public.usuario'::regclass),
          'usuario no es entidad del motor de sync: el token no sube ni baja por ahí');
select ok(not has_function_privilege('authenticated', 'public.tg_usuario_fcm_token_unico()', 'execute')
          and not has_function_privilege('anon', 'public.tg_usuario_fcm_token_unico()', 'execute'),
          'la función del trigger no la ejecuta nadie desde afuera');

-- ---------------------------------------------------------------------------
-- 2. Cada uno escribe el suyo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
update public.usuario set fcm_token = 'token-de-ana-1' where id = pg_temp.u('a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.token_de('a1'), 'token-de-ana-1', 'la colportora guarda su token con un PATCH de su fila');

select pg_temp.actuar_como(pg_temp.u('a1'));
update public.usuario set fcm_token = 'token-de-ana-2' where id = pg_temp.u('a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.token_de('a1'), 'token-de-ana-2', 'si el sistema lo renueva, lo vuelve a guardar y queda el nuevo');

-- Otra colportora no puede escribir el token de Ana: la RLS no le deja ver la fila (0 filas, sin error).
select pg_temp.actuar_como(pg_temp.u('a2'));
update public.usuario set fcm_token = 'token-robado' where id = pg_temp.u('a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.token_de('a1'), 'token-de-ana-2', 'una colportora no escribe el token de otra');

select pg_temp.actuar_como(pg_temp.u('a1'));
update public.usuario set fcm_token = null where id = pg_temp.u('a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.token_de('a1'), null, 'al cerrar sesión la app lo borra con null');

-- ---------------------------------------------------------------------------
-- 3. La forma del token
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de($$update public.usuario set fcm_token = '' where id = pg_temp.u('a1')$$), '23514',
          'una cadena vacía no es un token: para borrarlo se manda null');
select is(pg_temp.error_de($$update public.usuario set fcm_token = 'con espacio' where id = pg_temp.u('a1')$$), '23514',
          'un token con espacios no entra');
select is(pg_temp.error_de($$update public.usuario set fcm_token = E'con\nsalto' where id = pg_temp.u('a1')$$), '23514',
          'un token con un salto de línea no entra');
select is(pg_temp.error_de($$update public.usuario set fcm_token = ' token' where id = pg_temp.u('a1')$$), '23514',
          'ni con un espacio al principio');
select is(pg_temp.error_de(format($$update public.usuario set fcm_token = %L where id = pg_temp.u('a1')$$,
                                  repeat('a', 4097))), '23514', 'ni de más de 4096 caracteres');
select is(pg_temp.error_de(format($$update public.usuario set fcm_token = %L where id = pg_temp.u('a1')$$,
                                  repeat('a', 4096))), 'ok', 'uno de 4096 sí');
select is(pg_temp.error_de($$update public.usuario set fcm_token = 'dXN1YXJpbzoxMjM0NTY3ODkw_-:APA91bF-abc' where id = pg_temp.u('a1')$$),
          'ok', 'un token con la forma de los de FCM (letras, números, guion, guion bajo y dos puntos) entra');
update public.usuario set fcm_token = null where id = pg_temp.u('a1');

-- ---------------------------------------------------------------------------
-- 4. Un token, un usuario
-- ---------------------------------------------------------------------------
update public.usuario set fcm_token = 'token-del-telefono-de-ana' where id = pg_temp.u('a1');
select is(pg_temp.token_de('a1'), 'token-del-telefono-de-ana', 'Ana guarda el token de su teléfono');

-- Beto inicia sesión en ese mismo teléfono y la app guarda el token en su cuenta.
select pg_temp.actuar_como(pg_temp.u('a2'));
update public.usuario set fcm_token = 'token-del-telefono-de-ana' where id = pg_temp.u('a2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.token_de('a2'), 'token-del-telefono-de-ana', 'Beto queda con el token del teléfono');
select is(pg_temp.token_de('a1'), null,
          'y Ana lo pierde en la misma transacción: sus avisos no llegan al teléfono de Beto');

-- Un token distinto no toca a nadie.
update public.usuario set fcm_token = 'otro-token-de-ana' where id = pg_temp.u('a1');
select is(pg_temp.token_de('a2'), 'token-del-telefono-de-ana', 'guardar otro token no le quita el suyo a Beto');

-- Borrar el propio (null) no toca a nadie y no dispara el movimiento.
update public.usuario set fcm_token = null where id = pg_temp.u('a2');
select is(pg_temp.token_de('a1'), 'otro-token-de-ana', 'borrar el token de Beto no toca el de Ana');

-- El mismo token que ya tenía no cambia nada (el UPDATE no suelta la fila de nadie más).
update public.usuario set fcm_token = 'otro-token-de-ana' where id = pg_temp.u('a1');
select is(pg_temp.token_de('a1'), 'otro-token-de-ana', 'reenviar el mismo token deja todo igual');

-- ---------------------------------------------------------------------------
-- 5. Quién lo lee
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select fcm_token from public.usuario where id = pg_temp.u('a1')), 'otro-token-de-ana',
          'la dueña lee su token');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*)::int from public.usuario where id = pg_temp.u('a1')), 0,
          'otra colportora no ve ni la fila de Ana');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.usuario where id = pg_temp.u('a1')), 0,
          'la coordinadora tampoco ve tokens ajenos');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select fcm_token from public.usuario where id = pg_temp.u('a1')), 'otro-token-de-ana',
          'el ADMIN sí lo lee');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
