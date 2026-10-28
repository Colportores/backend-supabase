-- ============================================================================
-- 0132 · Becas y alquiler con las respuestas del 27/10: sin becas en una campaña permanente, la carrera
--        corregida recalcula la meta, quien se da de baja no debe alquiler y el saldo de alquiler se guarda
--        por persona y por campaña (backend-supabase#202, seguimiento de #112, #111 y #155)
--
-- Origen: las respuestas de Cristian del 27/10 a las pendientes de los PR 187 (#112), 183 (#111) y 189 (#155)
-- y la de «Logro beca» del panel (front-coordinadores-web#95). Esta migración SOLO SUMA o redefine con
-- `create or replace`: no cambia ni borra ninguna fila que ya exista.
--
-- ## 1. «Beca perman.»: en una campaña permanente no hay becas (#187)
--
--   · `asignar_beca()` rechaza MEDIA o COMPLETA en una campaña PERMANENTE con BC006, «En una campaña permanente
--     no hay becas.» «Sin beca» (null) sí se puede: es lo único que hay. Se mira antes que la carrera o la meta
--     de cada colportor, así que ya no sale BC004 («falta configurar la meta») en una permanente.
--   · Un trigger (`campania_colportor_sin_beca_en_permanente`) cierra el mismo camino por la API directa: el
--     coordinador puede hacer UPDATE de su inscripción (política de 0003), y ahí el tipo de beca también se
--     rechaza con BC006. Solo mira cuando `tipo_beca` cambia a un valor: lo que ya hubiera no se toca.
--   · No se suma un tipo PERMANENTE a `meta_beca` (el CHECK sigue en VERANO / INVIERNO).
--
-- ## 2. «Carrera corr»: corregir la carrera recalcula la meta (#187)
--
--   · Cuando cambia la carrera de un colportor (de una a otra, o de ninguna a una: quitarla y elegir otra es
--     corregirla, ronda 1 de la revisión), las inscripciones VIVAS
--     que tienen tipo de beca y están en una campaña que no terminó toman las metas de la carrera nueva (libros
--     y monto, del mismo tipo de beca y del tipo de la campaña). Las campañas terminadas quedan como estaban,
--     igual que en `asignar_beca()` (BC001: «sus becas quedan como estaban»).
--   · Si la carrera nueva no tiene la meta cargada para alguna de esas campañas, la corrección se rechaza
--     con BC004 y no cambia nada: ante la duda se bloquea, y es lo que ya hace `asignar_beca()`.
--   · Lo que no cambia no se toca: si la meta nueva es igual a la que tenía, no hay escritura ni evento.
--   · Queda en `audit_log`: `carrera_del_colportor_cambiada` (0117), `beca_asignada` (0117, por el cambio de las
--     metas de la inscripción) y el evento nuevo `meta_de_beca_recalculada`, que dice POR QUÉ cambió la meta
--     (carrera anterior y nueva, tipo, metas de antes y de después; solo ids y números).
--   · `becas_de_campania()` suma `meta_recalculada_en`: cuándo se recalculó la meta de esa inscripción por una
--     corrección de carrera, mientras la inscripción siga con esa meta. El panel dibuja el aviso «Carrera
--     corregida: meta de <carrera>» (`carrera_nombre`) cuando no es null. Si el coordinador cambia después el tipo
--     y las metas ya no son las recalculadas, vuelve a ser null.
--
-- ## 3. «Logro beca»: lo alcanzado no se pierde (front-coordinadores-web#95)
--
--   La decisión vale «si la lectura de Becas calcula el estado». `becas_de_campania()` todavía no calcula el
--   avance ni el estado de la meta (HU-BEC-002, sin issue todavía): no hay nada que cambiar acá. Cuando ese cálculo exista,
--   tiene que devolver la meta alcanzada aunque el tipo pase a «Sin beca» (hoy «Sin beca» deja el tipo y las
--   metas en null, R-BC06: ese cálculo tendrá que guardar lo alcanzado antes de eso).
--
-- ## 4. «Alq. de baja»: quien se da de baja no debe alquiler (#183)
--
--   Una inscripción dada de baja deja de deber el alquiler: `alquiler_debe` queda en 0 (en una campaña que
--   cobra). Lo que ya pagó queda a favor (`alquiler_a_favor` = todo lo pagado). Por regla R7, si la inscripción
--   se reactiva vuelve a deber el alquiler de la campaña, contando lo que ya había pagado (monto menos lo pagado,
--   como a cualquiera). Una campaña que no cobra alquiler sigue con `alquiler_debe` null.
--
--   · `alquiler_calculado(usuario, campania)` (interna) es la ÚNICA cuenta del alquiler: monto, lo debido
--     (monto; 0 si está de baja; null si no cobra), pagado (depósitos validados de la campaña), por validar,
--     debe, a favor y fecha del último pago. La usan `cuentas_de_campania()`, la tabla del punto 5 y la vista
--     previa de validar un ticket (`validacion_calculada()`), así que las tres dicen lo mismo.
--   · `cuentas_de_campania()` suma la columna `alquiler_a_favor` al final (cambia su salida: drop + create y los
--     mismos privilegios).
--
-- ## 5. «Deuda alq.»: el saldo de alquiler por persona y por campaña se guarda (#189)
--
--   La tabla `cuenta_alquiler` guarda, por (colportor, campaña) con inscripción (aun de baja): el monto, lo
--   pagado, lo que está por validar, lo que debe, lo que queda a favor y la fecha del último pago. La mantiene el
--   servidor en la MISMA transacción que cada cosa que mueve el saldo, para que no se desfase:
--
--     · un depósito de alquiler que se crea, se valida (`validado_en`), cambia de monto, de campaña o de dueño, o
--       se da de baja (`tg_deposito_cuenta_alquiler`);
--     · el cambio de estado de un ticket (PENDIENTE a RECHAZADO deja de contar como «por validar»);
--     · el cambio del monto del alquiler de la campaña (todas sus filas);
--     · el alta de una inscripción, su baja y su reactivación.
--
--   `cuentas_de_campania()` sigue calculando el alquiler desde los depósitos (no lee la tabla): la tabla no puede
--   desfasarse sin que se note, porque un test la compara con esa lectura después de cada tipo de movimiento. La
--   fila se escribe solo si cambia algo (ni `sync_version` ni registro de más). Un candado por campaña serializa
--   los refrescos: dos depósitos a la vez no se pisan con una cuenta vieja.
--   La lee su dueño, el ADMIN y quien coordina ESA campaña (no la de otra campaña del mismo colportor); no la
--   escribe nadie con JWT. No viaja por el sync: el teléfono ya baja la campaña (`alquiler_monto`) y sus
--   depósitos. La columna `deuda_alquiler` por persona de `cuenta_colportor` queda como está, sin uso (quitarla
--   no se decidió).
--
-- ## Códigos de error nuevos
--
--   BC006 · en una campaña permanente no hay becas. (BC004 ahora también corta la corrección de carrera.)
--
-- ## Los datos
--
--   Una tabla nueva con una fila por inscripción que ya existe (se carga al migrar, con la misma cuenta que
--   usan los triggers) y nada más. Ninguna fila de otra tabla cambia, ni su `sync_version` ni su `xmin_w`.
--   Lo prueba supabase/tests_migracion/0132_ok.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Sin becas en una campaña permanente
-- ----------------------------------------------------------------------------

create function public.tg_campania_colportor_sin_beca_en_permanente()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.tipo_beca is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.tipo_beca is not distinct from new.tipo_beca then
    return new;
  end if;

  if exists (select 1 from public.campania c where c.id = new.campania_id and c.tipo = 'PERMANENTE') then
    raise exception 'En una campaña permanente no hay becas.' using errcode = 'BC006';
  end if;
  return new;
end;
$$;

comment on function public.tg_campania_colportor_sin_beca_en_permanente() is
  'BEFORE INSERT / UPDATE OF tipo_beca en campania_colportor (0132, backend-supabase#202): un tipo de beca en una '
  'campaña PERMANENTE se rechaza con BC006, venga de asignar_beca() o de un UPDATE directo. Solo mira cuando el '
  'tipo cambia a un valor; "sin beca" siempre se puede.';

revoke all on function public.tg_campania_colportor_sin_beca_en_permanente()
  from public, anon, authenticated, service_role;

create trigger campania_colportor_sin_beca_en_permanente
  before insert or update of tipo_beca on public.campania_colportor
  for each row
  when (new.tipo_beca is not null)
  execute function public.tg_campania_colportor_sin_beca_en_permanente();

-- asignar_beca: igual que en 0117, salvo que mira el tipo de la campaña antes que la carrera y la meta de cada
-- colportor (BC006). Misma firma: los privilegios se conservan.
create or replace function public.asignar_beca(p_campania_id uuid, p_usuarios uuid[], p_tipo text)
returns table (usuario_id uuid, tipo_beca text, meta_libros integer, meta_monto_ces bigint, cambio boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ids            uuid[];
  v_cambiaron      uuid[];
  v_tipo_campania  text;
  v_inscriptos     integer;
  v_sin_carrera    integer;
  v_sin_meta       integer;
begin
  perform public.exigir_coordinador_de_campania_para_beca(p_campania_id);

  if p_tipo is not null and p_tipo not in ('MEDIA', 'COMPLETA') then
    raise exception 'El tipo de beca puede ser media, completa o sin beca.' using errcode = 'invalid_parameter_value';
  end if;

  -- «Beca perman.» (27/10): en una campaña permanente no hay becas. Antes de mirar la carrera o la meta de
  -- cada colportor: ahí no hay meta posible y el aviso tiene que ser este.
  select c.tipo into v_tipo_campania from public.campania c where c.id = p_campania_id;
  if p_tipo is not null and v_tipo_campania = 'PERMANENTE' then
    raise exception 'En una campaña permanente no hay becas.' using errcode = 'BC006';
  end if;

  select coalesce(array_agg(distinct x order by x), array[]::uuid[]) into v_ids
    from unnest(p_usuarios) as x
   where x is not null;
  if cardinality(v_ids) = 0 then
    raise exception 'Elegí al menos un colportor para asignarle la beca.' using errcode = 'invalid_parameter_value';
  end if;

  -- Las inscripciones vivas, con candado y en orden de usuario: dos asignaciones a la vez se serializan.
  perform 1 from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = any (v_ids) and cc.deleted_at is null
   order by cc.usuario_id
     for update;
  select count(*) into v_inscriptos
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id and u.deleted_at is null
   where cc.campania_id = p_campania_id and cc.usuario_id = any (v_ids) and cc.deleted_at is null;
  if v_inscriptos <> cardinality(v_ids) then
    raise exception 'Alguno de los colportores no está en esta campaña. Recargá Equipo y volvé a intentar.'
      using errcode = 'CZ003';
  end if;

  if p_tipo is not null then
    select count(*) filter (where u.carrera_id is null),
           count(*) filter (where u.carrera_id is not null and mb.id is null)
      into v_sin_carrera, v_sin_meta
      from public.usuario u
      left join public.meta_beca mb
             on mb.carrera_id = u.carrera_id and mb.tipo_campania = v_tipo_campania and mb.deleted_at is null
     where u.id = any (v_ids);

    if v_sin_carrera > 0 then
      raise exception 'Falta elegir la carrera de % colportor(es). Elegila en Becas y volvé a asignar la beca.', v_sin_carrera
        using errcode = 'BC003';
    end if;
    if v_sin_meta > 0 then
      raise exception 'Falta configurar la meta de esta carrera. Avisale al administrador para que la cargue y volvé a asignar la beca.'
        using errcode = 'BC004';
    end if;
  end if;

  -- Solo se toca lo que cambia: sin escritura de más, sin sync_version que sube por nada.
  with cambiadas as (
  update public.campania_colportor cc
     set tipo_beca      = p_tipo,
         meta_libros    = case p_tipo when 'MEDIA' then mb.meta_media
                                      when 'COMPLETA' then mb.meta_completa end,
         meta_monto_ces = case p_tipo when 'MEDIA' then mb.meta_media_monto
                                      when 'COMPLETA' then mb.meta_completa_monto end
    from public.usuario u
    left join public.meta_beca mb
           on mb.carrera_id = u.carrera_id and mb.tipo_campania = v_tipo_campania and mb.deleted_at is null
   where cc.campania_id = p_campania_id and cc.usuario_id = any (v_ids) and cc.deleted_at is null
     and u.id = cc.usuario_id
     and (cc.tipo_beca is distinct from p_tipo
          or cc.meta_libros is distinct from case p_tipo when 'MEDIA' then mb.meta_media
                                                         when 'COMPLETA' then mb.meta_completa end
          or cc.meta_monto_ces is distinct from case p_tipo when 'MEDIA' then mb.meta_media_monto
                                                            when 'COMPLETA' then mb.meta_completa_monto end)
  returning cc.usuario_id
  )
  select coalesce(array_agg(x.usuario_id), array[]::uuid[]) into v_cambiaron from cambiadas x;

  -- Lo que quedó, con una marca por los que cambiaron en esta llamada.
  return query
    select cc.usuario_id, cc.tipo_beca, cc.meta_libros, cc.meta_monto_ces,
           (cc.usuario_id = any (v_cambiaron))
      from public.campania_colportor cc
     where cc.campania_id = p_campania_id and cc.usuario_id = any (v_ids) and cc.deleted_at is null
     order by cc.usuario_id;
end;
$$;

comment on function public.asignar_beca(uuid, uuid[], text) is
  'Vista 33, HU-BEC-006 (0117, backend-supabase#112; 0132, #202): el coordinador de la campaña (o un ADMIN) asigna '
  'MEDIA, COMPLETA o sin beca (null) a uno o varios colportores inscriptos, todo o nada. Copia en la inscripción '
  'las metas de meta_beca de la carrera del colportor y del tipo de la campaña (meta_libros y meta_monto_ces, '
  'centavos); sin beca las deja en null. En una campaña PERMANENTE solo se puede «sin beca» (BC006). Idempotente: '
  'lo que no cambia no se toca (cambio = false). Queda en audit_log. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente; BC001 campaña terminada; 22023 tipo o lista inválidos; BC006 campaña permanente; CZ003 alguno '
  'no está en la campaña; BC003 a alguno le falta la carrera; BC004 la carrera no tiene meta cargada.';

-- ----------------------------------------------------------------------------
-- 2. Corregir la carrera recalcula la meta de las inscripciones con beca
-- ----------------------------------------------------------------------------

-- AFTER UPDATE OF carrera_id en usuario, cuando la carrera pasa a otra o de ninguna a una (quitarla y elegir otra
-- es corregirla). La corrige el ADMIN (0117); `elegir_carrera()` la fija por primera vez; el servidor también
-- puede. Sin inscripción viva con beca no hace nada (la primera elección de quien no tiene beca no recalcula).
-- Recalcula TODAS las campañas de la persona, no solo las que coordina quien dispara el cambio (por eso es
-- DEFINER y avisa al guard de la beca con `colportores.recalculo_de_metas`).
create function public.tg_usuario_carrera_recalcula_metas()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_sin_meta integer;
  v_antes    text;
  r          record;
begin
  -- Las inscripciones vivas con beca, en campañas que no terminaron, con candado y en orden de id: una
  -- asignación del coordinador al mismo tiempo se serializa con la corrección.
  perform 1
    from public.campania_colportor cc
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = new.id and cc.deleted_at is null and cc.tipo_beca is not null
     and c.deleted_at is null and c.tipo in ('VERANO', 'INVIERNO')
     and (c.fecha_fin is null or c.fecha_fin >= public.hoy_montevideo())
   order by cc.id
     for update of cc;

  -- Sin la meta de la carrera nueva para alguna de ellas, no se corrige: ante la duda se bloquea.
  select count(*) into v_sin_meta
    from public.campania_colportor cc
    join public.campania c on c.id = cc.campania_id
    left join public.meta_beca mb
           on mb.carrera_id = new.carrera_id and mb.tipo_campania = c.tipo and mb.deleted_at is null
   where cc.usuario_id = new.id and cc.deleted_at is null and cc.tipo_beca is not null
     and c.deleted_at is null and c.tipo in ('VERANO', 'INVIERNO')
     and (c.fecha_fin is null or c.fecha_fin >= public.hoy_montevideo())
     and mb.id is null;
  if v_sin_meta > 0 then
    -- El coordinador que elige la carrera no la carga: el aviso es el de asignar_beca() y lo manda al ADMIN.
    if auth.uid() is not null and not public.tiene_rol('ADMIN') then
      raise exception 'Falta configurar la meta de esta carrera. Avisale al administrador para que la cargue y volvé a asignar la beca.'
        using errcode = 'BC004';
    end if;
    raise exception 'La carrera nueva no tiene la meta cargada para la campaña de este colportor. Cargala primero y volvé a corregir la carrera.'
      using errcode = 'BC004';
  end if;

  -- El guard de la beca (0117/0120) deja pasar este cambio aunque lo dispare un coordinador de otra campaña.
  v_antes := current_setting('colportores.recalculo_de_metas', true);
  perform set_config('colportores.recalculo_de_metas', 'on', true);

  -- Solo se toca lo que cambia; por cada inscripción cambiada queda el evento que dice por qué.
  for r in
    with objetivo as (
      select cc.id, cc.campania_id, cc.tipo_beca,
             cc.meta_libros as libros_antes, cc.meta_monto_ces as monto_antes,
             case cc.tipo_beca when 'MEDIA' then mb.meta_media else mb.meta_completa end as libros,
             case cc.tipo_beca when 'MEDIA' then mb.meta_media_monto else mb.meta_completa_monto end as monto
        from public.campania_colportor cc
        join public.campania c on c.id = cc.campania_id
        join public.meta_beca mb
          on mb.carrera_id = new.carrera_id and mb.tipo_campania = c.tipo and mb.deleted_at is null
       where cc.usuario_id = new.id and cc.deleted_at is null and cc.tipo_beca is not null
         and c.deleted_at is null and c.tipo in ('VERANO', 'INVIERNO')
         and (c.fecha_fin is null or c.fecha_fin >= public.hoy_montevideo())
    ), cambiadas as (
      update public.campania_colportor cc
         set meta_libros = o.libros, meta_monto_ces = o.monto
        from objetivo o
       where cc.id = o.id
         and (cc.meta_libros is distinct from o.libros or cc.meta_monto_ces is distinct from o.monto)
      returning cc.id
    )
    select o.id, o.campania_id, o.tipo_beca, o.libros_antes, o.monto_antes, o.libros, o.monto
      from objetivo o
      join cambiadas x on x.id = o.id
     order by o.id
  loop
    perform auditoria.registrar(
      'meta_de_beca_recalculada', 'campania_colportor', r.id, new.id,
      jsonb_build_object('campania_id', r.campania_id,
                         'carrera_anterior', old.carrera_id, 'carrera_nueva', new.carrera_id,
                         'tipo_beca', r.tipo_beca,
                         'meta_libros_anterior', r.libros_antes, 'meta_libros', r.libros,
                         'meta_monto_ces_anterior', r.monto_antes, 'meta_monto_ces', r.monto));
  end loop;

  perform set_config('colportores.recalculo_de_metas', coalesce(v_antes, 'off'), true);
  return null;
end;
$$;

comment on function public.tg_usuario_carrera_recalcula_metas() is
  'AFTER UPDATE OF carrera_id en usuario, cuando pasa a otra carrera o de ninguna a una (0132, backend-supabase#202, '
  '«Carrera corr»): las inscripciones vivas con tipo de beca en campañas que no terminaron toman las metas de la '
  'carrera nueva. Sin esa meta cargada para alguna: BC004 y no cambia nada. Lo que no cambia no se toca. Cada '
  'inscripción cambiada deja meta_de_beca_recalculada en audit_log.';

revoke all on function public.tg_usuario_carrera_recalcula_metas()
  from public, anon, authenticated, service_role;

create trigger usuario_carrera_recalcula_metas
  after update of carrera_id on public.usuario
  for each row
  when (new.carrera_id is not null and old.carrera_id is distinct from new.carrera_id)
  execute function public.tg_usuario_carrera_recalcula_metas();

-- El guard de la beca (0120) deja pasar el recálculo de metas: igual que en 0120 salvo la primera guarda. La
-- corrección de carrera puede dispararla un coordinador (elegir_carrera) y tiene que tocar también las inscripciones
-- de campañas que no coordina. La bandera es de la transacción y solo la pone tg_usuario_carrera_recalcula_metas().
create or replace function public.tg_campania_colportor_beca_y_limite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if new.tipo_beca is not distinct from old.tipo_beca
     and new.meta_libros is not distinct from old.meta_libros
     and new.meta_monto_ces is not distinct from old.meta_monto_ces then
    return new;
  end if;

  if current_setting('colportores.recalculo_de_metas', true) = 'on' then
    return new;
  end if;

  if public.tiene_rol('ADMIN')
     or (public.tiene_rol('COORDINADOR')
         and exists (select 1 from public.campania c
                      where c.id = new.campania_id and c.coordinador_id = auth.uid())) then
    return new;
  end if;

  raise exception 'La beca y la meta las fija el coordinador de la campaña'
    using errcode = '42501';
end;
$$;

comment on function public.tg_campania_colportor_beca_y_limite() is
  'BEFORE UPDATE OF tipo_beca, meta_libros, meta_monto_ces en campania_colportor (0067, 0117, 0120, 0132): solo '
  'el ADMIN o el coordinador de esa campaña los cambian con un JWT (42501); el servidor, sin restricción; y el '
  'recálculo de metas por corrección de carrera (colportores.recalculo_de_metas, lo pone solo ese trigger).';

-- becas_de_campania: igual que en 0117 más `meta_recalculada_en` (la marca del aviso «Carrera corregida: meta de
-- <carrera>»). Sumar una columna de salida pide drop + create + los mismos privilegios.
drop function public.becas_de_campania(uuid);

create function public.becas_de_campania(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text, carrera_id uuid, carrera_nombre text,
               carrera_elegida_en timestamptz, tipo_beca text, meta_libros integer, meta_monto_ces bigint,
               meta_configurada boolean, meta_recalculada_en timestamptz)
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
    select u.id, u.nombre, u.apellido, ca.id, ca.nombre, u.carrera_elegida_en,
           cc.tipo_beca, cc.meta_libros, cc.meta_monto_ces,
           exists (select 1 from public.meta_beca mb
                    where mb.carrera_id = u.carrera_id and mb.tipo_campania = v_tipo_campania
                      and mb.deleted_at is null),
           -- La última vez que una corrección de carrera dejó a esta inscripción con la meta que tiene ahora.
           (select max(a.created_at)
              from auditoria.audit_log a
             where a.event_type = 'meta_de_beca_recalculada'
               and a.target_user_id = u.id and a.fila_id = cc.id
               and a.metadata ->> 'tipo_beca' = cc.tipo_beca
               and (a.metadata ->> 'meta_libros')::integer is not distinct from cc.meta_libros
               and (a.metadata ->> 'meta_monto_ces')::bigint is not distinct from cc.meta_monto_ces)
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.carrera ca on ca.id = u.carrera_id
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id;
end;
$$;

comment on function public.becas_de_campania(uuid) is
  'Vista 33, HU-BEC-004/006 (0117, backend-supabase#112; 0132, #202): los inscriptos vivos de p_campania_id con '
  'su carrera y cuándo se eligió (carrera_elegida_en, para «elegida el 01/09»), el tipo de beca asignado, las '
  'dos metas copiadas (libros y monto en centavos), si la carrera tiene meta cargada para el tipo de la campaña '
  '(meta_configurada) y meta_recalculada_en: cuándo una corrección de carrera dejó a la inscripción con la meta '
  'que tiene (null si nunca, o si la meta cambió después): el aviso «Carrera corregida: meta de <carrera>». No '
  'trae el avance (HU-BEC-002, sin issue todavía). Errores: 42501 sin permiso; CZ001 inexistente; BC001 terminada.';

revoke all on function public.becas_de_campania(uuid) from public, anon, authenticated, service_role;
grant execute on function public.becas_de_campania(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. La cuenta del alquiler: una sola, la que usan todos
-- ----------------------------------------------------------------------------

-- Lo que debe, lo que pagó y lo que queda a favor un colportor de UNA campaña. Una sola cuenta para
-- cuentas_de_campania(), la tabla cuenta_alquiler y la vista previa de validar un ticket.
--
--   debido      lo que esa inscripción debe pagar: el monto de la campaña; 0 si la inscripción está dada de
--               baja («Alq. de baja», 27/10); null si la campaña no cobra alquiler.
--   pagado      depósitos de ALQUILER de la campaña, validados (validado_en, 0129), sin los dados de baja.
--   por_validar los que todavía no cuentan y no fueron rechazados: sin ticket, o con el ticket pendiente.
--   debe        debido menos pagado, sin bajar de 0 (null si no cobra).
--   a_favor     lo pagado que excede lo debido (si está de baja, todo lo pagado; si la campaña no cobra, todo).
--   ultimo_pago fecha del último depósito validado.
--
-- Una fila siempre que la campaña exista; sin inscripción se trata como no dada de baja. Interna.
create function public.alquiler_calculado(p_usuario_id uuid, p_campania_id uuid)
returns table (monto bigint, debido bigint, pagado bigint, por_validar bigint, debe bigint, a_favor bigint,
               ultimo_pago timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select c.alquiler_monto,
         d.debido,
         s.pagado,
         s.por_validar,
         case when d.debido is null then null else greatest(d.debido - s.pagado, 0) end,
         greatest(s.pagado - coalesce(d.debido, 0), 0),
         s.ultimo_pago
    from public.campania c
    left join public.campania_colportor i on i.campania_id = c.id and i.usuario_id = p_usuario_id
    cross join lateral (
      select case when c.alquiler_monto is null then null
                  when i.deleted_at is not null then 0::bigint
                  else c.alquiler_monto end as debido
    ) d
    cross join lateral (
      select coalesce(sum(dep.monto) filter (where dep.validado_en is not null), 0)::bigint as pagado,
             coalesce(sum(dep.monto) filter (where dep.validado_en is null
                                               and (t.id is null or t.estado = 'PENDIENTE')), 0)::bigint
               as por_validar,
             max(dep.fecha) filter (where dep.validado_en is not null) as ultimo_pago
        from public.deposito dep
        left join public.ticket t on t.id = dep.ticket_id
       where dep.colportor_id = p_usuario_id and dep.deleted_at is null
         and dep.concepto = 'ALQUILER' and dep.campania_id = p_campania_id
    ) s
   where c.id = p_campania_id;
$$;

comment on function public.alquiler_calculado(uuid, uuid) is
  'La cuenta del alquiler de un colportor en una campaña (0132, backend-supabase#202): monto de la campaña, lo '
  'debido (0 si la inscripción está de baja, null si no cobra), pagado (depósitos validados), por validar, debe '
  '(debido menos pagado, sin bajar de 0), a favor y fecha del último pago. La usan cuentas_de_campania(), '
  'cuenta_alquiler y validacion_calculada(). Interna.';

revoke all on function public.alquiler_calculado(uuid, uuid) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. cuenta_alquiler: el saldo guardado por persona y por campaña
-- ----------------------------------------------------------------------------

create table public.cuenta_alquiler (
  id                          uuid primary key default public.uuid_generate_v7(),
  usuario_id                  uuid not null references public.usuario(id) on delete cascade,
  campania_id                 uuid not null references public.campania(id) on delete cascade,
  alquiler_monto              bigint,
  alquiler_pagado             bigint not null default 0,
  alquiler_por_validar        bigint not null default 0,
  alquiler_debe               bigint,
  alquiler_a_favor            bigint not null default 0,
  alquiler_ultimo_pago_fecha  timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  created_by                  uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at                  timestamptz,
  sync_version                bigint not null default 0,
  xmin_w                      xid8 not null default pg_current_xact_id(),
  constraint cuenta_alquiler_usuario_campania_key unique (usuario_id, campania_id),
  constraint cuenta_alquiler_cifras_check
    check (alquiler_pagado >= 0 and alquiler_por_validar >= 0 and alquiler_a_favor >= 0
           and (alquiler_debe is null or alquiler_debe >= 0))
);

create index cuenta_alquiler_campania_idx on public.cuenta_alquiler (campania_id);

comment on table public.cuenta_alquiler is
  'El saldo de alquiler de cada colportor en cada campaña en la que tiene o tuvo inscripción (0132, '
  'backend-supabase#202, «Deuda alq.», 27/10): monto de la campaña, pagado (depósitos validados), por validar, '
  'lo que debe, lo que queda a favor y la fecha del último pago. Lo escribe SOLO el servidor, en la misma '
  'transacción que cada depósito, ticket, cambio del monto o inscripción que lo mueve (refrescar_cuenta_alquiler); '
  'la cuenta es la de alquiler_calculado(), la misma de cuentas_de_campania(). Quien se da de baja debe 0 y lo '
  'pagado queda a favor. No viaja por el sync.';
comment on column public.cuenta_alquiler.alquiler_monto is
  'Lo que cobra la campaña por colportor (centavos); null si no cobra alquiler.';
comment on column public.cuenta_alquiler.alquiler_debe is
  'Lo que debe: el monto menos lo pagado, sin bajar de 0; 0 si la inscripción está dada de baja; null si la '
  'campaña no cobra.';
comment on column public.cuenta_alquiler.alquiler_a_favor is
  'Lo pagado que excede lo debido (si está de baja, todo lo pagado).';

create trigger cuenta_alquiler_auditoria_insert
  before insert on public.cuenta_alquiler
  for each row execute function public.tg_auditoria_insert();
create trigger cuenta_alquiler_auditoria_update
  before update on public.cuenta_alquiler
  for each row execute function public.tg_auditoria_update();

alter table public.cuenta_alquiler enable row level security;
revoke all on public.cuenta_alquiler from anon, authenticated;
grant select on public.cuenta_alquiler to authenticated;
grant all on public.cuenta_alquiler to service_role;

-- LEE: su dueño, el ADMIN y quien coordina ESA campaña. Sin políticas de escritura: no escribe nadie con JWT.
create policy cuenta_alquiler_select on public.cuenta_alquiler
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or ((select public.tiene_rol('COORDINADOR'))
             and exists (select 1 from public.campania c
                          where c.id = cuenta_alquiler.campania_id
                            and c.coordinador_id = (select auth.uid()))));

-- ----------------------------------------------------------------------------
-- 5. Quién la mantiene
-- ----------------------------------------------------------------------------

-- Recalcula la fila de un colportor de una campaña (p_usuario_id) o de todos los inscriptos (null). Solo escribe
-- lo que cambia. El candado por campaña va ANTES de la cuenta: con la lectura ya tomada, dos depósitos a la vez
-- guardarían una cuenta vieja; con el candado, el segundo espera al primero y recién entonces mira (cada
-- sentencia de una función volátil toma su propia foto). Interna.
create function public.refrescar_cuenta_alquiler(p_campania_id uuid, p_usuario_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('cuenta_alquiler:' || p_campania_id::text, 0));

  insert into public.cuenta_alquiler as ca
         (usuario_id, campania_id, alquiler_monto, alquiler_pagado, alquiler_por_validar, alquiler_debe,
          alquiler_a_favor, alquiler_ultimo_pago_fecha)
  select i.usuario_id, i.campania_id, a.monto, a.pagado, a.por_validar, a.debe, a.a_favor, a.ultimo_pago
    from public.campania_colportor i
    cross join lateral public.alquiler_calculado(i.usuario_id, i.campania_id) a
   where i.campania_id = p_campania_id
     and (p_usuario_id is null or i.usuario_id = p_usuario_id)
  on conflict (usuario_id, campania_id) do update
     set alquiler_monto = excluded.alquiler_monto,
         alquiler_pagado = excluded.alquiler_pagado,
         alquiler_por_validar = excluded.alquiler_por_validar,
         alquiler_debe = excluded.alquiler_debe,
         alquiler_a_favor = excluded.alquiler_a_favor,
         alquiler_ultimo_pago_fecha = excluded.alquiler_ultimo_pago_fecha
   where (ca.alquiler_monto, ca.alquiler_pagado, ca.alquiler_por_validar, ca.alquiler_debe,
          ca.alquiler_a_favor, ca.alquiler_ultimo_pago_fecha)
         is distinct from
         (excluded.alquiler_monto, excluded.alquiler_pagado, excluded.alquiler_por_validar, excluded.alquiler_debe,
          excluded.alquiler_a_favor, excluded.alquiler_ultimo_pago_fecha);
end;
$$;

comment on function public.refrescar_cuenta_alquiler(uuid, uuid) is
  'Recalcula cuenta_alquiler de un colportor de una campaña (o de todos sus inscriptos con p_usuario_id null) '
  'con alquiler_calculado() y escribe solo lo que cambia (0132). Toma un candado por campaña. La llaman los '
  'triggers de depósito, ticket, campaña e inscripción, en la transacción del cambio. Interna.';

revoke all on function public.refrescar_cuenta_alquiler(uuid, uuid) from public, anon, authenticated, service_role;

-- Un depósito de alquiler que se crea, se valida, cambia o se da de baja. Refresca el par de antes y el de
-- después (si cambió de campaña o de dueño), en orden de campaña para que dos cambios cruzados no se traben.
create function public.tg_deposito_cuenta_alquiler()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select distinct p.campania_id, p.colportor_id
      from (values (case when tg_op in ('UPDATE', 'DELETE') and old.concepto = 'ALQUILER' then old.campania_id end,
                    case when tg_op in ('UPDATE', 'DELETE') and old.concepto = 'ALQUILER' then old.colportor_id end),
                   (case when tg_op in ('INSERT', 'UPDATE') and new.concepto = 'ALQUILER' then new.campania_id end,
                    case when tg_op in ('INSERT', 'UPDATE') and new.concepto = 'ALQUILER' then new.colportor_id end))
           as p (campania_id, colportor_id)
     where p.campania_id is not null
     order by p.campania_id, p.colportor_id
  loop
    perform public.refrescar_cuenta_alquiler(r.campania_id, r.colportor_id);
  end loop;
  return null;
end;
$$;

comment on function public.tg_deposito_cuenta_alquiler() is
  'AFTER INSERT / DELETE / UPDATE (monto, concepto, campaña, dueño, ticket, validación, baja) en deposito '
  '(0132): refresca cuenta_alquiler del par (campaña, colportor) de antes y de después. La fecha no está en la '
  'lista: solo importa la de un depósito validado y ese no se edita (DP001).';

revoke all on function public.tg_deposito_cuenta_alquiler() from public, anon, authenticated, service_role;

create trigger deposito_cuenta_alquiler
  after insert or delete or update of colportor_id, monto, ticket_id, concepto, campania_id, validado_en, deleted_at
  on public.deposito
  for each row execute function public.tg_deposito_cuenta_alquiler();

-- Un ticket que cambia de estado: lo rechazado deja de estar «por validar».
create function public.tg_ticket_cuenta_alquiler()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select distinct d.campania_id, d.colportor_id
      from public.deposito d
     where d.ticket_id = new.id and d.concepto = 'ALQUILER' and d.campania_id is not null
       and d.deleted_at is null
     order by d.campania_id, d.colportor_id
  loop
    perform public.refrescar_cuenta_alquiler(r.campania_id, r.colportor_id);
  end loop;
  return null;
end;
$$;

comment on function public.tg_ticket_cuenta_alquiler() is
  'AFTER UPDATE OF estado en ticket (0132): refresca cuenta_alquiler de los depósitos de alquiler del ticket.';

revoke all on function public.tg_ticket_cuenta_alquiler() from public, anon, authenticated, service_role;

create trigger ticket_cuenta_alquiler
  after update of estado on public.ticket
  for each row
  when (old.estado is distinct from new.estado)
  execute function public.tg_ticket_cuenta_alquiler();

-- El monto del alquiler de la campaña cambia: se recalcula a todos sus inscriptos.
create function public.tg_campania_cuenta_alquiler()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.refrescar_cuenta_alquiler(new.id, null);
  return null;
end;
$$;

comment on function public.tg_campania_cuenta_alquiler() is
  'AFTER UPDATE OF alquiler_monto en campania (0132): refresca cuenta_alquiler de todos los inscriptos.';

revoke all on function public.tg_campania_cuenta_alquiler() from public, anon, authenticated, service_role;

create trigger campania_cuenta_alquiler
  after update of alquiler_monto on public.campania
  for each row
  when (old.alquiler_monto is distinct from new.alquiler_monto)
  execute function public.tg_campania_cuenta_alquiler();

-- Una inscripción que nace, se da de baja o se reactiva: aparece su fila, deja de deber o vuelve a deber.
create function public.tg_campania_colportor_cuenta_alquiler()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.refrescar_cuenta_alquiler(new.campania_id, new.usuario_id);
  return null;
end;
$$;

comment on function public.tg_campania_colportor_cuenta_alquiler() is
  'AFTER INSERT / UPDATE OF deleted_at en campania_colportor (0132): refresca cuenta_alquiler del inscripto '
  '(alta, baja: debe 0, reactivación: vuelve a deber).';

revoke all on function public.tg_campania_colportor_cuenta_alquiler()
  from public, anon, authenticated, service_role;

create trigger campania_colportor_cuenta_alquiler
  after insert or update of deleted_at on public.campania_colportor
  for each row
  execute function public.tg_campania_colportor_cuenta_alquiler();

-- Las inscripciones que ya existen: una fila por cada una, con la misma cuenta que usan los triggers.
select public.refrescar_cuenta_alquiler(c.id, null) from public.campania c;

-- ----------------------------------------------------------------------------
-- 6. La vista previa de validar un ticket usa la misma cuenta (0129)
-- ----------------------------------------------------------------------------

-- Igual que la de 0129 salvo la rama del alquiler: lo debido y lo pagado salen de alquiler_calculado(), así que
-- quien está de baja no debe nada y todo lo que se le valida queda «a favor». Misma firma: se conservan los
-- privilegios.
create or replace function public.validacion_calculada(p_ticket_id uuid, p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, diferencia bigint,
               deuda_antes bigint, deuda_despues bigint, supera_deuda bigint, a_favor_despues bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_t         public.ticket;
  v_d         public.deposito;
  v_colportor uuid;
  v_concepto  text;
  v_monto     bigint;
  v_cobros    bigint;
  v_pendiente boolean;
  v_antes     bigint;
  v_despues   bigint;
  v_alquiler  bigint;
  v_pagado    bigint;
begin
  if p_ticket_id is not null then
    select * into v_t from public.ticket t where t.id = p_ticket_id;
    select * into v_d
      from public.deposito d
     where d.ticket_id = p_ticket_id and d.deleted_at is null
     order by d.created_at, d.id
     limit 1;
    v_colportor := v_t.usuario_id;
    v_pendiente := v_t.estado = 'PENDIENTE';
  else
    select * into v_d from public.deposito d where d.id = p_deposito_id;
    v_colportor := v_d.colportor_id;
    v_pendiente := v_d.validado_en is null and v_d.deleted_at is null;
  end if;

  if v_t.id is null or v_t.tipo = 'DEPOSITO' then
    -- Un depósito (con ticket, o un retiro sin ticket): el monto es el del depósito.
    v_monto := v_d.monto;
    v_concepto := v_d.concepto;
    if v_d.id is not null then
      select coalesce(sum(c.monto), 0)::bigint into v_cobros
        from public.deposito_cobro dc
        join public.cobranza c on c.id = dc.cobranza_id
       where dc.deposito_id = v_d.id and dc.deleted_at is null
         and c.deleted_at is null and c.anulado_at is null;
    end if;
  elsif v_t.tipo = 'COBRO_TARJETA' then
    -- El cobro con tarjeta: el monto es el del ticket, y es plata de la casa editora (S66).
    v_monto := v_t.monto;
    v_concepto := 'CASA_EDITORA';
    select coalesce(sum(c.monto), 0)::bigint into v_cobros
      from public.cobranza c
     where c.ticket_id = v_t.id and c.deleted_at is null and c.anulado_at is null;
  end if;

  if v_monto is not null and v_pendiente then
    if v_concepto = 'CASA_EDITORA' then
      select cu.deuda_total into v_antes
        from public.cuenta_colportor cu
       where cu.usuario_id = v_colportor and cu.deleted_at is null;
      v_antes := coalesce(v_antes, 0);
      v_despues := v_antes - v_monto;
    elsif v_concepto = 'ALQUILER' then
      -- v_alquiler es lo DEBIDO (0132): el monto de la campaña, 0 si la inscripción está de baja, null si no cobra.
      select a.debido, a.pagado into v_alquiler, v_pagado
        from public.alquiler_calculado(v_colportor, v_d.campania_id) a;
      if v_alquiler is not null then
        v_antes := greatest(v_alquiler - v_pagado, 0);
        v_despues := v_alquiler - v_pagado - v_monto;
      end if;
    end if;
  end if;

  return query
    select v_t.id,
           v_d.id,
           v_colportor,
           v_t.tipo,
           v_concepto,
           v_d.destino,
           v_d.campania_id,
           v_t.monto,
           v_monto,
           v_cobros,
           v_monto - v_cobros,
           v_antes,
           case when v_despues is null then null else greatest(v_despues, 0) end,
           case when v_antes is null then null else greatest(v_monto - greatest(v_antes, 0), 0) end,
           case when v_despues is null then null else greatest(-v_despues, 0) end;
end;
$$;

comment on function public.validacion_calculada(uuid, uuid) is
  'Qué pasa al validar un ticket (p_ticket_id) o un retiro sin ticket (p_deposito_id): monto que se acredita, '
  'cobros vinculados y diferencia, y la deuda del concepto antes y después (casa editora: deuda_total; alquiler: '
  'lo debido de la campaña del depósito según alquiler_calculado(), 0132: quien está de baja no debe nada). Ya '
  'validado, las cifras de la deuda son null. Sin permisos: interna (0129).';

-- ----------------------------------------------------------------------------
-- 7. cuentas_de_campania: el alquiler por la cuenta única y la columna «a favor»
-- ----------------------------------------------------------------------------

-- Igual que la de 0129 salvo el alquiler: sale de alquiler_calculado() (quien está de baja debe 0 y lo pagado
-- queda a favor) y suma `alquiler_a_favor` al final. Sumar una columna de salida pide drop + create y los
-- mismos privilegios.
drop function public.cuentas_de_campania(uuid);

create function public.cuentas_de_campania(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               deuda_total bigint, dinero_depositado bigint, dinero_en_mano bigint,
               dinero_por_cobrar bigint,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint,
               alquiler_monto bigint, alquiler_pagado bigint, alquiler_por_validar bigint,
               alquiler_debe bigint, alquiler_ultimo_pago_fecha timestamptz, alquiler_a_favor bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee; lo demás es lo de siempre.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus cuentas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select i.usuario_id,
           usr.nombre,
           usr.apellido,
           (i.deleted_at is not null),
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           case when vg.vigente then coalesce(cu.deuda_total, 0) end,
           case when vg.vigente then coalesce(cu.dinero_depositado, 0) end,
           case when vg.vigente then coalesce(cu.dinero_en_mano, 0) end,
           case when vg.vigente then coalesce(cu.dinero_por_cobrar, 0) end,
           ult.fecha,
           ult.monto,
           alq.monto,
           alq.pagado,
           alq.por_validar,
           alq.debe,
           alq.ultimo_pago,
           alq.a_favor
      from public.campania_colportor i
      join public.usuario usr on usr.id = i.usuario_id
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
      left join public.cuenta_colportor cu
             on cu.usuario_id = i.usuario_id and cu.deleted_at is null
      -- ¿Esta es la campaña vigente del colportor hoy? (la ventana de su inscripción, 0113). Las cuatro cifras
      -- no tienen campaña: solo se muestran a quien coordina la campaña en la que el colportor está ahora.
      cross join lateral (
        select (public.campania_del_ticket(i.usuario_id, now()) = p_campania_id) as vigente
      ) vg
      left join lateral (
        select d.fecha, d.monto
          from public.deposito d
         where d.colportor_id = i.usuario_id and d.deleted_at is null
           and d.concepto = 'CASA_EDITORA'
           -- Solo los de ESTA campaña: el que lleva campania_id, o el que no la lleva y su fecha cae en la
           -- ventana de esta inscripción (campania_del_ticket, 0113). Lo que el colportor hace en otra campaña
           -- no se le muestra a este coordinador.
           and coalesce(d.campania_id, public.campania_del_ticket(d.colportor_id, d.fecha)) = p_campania_id
         order by d.fecha desc, d.id
         limit 1
      ) ult on true
      -- El alquiler de ESTA campaña, por la cuenta única (quien está de baja debe 0; lo pagado queda a favor).
      cross join lateral public.alquiler_calculado(i.usuario_id, p_campania_id) alq
     where i.campania_id = p_campania_id
     order by ciu.nombre nulls last, usr.apellido, usr.nombre, i.usuario_id;
end;
$$;

comment on function public.cuentas_de_campania(uuid) is
  'Vista 36, HU-CTA-005 y HU-CTA-007 (0114, backend-supabase#111; 0129, #110; 0132, #202): una fila por colportor '
  'de la campaña con su ciudad (la de su zona actual), las cuatro cifras de su cuenta (cuenta_colportor, 0 si no '
  'tiene fila), el último depósito de casa editora y el alquiler de ESTA campaña aparte: monto, pagado '
  '(depósitos validados), por validar, lo que debe, la fecha del último pago y lo que queda a favor. Quien está '
  'de baja debe 0 y todo lo pagado queda a favor; si no, el a favor es pagado menos monto cuando es positivo. '
  'Ni clientes ni personas visitadas. Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña '
  'terminada se lee.';

revoke all on function public.cuentas_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.cuentas_de_campania(uuid) to authenticated;
