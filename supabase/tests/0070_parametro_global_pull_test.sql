-- pgTAP · migración 0070 (backend-supabase#137): lo que baja por el pull. El código del editor viaja con el
-- producto y el parámetro de los días de antigüedad de los precios baja a todo colportor, solo como
-- réplica de lectura; un cambio del servidor llega en el pull siguiente.
--
-- Como 0017, NO va en una transacción: el delta solo sirve filas commiteadas. Limpia al final.

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

-- Los códigos del editor de los productos de la prueba que trae un pull, ordenados por nombre.
create or replace function pg_temp.codigos(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> 'codigo_editor', '-') order by e ->> 'nombre'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'producto', '[]'::jsonb)) e
   where e ->> 'nombre' like 'Prueba pull 70%';
$$;

-- El valor de los días de antigüedad en un pull, o '-' si no vino.
create or replace function pg_temp.dias(p_delta jsonb) returns text language sql as $$
  select coalesce(
    (select e ->> 'valor'
       from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'parametro_global', '[]'::jsonb)) e
      where e ->> 'clave' = 'dias_antiguedad_precios'),
    '-');
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: un colportor sin ninguna campaña y tres productos, dos con código.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000070b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'pull70-b1@example.com', 'x', now(), now(), now());
insert into public.producto (id, nombre, tipo, codigo_editor) values
  ('01920000-0000-7000-8000-0000000070d1', 'Prueba pull 70 A', 'LIBRO', 'EDI-001'),
  ('01920000-0000-7000-8000-0000000070d2', 'Prueba pull 70 B', 'LIBRO', null),
  ('01920000-0000-7000-8000-0000000070d3', 'Prueba pull 70 C', 'REVISTA', '00042');

-- ---------------------------------------------------------------------------
-- 1. El primer pull trae el código y el parámetro
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000070b1');
create temp table pull_b1 as
select sync.pull(array['producto', 'parametro_global'], '{}'::jsonb, 1000) as d;

select is(pg_temp.codigos(d), array['EDI-001', '-', '00042'],
          'el producto baja con su código (texto, ceros a la izquierda) y el que no tiene baja sin él') from pull_b1;
select ok((select exists (select 1 from jsonb_array_elements(d -> 'rows' -> 'producto') e
                           where e ->> 'nombre' = 'Prueba pull 70 B' and e ? 'codigo_editor'
                             and jsonb_typeof(e -> 'codigo_editor') = 'null') from pull_b1),
          'sin código la clave viaja en null: el teléfono lo distingue de «campo que no conoce»');
select is(pg_temp.dias(d), '15', 'los días de antigüedad bajan con su valor por defecto: 15') from pull_b1;
select ok((select not jsonb_path_exists(d, '$.rows.parametro_global[*].xmin_w') from pull_b1), 'xmin_w no viaja');
select is((select jsonb_array_length(d -> 'rows' -> 'parametro_global') from pull_b1), 1,
          'una sola fila de parámetros, aunque el colportor no tenga campaña ni zona');

-- ---------------------------------------------------------------------------
-- 2. Sin cambios no baja nada; un cambio del servidor llega en el pull siguiente
-- ---------------------------------------------------------------------------
select is((select sync.pull(array['producto', 'parametro_global'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

select pg_temp.como_servidor();
-- Esta prueba no corre en una transacción y audit_log solo se agrega (0073): sus cambios de 15 a 20 y de vuelta
-- dejarían registros para siempre y romperían los conteos de los tests siguientes (0073, 0110). El registro de
-- los cambios lo prueba 0110; acá se apaga el trigger mientras dura y se enciende en la limpieza.
alter table public.parametro_global disable trigger parametro_global_auditar_cambio;
update public.parametro_global set valor = 20 where clave = 'dias_antiguedad_precios';
update public.producto set codigo_editor = 'EDI-002' where id = '01920000-0000-7000-8000-0000000070d2';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000070b1');
create temp table pull_b1_cambios as
select sync.pull(array['producto', 'parametro_global'], (select d -> 'watermark' from pull_b1), 1000) as d;
select is(pg_temp.dias(d), '20', 'los 20 días nuevos llegan en el pull siguiente') from pull_b1_cambios;
select is(pg_temp.codigos(d), array['EDI-002'], 'y el código cargado después, solo el de ese producto') from pull_b1_cambios;

-- ---------------------------------------------------------------------------
-- 3. La app no lo escribe: réplica de solo lectura
-- ---------------------------------------------------------------------------
create temp table push_b1 as
select sync.push(jsonb_build_array(jsonb_build_object(
  'client_op_id', gen_random_uuid(), 'entity', 'parametro_global', 'op', 'update', 'sync_version', 0,
  'payload', jsonb_build_object('id', (select id from public.parametro_global where clave = 'dias_antiguedad_precios'),
                                'valor', 1)))) as r;
select is((select r #>> '{results,0,outcome}' from push_b1), 'invalid', 'el push de los días se rechaza');
select ok((select (r #>> '{results,0}') like '%ENTIDAD_DE_SOLO_LECTURA%' from push_b1), 'como réplica de solo lectura');
select pg_temp.como_servidor();
select is((select valor from public.parametro_global where clave = 'dias_antiguedad_precios'), 20, 'y el valor no cambia');

-- ---------------------------------------------------------------------------
-- Limpieza: el parámetro vuelve a su valor de referencia
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table pull_b1, pull_b1_cambios, push_b1;
update public.parametro_global set valor = 15 where clave = 'dias_antiguedad_precios';
alter table public.parametro_global enable trigger parametro_global_auditar_cambio;
delete from public.producto where id in ('01920000-0000-7000-8000-0000000070d1', '01920000-0000-7000-8000-0000000070d2',
                                         '01920000-0000-7000-8000-0000000070d3');
delete from auth.users where id = '01920000-0000-7000-8000-0000000070b1';

select * from finish();
