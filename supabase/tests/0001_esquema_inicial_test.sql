-- pgTAP · migración 0001
-- Corre con scripts/db-test.sh (pg_prove). Cada archivo va en su transacción y hace rollback.
begin;
select * from no_plan();

-- ---------------------------------------------------------------------------
-- 1. Existen todas las tablas V1 del cloud
-- ---------------------------------------------------------------------------
select has_table('public', t, format('tabla %s existe', t))
from unnest(array[
  'pais','ciudad','usuario','rol','usuario_rol','horario_colportor','campania','zona',
  'campania_colportor','producto','coleccion','producto_coleccion','precio_por_zona',
  'ubicacion','espacio','espacio_persona','jornada','visita','agenda','venta','venta_item',
  'entrega','cobranza','house_status'
]) as t;

-- ---------------------------------------------------------------------------
-- 2. Guardas de privacidad (Ley 18.331) — si esto falla, el PR se rechaza
-- ---------------------------------------------------------------------------
select hasnt_table('public', 'persona',    'persona NO existe en cloud');
select hasnt_table('public', 'nota',       'nota NO existe en cloud');
select hasnt_table('public', 'sync_queue', 'sync_queue es estado interno del cliente');

select is(
  (select count(*) from information_schema.columns
    where table_schema = 'public' and column_name in ('telefono','notas','notas_globales','texto')),
  0::bigint,
  'ninguna tabla tiene columnas telefono/notas/texto'
);

select is(
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name <> 'usuario'
      and column_name in ('nombre','apellido') and table_name not in
      ('pais','ciudad','zona','campania','rol','producto','coleccion')),
  0::bigint,
  'nombre/apellido solo en usuario y catálogos (nunca en tablas del cliente final)'
);

select col_hasnt_default('public', 'espacio_persona', 'persona_id', 'persona_id lo genera el dispositivo');
select is(
  (select count(*) from information_schema.table_constraints tc
     join information_schema.key_column_usage k using (constraint_name, table_schema)
    where tc.table_schema = 'public' and tc.table_name = 'espacio_persona'
      and tc.constraint_type = 'FOREIGN KEY' and k.column_name = 'persona_id'),
  0::bigint,
  'espacio_persona.persona_id no tiene FK (la persona no existe en cloud)'
);

-- ---------------------------------------------------------------------------
-- 3. Auditoría en TODAS las tablas de public
-- ---------------------------------------------------------------------------
select has_column('public', t.tablename, c, format('%s.%s', t.tablename, c))
from pg_tables t, unnest(array['created_at','updated_at','created_by','deleted_at','sync_version']) as c
where t.schemaname = 'public';

select col_type_is('public', t.tablename, 'sync_version', 'bigint', format('%s.sync_version es bigint', t.tablename))
from pg_tables t where t.schemaname = 'public';

select has_trigger('public', t.tablename, t.tablename || '_auditoria_update',
                   format('%s tiene trigger de auditoría', t.tablename))
from pg_tables t where t.schemaname = 'public';

-- ---------------------------------------------------------------------------
-- 4. RLS habilitada en todas, anon sin privilegios, authenticated sin DELETE
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from pg_tables where schemaname = 'public' and not rowsecurity),
  0::bigint,
  'todas las tablas de public tienen RLS habilitada'
);

select is(
  (select count(*) from pg_tables where schemaname = 'public'
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = pg_tables.tablename)),
  0::bigint,
  'todas las tablas tienen al menos una política'
);

select is(
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon'),
  0::bigint,
  'anon no tiene privilegios sobre public'
);

select is(
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'authenticated' and privilege_type = 'DELETE'),
  0::bigint,
  'authenticated no puede DELETE (solo soft delete)'
);

-- ---------------------------------------------------------------------------
-- 5. IDs: uuid en todas las PK, nunca serial/identity
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from information_schema.columns
    where table_schema = 'public' and (column_default like 'nextval%' or is_identity = 'YES')),
  0::bigint,
  'ninguna columna es serial/identity'
);

select col_type_is('public', t.tablename, 'id', 'uuid', format('%s.id es uuid', t.tablename))
from pg_tables t where t.schemaname = 'public' and t.tablename <> 'house_status';
select col_type_is('public', 'house_status', 'ubicacion_id', 'uuid', 'house_status.ubicacion_id es uuid');

select matches(public.uuid_generate_v7()::text, '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
               'uuid_generate_v7() produce un UUID v7 válido');

-- ---------------------------------------------------------------------------
-- 6. Comportamiento: trigger de auditoría y alta de perfil desde auth.users
-- ---------------------------------------------------------------------------
-- created_at en el pasado: dentro de una transacción now() es constante y no distinguiría el UPDATE.
insert into public.pais (id, nombre, iso_code, created_at, updated_at)
values ('01920000-0000-7000-8000-0000000000aa', 'Uruguay', 'UY',
        now() - interval '1 minute', now() - interval '1 minute');

update public.pais set nombre = 'República Oriental del Uruguay'
where id = '01920000-0000-7000-8000-0000000000aa';

select is(sync_version, 1::bigint, 'UPDATE incrementa sync_version')
from public.pais where id = '01920000-0000-7000-8000-0000000000aa';
select ok(updated_at > created_at, 'UPDATE avanza updated_at')
from public.pais where id = '01920000-0000-7000-8000-0000000000aa';

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_user_meta_data,
                        created_at, updated_at)
values ('01920000-0000-7000-8000-0000000000bb', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'colportor.prueba@example.com', 'x',
        '{"nombre":"Prueba","apellido":"Colportor"}', now(), now());

select row_eq(
  $$ select email, nombre, apellido from public.usuario where id = '01920000-0000-7000-8000-0000000000bb' $$,
  row('colportor.prueba@example.com'::text, 'Prueba'::text, 'Colportor'::text),
  'al crear auth.users se crea public.usuario con el mismo id'
);

-- ---------------------------------------------------------------------------
-- 7. Roles de referencia
-- ---------------------------------------------------------------------------
select bag_eq(
  $$ select codigo from public.rol $$,
  array['GUEST','COLPORTOR','COORDINADOR','ADMIN','ASISTENTE_FIN','ACOMPANANTE'],
  'los seis roles de negocio existen'
);

-- ---------------------------------------------------------------------------
-- 8. Realtime solo en catálogo
-- ---------------------------------------------------------------------------
select bag_eq(
  $$ select tablename::text from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' $$,
  array['producto','coleccion','producto_coleccion','precio_por_zona'],
  'supabase_realtime publica solo el catálogo'
);

select * from finish();
rollback;
