-- ============================================================================
-- 0104 · Ningún texto libre de un depto sube al servidor: se saca espacio.descripcion
--      (backend-supabase#79, BACK-HU-UBI-007)
--
-- Decisión de Cristian del 06/10, «Notas depto» («Nota por depto en el teléfono»): la nota de un
-- depto queda solo en el teléfono, como las notas del cliente, y la `descripcion` del espacio, que
-- sube, se saca igual. Agustín puede anotar «timbre roto, tocar fuerte» o «la señora Pérez,
-- jubilada»: ese texto puede nombrar a una persona y no puede llegar al servidor, donde lo bajan
-- los demás colportores de la ciudad. Hoy `espacio.descripcion` (0001) es un texto libre que sube y
-- que ninguna pantalla llena.
--
-- ## Qué hace
--
--   · Antes de cambiar nada revisa TODAS las filas de espacio (también las dadas de baja): si
--     alguna tiene texto en `descripcion`, la migración se ABORTA, no cambia nada y lista cada caso
--     (espacio, ubicación y ciudad), como 0017 y 0027. No se borra un texto que alguien cargó. El
--     texto mismo no sale en el mensaje (puede nombrar a una persona y el error termina en los
--     logs): se lee del espacio por su id. Un valor en blanco (solo espacios) no es un texto: no
--     frena la migración.
--   · Si está vacía en todas, saca la columna. `espacio` queda con `id`, `ubicacion_id`,
--     `numero_depto`, `piso` y las columnas de auditoría y de sync de siempre. Ninguna fila cambia:
--     ni `sync_version` ni `xmin_w` (no es un UPDATE), así que ningún teléfono baja nada de nuevo.
--
-- ## Lo que no cambia
--
--   · Nada del servidor lee la columna: ninguna política, función, trigger ni índice la nombra
--     (la lee solo el aviso de 0017, que ya corrió). El pull baja las columnas de la tabla
--     (`sync.expresion_json`): `espacio` baja sin `descripcion` sin tocar el motor. Un push viejo
--     del teléfono que mande `descripcion` falla con el error de una columna que no existe.
--
-- ## Para otros repos
--
--   · docs-organizacion: el contrato de sync (§2, fila de `espacio`) y esquema-datos.md sacan la
--     columna, en un PR de docs aparte desde `main` que revisa @BrunoFCapri. Esta migración se
--     mergea DESPUÉS de ese OK, para que el motor del teléfono no mande una columna que ya no
--     existe.
--   · front-colportores-mobile: la nota del depto es local y no toca el servidor; el motor deja de
--     mandar `descripcion` en el push de `espacio` y de leerla en el pull.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

do $$
declare
  v_casos text;
  v_n     bigint;
begin
  select count(*),
         string_agg(
           format('  · espacio %s en %s %s (ubicación %s, %s)%s: tiene un texto en la descripción.',
                  e.id, coalesce(u.calle, 'sin calle'), coalesce(u.numero, 's/n'), u.id, c.nombre,
                  case when e.deleted_at is not null then ' (dado de baja)' else '' end),
           E'\n' order by c.nombre, u.id, e.id)
    into v_n, v_casos
    from public.espacio e
    join public.ubicacion u on u.id = e.ubicacion_id
    join public.ciudad c on c.id = u.ciudad_id
   where nullif(btrim(e.descripcion), '') is not null;

  if v_n > 0 then
    raise exception using
      message = format('La migración 0104 (sacar espacio.descripcion) no se aplicó: hay %s espacio(s) '
                       'con un texto en la descripción. No se cambió nada.', v_n),
      detail  = v_casos,
      hint    = 'La descripción de un depto no sube al servidor y la migración no borra un texto que '
                'alguien cargó. Leé el texto de cada espacio por su id, resolvé qué se hace con él '
                '(la nota de un depto vive en el teléfono), vaciá la columna de esos espacios y '
                'volvé a aplicar la migración.';
  end if;
end
$$;

alter table public.espacio drop column descripcion;
