-- pgTAP · backend-supabase#249 («Lista acomp.»): lo que la lista «¿Quién te acompaña?» NO le muestra a la colportora.
-- La lista es la entidad de sync `campania_coordinador` (0174 y 0178; la RPC `acompaniantes_de_mi_campania` que pedía el issue
-- se reemplazó por el pull, decisión de Cristian del 05/11 y del 09/11: solo coordinadores). El test 0178 cubre el camino feliz,
-- el pull y el solo bajada; este cubre los bordes que pedía el issue:
--   · una colportora con la cuenta suspendida o dada de baja no recibe ningún coordinador;
--   · un coordinador con la cuenta suspendida, dada de baja, con el rol vencido o con la fila de la campaña dada de baja no sale;
--   · quien llama no se ve a sí misma como acompañante cuando además es coordinadora de otra campaña en la que está inscripta
--     (la fila de su propia coordinación existe, pero la lista del teléfono elige entre las de su campaña de inscripción);
--   · una persona sin sesión (anon) no lee nada;
--   · el nombre y el apellido que sale es el del perfil, y nunca aparece el correo.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

create or replace function pg_temp.como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000249' || p_sufijo)::uuid
$$;

-- Los sufijos de los usuarios de las filas de `campania_coordinador` que ve la sesión, ordenados.
create or replace function pg_temp.veo() returns text[] language sql as $$
  select coalesce(array_agg(right(usuario_id::text, 2) order by usuario_id), array[]::text[])
    from public.campania_coordinador
   where deleted_at is null and campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Cuentas:
--   b1 colportora (Ana Lopez)             b2 colportora suspendida          b3 colportora dada de baja
--   c1 coordinador de e1 (Luis Gomez)     c2 coordinador suspendido         c3 coordinador dado de baja
--   c4 coordinador con el rol vencido     c5 coordinador con la fila de e1 dada de baja
--   c6 coordinadora de e2 que además está inscripta como colportora en e1
-- Campañas: e1 (c1, c2, c3, c4, c5), e2 (c6).
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'lista249-' || x.s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', x.nombre, 'apellido', x.apellido)
  from (values ('b1','Ana','Lopez'), ('b2','Bea','Suspendida'), ('b3','Beto','Baja'),
               ('c1','Luis','Gomez'), ('c2','Cesar','Suspendido'), ('c3','Carlos','Baja'),
               ('c4','Cora','Vencida'), ('c5','Celia','Quitada'), ('c6','Clara','Doble')) x(s, nombre, apellido);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('c1','COORDINADOR'), ('c2','COORDINADOR'),
               ('c3','COORDINADOR'), ('c5','COORDINADOR'), ('c6','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
-- c4: el rol de coordinador venció ayer.
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('c4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 lista249', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 lista249', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c6'));
insert into public.campania_coordinador (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('e1'), pg_temp.u('c3')),
  (pg_temp.u('e1'), pg_temp.u('c4')),
  (pg_temp.u('e1'), pg_temp.u('c5'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')),
  (pg_temp.u('e1'), pg_temp.u('b2')),
  (pg_temp.u('e1'), pg_temp.u('b3')),
  (pg_temp.u('e1'), pg_temp.u('c6'));

-- Las bajas y suspensiones que no deben aparecer.
update public.usuario set suspendido_en = now() where id in (pg_temp.u('b2'), pg_temp.u('c2'));
update public.usuario set deleted_at = now() where id in (pg_temp.u('b3'), pg_temp.u('c3'));
update public.campania_coordinador set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('c5');

-- ---------------------------------------------------------------------------
-- 1. Ana (inscripta, cuenta activa): ve solo a los coordinadores vigentes de e1
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
select is(pg_temp.veo(), array['c1','c2','c3','c4','c6'],
          'el servidor ve todas las filas vivas de la tabla (c1 por el espejo; c2, c3 y c4 cargados; c6 de e2)');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), array['c1'],
          'Ana ve solo a c1: no salen el coordinador suspendido, el dado de baja, el de rol vencido, el que se quitó de la '
          'campaña ni los de otra campaña');
select is((select string_agg(nombre || ' ' || apellido, ',') from public.campania_coordinador
            where campania_id = pg_temp.u('e1') and deleted_at is null),
          'Luis Gomez', 'con nombre y apellido del perfil');
select is((select count(*)::int from public.campania_coordinador where campania_id = pg_temp.u('e2')), 0,
          'y ninguno de la campaña en la que no está');

-- ---------------------------------------------------------------------------
-- 2. La colportora suspendida o dada de baja no recibe nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.veo(), array[]::text[], 'una colportora con la cuenta suspendida no ve a ningún coordinador');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c1')), false,
          'y puedo_ver_al_coordinador le da false aunque c1 coordine su campaña');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.veo(), array[]::text[], 'una colportora con la cuenta dada de baja tampoco');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c1')), false, 'y le da false');

-- ---------------------------------------------------------------------------
-- 3. Cada coordinador que no cuenta da false, aunque tenga fila en la campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c1')), true, 'c1 (activo, con el rol): true');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c2')), false, 'c2 suspendido: false');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c3')), false, 'c3 dado de baja: false');
select is(public.puedo_ver_al_coordinador(pg_temp.u('e1'), pg_temp.u('c4')), false, 'c4 con el rol vencido: false');

-- ---------------------------------------------------------------------------
-- 4. Quien coordina otra campaña y está inscripta como colportora en e1
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c6'));
select is(pg_temp.veo(), array['c1','c6'],
          'c6 ve a c1 (está inscripta en e1) y su propia fila de e2; la lista del teléfono elige por campaña, así que no se ofrece a sí misma');
select is((select count(*)::int from public.campania_coordinador
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('c6')), 0,
          'en e1 no hay una fila de c6: no puede salir como acompañante de su propia jornada de e1');

-- ---------------------------------------------------------------------------
-- 5. Sin sesión no se lee nada, y el correo nunca aparece
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
select pg_temp.como_anon();
select throws_ok($$ select count(*) from public.campania_coordinador $$, '42501', null,
                 'anon no puede leer la lista de coordinadores');

select pg_temp.como_servidor();
select is((select count(*)::int from information_schema.columns
            where table_schema = 'public' and table_name = 'campania_coordinador'
              and column_name in ('email', 'correo', 'telefono', 'celular')), 0,
          'la tabla que baja al teléfono no tiene correo ni teléfono');

select * from finish();
rollback;
