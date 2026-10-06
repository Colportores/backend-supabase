-- Datos con el esquema de 0029 (la tabla se llama precio_por_zona y ya cuelga de la campania_ciudad),
-- para probar que 0030 la renombra a precio_por_ciudad sin recrearla ni tocar una fila: mismas filas,
-- mismos valores (incluidos sync_version, xmin_w, created_at y updated_at), mismas definiciones de
-- restricciones, índices, triggers y políticas, mismos privilegios y misma pertenencia a la publicación
-- de realtime; solo cambian los nombres. Ver scripts/db-test-migracion.sh.
--
-- Dos campania_ciudad (Verano en Montevideo y en Salto) y siete precios:
--   a1 p1 en Montevideo, 250,00, desde 01/01, sin fin                    → vigente
--   a2 p1 en Salto, 260,00, desde 01/01, sin fin                         → vigente en otra ciudad
--   a3 p2 en Montevideo [01/01–31/03], 300,00                            → con fin
--   a4 p2 en Montevideo, 320,00, desde 01/04, sin fin                    → contiguo al anterior
--   a5 p3 en Montevideo, 90,00, dado de baja (deleted_at)                → de baja: se conserva
--   a6 k1 (colección) en Montevideo, 450,00, sin fin                     → precio de colección
--   a7 p1 en Montevideo [01/01–31/12 del año anterior], 200,00 (histórico)
-- La foto de antes queda en prueba_0030_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000030c0', 'Pais migración 30', 'ZY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000030c1', 'Montevideo', '01920000-0000-7000-8000-0000000030c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-0000000030c2', 'Salto',      '01920000-0000-7000-8000-0000000030c0', -31.38, -57.96);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000030e1', 'Verano', 'VERANO', '2026-01-05', '2026-12-20');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000030f1', '01920000-0000-7000-8000-0000000030e1', '01920000-0000-7000-8000-0000000030c1'),
  ('01920000-0000-7000-8000-0000000030f2', '01920000-0000-7000-8000-0000000030e1', '01920000-0000-7000-8000-0000000030c2');

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-0000000030a1', 'Libro p1', 'LIBRO'),
  ('01920000-0000-7000-8000-0000000030a2', 'Libro p2', 'LIBRO'),
  ('01920000-0000-7000-8000-0000000030a3', 'Libro p3', 'LIBRO');
insert into public.coleccion (id, nombre) values ('01920000-0000-7000-8000-0000000030b1', 'Colección k1');

insert into public.precio_por_zona
  (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  ('01920000-0000-7000-8000-000000003001', '01920000-0000-7000-8000-0000000030a1', null, '01920000-0000-7000-8000-0000000030f1', 25000, '2026-01-01', null,         null),
  ('01920000-0000-7000-8000-000000003002', '01920000-0000-7000-8000-0000000030a1', null, '01920000-0000-7000-8000-0000000030f2', 26000, '2026-01-01', null,         null),
  ('01920000-0000-7000-8000-000000003003', '01920000-0000-7000-8000-0000000030a2', null, '01920000-0000-7000-8000-0000000030f1', 30000, '2026-01-01', '2026-03-31', null),
  ('01920000-0000-7000-8000-000000003004', '01920000-0000-7000-8000-0000000030a2', null, '01920000-0000-7000-8000-0000000030f1', 32000, '2026-04-01', null,         null),
  ('01920000-0000-7000-8000-000000003005', '01920000-0000-7000-8000-0000000030a3', null, '01920000-0000-7000-8000-0000000030f1', 9000,  '2026-01-01', null,         '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-000000003006', null, '01920000-0000-7000-8000-0000000030b1', '01920000-0000-7000-8000-0000000030f1', 45000, '2026-01-01', null,         null),
  ('01920000-0000-7000-8000-000000003007', '01920000-0000-7000-8000-0000000030a1', null, '01920000-0000-7000-8000-0000000030f1', 20000, '2025-01-01', '2025-12-31', null);

-- La foto de antes: las filas enteras, y cómo está definido cada objeto de la tabla, con el nombre
-- viejo (la prueba lo compara con el nuevo, cambiando solo el prefijo).
create table public.prueba_0030_precio as
select * from public.precio_por_zona;

create table public.prueba_0030_objeto as
  select 'restriccion' as clase, c.conname::text as nombre, pg_get_constraintdef(c.oid) as def
    from pg_constraint c where c.conrelid = 'public.precio_por_zona'::regclass
  union all
  select 'indice', i.indexname::text, i.indexdef
    from pg_indexes i where i.schemaname = 'public' and i.tablename = 'precio_por_zona'
  union all
  select 'trigger', t.tgname::text, pg_get_triggerdef(t.oid)
    from pg_trigger t where t.tgrelid = 'public.precio_por_zona'::regclass and not t.tgisinternal
  union all
  select 'politica', p.policyname::text,
         concat_ws(' | ', p.cmd, p.roles::text, p.permissive, p.qual, p.with_check)
    from pg_policies p where p.schemaname = 'public' and p.tablename = 'precio_por_zona'
  union all
  select 'columna', a.attname::text,
         concat_ws(' | ', format_type(a.atttypid, a.atttypmod), a.attnotnull::text, pg_get_expr(d.adbin, d.adrelid))
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.precio_por_zona'::regclass and a.attnum > 0 and not a.attisdropped
  union all
  select 'privilegios', 'tabla', c.relacl::text || ' | rls=' || c.relrowsecurity || ' | force=' || c.relforcerowsecurity
    from pg_class c where c.oid = 'public.precio_por_zona'::regclass
  union all
  select 'sync', e.nombre::text,
         concat_ws(' | ', e.tabla::oid::text, e.columna_pk, e.permite_push::text, e.sigue_campanias::text,
                   coalesce(e.columna_duenio, '-'), coalesce(e.columna_ubicacion, '-'))
    from sync.entidad e where e.tabla = 'public.precio_por_zona'::regclass
  union all
  select 'realtime', pt.pubname::text, pt.schemaname || '.' || pt.tablename
    from pg_publication_tables pt where pt.tablename = 'precio_por_zona';

-- El OID de la tabla: un rename lo conserva; recrearla lo cambia.
create table public.prueba_0030_oid as
select 'public.precio_por_zona'::regclass::oid as oid_antes;
