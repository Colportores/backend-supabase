-- ============================================================================
-- 0192 · Quitar a un colportor de la campaña (backend-supabase#273, HU-CAM-005 «Remover»)
--
-- Decisión de Cristian del 11/11 («Quitar colp.»): se adelanta solo «Quitar de la campaña» en Equipo
-- (front-coordinadores-web#184), con doble confirmación en el panel. La base cierra la inscripción, su
-- jornada abierta y su cuenta de alquiler sin borrar nada, y si se lo vuelve a añadir la inscripción se
-- reactiva. «Reasignar» sigue para después del 20/11.
-- Decisión del agente de decisiones del 11/11 (convención técnica y coherencia entre pantallas, R7): la firma
-- es por campaña y usuario, como todas las escrituras del panel sobre un colportor (`inscribir_colportor`,
-- `asignar_zona`, `elegir_carrera`, `asignar_beca`); el panel no tiene el id de la inscripción.
--
-- El caso: Luis añadió por error a Ana a su campaña y quiere sacarla. Hasta hoy no había una RPC: el 11/11
-- hubo que cerrar a mano la inscripción, la cuenta de alquiler y la jornada abierta de coordinador.demo.
--
-- ## quitar_de_campania(p_campania_id, p_usuario_id)
--
-- Puede llamarla quien puede inscribir en esa campaña: un coordinador de la campaña (`campania_coordinador`,
-- 0174) o un ADMIN, con la misma regla de `inscribir_colportor()` (`motivo_campania_del_coordinador()`,
-- 0175). Toma el mismo candado por usuario que `inscribir_colportor()`, así un «Quitar» y un «Añadir» del
-- mismo colportor a la vez se ordenan, y la inscripción viva FOR UPDATE.
--
--   1. La inscripción: `campania_colportor.deleted_at = now()`. Lo demás lo hacen los triggers de siempre,
--      que valen para todo camino de baja:
--        · queda sin zona y su tramo del historial se cierra con quién lo sacó y cuándo (0022);
--        · la cuenta de alquiler se refresca (0132): debe 0, lo pagado queda «por decidir» y el coordinador
--          elige su destino en Cuentas (`decidir_alquiler_pagado`, 0159/0167). No se le pone deleted_at:
--          así se cierra sin que se pierda la plata («Alq. de baja», «Alq. baja»).
--   2. La jornada abierta (trigger nuevo, punto de abajo).
--   3. Una línea en `audit_log`: `colportor_quitado_de_campania` sobre la inscripción, con la campaña, la
--      zona que tenía y cuántas jornadas se cerraron (solo ids y números).
--   4. El estado de la cuenta: no es una columna, sale de `estado_de_cuenta()` (0015, 0102). Si no le queda
--      otra inscripción viva en una campaña que no terminó vuelve a PENDIENTE_ASIGNACION; si le queda, sigue
--      ACTIVA. La RPC devuelve cómo quedó.
--
-- Devuelve una fila: inscripcion_id, quitado_en (el deleted_at), jornadas_cerradas y estado (el de la cuenta
-- después de quitarlo).
--
-- Rechazos (todo aviso dice qué pasa y qué hacer):
--   42501  sin sesión, o no coordina la campaña ni es ADMIN (como inscribir_colportor()).
--   QC001  la campaña no existe o fue dada de baja.
--   QC002  la campaña ya terminó: lo cerrado no se toca, igual que al inscribir (CI002).
--   QC003  no está en el equipo de esta campaña o ya lo quitaron (otro coordinador, otra pestaña): el panel
--          refresca la lista.
--
-- Volver a añadirlo: `inscribir_colportor()` reactiva la misma fila, sin zona (0028), y deja el hueco de la
-- baja en `tramos_afuera` (0100); la cuenta de alquiler vuelve a deber (0132). No cambia.
--
-- ## La jornada abierta se cierra con la baja (trigger nuevo)
--
-- `campania_colportor_cierra_la_jornada`, AFTER UPDATE OF deleted_at cuando la inscripción pasa de viva a de
-- baja, por cualquier camino (esta RPC, un UPDATE del servidor o del personal): cierra las jornadas abiertas
-- (fin null, sin baja) del colportor que son de esa inscripción con `fin` = el momento de la baja. «De esa
-- inscripción» es: empezó dentro de su ventana (`inscripcion_cubre_el_instante()`, 0100: desde el alta,
-- antes de la baja, fuera de los huecos) y en un día de la campaña (de `fecha_inicio` a `fecha_fin`, o sin
-- fin). El día mira las fechas porque una inscripción en una campaña por empezar también cubre el instante:
-- sin eso, quitarlo de la de diciembre le cerraría la jornada de hoy en la de noviembre. Si la campaña
-- todavía no empezó no hay jornada que cerrar («Cuenta antes», 0102). Nada se borra.
--
-- Republicado (0011, como 0124 y 0176): el UPDATE sube `xmin_w` (el teléfono baja la jornada cerrada en el
-- próximo pull) pero NO `sync_version` ni `updated_at`. Así lo que el teléfono registró antes de la baja y
-- sube después no se rechaza por la baja: el push de esa jornada (cerrarla con su hora, sus totales) trae la
-- versión de antes y entra; con la versión subida volvería `conflict` y se perdería lo del teléfono.
-- SECURITY DEFINER: cierra la jornada de otra persona.
--
-- ## Lo que el teléfono sube después de la baja
--
-- La venta, la visita, la persona, la casa nueva y la jornada no miran la inscripción viva (0020, 0102,
-- 0115: una baja cuenta como «estuvo en la campaña»), y el ticket y el cobro buscan su campaña en la ventana
-- de alta a baja (0113). Lo que sí mira la inscripción viva es cargar un espacio o un estado en una casa
-- ajena y corregir lo ya cargado (`mis_campanias_para_escribir()`, 0020/0021): eso hoy vuelve 42501 si llega
-- después de la baja. Queda como pendiente de decisión (ver el PR); esta migración no lo cambia.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#184: `quitarDeCampania(campaniaId, colportorId)` llama con `p_campania_id` y
--     `p_usuario_id`; 42501, QC001, QC002 y QC003 a un aviso cada uno (QC003 refresca la lista).
--   · front-colportores-mobile: el pull baja la inscripción con `deleted_at` y la jornada cerrada. La
--     notificación al colportor (HU-NOT-003) se suma cuando estén las push (#614).
--   · docs-organizacion#188: HU-CAM-005 «Remover» con esta regla.
--
-- Datos: ninguno; una función, un trigger y su función.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La baja de la inscripción cierra su jornada abierta
-- ----------------------------------------------------------------------------

create function public.tg_campania_colportor_cierra_la_jornada()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_antes text := current_setting('colportores.republicar', true);
begin
  -- Republicado (0011): solo mientras dura este UPDATE.
  perform set_config('colportores.republicar', 'on', true);

  update public.jornada j
     set fin = new.deleted_at
    from public.campania c
   where c.id = new.campania_id
     and j.colportor_id = new.usuario_id
     and j.fin is null
     and j.deleted_at is null
     and public.inscripcion_cubre_el_instante(new.created_at, new.deleted_at, new.tramos_afuera, j.inicio)
     and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
     and (c.fecha_fin is null or public.hoy_montevideo(j.inicio) <= c.fecha_fin);

  perform set_config('colportores.republicar', coalesce(v_antes, 'off'), true);
  return null;
end;
$$;

comment on function public.tg_campania_colportor_cierra_la_jornada() is
  'AFTER UPDATE OF deleted_at de campania_colportor, al darla de baja (0192, HU-CAM-005): cierra con fin = el '
  'momento de la baja las jornadas abiertas del colportor que empezaron dentro de la ventana de la inscripción '
  '(inscripcion_cubre_el_instante, 0100) y en un día de la campaña. Republicado (0011): sube xmin_w, no '
  'sync_version, para que el push posterior del teléfono sobre esa jornada no vuelva conflict. Nada se borra.';

revoke all on function public.tg_campania_colportor_cierra_la_jornada()
  from public, anon, authenticated, service_role;

create trigger campania_colportor_cierra_la_jornada
  after update of deleted_at on public.campania_colportor
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.tg_campania_colportor_cierra_la_jornada();

-- ----------------------------------------------------------------------------
-- 2. quitar_de_campania()
-- ----------------------------------------------------------------------------

create function public.quitar_de_campania(p_campania_id uuid, p_usuario_id uuid)
returns table (inscripcion_id uuid, quitado_en timestamptz, jornadas_cerradas integer, estado text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_fila      public.campania_colportor;
  v_zona      uuid;
  v_cerradas  integer;
  v_estado    text;
begin
  if auth.uid() is null then
    raise exception 'Para quitar a un colportor de la campaña hay que iniciar sesión. Volvé a entrar.'
      using errcode = 'insufficient_privilege';
  end if;

  -- El mismo candado que inscribir_colportor(): «Quitar» y «Añadir» del mismo colportor se ordenan.
  perform pg_advisory_xact_lock(hashtextextended('inscribir_colportor:' || p_usuario_id::text, 0));

  case public.motivo_campania_del_coordinador(p_campania_id)
    when 'SIN_PERMISO' then
      raise exception 'Solo un coordinador de la campaña o un administrador puede quitar colportores de ella. Entrá con la cuenta de un coordinador de esta campaña.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe o fue dada de baja. Actualizá la lista de campañas.'
        using errcode = 'QC001';
    when 'CAMPANIA_NO_VIGENTE' then
      raise exception 'La campaña ya terminó y su equipo queda como está. Elegí una campaña en curso o por empezar.'
        using errcode = 'QC002';
    else
      null;
  end case;

  select * into v_fila
    from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id and cc.deleted_at is null
     for update;
  if not found then
    raise exception 'No está en el equipo de esta campaña: puede que ya lo hayan quitado. Actualizá la lista.'
      using errcode = 'QC003';
  end if;
  v_zona := v_fila.zona_id;

  -- La zona y el historial (0022), la cuenta de alquiler (0132) y la jornada abierta (arriba) los hacen los
  -- triggers de la baja.
  update public.campania_colportor cc
     set deleted_at = now()
   where cc.id = v_fila.id
  returning * into v_fila;

  -- Las que cerró el trigger: del colportor, con fin = la baja y escritas en esta transacción.
  select count(*)::integer into v_cerradas
    from public.jornada j
   where j.colportor_id = p_usuario_id
     and j.fin = v_fila.deleted_at
     and j.xmin_w = pg_current_xact_id();

  perform auditoria.registrar('colportor_quitado_de_campania', 'campania_colportor', v_fila.id, p_usuario_id,
                              jsonb_build_object('campania_id', p_campania_id, 'zona_id', v_zona,
                                                 'jornadas_cerradas', v_cerradas));

  select public.estado_de_cuenta(u.suspendido_en,
                                 exists (select 1 from public.inscripciones_no_terminadas_de(u.id)))
    into v_estado
    from public.usuario u
   where u.id = p_usuario_id;

  return query select v_fila.id, v_fila.deleted_at, v_cerradas, v_estado;
end;
$$;

comment on function public.quitar_de_campania(uuid, uuid) is
  'HU-CAM-005 «Remover» (0192, backend-supabase#273): quita a p_usuario_id del equipo de p_campania_id. Da de '
  'baja su inscripción viva (deleted_at = now(); queda sin zona y su tramo del historial se cierra, 0022), cierra '
  'su jornada abierta de esa campaña con fin = la baja (republicado, sin subir la versión), deja su cuenta de '
  'alquiler en debe 0 con lo pagado por decidir en Cuentas (0132, 0159) y registra colportor_quitado_de_campania '
  'en audit_log. Nada se borra. La puede llamar quien puede inscribir en la campaña (un coordinador de ella o un '
  'ADMIN, como inscribir_colportor()); volver a añadirlo con inscribir_colportor() reactiva la misma fila, sin '
  'zona. Devuelve inscripcion_id, quitado_en, jornadas_cerradas y estado (el de la cuenta después: '
  'PENDIENTE_ASIGNACION si no le queda otra inscripción viva en una campaña que no terminó). Errores: 42501 sin '
  'sesión o sin permiso; QC001 la campaña no existe o está dada de baja; QC002 la campaña ya terminó; QC003 no '
  'está en el equipo de la campaña o ya lo quitaron.';

revoke all on function public.quitar_de_campania(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.quitar_de_campania(uuid, uuid) to authenticated, service_role;
