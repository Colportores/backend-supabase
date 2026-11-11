-- 0186 · El catálogo de carreras con sus metas, para la pestaña «Becas» del panel (vista 33, HU-BEC-001,
--        HU-BEC-006; front-coordinadores-web#181)
--
-- ## Por qué
--
-- La pestaña «Becas» de Equipo necesita la lista de carreras para «Elegir carrera» y la meta de cada una (media
-- beca y beca completa, en libros y en monto) para mostrar a qué apunta el colportor. `carrera` y `meta_beca`
-- (0117) solo se leían por SELECT de tabla, y los clientes no leen tablas directo (ADR-013: van por RPC). Sin
-- esta lectura la pestaña quedaba oculta en el panel.
--
-- ## Qué hace
--
--   `carreras_de_beca(p_campania_id)` — las carreras vivas, con la meta de `meta_beca` del TIPO de esa campaña
--   (VERANO / INVIERNO). Una carrera sin meta cargada para ese tipo sale igual, con los cuatro campos de la meta
--   en null: la vista avisa «Falta configurar la meta de esta carrera» (HU-BEC-006). En una campaña PERMANENTE
--   (sin becas, 0132) todas salen sin meta, porque `meta_beca` no tiene ese tipo. Orden: por nombre sin
--   mayúsculas y, a igual nombre, por id (estable entre llamadas).
--
-- ## Quién
--
--   El mismo permiso que `becas_de_campania()` y las otras RPC de becas (`exigir_coordinador_de_campania_para_beca`,
--   0117): el coordinador de la campaña o un ADMIN. 42501 sin sesión o sin ese permiso; CZ001 campaña inexistente;
--   BC001 campaña terminada. SECURITY DEFINER con `search_path` vacío; EXECUTE solo para `authenticated`.
--
-- ## Qué no hace
--
--   · No cambia ninguna tabla ni ningún dato (aditiva: una función nueva).
--   · No escribe el catálogo: carreras y metas las sigue cargando el servidor (0117).

create function public.carreras_de_beca(p_campania_id uuid)
returns table (carrera_id uuid, nombre text,
               meta_media integer, meta_media_monto bigint,
               meta_completa integer, meta_completa_monto bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tipo_campania text;
begin
  perform public.exigir_coordinador_de_campania_para_beca(p_campania_id);

  select c.tipo into v_tipo_campania from public.campania c where c.id = p_campania_id;

  return query
    select ca.id, ca.nombre,
           mb.meta_media, mb.meta_media_monto,
           mb.meta_completa, mb.meta_completa_monto
      from public.carrera ca
      left join public.meta_beca mb
             on mb.carrera_id = ca.id and mb.tipo_campania = v_tipo_campania and mb.deleted_at is null
     where ca.deleted_at is null
     order by lower(ca.nombre), ca.id;
end;
$$;

comment on function public.carreras_de_beca(uuid) is
  'Vista 33, HU-BEC-001/006 (0186, front-coordinadores-web#181): el catálogo de carreras vivas para «Elegir '
  'carrera», cada una con la meta de meta_beca del tipo de p_campania_id: meta_media y meta_completa (libros) y '
  'meta_media_monto y meta_completa_monto (compra a la casa editora, en centavos). Sin meta cargada para ese tipo '
  '(o en una campaña PERMANENTE) los cuatro van en null. Orden: lower(nombre), id. Errores: 42501 sin permiso '
  '(coordinador de la campaña o ADMIN); CZ001 inexistente; BC001 terminada.';

revoke all on function public.carreras_de_beca(uuid) from public, anon, authenticated, service_role;
grant execute on function public.carreras_de_beca(uuid) to authenticated;
