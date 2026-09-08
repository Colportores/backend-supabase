-- Carga sintética para medir el delta. Ver supabase/bench/README.md.
--
-- Dimensionado según RP-01: 150 colportores, una temporada de campaña.
-- Se ajusta con -v colportores=N al invocar psql.
--
-- Corre como postgres (sin RLS): es el harness, no el camino de la app.

\set ON_ERROR_STOP on
\if :{?colportores} \else \set colportores 150 \endif

\echo '-- limpiando corrida anterior'
delete from public.venta          where numero_talonario like 'BENCH-%';
delete from public.visita         where id in (select id from public.visita where created_by in (select id from public.usuario where email like 'bench-%@bench.local'));
delete from public.espacio_persona where created_by in (select id from public.usuario where email like 'bench-%@bench.local');
delete from public.espacio        where created_by in (select id from public.usuario where email like 'bench-%@bench.local');
delete from public.ubicacion      where created_by in (select id from public.usuario where email like 'bench-%@bench.local');
delete from public.jornada        where colportor_id in (select id from public.usuario where email like 'bench-%@bench.local');
delete from public.zona           where nombre like 'BENCH zona %';
delete from public.ciudad         where nombre = 'BENCH ciudad';
delete from public.pais           where iso_code = 'ZZ';
delete from auth.users            where email like 'bench-%@bench.local';

\echo '-- geografía'
insert into public.pais (id, nombre, iso_code)
values ('01920000-0000-7000-8000-0000000be000', 'BENCH', 'ZZ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values ('01920000-0000-7000-8000-0000000be001', 'BENCH ciudad',
        '01920000-0000-7000-8000-0000000be000', -34.9, -56.16);

\echo '-- colportores y zonas'
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
select public.uuid_generate_v7(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'bench-' || n || '@bench.local', 'x', now(), now()
from generate_series(1, :colportores) n;

insert into public.zona (id, nombre, ciudad_id)
select public.uuid_generate_v7(), 'BENCH zona ' || n, '01920000-0000-7000-8000-0000000be001'
from generate_series(1, :colportores) n;

-- Un colportor por zona: es el reparto que hace que la RLS por zona tenga algo
-- que filtrar. Sin esto todos verían todo y la medición no diría nada.
with c as (select id, row_number() over (order by email) rn from public.usuario where email like 'bench-%@bench.local'),
     z as (select id, row_number() over (order by nombre) rn from public.zona where nombre like 'BENCH zona %')
update public.usuario u set zona_id = z.id from c join z using (rn) where u.id = c.id;

\echo '-- jornadas (200 por colportor)'
insert into public.jornada (id, colportor_id, inicio, fin, created_by)
select public.uuid_generate_v7(), u.id, now() - (n || ' days')::interval,
       now() - (n || ' days')::interval + interval '8 hours', u.id
from public.usuario u, generate_series(1, 200) n
where u.email like 'bench-%@bench.local';

\echo '-- ubicaciones (400 por colportor)'
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id, created_by)
select public.uuid_generate_v7(), 'CASA', 'Calle ' || (n % 80), n::text,
       -34.9 + (n % 100) * 0.0001, -56.16 + (n % 100) * 0.0001,
       '01920000-0000-7000-8000-0000000be001', u.zona_id, u.id
from public.usuario u, generate_series(1, 400) n
where u.email like 'bench-%@bench.local';

\echo '-- espacios y vínculos'
insert into public.espacio (id, ubicacion_id, created_by)
select public.uuid_generate_v7(), ub.id, ub.created_by
from public.ubicacion ub
where ub.created_by in (select id from public.usuario where email like 'bench-%@bench.local');

insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
select public.uuid_generate_v7(), e.id, public.uuid_generate_v7(), e.created_by
from public.espacio e
where e.created_by in (select id from public.usuario where email like 'bench-%@bench.local');

\echo '-- visitas (1000 por colportor)'
insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by)
select public.uuid_generate_v7(), ep.id, now() - (ep.rn || ' hours')::interval,
       (array['VENTA','NO_CONTESTO','RECHAZO','ENTREVISTA'])[1 + ep.rn % 4],
       ep.created_by, ep.created_by
from (
  select id, created_by, row_number() over (partition by created_by order by id) rn
  from public.espacio_persona
  where created_by in (select id from public.usuario where email like 'bench-%@bench.local')
) ep
where ep.rn <= 1000;

\echo '-- ventas (400 por colportor) con su detalle'
insert into public.producto (id, nombre, tipo)
select '01920000-0000-7000-8000-0000000be0e1', 'BENCH libro', 'LIBRO'
where not exists (select 1 from public.producto where id = '01920000-0000-7000-8000-0000000be0e1');

insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select public.uuid_generate_v7(), ep.id, 'BENCH-' || ep.created_by || '-' || ep.rn,
       50000 + ep.rn, now() - (ep.rn || ' hours')::interval, ep.created_by, ep.created_by
from (
  select id, created_by, row_number() over (partition by created_by order by id) rn
  from public.espacio_persona
  where created_by in (select id from public.usuario where email like 'bench-%@bench.local')
) ep
where ep.rn <= 400;

insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, created_by)
select public.uuid_generate_v7(), v.id, '01920000-0000-7000-8000-0000000be0e1', 2, 25000, 50000, v.created_by
from public.venta v where v.numero_talonario like 'BENCH-%';

-- ---------------------------------------------------------------------------
-- El cursor, repartido
-- ---------------------------------------------------------------------------

-- Toda la carga entró en pocas transacciones, así que casi todas las filas
-- comparten `xmin_w` y la paginación del delta degeneraría a ordenar por `id`.
-- Acá se reparte el cursor a mano para que la medición se parezca a una base
-- que se llenó a lo largo de una temporada.
--
-- Los valores tienen que quedar POR DEBAJO del xid actual, o el corte por
-- horizonte de `sync.pull` los deja afuera y el delta mide sobre cero filas.
\echo '-- repartiendo xmin_w bajo el horizonte'
do $$
declare
  t      text;
  v_base bigint := pg_current_xact_id()::text::bigint;
begin
  foreach t in array array['jornada','ubicacion','espacio','espacio_persona','visita','venta','venta_item'] loop
    execute format('alter table public.%I disable trigger %I', t, t || '_auditoria_update');
    execute format($q$
      update public.%I x set xmin_w = (greatest(1, $1 - s.rn))::text::xid8
        from (select id, row_number() over (order by id) rn from public.%I) s
       where s.id = x.id
    $q$, t, t) using v_base;
    execute format('alter table public.%I enable trigger %I', t, t || '_auditoria_update');
  end loop;
end
$$;

analyze;

\echo ''
\echo '-- filas cargadas'
select 'jornada' t, count(*) from public.jornada where colportor_id in (select id from public.usuario where email like 'bench-%@bench.local')
union all select 'ubicacion', count(*) from public.ubicacion where created_by in (select id from public.usuario where email like 'bench-%@bench.local')
union all select 'espacio', count(*) from public.espacio where created_by in (select id from public.usuario where email like 'bench-%@bench.local')
union all select 'espacio_persona', count(*) from public.espacio_persona where created_by in (select id from public.usuario where email like 'bench-%@bench.local')
union all select 'visita', count(*) from public.visita where colportor_id in (select id from public.usuario where email like 'bench-%@bench.local')
union all select 'venta', count(*) from public.venta where numero_talonario like 'BENCH-%'
union all select 'venta_item', count(*) from public.venta_item where venta_id in (select id from public.venta where numero_talonario like 'BENCH-%')
order by 1;
