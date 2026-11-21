-- pgTAP · la cédula se guarda en 7 u 8 dígitos y el registro rechaza otra (migración 0190,
-- backend-supabase#266, P1: decisión del orquestador del 11/11, seguridad barata)
--   1. La forma: cedula_normalizada() (interna) y el CHECK de 7 u 8 dígitos.
--   2. El registro normaliza lo que la app deja pasar (puntos, guion, espacios) y guarda solo dígitos.
--   3. Lo que no queda en 7 u 8 dígitos frena el registro con CD005, sin perfil, cuenta ni ficha, y el
--      aviso no repite lo que llegó.
--   4. Sin la clave, null o en blanco: el registro sigue sin ficha, como en la 0188.
begin;
select * from no_plan();

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000190' || p_sufijo)::uuid
$$;

create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

create or replace function pg_temp.registrar(p_sufijo text, p_meta jsonb) returns text language plpgsql as $$
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_user_meta_data,
                          created_at, updated_at)
  values (pg_temp.u(p_sufijo), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'cedula189-' || p_sufijo || '@example.com', 'x', p_meta, now(), now());
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

create or replace function pg_temp.ficha(p_sufijo text) returns text language sql as $$
  select coalesce((select f.cedula from public.ficha_administrativa f where f.usuario_id = pg_temp.u(p_sufijo)),
                  '(sin ficha)')
$$;

-- El rechazo, con el aviso exacto.
create or replace function pg_temp.rechazo() returns text language sql immutable as $$
  select 'CD005|La cédula no es válida: tienen que ser 7 u 8 dígitos, con o sin puntos y guion. Revisala y volvé a registrarte.'
$$;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is(public.cedula_normalizada('4.567.890-1'), '45678901', 'saca puntos y guion');
select is(public.cedula_normalizada(' 4 567 890 1 '), '45678901', 'saca los espacios de cualquier lugar');
select is(public.cedula_normalizada(E'4567890\t1'), '45678901', 'y un tabulador');
select is(public.cedula_normalizada('ab12'), 'ab12', 'no valida: deja lo que no es puntuación');
select is(public.cedula_normalizada(null), null, 'null queda null');
select ok(not has_function_privilege('authenticated', 'public.cedula_normalizada(text)', 'execute')
          and not has_function_privilege('anon', 'public.cedula_normalizada(text)', 'execute')
          and not has_function_privilege('service_role', 'public.cedula_normalizada(text)', 'execute'),
          'la normalización es interna: nadie con JWT la llama');

select is(
  (select array_agg(c.conname::text order by c.conname)
     from pg_constraint c where c.conrelid = 'public.ficha_administrativa'::regclass and c.contype = 'c'),
  array['ficha_administrativa_cedula_7_u_8_digitos'],
  'un solo CHECK de la cédula: 7 u 8 dígitos (el de «no en blanco» se fue)'
);

-- El CHECK, como servidor sobre una cuenta sin ficha.
select is(pg_temp.registrar('c0', '{"nombre":"Sin","apellido":"Ficha"}'), 'ok', 'una cuenta sin ficha');
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('c0'), '4.567.890-1') $$), 5),
          '23514', 'el servidor tampoco guarda una cédula con puntos y guion');
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('c0'), '123456') $$), 5),
          '23514', 'ni una de 6 dígitos');
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('c0'), '123456789') $$), 5),
          '23514', 'ni una de 9');
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('c0'), E'1234567\n') $$), 5),
          '23514', 'ni una con un salto de línea al final');
select is(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                             values (pg_temp.u('c0'), '1234567') $$),
          'ok', 'sí una de 7 dígitos');

-- ---------------------------------------------------------------------------
-- 2. El registro normaliza
-- ---------------------------------------------------------------------------
select is(pg_temp.registrar('a1', '{"nombre":"Rocío","apellido":"Alfa","cedula":"4.567.890-1","terminos_version":"v1"}'),
          'ok', 'con puntos y guion (como la escribe la app) el registro se crea');
select is(pg_temp.ficha('a1'), '45678901', 'y la ficha queda en solo dígitos');
select is((select version from public.consentimiento_terminos where usuario_id = pg_temp.u('a1')), 'v1',
          'el consentimiento se guarda igual');
select is(pg_temp.registrar('a2', '{"cedula":"1.234.567"}'), 'ok', '7 dígitos con puntos');
select is(pg_temp.ficha('a2'), '1234567', 'quedan los 7');
select is(pg_temp.registrar('a3', '{"cedula":"  1234567-8  "}'), 'ok', 'con espacios en los extremos y guion');
select is(pg_temp.ficha('a3'), '12345678', 'quedan los 8');
select is(pg_temp.registrar('a4', '{"cedula":"4 567 890 1"}'), 'ok', 'con espacios en el medio');
select is(pg_temp.ficha('a4'), '45678901', 'quedan los 8');
select is(pg_temp.registrar('a5', '{"cedula":12345678}'), 'ok', 'un número JSON de 8 dígitos');
select is(pg_temp.ficha('a5'), '12345678', 'se guarda como texto');
select is(pg_temp.registrar('a6', '{"cedula":"01234567"}'), 'ok', 'con un cero adelante');
select is(pg_temp.ficha('a6'), '01234567', 'el cero se conserva');

-- ---------------------------------------------------------------------------
-- 3. Lo que no queda en 7 u 8 dígitos frena el registro
-- ---------------------------------------------------------------------------
select is(pg_temp.registrar('e1', '{"cedula":"123456"}'), pg_temp.rechazo(), '6 dígitos se rechaza');
select is(pg_temp.registrar('e2', '{"cedula":"123456789"}'), pg_temp.rechazo(), '9 dígitos se rechaza');
select is(pg_temp.registrar('e3', '{"cedula":"4.567.890-K"}'), pg_temp.rechazo(), 'una letra se rechaza');
select is(pg_temp.registrar('e4', '{"cedula":"..-"}'), pg_temp.rechazo(), 'solo puntuación se rechaza');
select is(pg_temp.registrar('e5', '{"cedula":"1234567/8"}'), pg_temp.rechazo(), 'otro separador se rechaza');
select is(pg_temp.registrar('e6', ('{"cedula":"' || repeat('9', 5000) || '"}')::jsonb), pg_temp.rechazo(),
          'una larguísima se rechaza');
select is(pg_temp.registrar('e7', '{"cedula":["45678901"]}'), pg_temp.rechazo(), 'una lista JSON se rechaza');
select is(pg_temp.registrar('e8', '{"cedula":true}'), pg_temp.rechazo(), 'un booleano JSON se rechaza');
select is(pg_temp.registrar('e9', '{"cedula":"１２３４５６７８"}'), pg_temp.rechazo(), 'dígitos de ancho completo se rechazan');
select is(pg_temp.registrar('ea', '{"cedula":"1234567; drop table usuario"}'), pg_temp.rechazo(), 'texto de más se rechaza');
select ok(position('drop' in pg_temp.registrar('eb', '{"cedula":"drop1234"}')) = 0,
          'el aviso no repite lo que llegó (dato personal)');
select is(
  (select count(*) from public.usuario where id in
     (select pg_temp.u(s) from unnest(array['e1','e2','e3','e4','e5','e6','e7','e8','e9','ea','eb']) s)),
  0::bigint, 'ningún registro rechazado dejó el perfil');
select is(
  (select count(*) from auth.users where id in
     (select pg_temp.u(s) from unnest(array['e1','e2','e3','e4','e5','e6','e7','e8','e9','ea','eb']) s)),
  0::bigint, 'ni la cuenta');
select is(
  (select count(*) from public.ficha_administrativa where usuario_id in
     (select pg_temp.u(s) from unnest(array['e1','e2','e3','e4','e5','e6','e7','e8','e9','ea','eb']) s)),
  0::bigint, 'ni la ficha');

-- La versión de los Términos se mira primero: con las dos mal, TC001.
select is(left(pg_temp.registrar('ec', '{"cedula":"123","terminos_version":"v9"}'), 5), 'TC001',
          'con la versión y la cédula mal, manda la versión (TC001)');

-- ---------------------------------------------------------------------------
-- 4. Sin cédula, como en la 0188
-- ---------------------------------------------------------------------------
select is(pg_temp.registrar('b1', '{"nombre":"Beto","apellido":"Bravo"}'), 'ok', 'sin la clave el registro se crea');
select is(pg_temp.ficha('b1'), '(sin ficha)', 'sin ficha');
select is(pg_temp.registrar('b2', '{"cedula":null}'), 'ok', 'con null el registro se crea');
select is(pg_temp.ficha('b2'), '(sin ficha)', 'sin ficha');
select is(pg_temp.registrar('b3', '{"cedula":"   "}'), 'ok', 'en blanco el registro se crea');
select is(pg_temp.ficha('b3'), '(sin ficha)', 'sin ficha');
select is(pg_temp.registrar('b4', '{"cedula":""}'), 'ok', 'vacía el registro se crea');
select is(pg_temp.ficha('b4'), '(sin ficha)', 'sin ficha');
select is(pg_temp.registrar('b5', null), 'ok', 'sin metadatos el registro se crea');
select is(pg_temp.ficha('b5'), '(sin ficha)', 'sin ficha');

select * from finish();
rollback;
