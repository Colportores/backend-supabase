-- pgTAP · migración 0029 (backend-supabase#42, decisión de Cristian del 06/10): el bucket `mapas` es
-- público (se lee por URL sin login), tiene el tope de 50 MiB del plan Free y solo acepta los tipos de
-- archivo que se publican; y NADIE más que la clave de servicio puede listar, subir, pisar ni borrar
-- objetos (ni `anon` ni `authenticated`: no hay políticas sobre storage.objects que los habiliten).
--
-- Las tablas de `storage` las crea el servicio Storage, no la imagen de Postgres: contra la base de
-- CI (solo `db`) no existen y las pruebas se saltean, a la vista (SKIP): el job `migraciones` de CI
-- NO ejercita esta prueba. Con Storage corriendo se ejecutan todas: `supabase start`, el proyecto
-- hosteado, o `bash tiles/prueba-storage/correr.sh` (levanta un storage-api real, con `SOLO_BASE=1`
-- se detiene después de esta prueba). psql decide con \if, porque un SELECT sobre una tabla que no
-- existe no llega ni a parsearse.
begin;
select * from no_plan();

select to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null as hay_storage \gset

\if :hay_storage

-- --- el bucket ---------------------------------------------------------------------
select is(
  (select count(*) from storage.buckets where id = 'mapas'),
  1::bigint,
  'existe el bucket mapas'
);

select is(
  (select public from storage.buckets where id = 'mapas'),
  true,
  'el bucket mapas es público: se lee por URL, sin login'
);

select is(
  (select file_size_limit from storage.buckets where id = 'mapas'),
  52428800::bigint,
  'el tope por archivo es 50 MiB, el del plan Free'
);

select is(
  (select allowed_mime_types from storage.buckets where id = 'mapas'),
  array['application/json', 'application/octet-stream', 'application/x-protobuf', 'image/png', 'text/plain'],
  'solo acepta catálogo/estilo (json), paquetes (octet-stream), glyphs (protobuf), sprites (png) y licencias (texto)'
);

-- --- quién puede escribir ---------------------------------------------------------------
-- Sin políticas que nombren al bucket, RLS le niega a anon y authenticated todo sobre sus objetos.
select is(
  (select count(*) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and (qual ilike '%mapas%' or with_check ilike '%mapas%')),
  0::bigint,
  'ninguna política de storage.objects habilita al bucket mapas: solo escribe service_role'
);

select is(
  (select relrowsecurity from pg_class where oid = 'storage.objects'::regclass),
  true,
  'storage.objects tiene RLS activa (sin ella, las políticas de arriba no protegerían nada)'
);

-- anon no puede subir (42501: RLS rechaza el INSERT)...
set local role anon;
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('mapas', 'paquetes/ciudad/intruso.pmtiles')$$,
  '42501',
  null,
  'anon no puede subir objetos al bucket mapas'
);
reset role;

-- ...ni authenticated...
set local role authenticated;
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('mapas', 'paquetes/ciudad/intruso.pmtiles')$$,
  '42501',
  null,
  'authenticated no puede subir objetos al bucket mapas'
);
reset role;

-- ...y ninguno de los dos ve la lista de objetos (la lectura es por URL pública, no por la API).
insert into storage.objects (bucket_id, name) values ('mapas', 'catalogo.json');

set local role anon;
select is(
  (select count(*) from storage.objects where bucket_id = 'mapas'),
  0::bigint,
  'anon no puede listar los objetos del bucket mapas'
);
reset role;

set local role authenticated;
select is(
  (select count(*) from storage.objects where bucket_id = 'mapas'),
  0::bigint,
  'authenticated no puede listar los objetos del bucket mapas'
);
reset role;

-- ...ni pisan ni borran lo que ya está publicado (catalogo.json, insertado arriba). Sin política, RLS
-- deja el UPDATE y el DELETE en cero filas (o los rechaza con 42501): sirve cualquiera de las dos, lo
-- que importa es que el objeto quede intacto. El bloque con EXCEPTION traga el error para poder mirar
-- después.
--  - Sin WHERE a propósito: con un WHERE sobre columnas, Postgres exige además una política de SELECT,
--    y una política de borrado o de actualización sola (la que esto vigila) no se notaría.
--  - Storage protege la tabla con un trigger (`protect_delete`) que rechaza todo DELETE directo salvo
--    que la sesión traiga `storage.allow_delete_query = 'true'`, que es lo que activa la propia API
--    de Storage al borrar un objeto. Sin ese ajuste, esta aserción vigilaría al trigger y no a las
--    políticas: una política `for delete to anon using (true)` pasaría inadvertida y la API de Storage
--    le dejaría borrar a cualquiera. Por eso se activa acá y se apaga al terminar.
-- Todo esto vive dentro de la transacción de la prueba, que termina en ROLLBACK.
set local storage.allow_delete_query = 'true';
set local role anon;
do $$ begin update storage.objects set name = 'catalogo-pisado.json'; exception when others then null; end $$;
do $$ begin delete from storage.objects; exception when others then null; end $$;
reset role;

select is(
  (select array_agg(name order by name) from storage.objects where bucket_id = 'mapas'),
  array['catalogo.json'],
  'anon no puede pisar ni borrar objetos del bucket mapas'
);

set local role authenticated;
do $$ begin update storage.objects set name = 'catalogo-pisado.json'; exception when others then null; end $$;
do $$ begin delete from storage.objects; exception when others then null; end $$;
reset role;

select is(
  (select array_agg(name order by name) from storage.objects where bucket_id = 'mapas'),
  array['catalogo.json'],
  'authenticated no puede pisar ni borrar objetos del bucket mapas'
);
reset storage.allow_delete_query;

\else

select skip('la base no tiene el servicio Storage (storage.buckets / storage.objects): no hay bucket que probar', 1);

\endif

select * from finish();
rollback;
