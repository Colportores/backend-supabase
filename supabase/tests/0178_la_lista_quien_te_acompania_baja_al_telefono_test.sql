-- pgTAP · migración 0178 (backend-supabase#254, casilla «Lista acomp.»): la lista «¿Quién te acompaña?» baja al teléfono por el sync.
--   · el registro: `campania_coordinador` es entidad de solo bajada que sigue las campañas del mapa; la tabla no tiene correo ni
--     teléfono; nadie borra y el teléfono no sube esta entidad;
--   · quién ve a quién: la colportora inscripta ve a los coordinadores de SU campaña (con nombre y apellido), solo a quienes tienen
--     hoy el rol COORDINADOR (nunca a un administrador), no ve los de otra campaña, ni los de una campaña de la que se dio de
--     baja; si el coordinador pierde el rol deja de verse; el coordinador ve a sus colegas y el ADMIN ve todo;
--   · el pull: la colportora baja esas filas (sin la maquinaria del delta) y el teléfono no puede escribirlas;
--   · `puedo_ver_al_coordinador` con un uuid cualquiera da false: no sirve para averiguar roles.
--
-- Como 0145, NO va en una transacción: el delta solo sirve lo commiteado. Limpia al empezar y al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

-- Ids con el prefijo 178: usuarios 178b1.., campañas 178e1 y 178e2.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000178' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.usuario_rol
   where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('c3'), pg_temp.u('ad'));
  delete from auth.users
   where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('c3'), pg_temp.u('ad'));
end $$;

-- Los sufijos de los usuarios de las filas de `campania_coordinador` que ve la sesión (o bajó el pull), ordenados.
create or replace function pg_temp.veo() returns text[] language sql as $$
  select coalesce(array_agg(right(usuario_id::text, 2) order by usuario_id), array[]::text[])
    from public.campania_coordinador where deleted_at is null;
$$;
create or replace function pg_temp.bajaron(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'usuario_id', 2) order by e ->> 'usuario_id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'campania_coordinador', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- 1. El registro
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where nombre = 'campania_coordinador' $$,
  $$ values ('campania_coordinador'::text, 'campania_coordinador'::text, 'id'::text, false, true, null::text, null::text) $$,
  'la entidad de sync: campania_coordinador, de solo bajada, que sigue las campañas del mapa');
select is((select count(*)::int from information_schema.columns
            where table_schema = 'public' and table_name = 'campania_coordinador'
              and column_name in ('email', 'correo', 'telefono', 'celular', 'password')),
          0, 'la tabla no tiene correo ni teléfono: nada del perfil que no sea nombre y apellido');
select is((select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants
            where table_schema = 'public' and table_name = 'campania_coordinador' and grantee = 'authenticated'),
          'INSERT,SELECT,UPDATE', 'y no tiene DELETE (escribir es del ADMIN por RLS, 0174; el teléfono no sube esta entidad)');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'campania_coordinador'),
          0, 'no va a Realtime (ADR-012)');

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). e1: coordinan c1 y c2 (y el ADMIN ad, que no coordina por rol); e2: coordina c3.
-- b1 y b3 se inscriben en e1 (b3 se da de baja); b2 solo en e2.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'acomp178-' || s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', 'Nom' || s, 'apellido', 'Ape' || s)
  from unnest(array['b1','b2','b3','c1','c2','c3','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'),
               ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('c3','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 acomp178', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 acomp178', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c3'));
insert into public.campania_coordinador (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('e1'), pg_temp.u('ad'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')),
  (pg_temp.u('e1'), pg_temp.u('b3')),
  (pg_temp.u('e2'), pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 2. Quién ve a quién
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
select is(pg_temp.veo(), array['ad','c1','c2','c3'], 'el servidor ve las cuatro filas (e1: c1, c2 y ad; e2: c3)');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), array['c1','c2'], 'Ana (b1, inscripta en e1) ve a los coordinadores de e1: c1 y c2');
select is((select string_agg(nombre || ' ' || apellido, ',' order by usuario_id) from public.campania_coordinador
            where deleted_at is null),
          'Nomc1 Apec1,Nomc2 Apec2', 'con nombre y apellido');
select is((select count(*)::int from public.campania_coordinador where usuario_id = pg_temp.u('ad')), 0,
          'no ve al administrador, aunque figure en la campaña');
select is((select count(*)::int from public.campania_coordinador where campania_id = pg_temp.u('e2')), 0,
          'ni a los coordinadores de una campaña en la que no está');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c1')), true, 'puedo_ver_al_coordinador: el coordinador de su campaña');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('ad')), false, 'el administrador, no');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('b2')), false, 'otra colportora, no: no sirve para averiguar roles');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e2'), pg_temp.u('c3')), false, 'ni el coordinador de una campaña en la que no está');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), '01920000-0000-7000-8000-000000178fff'), false, 'ni un uuid cualquiera');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.veo(), array['c3'], 'b2 (inscripta solo en e2) ve a c3 y a nadie de e1');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.veo(), array['ad','c1','c2'], 'el coordinador de e1 ve a sus colegas (y al administrador del equipo) y nada de e2');

select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.veo(), array['ad','c1','c2','c3'], 'el ADMIN ve todo, como antes');

-- ---------------------------------------------------------------------------
-- 3. El pull
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['campania_coordinador'], '{}'::jsonb, 1000) as d;
select is(pg_temp.bajaron(d), array['c1','c2'], 'Ana baja a c1 y c2 de e1') from p1;
select ok((select bool_and((e ->> 'campania_id') = pg_temp.u('e1')::text and e ? 'nombre' and e ? 'apellido'
                           and not (e ? 'email') and not (e ? 'telefono') and not (e ? 'xmin_w'))
             from p1, jsonb_array_elements(d -> 'rows' -> 'campania_coordinador') e),
          'cada fila trae la campaña, el nombre y el apellido; ni correo ni teléfono ni la maquinaria del delta') from p1;

-- c2 pierde el rol de coordinador: Ana deja de verlo.
select pg_temp.como_servidor();
delete from public.usuario_rol
 where usuario_id = pg_temp.u('c2') and rol_id = (select id from public.rol where codigo = 'COORDINADOR');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), array['c1'], 'si c2 deja de tener el rol COORDINADOR, Ana ya no lo ve');

-- Un coordinador nuevo en e1 baja por el delta.
select pg_temp.como_servidor();
insert into public.campania_coordinador (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('c3'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.bajaron(sync.pull(array['campania_coordinador'], (select d -> 'watermark' from p1), 1000)), array['c3'],
          'un coordinador nuevo en la campaña de Ana baja por el delta');

-- Ana se da de baja de e1: ya no ve a ninguno.
select pg_temp.como_servidor();
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), array[]::text[], 'dada de baja de la campaña, Ana no ve a ningún coordinador');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.veo(), array['c1','c3'], 'b3, que sigue inscripta en e1, ve a los coordinadores vigentes: c1 y c3 (c2 ya no es coordinador)');

-- ---------------------------------------------------------------------------
-- 4. Solo bajada: el teléfono no escribe la lista
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000178b01', 'entity', 'campania_coordinador', 'op', 'insert',
    'payload', jsonb_build_object('id', pg_temp.u('f1'), 'campania_id', pg_temp.u('e1'), 'usuario_id', pg_temp.u('b3'),
                                  'nombre', 'X', 'apellido', 'Y'))))
    #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA', 'subir un coordinador inventado se rechaza (la réplica es de solo lectura)');
select pg_temp.como_servidor();
select is((select count(*)::int from public.campania_coordinador where id = pg_temp.u('f1')), 0, 'y no quedó escrito');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table p1;
select pg_temp.limpiar();
select is((select count(*)::int from public.campania_coordinador
            where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'))), 0, 'limpieza: no queda nada de la prueba');

select * from finish();
