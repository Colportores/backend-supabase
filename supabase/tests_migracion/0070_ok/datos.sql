-- Datos con el esquema de 0069 (producto sin codigo_editor; sin parametro_global) para probar que 0070 solo
-- suma la columna, en null, y la tabla con su única fila, sin tocar ningún producto ni su sincronización.
-- Ver scripts/db-test-migracion.sh.
--
-- Tres productos: uno vivo, uno bonificable y uno dado de baja. La foto de antes queda en
-- prueba_0070_producto de public: db-reset.sh la borra con el resto.

insert into public.producto (id, nombre, descripcion, tipo, es_bonificable, es_misionero, precio_base_compra,
                             casa_editora, imagen_url, deleted_at) values
  ('01920000-0000-7000-8000-0000000070d1', 'Libro 70 A', 'Un libro', 'LIBRO', false, false, 12000,
   'Editorial 70', null, null),
  ('01920000-0000-7000-8000-0000000070d2', 'Revista 70 B', null, 'REVISTA', true, false, null,
   null, 'https://example.com/b.png', null),
  ('01920000-0000-7000-8000-0000000070d3', 'Material 70 C', null, 'MATERIAL', false, false, 500,
   null, null, '2026-09-01 10:00:00+00');

-- La foto de antes: las filas enteras.
create table public.prueba_0070_producto as
select * from public.producto where id::text like '01920000-0000-7000-8000-0000000070%';
