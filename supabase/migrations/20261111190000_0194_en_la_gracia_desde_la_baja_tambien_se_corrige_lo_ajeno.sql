-- ============================================================================
-- 0194 · En la gracia desde la baja también entra la corrección de lo ajeno, aunque ya no se lea
--        (backend-supabase#280, HU-CAM-005; seguimiento de 0193)
--
-- Aclaración del 11/11 del agente de decisiones, aplicando la decisión de Cristian «Gracia baja» (#280,
-- comentario 6809838196; P1 de `backend-supabase-280-impl-261111-2015.md`): «en la gracia desde la baja
-- también entran las correcciones de lo ajeno, así que CG001 no aplica a ese caso y su texto queda como está.
-- […] `correccion_ajena_en_gracia()` y el trigger de 0021 devuelven CG001 solo cuando lo que habilita a
-- escribir es la gracia del fin de la campaña. Si lo habilita la gracia de la baja (inscripción quitada hace
-- 15 días o menos en una campaña en curso), la corrección entra, también por el push aunque la fila ajena ya
-- no se lea. […] El día 16, 42501. Sin código nuevo y sin cambios en el contrato.»
-- La regla de #52 (02/10: tras el FIN de la campaña no se corrige lo ajeno, CG001) no cambia.
--
-- 0193 (ya aplicada, forward-only) había hecho que mis_campanias_en_curso_para_escribir() exigiera la
-- inscripción viva, para devolver CG001 también en la gracia de la baja. Esta migración lo deshace y suma el
-- camino del push para lo que ya no se lee.
--
-- ## 1. Lo ajeno, sin CG001 en la gracia de la baja
--
-- mis_campanias_en_curso_para_escribir() vuelve al cuerpo de 0021: sale de mis_campanias_para_escribir()
-- (que desde 0193 cuenta la baja de 15 días o menos) y de escritura_en_curso(fecha_fin). Con la campaña en
-- curso, la inscripción quitada dentro de los 15 días cuenta como «en curso»: puedo_corregir_ajeno_en_ubicacion()
-- la habilita y ni correccion_ajena_en_gracia() ni tg_control_de_correccion() devuelven CG001. Si la campaña
-- ya terminó, manda la regla del fin: CG001.
--
-- ## 2. La corrección de lo que ya no lee, por el push
--
-- La lectura no tiene gracia: tras la baja la casa ajena ya no se ve, y el push volvía FILA_INEXISTENTE
-- (sync.aplicar_job_interno lee la fila con la RLS de lectura antes de comparar la versión). Ahora, si la fila
-- (ubicacion, espacio o house_status) no se lee:
--   · gracia_de_baja_en_ubicacion(ubicación): null si su ciudad no es de una campaña EN CURSO de la que
--     quitaron al usuario (después del comienzo); true si la baja está en los 15 días (la campaña figura en
--     mis_campanias_para_escribir()); false si ya pasaron.
--   · corregir_en_gracia_de_baja(entidad, op, payload, versión), SECURITY DEFINER: con null sigue
--     FILA_INEXISTENTE como antes; con false, 42501 (día 16); con true lee la fila con candado, compara la
--     versión (conflict con server_row, como siempre) y aplica el update o el delete con las mismas columnas
--     escribibles y la misma sentencia del push. Como no pasa por la RLS, repite el WITH CHECK de las
--     políticas de UPDATE de 0021 sobre la fila nueva (42501 si no lo cumple). Los triggers corren igual
--     (tg_control_de_correccion: mover la fila, CG001).
--   · Las demás filas que no se leen (otra ciudad, la zona que acota la lectura de una inscripción viva, una
--     campaña terminada) siguen en FILA_INEXISTENTE.
--   · El server_row de un conflict es la fila de la casa que la colportora leía hasta la baja (ubicación, depto
--     o estado: sin personas ni ventas).
--   · Solo para escribir: la lectura, el estado de la cuenta, la zona y la inscripción no cambian.
--
-- ## Para otros repos
--
--   · front-colportores-mobile y motor: durante los 15 días desde la baja (campaña en curso) el push acepta la
--     corrección (propia o ajena) de casas, deptos y estados de la ciudad, también los que ya no baja; el día 16,
--     42501. CG001 sigue saliendo solo tras el fin de la campaña, con su texto de siempre. Sin cambios en el
--     contrato.
--   · docs-organizacion#188: HU-CAM-005 (la gracia desde la baja incluye las correcciones de lo ajeno).
--
-- Datos: ninguno; solo funciones. Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Lo ajeno, sin CG001 en la gracia de la baja
-- ----------------------------------------------------------------------------

-- Misma firma y mismo cuerpo que en 0021 (0193 lo había cambiado): sale de mis_campanias_para_escribir().
create or replace function public.mis_campanias_en_curso_para_escribir()
returns table (campania_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select m.campania_id
    from public.mis_campanias_para_escribir() m
    join public.campania c on c.id = m.campania_id
   where public.escritura_en_curso(c.fecha_fin);
$$;

comment on function public.mis_campanias_en_curso_para_escribir() is
  'Campañas del usuario autenticado en las que puede escribir sin la gracia del fin: ya empezadas y sin '
  'terminar (0021). Incluye la inscripción quitada hace 15 días o menos de una campaña en curso (0193, 0194: '
  'en esa gracia también se corrige lo ajeno). Interna.';

-- ----------------------------------------------------------------------------
-- 2. La corrección de lo que ya no lee, por el push
-- ----------------------------------------------------------------------------

-- Si la ubicación es de una ciudad de una campaña en curso de la que quitaron al usuario autenticado
-- (después del comienzo): true si la baja está en los 15 días de gracia, false si ya pasaron; null si no.
create function public.gracia_de_baja_en_ubicacion(p_ubicacion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select bool_or(c.id in (select m.campania_id from public.mis_campanias_para_escribir() m))
    from public.ubicacion u
    join public.campania_ciudad cci on cci.ciudad_id = u.ciudad_id and cci.deleted_at is null
    join public.campania c on c.id = cci.campania_id
    join public.campania_colportor i on i.campania_id = c.id
   where u.id = p_ubicacion_id
     and i.usuario_id = auth.uid()
     and i.deleted_at is not null
     and c.deleted_at is null
     and c.fecha_inicio <= public.hoy_montevideo()
     and public.escritura_en_curso(c.fecha_fin)
     and public.hoy_montevideo(i.deleted_at) >= c.fecha_inicio;
$$;

comment on function public.gracia_de_baja_en_ubicacion(uuid) is
  'Si la ubicación es de una ciudad de una campaña en curso de la que quitaron al usuario autenticado: true '
  'dentro de los 15 días desde la baja (mis_campanias_para_escribir()), false pasados; null si no hay tal '
  'baja (0194). Sin pasar por la RLS de lectura. Interna.';

-- La corrección (update o delete) de una ubicacion, un espacio o un house_status que el usuario ya no lee
-- porque lo quitaron de la campaña, dentro de los 15 días (0194). Devuelve {outcome: accepted|conflict,
-- sync_version, server_row?}, o null si no es ese caso (el push sigue con FILA_INEXISTENTE). 42501 pasados
-- los 15 días o si la fila nueva no cumple el WITH CHECK de 0021. SECURITY DEFINER: lee y escribe sin la RLS
-- de lectura, así que todo control va acá adentro (authenticated la puede llamar directo, igual que el push).
create function public.corregir_en_gracia_de_baja(p_entidad text, p_op text, p_payload jsonb, p_version bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tabla     regclass;
  v_pk_col    text;
  v_pk        uuid;
  v_ubicacion uuid;
  v_gracia    boolean;
  v_actual    jsonb;
  v_usadas    text[];
  v_ok        boolean;
  v_nueva     bigint;
begin
  if auth.uid() is null
     or p_entidad is null or p_entidad not in ('ubicacion', 'espacio', 'house_status')
     or p_op is null or p_op not in ('update', 'delete') then
    return null;
  end if;

  select e.tabla, e.columna_pk into v_tabla, v_pk_col from sync.entidad e where e.nombre = p_entidad;
  begin
    v_pk := (p_payload ->> v_pk_col)::uuid;
  exception when invalid_text_representation then
    return null;
  end;
  if v_pk is null then
    return null;
  end if;

  if p_entidad = 'ubicacion' then
    select u.id into v_ubicacion from public.ubicacion u where u.id = v_pk;
  elsif p_entidad = 'espacio' then
    select e.ubicacion_id into v_ubicacion from public.espacio e where e.id = v_pk;
  else
    select h.ubicacion_id into v_ubicacion from public.house_status h where h.ubicacion_id = v_pk;
  end if;
  if v_ubicacion is null then
    return null;
  end if;

  v_gracia := public.gracia_de_baja_en_ubicacion(v_ubicacion);
  if v_gracia is null then
    return null;
  end if;
  if not v_gracia then
    raise exception using
      errcode = '42501',
      message = 'Pasaron más de 15 días desde que te quitaron de la campaña: este cambio ya no se guarda. La '
                'fila queda como estaba.',
      hint    = 'Descartá este cambio.';
  end if;

  -- Con candado: entre la comparación y el UPDATE nadie más la cambia.
  execute format('select %s from %s t where t.%I = $1 for update',
                 sync.expresion_json(v_tabla), v_tabla, v_pk_col)
    into v_actual using v_pk;

  -- LWW por sync_version, como el push (contrato §5.4).
  if p_version is null or (v_actual ->> 'sync_version')::bigint <> p_version then
    return jsonb_build_object('outcome', 'conflict',
                              'sync_version', (v_actual ->> 'sync_version')::bigint,
                              'server_row', v_actual);
  end if;

  if p_op = 'delete' then
    execute format('update %s t set deleted_at = now() where t.%I = $1 and t.sync_version = $2',
                   v_tabla, v_pk_col) using v_pk, p_version;
  else
    -- Solo las columnas que el cliente puede escribir (contrato §5.4), como el push.
    select array_agg(k) into v_usadas
      from jsonb_object_keys(p_payload) k
     where k = any (sync.columnas_escribibles(p_entidad));
    if v_usadas is null then
      return null;
    end if;
    execute format(
      'update %s t set %s from jsonb_populate_record(null::%s, $1) x '
      'where t.%I = $2 and t.sync_version = $3',
      v_tabla,
      (select string_agg(format('%I = x.%I', c, c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using p_payload, v_pk, p_version;
  end if;

  -- El WITH CHECK de las políticas de UPDATE (0021), sobre la fila nueva: el DEFINER no pasa por la RLS.
  if p_entidad = 'ubicacion' then
    select (u.created_by = auth.uid() and public.tengo_campania_para_escribir())
           or u.ciudad_id in (select public.mis_ciudades_de_campania())
      into v_ok
      from public.ubicacion u where u.id = v_pk;
  elsif p_entidad = 'espacio' then
    select public.puedo_escribir_en_ubicacion(e.ubicacion_id) into v_ok from public.espacio e where e.id = v_pk;
  else
    select public.puedo_escribir_en_ubicacion(h.ubicacion_id) into v_ok
      from public.house_status h where h.ubicacion_id = v_pk;
  end if;
  if not coalesce(v_ok, false) then
    raise exception using
      errcode = '42501',
      message = 'No se puede guardar: la fila quedaría donde no podés escribir. La fila queda como estaba.',
      hint    = 'Descartá este cambio.';
  end if;

  execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
    into v_nueva using v_pk;
  return jsonb_build_object('outcome', 'accepted', 'sync_version', v_nueva);
end;
$$;

comment on function public.corregir_en_gracia_de_baja(text, text, jsonb, bigint) is
  'Aplica el update o delete de una ubicacion, un espacio o un house_status que el usuario autenticado ya no '
  'lee porque lo quitaron de una campaña en curso hace 15 días o menos (gracia_de_baja_en_ubicacion(); 0194, '
  'decisión del 11/11 «Gracia baja»): compara la versión (conflict con server_row) y repite el WITH CHECK de '
  '0021. Null si no es ese caso; 42501 pasados los 15 días. Para sync.aplicar_job_interno.';

revoke all on function public.gracia_de_baja_en_ubicacion(uuid) from public, anon, authenticated, service_role;
revoke all on function public.corregir_en_gracia_de_baja(text, text, jsonb, bigint)
  from public, anon, authenticated, service_role;
-- sync.aplicar_job_interno es SECURITY INVOKER: corre como authenticated (o service_role).
grant execute on function public.corregir_en_gracia_de_baja(text, text, jsonb, bigint) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. El push: la corrección de lo que ya no lee, en la gracia de la baja
-- ----------------------------------------------------------------------------

-- Igual que en 0191, más la rama de 0194 cuando la fila no se lee. Sus privilegios siguen.
create or replace function sync.aplicar_job_interno(p_op_id uuid, p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text  := p_job ->> 'entity';
  v_op        text  := p_job ->> 'op';
  v_version   bigint;
  v_payload   jsonb := p_job -> 'payload';
  v_tabla     regclass;
  v_pk_col    text;
  v_push_ok   boolean;
  v_pk        uuid;
  v_usadas    text[];
  v_cache     sync.op_cache%rowtype;
  v_actual    jsonb;
  v_nueva     bigint;
  -- EXECUTE no toca FOUND en PL/pgSQL: hay que leer ROW_COUNT a mano. Con FOUND,
  -- un insert que chocó con una PK existente se reportaría `accepted` porque la
  -- variable venía en true de un SELECT anterior.
  v_filas     integer;
  v_juntado   uuid;
  v_duplicada  uuid;
  v_conservada uuid;
  v_union      jsonb;
  v_juntada    jsonb;
  v_tc_version   text;
  v_tc_aceptado  timestamptz;
  v_tc_ya        boolean;
  v_tc_telefono  timestamptz;
  v_baja         jsonb;
begin
  if p_op_id is null then
    return sync.rechazo(p_op_id, 'OP_ID_REQUERIDO', 'falta client_op_id o no es un uuid');
  end if;

  -- El cache gana sobre cualquier validación. Un op ya aplicado vuelve
  -- `duplicate` y no se re-valida: si no, un job aplicado cuya respuesta se
  -- perdió y que en el reintento cae en una validación quedaría INVALID con la
  -- fila ya escrita, y el colportor vería en la cola de error una venta que ya
  -- cobró. Como acá solo entra lo aplicado, un conflicto anterior no lo activa.
  select * into v_cache from sync.op_cache where client_op_id = p_op_id;
  if found then
    return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'duplicate',
                              'sync_version', v_cache.sync_version);
  end if;

  select e.tabla, e.columna_pk, e.permite_push
    into v_tabla, v_pk_col, v_push_ok
    from sync.entidad e where e.nombre = v_entidad;
  if v_tabla is null then
    return sync.rechazo(p_op_id, 'ENTIDAD_DESCONOCIDA',
                        format('%L no está registrada para sync', v_entidad));
  end if;

  -- 0191: «aceptar los Términos» (BACK-HU-AUTH-011, backend-supabase#267; decisión de Cristian del 11/11, «TyC
  -- s/red»: se acepta sin señal y sube después, como «Duplicado»). No es un upsert: no trae PK ni sync_version y lo
  -- aplica aceptar_terminos(version) (0182), con sus permisos y sus errores. Va antes del chequeo de «solo lectura»:
  -- consentimiento_terminos no acepta filas por el push, solo este trabajo.
  --   · la versión va explícita (la que se leyó y se aceptó en el teléfono); sin ella, PAYLOAD_VACIO.
  --   · aplicada -> `accepted`; ya estaba aceptada -> `duplicate`. Los dos con ya_estaba, version, aceptado_en,
  --     aceptado_en_telefono y el sync_version de la fila, y entran al cache. La hora del teléfono, en la sección 0.
  --   · TC001 (versión no publicada) y 42501 (cuenta dada de baja) salen `invalid` (sync.aplicar_job, abajo).
  if v_op = 'aceptar_terminos' then
    if v_entidad <> 'consentimiento_terminos' then
      return sync.rechazo(p_op_id, 'OP_INVALIDA',
                          format('op %L solo va con la entidad consentimiento_terminos', v_op));
    end if;

    if jsonb_typeof(v_payload -> 'version') is distinct from 'string' then
      return sync.rechazo(p_op_id, 'PAYLOAD_VACIO',
                          'el payload no trae version: la versión de los Términos que se leyó y se aceptó (v1, v2…)');
    end if;

    select a.version, a.aceptado_en, a.ya_estaba
      into v_tc_version, v_tc_aceptado, v_tc_ya
      from public.aceptar_terminos(v_payload ->> 'version') a;

    -- La hora del teléfono, solo en la aceptación nueva y solo si es creíble (si no, null; la aceptación vale igual).
    if not v_tc_ya and jsonb_typeof(v_payload -> 'aceptado_en_telefono') = 'string' then
      perform sync.hora_de_aceptacion_del_telefono(v_tc_version, v_payload ->> 'aceptado_en_telefono');
    end if;

    select c.sync_version, c.aceptado_en_telefono into v_nueva, v_tc_telefono
      from public.consentimiento_terminos c
     where c.usuario_id = auth.uid() and c.version = v_tc_version;

    return sync.registrar(p_op_id, v_entidad, case when v_tc_ya then 'duplicate' else 'accepted' end, v_nueva)
           || jsonb_build_object('ya_estaba', v_tc_ya, 'version', v_tc_version, 'aceptado_en', v_tc_aceptado,
                                 'aceptado_en_telefono', v_tc_telefono);
  end if;

  if not v_push_ok then
    return sync.rechazo(p_op_id, 'ENTIDAD_DE_SOLO_LECTURA',
                        format('%L es una réplica: la app no la escribe', v_entidad));
  end if;

  -- 0101: «marcar como duplicado» (HU-UBI-006, backend-supabase#70; decisión de Cristian del 06/10,
  -- «Duplicado»: «Se encola y sube después»). No es un upsert: no tiene PK ni sync_version, y lo aplica
  -- la misma operación atómica e idempotente de la RPC, `marcar_como_duplicado(B, A)`, con los mismos
  -- permisos y los mismos errores. Va después del cache y de los chequeos de la entidad, y antes de
  -- todo lo que piensa en una fila: el payload trae los dos ids (`duplicada_id` = B, `conservada_id` =
  -- A) y no una PK. Se aplica en su lugar del lote: después de lo que ese teléfono subió de A y de B.
  --   · aplicado -> `accepted`; B ya estaba unida (a A o a otra; A ya se había unido a B) -> `duplicate`,
  --     con `ya_unida: true`. Los dos traen `destino_id` (A, o aquella a la que A ya se había unido) y el
  --     `sync_version` de B, y entran al cache: el reintento con el mismo client_op_id es `duplicate`.
  --   · UB003, UB004, 42501 y CG001 salen como `invalid` (los atrapa sync.aplicar_job, abajo) y una
  --     ubicación que no existe, como `invalid FILA_INEXISTENTE`: ninguno tumba el lote.
  if v_op = 'marcar_como_duplicado' then
    if v_entidad <> 'ubicacion' then
      return sync.rechazo(p_op_id, 'OP_INVALIDA',
                          format('op %L solo va con la entidad ubicacion', v_op));
    end if;

    v_duplicada  := (v_payload ->> 'duplicada_id')::uuid;
    v_conservada := (v_payload ->> 'conservada_id')::uuid;
    if v_duplicada is null or v_conservada is null then
      return sync.rechazo(p_op_id, 'PK_FALTANTE', 'el payload no trae duplicada_id y conservada_id');
    end if;

    begin
      v_union := public.marcar_como_duplicado(v_duplicada, v_conservada);
    exception when no_data_found then
      -- La RPC la levanta (P0002) cuando alguna de las dos no existe.
      return sync.rechazo(p_op_id, 'FILA_INEXISTENTE', sqlerrm);
    end;

    select t.sync_version into v_nueva from public.ubicacion t where t.id = v_duplicada;
    return sync.registrar(p_op_id, v_entidad,
                          case when (v_union ->> 'ya_unida')::boolean then 'duplicate' else 'accepted' end,
                          v_nueva)
           || jsonb_build_object('ya_unida', (v_union ->> 'ya_unida')::boolean,
                                 'destino_id', v_union -> 'destino_id');
  end if;

  v_pk := (v_payload ->> v_pk_col)::uuid;
  if v_pk is null then
    return sync.rechazo(p_op_id, 'PK_FALTANTE',
                        format('el payload no trae %L', v_pk_col));
  end if;

  -- Solo las columnas que el cliente puede escribir (contrato §5.4). Las del
  -- servidor se descartan aunque vengan.
  select array_agg(k) into v_usadas
    from jsonb_object_keys(v_payload) k
   where k = any (sync.columnas_escribibles(v_entidad));

  if v_usadas is null then
    return sync.rechazo(p_op_id, 'PAYLOAD_VACIO',
                        'el payload no trae ninguna columna escribible');
  end if;

  -- ---- insert ----
  if v_op = 'insert' then
    execute format(
      'insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1) x '
      'on conflict (%I) do nothing',
      v_tabla,
      (select string_agg(quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload;
    get diagnostics v_filas = row_count;

    -- 0064: el insert no insertó nada porque el vínculo se juntó con el que ya tenía la misma persona
    -- en el espacio fundido (el trigger de espacio_persona lo registró). No es un duplicado: el
    -- teléfono tiene que saber cuál es el vínculo que quedó. Reintentar da lo mismo.
    if v_filas = 0 and v_entidad = 'espacio_persona' then
      v_juntado := public.vinculo_juntado(v_pk);
      if v_juntado is not null then
        return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'merged',
                                  'merged_into', v_juntado);
      end if;
    end if;

    execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
      into v_nueva using v_pk;

    -- La PK ya existía: el UUID v7 lo generó el dispositivo, así que es la misma
    -- fila y no otra. Éxito idempotente, no error (contrato §7, replay).
    return sync.registrar(p_op_id, v_entidad,
                          case when v_filas > 0 then 'accepted' else 'duplicate' end, v_nueva);
  end if;

  if v_op not in ('update', 'delete') then
    return sync.rechazo(p_op_id, 'OP_INVALIDA', format('op %L', v_op));
  end if;

  -- ---- update / delete ----
  begin
    v_version := (p_job ->> 'sync_version')::bigint;
  exception when data_exception then
    v_version := null;
  end;

  -- 0021: corregir lo que cargó otro con la campaña en la gracia de 0020 (decisión de Cristian
  -- del 02/10 en #52). Antes de leer la fila: la lectura no tiene gracia y no la vería.
  if public.correccion_ajena_en_gracia(v_entidad, v_pk) then
    return sync.rechazo(p_op_id, 'CG001',
                        'La campaña ya terminó: solo se guardan tus ventas y lo que cargaste vos. Lo '
                        'que cargó otra persona queda como estaba. Descartá este cambio.');
  end if;

  execute format('select %s from %s t where t.%I = $1',
                 sync.expresion_json(v_tabla), v_tabla, v_pk_col)
    into v_actual using v_pk;
  if v_actual is null then
    -- 0123: un vínculo que se juntó con otro al llegar no existe como fila (0064): su update o delete
    -- se aplica al que quedó (decisión de Cristian del 23/10, «Edición tarde»), con conflicto si el
    -- que quedó cambió después de la unión. Solo si el id lo subió quien llama; si no, sigue como antes.
    if v_entidad = 'espacio_persona' then
      v_juntada := public.aplicar_a_vinculo_juntado(v_pk, v_op, v_payload);
      if v_juntada is not null then
        if v_juntada ->> 'outcome' = 'conflict' then
          return jsonb_build_object(
            'client_op_id', p_op_id, 'outcome', 'conflict',
            'sync_version', (v_juntada ->> 'sync_version')::bigint,
            'server_row', v_juntada -> 'server_row');
        end if;
        return sync.registrar(p_op_id, v_entidad, 'accepted', (v_juntada ->> 'sync_version')::bigint);
      end if;
    end if;
    -- 0194 («Gracia baja», decisión de Cristian del 11/11, aclarada el 11/11 en #280): a quien quitaron de una campaña
    -- en curso hace 15 días o menos se le aplica la corrección de una casa, un depto o un estado de su ciudad aunque
    -- ya no la lea (también la de lo que cargó otro). Pasados los 15 días, 42501.
    if v_entidad in ('ubicacion', 'espacio', 'house_status') then
      v_baja := public.corregir_en_gracia_de_baja(v_entidad, v_op, v_payload, v_version);
      if v_baja is not null then
        if v_baja ->> 'outcome' = 'conflict' then
          return jsonb_build_object(
            'client_op_id', p_op_id, 'outcome', 'conflict',
            'sync_version', (v_baja ->> 'sync_version')::bigint,
            'server_row', v_baja -> 'server_row');
        end if;
        return sync.registrar(p_op_id, v_entidad, 'accepted', (v_baja ->> 'sync_version')::bigint);
      end if;
    end if;
    return sync.rechazo(p_op_id, 'FILA_INEXISTENTE',
                        format('%s no existe en %s', v_pk, v_entidad));
  end if;

  -- 0148 («Cancelar tr.», decisión de Cristian del 28/10): lo mismo para la transferencia de stock que pidió la
  -- colportora: cancelarla no compara versión (el servidor le fija el número y el teléfono puede tener una vieja).
  -- 0138 («Cancelar ped», decisión de Cristian del 27/10): cancelar un pedido propio que está por autorizar NO
  -- compara versión. Cancelar es "no lo quiero" y no depende de qué versión del pedido tenía el teléfono (las
  -- líneas, el monto y el aviso del límite se recalculan en el servidor y el teléfono puede tener una vieja). Se
  -- aplica sobre la versión que hay. Si el pedido ya no está por autorizar, el trigger de pedido_casa_editora
  -- (0124) lo frena con su aviso (42501: el coordinador ya lo autorizó, pedile que lo cancele) y el push vuelve
  -- `invalid` con el texto; si ya estaba cancelado, no cambia nada. Una cancelación nunca vuelve atrás a
  -- «por autorizar»: ese cambio no es una cancelación y sigue comparando versión (y el trigger lo frena).
  if v_op = 'update' and v_entidad in ('pedido_casa_editora', 'transferencia_stock') and v_payload ->> 'estado' = 'CANCELADO' then
    v_version := (v_actual ->> 'sync_version')::bigint;
  end if;

  -- LWW por sync_version (contrato §5.4). Si el servidor tiene una más nueva,
  -- gana él y devuelve su fila: el cliente resuelve sin un pull extra.
  if v_version is null or (v_actual ->> 'sync_version')::bigint <> v_version then
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  -- La versión va en el WHERE del propio UPDATE, no solo en el `if` de arriba.
  --
  -- Entre aquel SELECT y este UPDATE hay una ventana: en READ COMMITTED otra
  -- transacción puede bumpear la fila justo ahí. El UPDATE quedaría esperando el
  -- lock, y al soltarse re-leería la fila y escribiría igual, pisando el cambio
  -- ajeno y devolviendo `accepted` con una versión que el cliente creía vieja.
  -- Es la actualización perdida clásica, y acá significa que el estado de una
  -- ubicación que dos dispositivos tocaron a la vez queda en el que llegó
  -- primero, sin que nadie se entere.
  --
  -- Con la versión en el WHERE es un compare-and-swap: o aplica sobre la versión
  -- que el cliente esperaba, o no aplica y se reporta como conflicto.
  --
  -- sync_version, updated_at y xmin_w no se asignan acá: los pone el trigger de
  -- auditoría del 0001 (§8), que corre igual venga la escritura de donde venga.
  if v_op = 'delete' then
    execute format('update %s t set deleted_at = now() where t.%I = $1 and t.sync_version = $2',
                   v_tabla, v_pk_col) using v_pk, v_version;
  else
    execute format(
      'update %s t set %s from jsonb_populate_record(null::%s, $1) x '
      'where t.%I = $2 and t.sync_version = $3',
      v_tabla,
      (select string_agg(format('%I = x.%I', c, c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload, v_pk, v_version;
  end if;
  get diagnostics v_filas = row_count;

  if v_filas = 0 then
    -- Otro escritor ganó la carrera entre el SELECT y el UPDATE.
    execute format('select %s from %s t where t.%I = $1',
                   sync.expresion_json(v_tabla), v_tabla, v_pk_col)
      into v_actual using v_pk;
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
    into v_nueva using v_pk;
  return sync.registrar(p_op_id, v_entidad, 'accepted', v_nueva);
end;
$$;

comment on function sync.aplicar_job_interno(uuid, jsonb) is
  'Aplica un job del push. Además de insert/update/delete de una entidad (0002, 0021, 0064), '
  'op ''marcar_como_duplicado'' con entity ''ubicacion'' y payload {duplicada_id, conservada_id}: llama a '
  'marcar_como_duplicado(B, A) y responde accepted, o duplicate con ya_unida (0101, HU-UBI-006); y op '
  '''aceptar_terminos'' con entity ''consentimiento_terminos'' y payload {version}: llama a aceptar_terminos(version) y '
  'responde accepted, o duplicate si ya estaba aceptada, con ya_estaba, version, aceptado_en y aceptado_en_telefono; '
  'guarda la hora del teléfono del payload (aceptado_en_telefono) si es creíble (0191, HU-AUTH-011). El '
  'update o delete de un espacio_persona que se juntó con otro al llegar se aplica al que quedó, con '
  'conflicto si cambió desde la unión (0123). El update de un pedido_casa_editora o de una transferencia_stock a '
  'CANCELADO no compara versión (0138, 0148). El update o delete de una ubicacion, un espacio o un house_status '
  'que ya no lee, de quien quitaron de una campaña en curso hace 15 días o menos, lo aplica '
  'corregir_en_gracia_de_baja() (0194).';
