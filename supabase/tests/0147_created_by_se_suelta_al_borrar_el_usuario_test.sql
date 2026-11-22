-- pgTAP · migración 0147 (backend-supabase#62): tg_auditoria_update ya no deshace el ON DELETE SET NULL de
-- created_by.
--   · borrar al usuario que creó filas deja created_by en null en todas las tablas (país, ciudad, campaña,
--     zona, ciudad de la campaña), sin 23503, sin dejar un uuid colgado, y la fila sube sync_version;
--   · created_by sigue inmutable para cualquier UPDATE de primer nivel (del servidor, del ADMIN con JWT): ni a null,
--     ni a otro usuario;
--   · el cambio a null solo pasa en un UPDATE anidado (la acción de la FK) y con el usuario inexistente: anidado
--     con el usuario vivo no cambia, y de primer nivel con el usuario inexistente tampoco;
--   · el trigger propio del historial de zonas (0022) ya no existe y el historial sigue soltando a quien se borra
--     (también el caso de dos FK en la misma fila, que cubre 0027 §10).
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

-- El created_by de una fila de país, como texto (null se ve como «-»).
create or replace function pg_temp.dueno_pais(p_id text) returns text language sql as $$
  select coalesce(right(created_by::text, 2), '-') from public.pais
   where id = ('01920000-0000-7000-8000-0000000147' || p_id)::uuid;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- u1 (a1) crea todo; u2 (a2) coordina la campaña; ad es ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000147' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cb-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000147' || x.s)::uuid, r.id
  from (values ('a2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code, created_by) values
  ('01920000-0000-7000-8000-0000000147c0', 'Pais cb', 'ZC', '01920000-0000-7000-8000-0000000147a1'),
  ('01920000-0000-7000-8000-0000000147c2', 'Pais cb propio de a2', 'ZD', '01920000-0000-7000-8000-0000000147a2');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, created_by) values
  ('01920000-0000-7000-8000-0000000147c1', 'Ciudad cb', 'Departamento de prueba', '01920000-0000-7000-8000-0000000147c0',
   -34.90, -56.16, '01920000-0000-7000-8000-0000000147a1');
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, created_by) values
  ('01920000-0000-7000-8000-0000000147e1', 'Campania cb', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000147a2', '01920000-0000-7000-8000-0000000147a1');
insert into public.campania_ciudad (id, campania_id, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000147f1', '01920000-0000-7000-8000-0000000147e1',
   '01920000-0000-7000-8000-0000000147c1', '01920000-0000-7000-8000-0000000147a1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, created_by) values
  ('01920000-0000-7000-8000-0000000147d1', 'Zona cb', '01920000-0000-7000-8000-0000000147f1', 'RADIAL',
   -34.88, -56.16, 300, '01920000-0000-7000-8000-0000000147a1');

select is(pg_temp.dueno_pais('c0'), 'a1', 'el país nace con created_by = a1');

-- ---------------------------------------------------------------------------
-- 1. created_by sigue inmutable en un UPDATE de primer nivel
-- ---------------------------------------------------------------------------
select lives_ok($$ update public.pais set created_by = null where id = '01920000-0000-7000-8000-0000000147c0' $$,
                'el servidor intenta poner created_by en null con un UPDATE directo');
select is(pg_temp.dueno_pais('c0'), 'a1', 'y created_by queda como estaba: no se suelta a mano');
select lives_ok($$ update public.pais set created_by = '01920000-0000-7000-8000-0000000147a2'
                    where id = '01920000-0000-7000-8000-0000000147c0' $$,
                'el servidor intenta reasignarlo a otro usuario');
select is(pg_temp.dueno_pais('c0'), 'a1', 'y tampoco se reasigna');

-- Cuántas filas tocó el UPDATE del ADMIN con JWT (la RLS podría dejarlo en 0 y el test no probaría nada).
create or replace function pg_temp.admin_edita_pais() returns integer language plpgsql as $$
declare n integer;
begin
  update public.pais set nombre = 'Pais cb editado', created_by = null
   where id = '01920000-0000-7000-8000-0000000147c0';
  get diagnostics n = row_count;
  return n;
end $$;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000147ad');
select is(pg_temp.admin_edita_pais(), 1, 'el ADMIN, con JWT, edita el país e intenta poner created_by en null');
select pg_temp.actuar_como_servidor();
select is(pg_temp.dueno_pais('c0'), 'a1', 'el nombre cambió y created_by no');
select is((select nombre from public.pais where id = '01920000-0000-7000-8000-0000000147c0'),
          'Pais cb editado', 'el resto del UPDATE sí valió');

-- ---------------------------------------------------------------------------
-- 2. El cambio a null solo pasa anidado y con el usuario inexistente
-- ---------------------------------------------------------------------------
-- Para probarlo sin borrar usuarios hace falta una fila con created_by colgado (como las que dejaba el bug
-- anterior): se suelta la FK de país adentro de esta transacción.
alter table public.pais drop constraint pais_created_by_fk;
insert into public.pais (id, nombre, iso_code, created_by) values
  ('01920000-0000-7000-8000-0000000147c3', 'Pais colgado', 'ZE', '01920000-0000-7000-8000-0147deadbeef'),
  ('01920000-0000-7000-8000-0000000147c4', 'Pais colgado 2', 'ZF', '01920000-0000-7000-8000-0147deadbee0');
select is(pg_temp.dueno_pais('c3'), 'ef', 'el país c3 nace con un created_by que no existe');

select lives_ok($$ update public.pais set created_by = null where id = '01920000-0000-7000-8000-0000000147c3' $$,
                'un UPDATE de primer nivel sobre la fila colgada');
select is(pg_temp.dueno_pais('c3'), 'ef', 'no la suelta: de primer nivel created_by no cambia, ni con el usuario inexistente');

-- Un UPDATE anidado (adentro de un trigger) sobre la fila colgada y sobre una con el usuario vivo.
create or replace function pg_temp.tg_anidado() returns trigger language plpgsql as $$
begin
  update public.pais set created_by = null
   where id in ('01920000-0000-7000-8000-0000000147c3', '01920000-0000-7000-8000-0000000147c2');
  -- Anidado y con el usuario inexistente, pero hacia OTRO usuario (no a null): tampoco se reasigna.
  update public.pais set created_by = '01920000-0000-7000-8000-0000000147a2'
   where id = '01920000-0000-7000-8000-0000000147c4';
  return null;
end $$;
create trigger zz_anidado after update of nombre on public.zona
  for each row execute function pg_temp.tg_anidado();
update public.zona set nombre = 'Zona cb editada' where id = '01920000-0000-7000-8000-0000000147d1';
drop trigger zz_anidado on public.zona;

select is(pg_temp.dueno_pais('c3'), '-', 'anidado y con el usuario inexistente: created_by pasa a null');
select is(pg_temp.dueno_pais('c2'), 'a2', 'anidado pero con el usuario vivo: created_by no cambia');
select is(pg_temp.dueno_pais('c4'), 'e0', 'anidado, con el usuario inexistente y hacia otro usuario: no se reasigna');

-- Se deshace lo armado a mano: fuera la fila colgada y de vuelta la FK, para probar el borrado real también en país.
delete from public.pais where id in ('01920000-0000-7000-8000-0000000147c3', '01920000-0000-7000-8000-0000000147c4');
alter table public.pais
  add constraint pais_created_by_fk foreign key (created_by) references public.usuario(id) on delete set null;

-- ---------------------------------------------------------------------------
-- 3. Borrar al usuario que creó filas deja su created_by en null, en todas las tablas
-- ---------------------------------------------------------------------------
create or replace function pg_temp.versiones() returns text language sql as $$
  select (select sync_version from public.ciudad where id = '01920000-0000-7000-8000-0000000147c1')::text || '/'
      || (select sync_version from public.campania where id = '01920000-0000-7000-8000-0000000147e1')::text || '/'
      || (select sync_version from public.zona where id = '01920000-0000-7000-8000-0000000147d1')::text;
$$;
select is(pg_temp.versiones(), '0/0/1', 'antes de borrar: ciudad y campaña en 0, la zona editada en 1');

select lives_ok($$ delete from auth.users where id = '01920000-0000-7000-8000-0000000147a1' $$,
                'se puede borrar al usuario que creó país, ciudad, campaña, ciudad de campaña y zona');
select is(pg_temp.dueno_pais('c0'), '-', 'el país quedó con created_by en null');
select is((select created_by from public.ciudad where id = '01920000-0000-7000-8000-0000000147c1'),
          null, 'la ciudad también');
select is((select created_by from public.campania where id = '01920000-0000-7000-8000-0000000147e1'),
          null, 'la campaña también');
select is((select created_by from public.campania_ciudad where id = '01920000-0000-7000-8000-0000000147f1'),
          null, 'la ciudad de la campaña también');
select is((select created_by from public.zona where id = '01920000-0000-7000-8000-0000000147d1'),
          null, 'y la zona');
select is(pg_temp.dueno_pais('c2'), 'a2', 'lo que creó otro usuario no se toca');
select is((select count(*)::integer from public.campania where id = '01920000-0000-7000-8000-0000000147e1'),
          1, 'y la campaña sigue viva: solo se soltó quién la creó');
select is(pg_temp.versiones(), '1/1/2',
          'cada fila soltada sube sync_version en uno: el delta la baja con created_by limpio');

-- Ninguna fila apunta a un usuario que ya no existe.
select is((select count(*)::integer
             from (select created_by from public.pais union all select created_by from public.ciudad
                   union all select created_by from public.campania
                   union all select created_by from public.campania_ciudad union all select created_by from public.zona) t
            where t.created_by is not null
              and not exists (select 1 from public.usuario u where u.id = t.created_by)),
          0, 'ningún uuid colgado en país, ciudad, campaña, ciudad de campaña ni zona');

-- ---------------------------------------------------------------------------
-- 4. Lo de 0022 sigue valiendo sin su trigger propio
-- ---------------------------------------------------------------------------
select hasnt_function('public', 'tg_campania_colportor_zona_historial_sin_usuario',
                      'la función propia del historial de zonas se fue con 0147');
select ok(exists (select 1 from pg_trigger t where t.tgrelid = 'public.campania_colportor_zona_historial'::regclass
                    and t.tgname = 'campania_colportor_zona_historial_auditoria_update'),
          'el historial sigue con el trigger de auditoría de todas las tablas');
select ok(obj_description('public.tg_auditoria_update()'::regprocedure, 'pg_proc') ilike '%0147%',
          'el comment on de tg_auditoria_update cuenta la excepción');

select * from finish();
rollback;
