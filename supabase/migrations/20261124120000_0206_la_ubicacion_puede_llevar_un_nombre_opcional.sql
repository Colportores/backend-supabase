-- ============================================================================
-- 0206 · La ubicación puede llevar un nombre opcional
--        (backend-supabase#313, casilla «Nombre ubic.»; decisión de Cristian del 24/11, no era la opción recomendada:
--        https://github.com/Colportores/front-colportores-mobile/issues/145#issuecomment-7086045758)
--
-- ## El caso
--
-- Lucía abre la ficha de María y marca que le cobra en la farmacia. El diseño muestra la ubicación alternativa como
-- «Farmacia Italia», pero la ubicación del modelo solo tenía dirección y tipo: la tarjeta decía «Av. Italia 3456 · Negocio».
-- Cristian decidió sumar un nombre.
--
-- ## Qué hace
--
-- Una columna nueva y opcional, `ubicacion.nombre`: texto libre de hasta 80 caracteres («Farmacia Italia», «Almacén de
-- Doña Rosa»). Sube y baja con la sincronización como cualquier otra columna de la ubicación (el push y el pull trabajan
-- con las columnas de la tabla: no hay nada que registrar).
--
--   · Forma: null, o de 1 a 80 caracteres. Un trigger BEFORE INSERT/UPDATE recorta los espacios de los extremos y guarda
--     null si queda vacío (la app puede mandar «» o « » al borrar el nombre: es lo mismo que no tener nombre). Más de 80
--     caracteres es 23514, y el push lo devuelve `invalid` (clase 23) sin tumbar el lote.
--   · Quién lo escribe: quien ya puede escribir la ubicación (la política de escritura de 0021 no cambia) y, como el resto de
--     la fila, lo que una persona cambia de una casa ajena lo controla `tg_control_de_correccion` (CG001 en la gracia).
--   · Quién lo lee: quien ya lee la ubicación (la RLS no cambia).
--
-- ## Lo que NO hace
--
--   · No va a las lecturas del panel (`casas_de_zona`, `casas_de_la_ciudad`, los reportes): todas enumeran sus columnas y no
--     cambian. Es texto libre que sale del teléfono: nombra un lugar, no a una persona.
--   · No se sigue en la unión de duplicados (`marcar_como_duplicado`): la conservada queda con el nombre que tenía.
--   · No hay filas que tocar: las ubicaciones que existen quedan sin nombre.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: la ficha muestra el nombre como título de la ubicación alternativa y lo manda en el alta.
--   · docs-organizacion: el contrato del sync (§2, `ubicacion`) y `esquema-datos.md` suman la columna. El issue de docs va en el
--     cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada. Lo prueba supabase/tests/0206_… .
-- ============================================================================

alter table public.ubicacion add column nombre text;

alter table public.ubicacion
  add constraint ubicacion_nombre_forma
    check (nombre is null or char_length(nombre) between 1 and 80);

comment on column public.ubicacion.nombre is
  'Nombre opcional del lugar (0206, backend-supabase#313): texto libre de hasta 80 caracteres, por ejemplo «Farmacia Italia». '
  'Nombra un lugar, no a una persona: no es para datos personales. Se recorta y queda null si queda vacío. Sube y baja con '
  'el sync como el resto de la fila.';

create function public.tg_ubicacion_nombre_normalizado()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.nombre := nullif(btrim(new.nombre), '');
  return new;
end;
$$;

comment on function public.tg_ubicacion_nombre_normalizado() is
  'BEFORE INSERT/UPDATE OF nombre de ubicacion: recorta los espacios de los extremos y guarda null si queda vacío (0206).';

revoke all on function public.tg_ubicacion_nombre_normalizado() from public, anon, authenticated, service_role;

create trigger ubicacion_nombre_normalizado
  before insert or update of nombre on public.ubicacion
  for each row execute function public.tg_ubicacion_nombre_normalizado();
