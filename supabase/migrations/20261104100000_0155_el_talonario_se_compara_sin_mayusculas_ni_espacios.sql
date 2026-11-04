-- ============================================================================
-- 0155 · El talonario se compara sin distinguir mayúsculas ni espacios en los extremos
--        (backend-supabase#234, casilla «Talonario =»; decisión de Cristian del 03/11 en
--        front-colportores-mobile#531: «combinación número y letra, sin chequeo de mayúsculas»)
--
-- El número del talonario es una combinación de letras y números («T-100»). «t-100», «T-100 » y «T-100» son el
-- mismo talonario; «0100» y «100» siguen siendo distintos. El teléfono ya lo compara así (front#608). El único
-- lugar donde el servidor compara talonarios es el índice único por colportor y año (0071): comparaba el texto tal
-- cual. Ahora compara `lower(btrim(numero_talonario))`.
--
-- El tope de largo (1 a 30 caracteres, 0150) mide el texto tal cual y ya prohíbe los espacios en los extremos; el
-- `btrim` del índice cubre además a las filas que quedaron fuera de ese CHECK (NOT VALID).
--
-- ## Los datos
--
--   Si dos ventas vivas de un mismo colportor y año ya difieren solo en mayúsculas o en los espacios de los
--   extremos, el índice nuevo no se puede crear sin tocar una de ellas: esas filas no se tocan (nunca se pierde una
--   venta). En ese caso la migración deja el índice viejo y avisa con un WARNING; rige la comparación literal de
--   siempre. Datos simulados hasta diciembre: no hay migración de limpieza.
--
-- ## Para otros repos
--   · front-colportores-mobile: nada que cambiar (compara igual). Un push con un talonario que choca por mayúsculas
--     responde `invalid` 23505, como con el texto idéntico.
--   · docs-organizacion: HU-VEN-001 y `esquema-datos.md` (venta.numero_talonario).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

do $mig$
begin
  if exists (select 1
               from public.venta v
              where v.deleted_at is null
              group by v.colportor_id, lower(btrim(v.numero_talonario)), public.anio_de_la_venta(v.fecha)
             having count(*) > 1) then
    raise warning '0155: hay ventas vivas de un mismo colportor y año cuyo talonario difiere solo en mayúsculas o espacios: el índice venta_talonario_por_colportor_y_anio_idx queda con la comparación literal para no tocar datos.';
  else
    drop index public.venta_talonario_por_colportor_y_anio_idx;
    create unique index venta_talonario_por_colportor_y_anio_idx
      on public.venta (colportor_id, (lower(btrim(numero_talonario))), (public.anio_de_la_venta(fecha)))
      where deleted_at is null;
  end if;
end
$mig$;

comment on column public.venta.numero_talonario is
  'Número del recibo físico (R-VE02, único por colportor y año sin distinguir mayúsculas ni espacios en los '
  'extremos: 0155, backend-supabase#234). Entre 1 y 30 caracteres visibles, sin espacios ni saltos de línea al '
  'principio ni al final (0150, backend-supabase#206).';
