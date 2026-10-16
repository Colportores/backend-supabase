-- ============================================================================
-- 0026 · «Marcar como duplicado»: todo lo de B pasa a A y B se da de baja, en una sola
--        transacción y de forma idempotente (backend-supabase#56; HU-UBI-006, vista 10)
--
-- Decisión de Cristian del 02/10 (backend-supabase#56):
--   «Marcar como duplicado y conservar A» pasa todo lo que cuelga de B a A y después da de baja
--   B. Lo hace el servidor, en una sola RPC atómica (todo o nada): a A pasan los espacios de B,
--   sus visitas, ventas y cobranzas, también las de otros colportores. Después B queda de baja,
--   sin el bloqueo de la baja común (UB001/UB002 de 0018): ya no cuelga nada de B. Nunca se borra
--   una venta ni una persona.
--
-- Decisión del orquestador del 02/10, por el mapa de decisiones
-- (docs-organizacion#31, comentario 5958646392):
--   · El estado de A (`house_status`) lo recalcula la app (ADR-003); acá no se elige ni «pasa».
--     La fila de `house_status` de B queda dada de baja con B.
--   · Espacio único: si A y B son casa o negocio (HU-UBI-007), lo que colgaba del espacio único de
--     B pasa al espacio único de A y el de B queda dado de baja (soft delete). A sigue con uno
--     solo; no se borra ninguna venta, visita ni persona.
--   · Una sola transacción, así que si falla no queda nada a medias; y **idempotente**: si B ya se
--     había unido a A, devuelve éxito y no hace nada de más (para que «Probá de nuevo» no mienta).
--
-- ## La función
--
--   select public.marcar_como_duplicado(p_duplicada_id := B, p_conservada_id := A) -> jsonb
--
--   {"duplicada_id", "conservada_id", "ya_unida", "espacios_pasados", "espacios_unidos",
--    "personas", "visitas", "ventas", "cobranzas"}
--
--   · `ya_unida = true`: B ya estaba de baja y no quedaba nada colgado de ella. No se hizo nada.
--   · `espacios_pasados`: espacios de B que ahora son de A tal cual (`espacio.ubicacion_id`: con
--     ellos viajan sus vínculos con personas, visitas, agendas, ventas y, por la venta, sus
--     cobranzas, entregas e ítems; los ids no cambian, así que lo que un teléfono ya subió sigue
--     apuntando a lo mismo).
--   · `espacios_unidos`: espacios únicos de B que se fundieron en el único de A.
--   · `personas`, `visitas`, `ventas`, `cobranzas`: lo que colgaba de B y ahora cuelga de A.
--
-- ## Qué hace, en este orden
--
--   1. Quién: un usuario autenticado que escribe en las dos casas (`puedo_escribir_en_ubicacion()`,
--      0021): el par sale de la vista 10, que compara las ubicaciones propias y las que llegan por
--      el sync de su ciudad. Si no, `42501` (también si alguna no existe: no se revela). Sin
--      usuario autenticado (`service_role`, mantenimiento) no se exige, como en 0018.
--   2. Bloquea las dos ubicaciones (`FOR UPDATE`, por id): dos llamadas sobre el mismo par se
--      hacen cola, y la segunda ve el resultado de la primera.
--   3. `UB004` si A y B son la misma. `UB003` si A está dada de baja («La ubicación que ibas a
--      conservar ya está dada de baja. Revisá el par de nuevo.»). Con B de baja y nada colgado,
--      responde `ya_unida` sin tocar nada.
--   4. Espacios de B que importan: los vivos, y los dados de baja que todavía tengan un vínculo
--      con una persona vivo o alguna visita, agenda o venta. Los demás (dados de baja y vacíos)
--      se quedan en B: no hay nada que mover.
--   5. Espacio único («único» = `numero_depto` nulo o en blanco, ADR-001 y esquema-datos.md; solo
--      si A y B son CASA o NEGOCIO): lo de B se funde en el único vivo más viejo de A.
--        · persona que está en los dos: la visita, agenda y venta del vínculo de B pasan al de A;
--          el de B se da de baja. Si el de A estaba de baja y el de B vivo, se reactiva el de A.
--          Si A no tenía `ubicacion_cobranza_alt_id` y B sí, A lo hereda (no se pierde).
--        · persona solo en B: su vínculo se muda al único de A (el id no cambia).
--        · el espacio único de B queda dado de baja (soft delete).
--      Si A no tiene un único vivo, el de B pasa a ser el de A. Los demás espacios (deptos de un
--      edificio, o cualquiera si no son los dos CASA/NEGOCIO) pasan a A sin mezclarse con los que
--      A ya tenía.
--   6. La fila de `house_status` de B se da de baja. La de A no se toca: la recalcula la app.
--   7. B se da de baja. Como ya no cuelga nada de ella, UB001 y UB002 (0018) no se disparan.
--
-- ## Lo que sube tarde
--
-- Un teléfono que todavía no sincronizó puede subir después una venta, visita o vínculo que apunta
-- al vínculo o espacio único de B ya fundido (dados de baja). No se pierde: queda colgando de B.
-- Volver a llamar a la función con el mismo par lo detecta (hay algo vivo o con eventos en un
-- espacio de B) y lo pasa a A; por eso «Reintentar» también sirve para barrerlo.
--
-- ## Las reglas de corrección de 0021 siguen valiendo (la función no las salta)
--
-- Mover un espacio, darlo de baja y dar de baja una casa pasan por los triggers de 0021. Con la
-- campaña terminada hace 15 días o menos y ninguna en curso que cubra la ciudad (la gracia de
-- 0020), lo que cargó otro no se corrige: la función termina con `CG001` y no queda nada a medias.
-- Sin ninguna campaña en la que escribir: `42501`.
--
-- ## No implementado (pendiente de decisión de Cristian; ver el archivo de pendientes del PR)
--
--   · Qué ve en su teléfono el otro colportor que tenía una venta en B (venta, visita y cobranza
--     solo suben y no bajan) y cómo quedan las referencias que apuntan a B:
--     `espacio_persona.ubicacion_cobranza_alt_id`, `agenda.ubicacion_alt_id` y, en el teléfono,
--     `ubicacion_par_decidido`. Esas referencias no se reapuntan: siguen en B (dada de baja).
--   · Dejar registrado que B se unió a A (no hay columna `duplicada_de`): la idempotencia se
--     decide por el estado, no por un registro.
--   · «Marcar como duplicado» sin conexión (por el motor de sync o por una llamada directa): esta
--     función es solo la llamada directa; `sync.push` no la conoce.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (vista 10): llamar a `marcar_como_duplicado(B, A)` con el cliente
--     de Supabase; con la respuesta, recalcular el `house_status` de A y registrar `duplicado_de_A`
--     en la auditoría local. Errores: `42501` (no escribe en alguna), `UB003` (A ya está dada de
--     baja: «La ubicación que ibas a conservar ya está dada de baja. Revisá el par de nuevo.»),
--     `UB004` (A y B son la misma), `CG001` (campaña terminada, lo ajeno no se corrige), `P0002`
--     (alguna no existe, solo sin usuario) y cualquier otro: «No se puede marcar como duplicado.
--     Probá de nuevo.» con «Reintentar».
--   · docs-organizacion: contrato (`contrato-sync-engine.md` / llamadas directas) y la vista 10
--     de HU-UBI-006.
--
-- Datos: ninguno cambia; se suma una función. Forward-only: no se edita una vez aplicada.
-- ============================================================================

create function public.marcar_como_duplicado(p_duplicada_id uuid, p_conservada_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid              uuid := auth.uid();
  v_a                public.ubicacion%rowtype;  -- la que se conserva
  v_b                public.ubicacion%rowtype;  -- la duplicada
  v_une_unicos       boolean;
  v_espacios         uuid[];
  v_unico_a          uuid;
  v_id               uuid;
  v_e                public.espacio%rowtype;
  v_ep               public.espacio_persona%rowtype;
  v_ep_a             public.espacio_persona%rowtype;
  v_espacios_pasados integer := 0;
  v_espacios_unidos  integer := 0;
  v_personas         integer;
  v_visitas          integer;
  v_ventas           integer;
  v_cobranzas        integer;
begin
  if p_duplicada_id is null or p_conservada_id is null then
    raise exception using
      errcode = '22023',
      message = 'Faltan las dos ubicaciones del par.';
  end if;

  if p_duplicada_id = p_conservada_id then
    raise exception using
      errcode = 'UB004',
      message = 'Una ubicación no puede ser el duplicado de sí misma.',
      hint    = 'Revisá el par de nuevo.';
  end if;

  -- 1. Quién: escribe en las dos. Sin usuario autenticado (service_role) no se exige.
  if v_uid is not null
     and not (public.puedo_escribir_en_ubicacion(p_conservada_id)
              and public.puedo_escribir_en_ubicacion(p_duplicada_id)) then
    raise exception using
      errcode = '42501',
      message = 'No podés marcar como duplicado este par: no escribís en alguna de las dos ubicaciones. '
                'Todo queda como estaba.',
      hint    = 'Revisá el par de nuevo.';
  end if;

  -- 2. Las dos filas bloqueadas, siempre por id: dos llamadas sobre el mismo par (o cruzadas) se
  --    hacen cola sin interbloquearse, y la segunda ve lo que dejó la primera.
  perform u.id
     from public.ubicacion u
    where u.id in (p_duplicada_id, p_conservada_id)
    order by u.id
      for update;

  select * into v_a from public.ubicacion where id = p_conservada_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'La ubicación que ibas a conservar no existe.';
  end if;
  select * into v_b from public.ubicacion where id = p_duplicada_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'La ubicación duplicada no existe.';
  end if;

  -- 3. A tiene que estar viva.
  if v_a.deleted_at is not null then
    raise exception using
      errcode = 'UB003',
      message = 'La ubicación que ibas a conservar ya está dada de baja. Revisá el par de nuevo.',
      hint    = 'No se aplicó nada.';
  end if;

  -- 4. Los espacios de B que importan: los vivos, y los dados de baja que todavía tienen un
  --    vínculo con una persona vivo o eventos colgando.
  select coalesce(array_agg(e.id order by e.created_at, e.id), '{}')
    into v_espacios
    from public.espacio e
   where e.ubicacion_id = p_duplicada_id
     and (e.deleted_at is null
          or exists (select 1
                       from public.espacio_persona ep
                      where ep.espacio_id = e.id
                        and (ep.deleted_at is null
                             or exists (select 1 from public.visita vi where vi.espacio_persona_id = ep.id)
                             or exists (select 1 from public.agenda ag where ag.espacio_persona_id = ep.id)
                             or exists (select 1 from public.venta v where v.espacio_persona_id = ep.id))));

  -- Idempotencia: B ya estaba de baja y no queda nada colgado de ella.
  if v_b.deleted_at is not null and cardinality(v_espacios) = 0 then
    return jsonb_build_object(
      'duplicada_id', p_duplicada_id, 'conservada_id', p_conservada_id, 'ya_unida', true,
      'espacios_pasados', 0, 'espacios_unidos', 0,
      'personas', 0, 'visitas', 0, 'ventas', 0, 'cobranzas', 0);
  end if;

  -- Lo que pasa a A (para la respuesta), contado antes de moverlo.
  select count(*) filter (where ep.deleted_at is null)
    into v_personas
    from public.espacio_persona ep
   where ep.espacio_id = any (v_espacios);
  select count(*)
    into v_visitas
    from public.visita vi
    join public.espacio_persona ep on ep.id = vi.espacio_persona_id
   where ep.espacio_id = any (v_espacios);
  select count(*)
    into v_ventas
    from public.venta v
    join public.espacio_persona ep on ep.id = v.espacio_persona_id
   where ep.espacio_id = any (v_espacios);
  select count(*)
    into v_cobranzas
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
    join public.espacio_persona ep on ep.id = v.espacio_persona_id
   where ep.espacio_id = any (v_espacios);

  -- 5. Pasar los espacios; los únicos se funden en el único de A.
  v_une_unicos := v_a.tipo in ('CASA', 'NEGOCIO') and v_b.tipo in ('CASA', 'NEGOCIO');
  if v_une_unicos then
    select e.id
      into v_unico_a
      from public.espacio e
     where e.ubicacion_id = p_conservada_id
       and e.deleted_at is null
       and nullif(btrim(e.numero_depto), '') is null
     order by e.created_at, e.id
     limit 1;
  end if;

  foreach v_id in array v_espacios loop
    select * into v_e from public.espacio e where e.id = v_id;

    if v_une_unicos and nullif(btrim(v_e.numero_depto), '') is null and v_unico_a is not null then
      -- El único de B se funde en el de A: persona por persona.
      for v_ep in
        select * from public.espacio_persona ep where ep.espacio_id = v_e.id order by ep.created_at, ep.id
      loop
        select * into v_ep_a
          from public.espacio_persona ep
         where ep.espacio_id = v_unico_a and ep.persona_id = v_ep.persona_id;

        if not found then
          -- Solo en B: su vínculo se muda al único de A, con el mismo id.
          update public.espacio_persona set espacio_id = v_unico_a where id = v_ep.id;
        else
          -- En las dos: lo de B cuelga ahora del vínculo de A (el unique espacio_id+persona_id
          -- no admite dos, vivos o dados de baja).
          update public.visita set espacio_persona_id = v_ep_a.id where espacio_persona_id = v_ep.id;
          update public.agenda set espacio_persona_id = v_ep_a.id where espacio_persona_id = v_ep.id;
          update public.venta  set espacio_persona_id = v_ep_a.id where espacio_persona_id = v_ep.id;

          if v_ep.deleted_at is null then
            if v_ep_a.deleted_at is not null
               or (v_ep_a.ubicacion_cobranza_alt_id is null and v_ep.ubicacion_cobranza_alt_id is not null) then
              update public.espacio_persona
                 set deleted_at = null,
                     ubicacion_cobranza_alt_id = coalesce(ubicacion_cobranza_alt_id, v_ep.ubicacion_cobranza_alt_id)
               where id = v_ep_a.id;
            end if;
            update public.espacio_persona set deleted_at = now() where id = v_ep.id;
          end if;
        end if;
      end loop;

      if v_e.deleted_at is null then
        update public.espacio set deleted_at = now() where id = v_e.id;
      end if;
      v_espacios_unidos := v_espacios_unidos + 1;
    else
      -- Pasa tal cual: con él viaja todo lo que cuelga de sus vínculos.
      update public.espacio set ubicacion_id = p_conservada_id where id = v_e.id;
      v_espacios_pasados := v_espacios_pasados + 1;
      -- A no tenía único vivo: el de B pasa a serlo (los demás únicos de B se funden en él).
      if v_une_unicos and v_unico_a is null and v_e.deleted_at is null
         and nullif(btrim(v_e.numero_depto), '') is null then
        v_unico_a := v_e.id;
      end if;
    end if;
  end loop;

  -- 6. El estado de B se da de baja con ella; el de A lo recalcula la app (ADR-003).
  update public.house_status set deleted_at = now()
   where ubicacion_id = p_duplicada_id and deleted_at is null;

  -- 7. B se da de baja. Ya no cuelga nada de ella: UB001 y UB002 no se disparan.
  if v_b.deleted_at is null then
    update public.ubicacion set deleted_at = now() where id = p_duplicada_id;
  end if;

  return jsonb_build_object(
    'duplicada_id', p_duplicada_id, 'conservada_id', p_conservada_id, 'ya_unida', false,
    'espacios_pasados', v_espacios_pasados, 'espacios_unidos', v_espacios_unidos,
    'personas', v_personas, 'visitas', v_visitas, 'ventas', v_ventas, 'cobranzas', v_cobranzas);
end;
$$;

comment on function public.marcar_como_duplicado(uuid, uuid) is
  'HU-UBI-006 (0026, decisión de Cristian del 02/10 en backend-supabase#56): pasa a A (p_conservada_id) '
  'los espacios de B (p_duplicada_id) con sus personas, visitas, agendas, ventas y cobranzas, también '
  'las de otros colportores; los espacios únicos (CASA/NEGOCIO) se funden en el de A; da de baja el '
  'estado de B y a B. Una sola transacción e idempotente (ya_unida). Escribe en las dos casas '
  '(puedo_escribir_en_ubicacion); los triggers de 0021 (42501, CG001) valen. Errores: UB003 (A de '
  'baja), UB004 (misma ubicación). No toca el house_status de A (lo recalcula la app).';

-- ----------------------------------------------------------------------------
-- Privilegios: la llama el colportor (RPC) y el servidor; nadie más.
-- ----------------------------------------------------------------------------

revoke all on function public.marcar_como_duplicado(uuid, uuid) from public, anon, authenticated;
grant execute on function public.marcar_como_duplicado(uuid, uuid) to authenticated, service_role;
