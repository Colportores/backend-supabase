-- pgTAP · bucket `tickets` de Supabase Storage (migración 0113, backend-supabase#108) tras la 0134 (backend-supabase#182):
-- las fotos de los tickets van a Cloudflare R2 y el bucket de Supabase DEJA DE USARSE. La fila del bucket queda (vacía y
-- privada: un DELETE por SQL no borra archivos) y las dos políticas de la 0113 (`tickets_subir_propia`, `tickets_ver`)
-- ya no están: con RLS activa y ninguna política que lo nombre, nadie sube ni ve nada de ese bucket desde la API
-- (ni la dueña, ni su coordinador, ni el ADMIN). Los permisos de la foto los da la base con las dos funciones de la
-- 0134 (supabase/tests/0134_fotos_de_tickets_en_r2_test.sql).
--
-- Las tablas de `storage` las crea el servicio Storage, no la imagen de Postgres: contra la base del job
-- `migraciones` de CI (solo `db`) no existen y las pruebas se saltean, a la vista (SKIP). Con Storage corriendo
-- se ejecutan todas (`supabase start`, el proyecto hosteado, o `bash tiles/prueba-storage/correr.sh`, que es lo
-- que corre el job `storage` de CI). Misma mecánica que 0036_bucket_mapas_test.sql: \if :hay_storage, y
-- EXIGIR_STORAGE=1 vuelve la falta de Storage una FALLA. Necesita psql 15 o más (\getenv).
\getenv exigir_storage EXIGIR_STORAGE
\if :{?exigir_storage}
select :'exigir_storage' = '1' as exigir \gset
\else
\set exigir false
\endif

begin;
select * from no_plan();

select to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null as hay_storage \gset

\if :hay_storage

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
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000114' || p)::uuid
$$;
-- «ok» o el sqlstate de lo que hace una sentencia.
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures: b1 colportora, c1 coordinador de su campaña, ad ADMIN -----------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'bk14-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 bk14', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '8 days');
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado)
values (pg_temp.u('a1'), pg_temp.u('b1'), 'DEPOSITO', now() - interval '2 days', 1000, now() - interval '2 days', 'PENDIENTE');

-- --- el bucket sigue, vacío y privado -----------------------------------------------------------------------------
select is((select count(*) from storage.buckets where id = 'tickets'), 1::bigint, 'la fila del bucket tickets sigue (no se borra por SQL)');
select is((select public from storage.buckets where id = 'tickets'), false, 'sigue PRIVADO: nada se lee por una URL pública');
select is((select relrowsecurity from pg_class where oid = 'storage.objects'::regclass), true,
          'storage.objects tiene RLS activa (sin ella, quitar las políticas no cerraría nada)');

-- --- las políticas ya no están ---------------------------------------------------------------------------------
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'tickets\_%'),
          0::bigint, 'ya no hay políticas tickets_* en storage.objects');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and (qual ilike '%tickets%' or with_check ilike '%tickets%')), 0::bigint,
          'ninguna política de storage.objects nombra al bucket tickets: ni subir, ni ver, ni pisar, ni borrar');

-- --- nadie sube ni ve --------------------------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg')),
          '42501', 'la dueña ya no sube la foto de su ticket al bucket de Supabase (va a R2 con el enlace de la función)');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('c1')::text || '/' || pg_temp.u('a1')::text || '.jpg')),
          '42501', 'el coordinador tampoco');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('ad')::text || '/' || pg_temp.u('a1')::text || '.jpg')),
          '42501', 'ni el ADMIN');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg')),
          '42501', 'anon no sube');

-- Un objeto que el servidor deje (lo que sea) no lo ve nadie desde la API.
select pg_temp.actuar_como_servidor();
insert into storage.objects (bucket_id, name)
values ('tickets', pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 0, 'la dueña no ve ni su propia foto en el bucket viejo');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 0, 'el coordinador no ve nada');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 0, 'el ADMIN tampoco: ver la foto es pedir el enlace a la función');
select pg_temp.actuar_como_anon();
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 0, 'anon no ve nada');
select pg_temp.actuar_como_servidor();

\else

\if :exigir
select fail('EXIGIR_STORAGE=1 y la base no tiene el servicio Storage (storage.buckets / storage.objects): la 0134 y esta prueba no se ejercitaron');
\else
select skip('la base no tiene el servicio Storage (storage.buckets / storage.objects): no hay bucket que probar', 1);
\endif

\endif

select * from finish();
rollback;
