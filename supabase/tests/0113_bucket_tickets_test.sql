-- pgTAP · migración 0113 (backend-supabase#108, ADR-012): el bucket `tickets` es PRIVADO (la foto se mira con
-- una URL firmada de corta duración), tiene el tope de 2 MiB y solo acepta imágenes; cada colportora sube a
-- su carpeta (`<usuario_id>/<ticket_id>.jpg`) y a ninguna otra; ve lo suyo, el coordinador ve la foto de los
-- tickets de SU campaña (la ventana de la inscripción por la fecha del ticket: decisión del 26/10, #101 y #179; no
-- la de quien alguna vez coordinó al colportor), el ADMIN ve todo, nadie más ve nada; y NADIE desde el teléfono
-- pisa ni borra una foto subida.
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
-- Los nombres de los objetos del bucket que ve quien actúa, ordenados («-» si ninguno).
create or replace function pg_temp.veo() returns text language sql as $$
  select coalesce(string_agg(regexp_replace(name, '01920000-0000-7000-8000-0000000114', '#', 'g'), ',' order by name), '-')
    from storage.objects where bucket_id = 'tickets'
$$;

-- --- fixtures -------------------------------------------------------------------
-- b1 y b2 colportoras; c1 coordinador de la campaña de b1; c2 coordinador de otra (con b2); ad ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'bk14-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 bk14', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 bk14', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'));
-- `created_at` explícito: lo que un colportor hace cuenta desde el día en que se inscribió.
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '8 days'), (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '8 days');
-- Los tickets de las fotos que se suben abajo (el coordinador ve la foto según el ticket de la ruta): a1, a2 y a4
-- de b1 y a3 de b2, cobrados hace 2 días, dentro de su ventana.
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado)
select pg_temp.u(x.t), pg_temp.u(x.b), 'DEPOSITO', now() - interval '2 days', 1000, now() - interval '2 days', 'PENDIENTE'
  from (values ('a1','b1'), ('a2','b1'), ('a4','b1'), ('a3','b2')) x(t, b);

-- --- el bucket --------------------------------------------------------------------
select is((select count(*) from storage.buckets where id = 'tickets'), 1::bigint, 'existe el bucket tickets');
select is((select public from storage.buckets where id = 'tickets'), false,
          'es PRIVADO: la foto de un ticket no se lee por una URL pública');
select is((select file_size_limit from storage.buckets where id = 'tickets'), 2097152::bigint, 'el tope por archivo es 2 MiB');
select is((select allowed_mime_types from storage.buckets where id = 'tickets'),
          array['image/jpeg', 'image/png', 'image/webp'], 'solo acepta imágenes: jpeg, png y webp');
select is((select relrowsecurity from pg_class where oid = 'storage.objects'::regclass), true,
          'storage.objects tiene RLS activa (sin ella, las políticas no protegerían nada)');

-- --- las políticas -----------------------------------------------------------------
select is((select array_agg(policyname || ' ' || cmd || ' {' || array_to_string(roles, ',') || '}' order by policyname)
             from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'tickets\_%'),
          array['tickets_subir_propia INSERT {authenticated}', 'tickets_ver SELECT {authenticated}'],
          'dos políticas para el bucket: subir lo propio y ver; ninguna de UPDATE ni de DELETE');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and (qual ilike '%tickets%' or with_check ilike '%tickets%') and cmd in ('UPDATE', 'DELETE', 'ALL')), 0::bigint,
          'ninguna política de UPDATE, DELETE o ALL nombra al bucket: una foto subida no se pisa ni se borra');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and (qual ilike '%tickets%' or with_check ilike '%tickets%') and 'anon' = any (roles::text[])), 0::bigint,
          'y ninguna es para anon');

-- --- subir -------------------------------------------------------------------------
-- Fotos de b1: del ticket a1 (jpg) y a2 (png); de b2: a3.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg')),
          'ok', 'b1 sube la foto de su ticket a su carpeta');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a2')::text || '.png')),
          'ok', 'también un png');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a4')::text)),
          'ok', 'y sin extensión');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b2')::text || '/' || pg_temp.u('a3')::text || '.jpg')),
          '42501', 'b1 no sube a la carpeta de b2');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/foto.jpg')),
          '42501', 'ni con un nombre que no es el id de un ticket');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a5')::text || '.gif')),
          '42501', 'ni un .gif');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/sub/' || pg_temp.u('a5')::text || '.jpg')),
          '42501', 'ni en una subcarpeta');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('a5')::text || '.jpg')),
          '42501', 'ni sin carpeta');
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  upper(pg_temp.u('b1')::text) || '/' || pg_temp.u('a5')::text || '.jpg')),
          '42501', 'ni con la carpeta en mayúsculas (no es la de auth.uid())');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b1')::text || '/' || pg_temp.u('a6')::text || '.jpg')),
          '42501', 'anon no sube');

-- Fotos de b2 y un objeto con una carpeta que no es un uuid (como postgres: ninguna política deja subirlo).
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de(format($$ insert into storage.objects (bucket_id, name) values ('tickets', %L) $$,
                                  pg_temp.u('b2')::text || '/' || pg_temp.u('a3')::text || '.jpg')),
          'ok', 'b2 sube la suya');
select pg_temp.actuar_como_servidor();
insert into storage.objects (bucket_id, name) values ('tickets', 'carpeta-rara/x.jpg');

-- --- ver -------------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), '#b1/#a1.jpg,#b1/#a2.png,#b1/#a4', 'b1 ve sus fotos y ninguna de b2');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.veo(), '#b2/#a3.jpg', 'b2 ve la suya');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.veo(), '#b1/#a1.jpg,#b1/#a2.png,#b1/#a4',
          'el coordinador de b1 ve las fotos de b1 (para validar), no las de b2 ni la carpeta rara');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.veo(), '#b2/#a3.jpg', 'el coordinador de b2 ve las de b2');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 5, 'el ADMIN ve todas, también la carpeta rara');
select pg_temp.actuar_como_anon();
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 0, 'anon no ve ninguna');

-- Un coordinador sin colportores no ve nada, y una carpeta que no es un uuid no hace fallar la consulta.
select pg_temp.actuar_como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('c3'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bk14-c3@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id) select pg_temp.u('c3'), r.id from public.rol r where r.codigo = 'COORDINADOR';
select pg_temp.actuar_como(pg_temp.u('c3'));
select is(pg_temp.veo(), '-', 'un coordinador sin colportores no ve ninguna (y la carpeta rara no hace fallar la consulta)');

-- Si un colportor se da de baja de la campaña, su coordinador sigue viendo lo que subió (la ventana de la inscripción
-- cuenta la inscripción dada de baja, como el ticket).
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.veo(), '#b1/#a1.jpg,#b1/#a2.png,#b1/#a4',
          'de baja el colportor, el coordinador sigue viendo lo que subió (los tickets son de antes de la baja)');

-- --- pisar y borrar -------------------------------------------------------------------------
-- Sin política de UPDATE ni de DELETE, RLS deja las dos en cero filas (o las rechaza): sirve cualquiera de las
-- dos; lo que importa es que la foto quede intacta. Sin WHERE a propósito, y con storage.allow_delete_query
-- activo: ver el comentario de 0036_bucket_mapas_test.sql.
select pg_temp.actuar_como_servidor();
set local storage.allow_delete_query = 'true';
select pg_temp.actuar_como(pg_temp.u('b1'));
do $$ begin update storage.objects set name = 'pisada.jpg'; exception when others then null; end $$;
do $$ begin delete from storage.objects; exception when others then null; end $$;
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 5,
          'la dueña no pisa ni borra sus fotos: una foto subida es la prueba del ticket');
select pg_temp.actuar_como(pg_temp.u('c1'));
do $$ begin update storage.objects set name = 'pisada.jpg'; exception when others then null; end $$;
do $$ begin delete from storage.objects; exception when others then null; end $$;
select pg_temp.actuar_como(pg_temp.u('ad'));
do $$ begin update storage.objects set name = 'pisada.jpg'; exception when others then null; end $$;
do $$ begin delete from storage.objects; exception when others then null; end $$;
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from storage.objects where bucket_id = 'tickets' and name <> 'pisada.jpg'), 5,
          'ni el coordinador ni el ADMIN por la API: el vencimiento lo borra el servidor');
reset storage.allow_delete_query;

-- --- La foto de otra campaña (decisión del 26/10: a una coordinadora no se le muestra lo de otra campaña) -------
-- b1 pasa a la campaña e3, de c2 (alta hace 1 día; en e1 ya está de baja desde ahora). El ticket a8 es de hoy, de
-- e3; la foto a7 subió antes que su ticket; la foto a9 es de un ticket de b1 que no es de ninguna campaña
-- (cobrado hace 100 días, antes de toda inscripción).
select pg_temp.actuar_como_servidor();
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('e3'), 'e3 bk14', 'VERANO', public.hoy_montevideo() - 5, public.hoy_montevideo() + 30, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('e3'), pg_temp.u('b1'), now() - interval '1 day');
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado) values
  (pg_temp.u('a8'), pg_temp.u('b1'), 'DEPOSITO', now(), 1000, now() + interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('a9'), pg_temp.u('b1'), 'DEPOSITO', now(), 1000, now() - interval '100 days', 'PENDIENTE'),
  (pg_temp.u('aa'), pg_temp.u('b1'), 'DEPOSITO', now(), 1000, now() - interval '2 days', 'PENDIENTE');
-- El ticket aa subió tarde (hoy, ya en e3) pero es de hace 2 días, de e1: la campaña la da la fecha del ticket, no
-- la de subida. Y una foto de la carpeta de b2 que nombra al ticket a8, que es de b1: la ruta no es de ese ticket.
insert into storage.objects (bucket_id, name) values
  ('tickets', pg_temp.u('b1')::text || '/' || pg_temp.u('aa')::text || '.jpg'),
  ('tickets', pg_temp.u('b2')::text || '/' || pg_temp.u('a8')::text || '.jpg'),
  ('tickets', pg_temp.u('b1')::text || '/' || pg_temp.u('a8')::text || '.jpg'),
  ('tickets', pg_temp.u('b1')::text || '/' || pg_temp.u('a7')::text || '.jpg'),
  ('tickets', pg_temp.u('b1')::text || '/' || pg_temp.u('a9')::text || '.jpg');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.veo(), '#b1/#a1.jpg,#b1/#a2.png,#b1/#a4,#b1/#aa.jpg',
          'c1 coordinó a b1 en e1: ve la foto de los tickets de e1 (también el aa, que subió tarde), no la del a8 (de e3) ni la a7 (sin ticket) ni la a9 (de ninguna campaña)');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.veo(), '#b1/#a8.jpg,#b2/#a3.jpg',
          'c2 ve la foto del a8, que es de su campaña e3, y la de b2; no las de e1 de b1 (aunque ahora coordine a b1) ni la de la carpeta de b2 que nombra al ticket de b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 7,
          'b1 ve sus siete fotos, también la sin ticket (a7) y la de ninguna campaña (a9)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from storage.objects where bucket_id = 'tickets'), 10, 'el ADMIN ve las diez');
select pg_temp.actuar_como_servidor();

\else

\if :exigir
select fail('EXIGIR_STORAGE=1 y la base no tiene el servicio Storage (storage.buckets / storage.objects): la 0113 y esta prueba no se ejercitaron');
\else
select skip('la base no tiene el servicio Storage (storage.buckets / storage.objects): no hay bucket que probar', 1);
\endif

\endif

select * from finish();
rollback;
