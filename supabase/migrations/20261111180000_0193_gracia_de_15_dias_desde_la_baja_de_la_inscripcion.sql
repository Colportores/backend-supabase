-- ============================================================================
-- 0193 · Gracia de 15 días desde la baja de la inscripción para escribir (backend-supabase#280,
--        HU-CAM-005; seguimiento de #273)
--
-- Decisión de Cristian del 11/11, «Gracia baja» (backend-supabase#273, comentario 6806541969; respuesta
-- al P1 de `backend-supabase-273-impl-261111-1730.md`): «Ana carga sin señal el depto 2 de una casa ajena,
-- la persona y una venta, y antes de sincronizar Luis la quita de la campaña. La inscripción quitada tiene
-- 15 días desde la baja, los mismos de gracia de las ventas, para que suba lo que cargó en casas ajenas
-- (deptos, estado de la casa y correcciones). Así no se pierde la venta. Durante esos días también podría
-- cargar algo nuevo en la ciudad, como ya pasa 15 días después del fin de la campaña.»
--
-- ## La regla
--
-- mis_campanias_para_escribir() (0020, 0024) cuenta también la inscripción dada de baja
-- (campania_colportor.deleted_at) hace 15 días o menos. El plazo es la MISMA cuenta de 0020: la baja hace
-- de «fin» de la inscripción y escritura_dentro_de_plazo() decide con el día de Montevideo (con la baja el
-- día D, el D + 15 entra hasta las 23:59 de Montevideo y el D + 16 no). La inscripción termina en lo que
-- llegue antes, el fin de la campaña o el día de la baja: `least(fecha_fin, día de la baja)` (least ignora
-- el null de una campaña sin fin). Lo demás no cambia: usuario y campaña vivos y la campaña ya empezada.
--   · Una baja ANTERIOR al comienzo de la campaña no da gracia: esa inscripción nunca pudo escribir en la
--     campaña, así que no hay nada cargado antes de la baja que tenga que subir (ante la duda se bloquea).
--   · Vale para todo lo que pasa por mis_campanias_para_escribir(): las altas y las correcciones de
--     puedo_cargar_en_ubicacion() / puedo_escribir_en_ubicacion() (espacio, house_status, ubicación) por
--     mis_ciudades_de_campania() y tengo_campania_para_escribir() (0020, 0021), igual que tras el fin.
--   · «Igual que tras el fin» (#52, 0021): en la gracia no se corrige lo AJENO. mis_campanias_en_curso_
--     para_escribir() salía de mis_campanias_para_escribir(); ahora exige la inscripción viva, así que la
--     corrección de una fila que cargó otro, durante la gracia de la baja, vuelve CG001 como en la del fin
--     (con otra campaña viva y en curso en la ciudad, entra, como hoy).
--   · Solo para escribir: la lectura (mis_ciudades_de_trabajo(), mis_inscripciones_no_terminadas()), el
--     estado de la cuenta, la zona y la inscripción (mis_campanias_vigentes()) no cambian.
--
-- ## Para otros repos
--
--   · front-colportores-mobile y motor: durante los 15 días desde la baja el push acepta el depto, el
--     estado y la corrección de lo propio en casas ajenas de la ciudad; lo ajeno vuelve CG001 (como tras el
--     fin); el día 16, 42501 como hoy.
--   · docs-organizacion#188: HU-CAM-005 y el contrato (la gracia también vale desde la baja).
--
-- Datos: ninguno; solo funciones (misma firma, `create or replace`: conservan sus privilegios).
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- Misma firma que en 0024; suma la inscripción dada de baja hace 15 días o menos.
create or replace function public.mis_campanias_para_escribir()
returns table (campania_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and u.deleted_at is null
     and c.deleted_at is null
     and c.fecha_inicio <= public.hoy_montevideo()
     and (cc.deleted_at is null
          or public.hoy_montevideo(cc.deleted_at) >= c.fecha_inicio)
     and public.escritura_dentro_de_plazo(
           case when cc.deleted_at is null then c.fecha_fin
                else least(c.fecha_fin, public.hoy_montevideo(cc.deleted_at)) end);
$$;

comment on function public.mis_campanias_para_escribir() is
  'Campañas del usuario autenticado en las que puede escribir: ya empezadas, con la inscripción viva y la '
  'campaña sin terminar o terminada hace 15 días o menos (0020), o con la inscripción dada de baja (desde el '
  'comienzo) hace 15 días o menos, sin pasar los 15 días del fin (0193, decisión del 11/11 «Gracia baja»). '
  'Día de America/Montevideo. Interna.';

-- Misma firma que en 0021; ya no sale de mis_campanias_para_escribir(): sin la gracia del fin NI la de la
-- baja (0193), solo las inscripciones vivas en campañas ya empezadas y sin terminar.
create or replace function public.mis_campanias_en_curso_para_escribir()
returns table (campania_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and cc.deleted_at is null
     and u.deleted_at is null
     and c.deleted_at is null
     and c.fecha_inicio <= public.hoy_montevideo()
     and public.escritura_en_curso(c.fecha_fin);
$$;

comment on function public.mis_campanias_en_curso_para_escribir() is
  'Campañas del usuario autenticado en las que puede escribir sin ninguna gracia: inscripción viva, ya '
  'empezadas y sin terminar (0021; 0193: la gracia de la baja tampoco cuenta). Interna.';
