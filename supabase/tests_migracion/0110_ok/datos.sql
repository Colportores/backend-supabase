-- Datos con el esquema de 0070 (parametro_global ya existe, sin trigger de auditoría) para probar que 0110 solo
-- suma el trigger: no toca la fila de parametro_global ni inventa registros hacia atrás. Ver
-- scripts/db-test-migracion.sh.
--
-- Administración ya había pasado los días de 15 a 20 ANTES de que existiera el registro: ese cambio no tiene
-- evento y no se inventa. La foto de antes queda en prueba_0110_parametro_global de public: db-reset.sh la
-- borra con el resto.

update public.parametro_global set valor = 20 where clave = 'dias_antiguedad_precios' and deleted_at is null;

create table public.prueba_0110_parametro_global as
select * from public.parametro_global;
