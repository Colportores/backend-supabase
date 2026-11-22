-- ============================================================================
-- 0162 · La cola de avisos push y los disparadores de los eventos
--        (backend-supabase#237, HU-NOT-003, ADR-014; payload: decisión del agente de decisiones del 03/11,
--        P2 de front-colportores-mobile#187)
--
-- El caso: la coordinadora le valida un ticket a Ana. Ana tiene la app cerrada y se entera por un aviso
-- del teléfono, sin abrirla. Hasta hoy el servidor no mandaba ninguno.
--
-- ## Cómo funciona (de punta a punta)
--
--   1. Un hecho de la base (un pedido que pasa a AUTORIZADO, un ticket que se valida o se rechaza, una
--      cuenta que pasa de PENDIENTE_ASIGNACION a ACTIVA) anota UN aviso en `push.evento`, en la misma
--      transacción: o queda el hecho con su aviso, o ninguno de los dos. Los avisos que no nacen de un
--      hecho de una fila (la cita de cobranza vencida y la agenda de mañana) los anotan dos tareas
--      programadas (0163).
--   2. `pg_cron` despierta a la Edge Function `push-fcm` cada minuto si hay avisos listos (0163). La
--      función llama a `public.push_tomar_pendientes()`, manda cada aviso a la FCM HTTP v1 API y le cuenta
--      a la base cómo salió con `public.push_resultado()`. Un token que FCM rechaza como inválido se
--      borra de `usuario.fcm_token` y no se reintenta.
--
--   La cola existe para que ningún aviso se pierda ni salga dos veces: si FCM está caído, el aviso espera
--   y se reintenta con espera creciente; si la función se cae a mitad de camino, el aviso reservado
--   vuelve a la cola a los 2 minutos; si el mismo hecho dispara dos veces, el aviso es uno solo.
--
-- ## Qué viaja al teléfono (decisión del 03/11, P2 de mobile#187)
--
--   Solo el tipo, el `event_id` y UUIDs de entidades. Todos los valores son texto (FCM manda `data` como
--   texto). Sin nombres, montos ni direcciones (R-NO02): el teléfono arma el texto leyendo su base.
--
--     pedido_autorizado    {type, event_id, pedido_id}
--     ticket_validado      {type, event_id, ticket_id}
--     ticket_rechazado     {type, event_id, ticket_id}
--     asignacion_campania  {type, event_id, campania_id[, zona_id]}   zona_id solo si la inscripción ya tiene zona
--     cuota_pendiente      {type, event_id, agenda_id}                (0163)
--     agenda_manana        {type, event_id}                           (0163)
--
--   `event_id` es el id del aviso en `push.evento`: es el mismo en cada reintento, así la app no muestra
--   dos veces el mismo aviso (HU-NOT-003, idempotencia).
--
-- ## Los disparadores
--
--   · `pedido_casa_editora.estado` pasa a AUTORIZADO (o nace AUTORIZADO) → `pedido_autorizado` a la
--     colportora del pedido. Sale a los 15 segundos y no antes, por el «Deshacer» de 8 segundos de la
--     bandeja (0112): si el coordinador se arrepiente, el aviso se descarta («YA_NO_APLICA») y la
--     colportora no se entera de algo que no pasó.
--   · `ticket.estado` pasa de PENDIENTE a VALIDADO / RECHAZADO → `ticket_validado` / `ticket_rechazado` a la
--     dueña del ticket. Una validación no se deshace, así que sale enseguida.
--   · `campania_colportor`: una inscripción viva (nueva, o reactivada después de una baja) en una campaña
--     que no terminó, en una cuenta que NO tenía otra inscripción así → `asignacion_campania` (la cuenta
--     pasa de PENDIENTE_ASIGNACION a ACTIVA, HU-AUTH-008; desde la 0102 cuenta una campaña por empezar).
--     Una cuenta que ya estaba ACTIVA y se suma a otra campaña no recibe aviso (no es ese paso), y una
--     suspendida tampoco.
--   · El aviso al coordinador por un colportor nuevo en su zona va dentro del panel, no por push (ADR-014).
--
-- ## Cuándo un aviso no sale (queda `DESCARTADO`, con su motivo)
--
--   SIN_TOKEN (la cuenta no guardó token), CUENTA_NO_ACTIVA (suspendida o dada de baja), YA_NO_APLICA
--   (el pedido ya no está autorizado, la inscripción se dio de baja, la cita ya no está programada),
--   VENCIDO (esperó más de su vigencia: un día; la agenda de mañana, cuatro horas), TOKEN_INVALIDO (FCM
--   lo rechazó), RECHAZADO_POR_FCM (FCM rechazó el mensaje por otra razón, sin sentido de reintentar) y
--   AGOTADO (6 intentos sin respuesta de FCM).
--
-- ## Quién toca qué
--
--   · `push` es un schema cerrado (como `sync` y `auditoria`): ni anon ni authenticated lo ven. La
--     Data API no lo expone.
--   · `push_tomar_pendientes()` y `push_resultado()` son las dos únicas RPC y solo las ejecuta
--     `service_role` (la clave de servicio que ya tiene la Edge Function en su entorno).
--   · El aviso no se copia a `audit_log`: es un reflejo de hechos que ya se auditan (validar un ticket,
--     autorizar un pedido); el token y el aviso son del servidor.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El schema, cerrado a los clientes
-- ----------------------------------------------------------------------------

create schema push;

comment on schema push is
  'La cola de avisos push (backend-supabase#237, HU-NOT-003, ADR-014): push.evento y las funciones que la '
  'llenan. Fuera de la API y sin acceso para anon ni authenticated; la lee la Edge Function push-fcm por '
  'public.push_tomar_pendientes() y public.push_resultado().';

revoke all on schema push from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. La cola
-- ----------------------------------------------------------------------------

create table push.evento (
  -- El `event_id` que viaja al teléfono: el mismo en todos los reintentos.
  id              uuid primary key default public.uuid_generate_v7(),
  usuario_id      uuid not null references public.usuario (id) on delete cascade,
  tipo            text not null,
  -- El pedido, el ticket, la campaña o la cita del aviso. Null solo en `agenda_manana`.
  entidad_id      uuid,
  -- Lo que impide que el mismo hecho anote dos avisos (ver push.encolar).
  clave           text not null,
  estado          text not null default 'PENDIENTE',
  motivo_descarte text,
  -- Código corto de FCM (UNAVAILABLE, UNREGISTERED…) del último intento; nunca texto libre.
  ultimo_error    text,
  intentos        integer not null default 0,
  creado_en       timestamptz not null default now(),
  -- No sale antes de esta hora (el «Deshacer» del pedido; el reintento con espera).
  enviar_desde    timestamptz not null default now(),
  -- No se manda después de esta hora: un aviso viejo miente («mañana» ya es hoy).
  vence_en        timestamptz not null default now() + interval '1 day',
  -- La Edge Function lo tiene reservado hasta esta hora; si no contó el resultado, vuelve a la cola.
  reservado_hasta timestamptz,
  enviado_en      timestamptz,
  constraint evento_clave_unica unique (clave),
  constraint evento_tipo_check check (tipo in (
    'pedido_autorizado', 'ticket_validado', 'ticket_rechazado', 'asignacion_campania',
    'cuota_pendiente', 'agenda_manana')),
  constraint evento_entidad_check check ((tipo = 'agenda_manana') = (entidad_id is null)),
  constraint evento_estado_check check (estado in ('PENDIENTE', 'ENVIADO', 'DESCARTADO')),
  constraint evento_motivo_check check (
    (estado = 'DESCARTADO') = (motivo_descarte is not null)
    and (motivo_descarte is null or motivo_descarte in (
      'SIN_TOKEN', 'CUENTA_NO_ACTIVA', 'YA_NO_APLICA', 'VENCIDO', 'TOKEN_INVALIDO',
      'RECHAZADO_POR_FCM', 'AGOTADO'))),
  constraint evento_enviado_check check ((estado = 'ENVIADO') = (enviado_en is not null)),
  constraint evento_error_forma check (ultimo_error is null or ultimo_error ~ '^[A-Z][A-Z0-9_]{0,39}$'),
  constraint evento_intentos_check check (intentos >= 0)
);

comment on table push.evento is
  'Cola de avisos push (0162): un aviso por hecho (clave única), con su estado, sus intentos y la hora desde '
  'la que puede salir. Solo ids; ningún dato personal. La lee y la actualiza la Edge Function push-fcm.';

-- Lo que mira la función en cada despertar: los pendientes que ya pueden salir.
create index evento_pendientes_idx on push.evento (enviar_desde, id) where estado = 'PENDIENTE';
-- Para purgar y para mirar los avisos de una cuenta.
create index evento_usuario_idx on push.evento (usuario_id);
create index evento_creado_idx on push.evento (creado_en);

alter table push.evento enable row level security;
revoke all on push.evento from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Anotar un aviso
-- ----------------------------------------------------------------------------

-- Anota un aviso. Si ya hay uno con esa `clave` no hace nada, salvo que haya quedado descartado por
-- YA_NO_APLICA y el hecho se repita (un pedido autorizado, deshecho y autorizado de nuevo): ahí lo
-- reabre para que salga. Un aviso ya enviado, o descartado por otra razón, no se reabre: el mismo
-- hecho no se avisa dos veces.
create function push.encolar(
  p_usuario  uuid,
  p_tipo     text,
  p_entidad  uuid,
  p_clave    text,
  p_demora   interval default interval '0 seconds',
  p_vigencia interval default interval '1 day')
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into push.evento as e (usuario_id, tipo, entidad_id, clave, enviar_desde, vence_en)
  values (p_usuario, p_tipo, p_entidad, p_clave, now() + p_demora, now() + p_demora + p_vigencia)
  on conflict (clave) do update
     set estado = 'PENDIENTE',
         motivo_descarte = null,
         intentos = 0,
         ultimo_error = null,
         creado_en = now(),
         enviar_desde = excluded.enviar_desde,
         vence_en = excluded.vence_en,
         reservado_hasta = null
   where e.estado = 'DESCARTADO' and e.motivo_descarte = 'YA_NO_APLICA';
end;
$$;

comment on function push.encolar(uuid, text, uuid, text, interval, interval) is
  'Anota un aviso push (0162). Idempotente por clave: el mismo hecho no anota dos avisos; solo reabre uno '
  'descartado por YA_NO_APLICA. p_demora: no sale antes; p_vigencia: no sale después de demora + vigencia.';

revoke all on function push.encolar(uuid, text, uuid, text, interval, interval)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Lo que viaja: el payload de cada aviso
-- ----------------------------------------------------------------------------

-- Solo el tipo, el event_id y UUIDs, todo como texto. El zona_id de la asignación se lee al momento de
-- mandar: si la coordinadora le asignó la zona entre el alta y el envío, ya sale con ella.
create function push.datos_del_aviso(p_evento push.evento)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('type', p_evento.tipo, 'event_id', p_evento.id::text)
         || case p_evento.tipo
              when 'pedido_autorizado' then jsonb_build_object('pedido_id', p_evento.entidad_id::text)
              when 'ticket_validado'   then jsonb_build_object('ticket_id', p_evento.entidad_id::text)
              when 'ticket_rechazado'  then jsonb_build_object('ticket_id', p_evento.entidad_id::text)
              when 'cuota_pendiente'   then jsonb_build_object('agenda_id', p_evento.entidad_id::text)
              when 'asignacion_campania' then
                jsonb_build_object('campania_id', p_evento.entidad_id::text)
                || coalesce(
                     (select jsonb_build_object('zona_id', cc.zona_id::text)
                        from public.campania_colportor cc
                       where cc.usuario_id = p_evento.usuario_id
                         and cc.campania_id = p_evento.entidad_id
                         and cc.deleted_at is null
                         and cc.zona_id is not null),
                     '{}'::jsonb)
              else '{}'::jsonb
            end;
$$;

comment on function push.datos_del_aviso(push.evento) is
  'El payload de un aviso (0162): type, event_id y los *_id, todos texto. Sin nombres, montos ni direcciones '
  '(R-NO02). Contrato en la HU-NOT-003 y en supabase/functions/push-fcm/README.md.';

revoke all on function push.datos_del_aviso(push.evento) from public, anon, authenticated, service_role;

-- ¿El hecho que motivó el aviso sigue siendo verdad al momento de mandarlo?
create function push.sigue_vigente(p_tipo text, p_entidad uuid, p_usuario uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_tipo
           when 'pedido_autorizado' then exists (
             select 1 from public.pedido_casa_editora p
              where p.id = p_entidad and p.deleted_at is null
                and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO'))
           when 'asignacion_campania' then exists (
             select 1 from public.campania_colportor cc
              where cc.usuario_id = p_usuario and cc.campania_id = p_entidad and cc.deleted_at is null)
           when 'cuota_pendiente' then exists (
             select 1 from public.agenda a
              where a.id = p_entidad and a.deleted_at is null and a.estado = 'PROGRAMADA')
           else true
         end;
$$;

comment on function push.sigue_vigente(text, uuid, uuid) is
  'Si el hecho de un aviso sigue valiendo al mandarlo (0162): pedido todavía autorizado, inscripción viva, '
  'cita todavía programada. Evita avisar de algo que se deshizo o se resolvió en el medio.';

revoke all on function push.sigue_vigente(text, uuid, uuid) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. Los disparadores
-- ----------------------------------------------------------------------------

-- Pedido autorizado. 15 segundos de demora: el «Deshacer» de la bandeja dura 8 (0112).
create function push.tg_pedido_autorizado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.estado = 'AUTORIZADO' and new.deleted_at is null
     and (tg_op = 'INSERT' or old.estado is distinct from 'AUTORIZADO') then
    perform push.encolar(new.colportor_id, 'pedido_autorizado', new.id,
                         'pedido_autorizado:' || new.id, interval '15 seconds');
  end if;
  return null;
end;
$$;

comment on function push.tg_pedido_autorizado() is
  'AFTER de pedido_casa_editora: el pedido pasa a AUTORIZADO → aviso pedido_autorizado a la colportora, a '
  'los 15 s (0162). Solo inserta en la cola, en la misma transacción del cambio.';

revoke all on function push.tg_pedido_autorizado() from public, anon, authenticated, service_role;

create trigger pedido_push_autorizado
  after insert or update of estado on public.pedido_casa_editora
  for each row execute function push.tg_pedido_autorizado();

-- Ticket revisado por el coordinador.
create function push.tg_ticket_revisado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.estado = 'PENDIENTE' and new.estado in ('VALIDADO', 'RECHAZADO') and new.deleted_at is null then
    perform push.encolar(new.usuario_id,
                         case new.estado when 'VALIDADO' then 'ticket_validado' else 'ticket_rechazado' end,
                         new.id, 'ticket:' || new.id);
  end if;
  return null;
end;
$$;

comment on function push.tg_ticket_revisado() is
  'AFTER UPDATE de ticket.estado: de PENDIENTE a VALIDADO o RECHAZADO → aviso ticket_validado / '
  'ticket_rechazado a la dueña del ticket (0162).';

revoke all on function push.tg_ticket_revisado() from public, anon, authenticated, service_role;

create trigger ticket_push_revisado
  after update of estado on public.ticket
  for each row
  when (old.estado is distinct from new.estado)
  execute function push.tg_ticket_revisado();

-- La cuenta pasa de PENDIENTE_ASIGNACION a ACTIVA.
create function push.tg_asignacion_campania()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Solo una inscripción viva que NACE o que se REACTIVA (de baja a viva).
  if new.deleted_at is not null or (tg_op = 'UPDATE' and old.deleted_at is null) then
    return null;
  end if;

  -- La campaña tiene que estar viva y no haber terminado; si no, la cuenta no pasa a ACTIVA por esta fila.
  if not exists (select 1 from public.inscripciones_no_terminadas_de(new.usuario_id) i
                  where i.campania_id = new.campania_id) then
    return null;
  end if;

  -- Si ya tenía otra inscripción así, la cuenta ya estaba ACTIVA: no es el paso que se avisa.
  if exists (select 1 from public.inscripciones_no_terminadas_de(new.usuario_id) i
              where i.campania_id <> new.campania_id) then
    return null;
  end if;

  -- Una cuenta suspendida es SUSPENDIDA, no ACTIVA (HU-AUTH-008).
  if exists (select 1 from public.usuario u where u.id = new.usuario_id and u.suspendido_en is not null) then
    return null;
  end if;

  -- La clave lleva la hora de la transacción: una inscripción que se da de baja y se reactiva es otro aviso.
  perform push.encolar(new.usuario_id, 'asignacion_campania', new.campania_id,
                       'asignacion:' || new.id || ':' || (extract(epoch from now()) * 1000000)::bigint);
  return null;
end;
$$;

comment on function push.tg_asignacion_campania() is
  'AFTER INSERT/UPDATE de campania_colportor: la primera inscripción viva en una campaña no terminada de una '
  'cuenta no suspendida (PENDIENTE_ASIGNACION → ACTIVA, HU-AUTH-008) → aviso asignacion_campania (0162).';

revoke all on function push.tg_asignacion_campania() from public, anon, authenticated, service_role;

create trigger campania_colportor_push_asignacion
  after insert or update of deleted_at on public.campania_colportor
  for each row execute function push.tg_asignacion_campania();

-- ----------------------------------------------------------------------------
-- 6. La Edge Function toma los avisos listos…
-- ----------------------------------------------------------------------------

-- Toma hasta p_max avisos (tope 200) que ya pueden salir, los RESERVA por 2 minutos y suma un intento a
-- cada uno. Los que no hay que mandar (cuenta no activa, hecho que ya no vale, sin token) se descartan acá
-- con su motivo y no se devuelven. `for update skip locked`: dos despertares a la vez no toman el mismo aviso.
create function public.push_tomar_pendientes(p_max integer default 50)
returns table (evento_id uuid, token text, datos jsonb, intento integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e      push.evento;
  v_u      public.usuario;
  v_limite integer := least(greatest(coalesce(p_max, 50), 1), 200);
begin
  update push.evento e
     set estado = 'DESCARTADO', motivo_descarte = 'VENCIDO', reservado_hasta = null
   where e.estado = 'PENDIENTE' and e.vence_en < now();

  for v_e in
    select e.*
      from push.evento e
     where e.estado = 'PENDIENTE'
       and e.enviar_desde <= now()
       and (e.reservado_hasta is null or e.reservado_hasta <= now())
     order by e.enviar_desde, e.id
     limit v_limite
       for update skip locked
  loop
    select u.* into v_u from public.usuario u where u.id = v_e.usuario_id;

    if not found or v_u.deleted_at is not null or v_u.suspendido_en is not null then
      update push.evento e set estado = 'DESCARTADO', motivo_descarte = 'CUENTA_NO_ACTIVA', reservado_hasta = null
       where e.id = v_e.id;
    elsif not push.sigue_vigente(v_e.tipo, v_e.entidad_id, v_e.usuario_id) then
      update push.evento e set estado = 'DESCARTADO', motivo_descarte = 'YA_NO_APLICA', reservado_hasta = null
       where e.id = v_e.id;
    elsif v_u.fcm_token is null then
      update push.evento e set estado = 'DESCARTADO', motivo_descarte = 'SIN_TOKEN', reservado_hasta = null
       where e.id = v_e.id;
    else
      update push.evento e
         set intentos = e.intentos + 1, reservado_hasta = now() + interval '2 minutes'
       where e.id = v_e.id;
      evento_id := v_e.id;
      token := v_u.fcm_token;
      datos := push.datos_del_aviso(v_e);
      intento := v_e.intentos + 1;
      return next;
    end if;
  end loop;
end;
$$;

comment on function public.push_tomar_pendientes(integer) is
  'Para la Edge Function push-fcm (0162): toma y reserva por 2 minutos hasta p_max (tope 200) avisos listos, '
  'con el token y el payload; descarta con su motivo los que no hay que mandar. Solo service_role.';

revoke all on function public.push_tomar_pendientes(integer) from public, anon, authenticated, service_role;
grant execute on function public.push_tomar_pendientes(integer) to service_role;

-- ----------------------------------------------------------------------------
-- 7. …y cuenta cómo salió cada uno
-- ----------------------------------------------------------------------------

-- p_resultado:
--   ENVIADO         FCM lo aceptó.
--   REINTENTAR      FCM no contestó o está caído: vuelve a la cola con espera (1, 2, 4, 8, 16 min) hasta 6
--                   intentos; después, AGOTADO.
--   TOKEN_INVALIDO  FCM dijo que el token no sirve: el aviso se descarta y el token se borra de
--                   usuario.fcm_token, SOLO si sigue siendo el mismo (si la app ya guardó uno nuevo, se queda).
--   DESCARTAR       FCM rechazó el mensaje por otra razón: no tiene sentido reintentar.
-- p_error: el código corto de FCM (UNAVAILABLE…); cualquier otra forma se guarda como null.
-- Un aviso que ya no está PENDIENTE (otro despertar lo resolvió) no se toca: devuelve false.
create function public.push_resultado(
  p_evento_id uuid,
  p_resultado text,
  p_token     text default null,
  p_error     text default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e     push.evento;
  v_error text := case when p_error ~ '^[A-Z][A-Z0-9_]{0,39}$' then p_error end;
begin
  if p_resultado is null or p_resultado not in ('ENVIADO', 'REINTENTAR', 'TOKEN_INVALIDO', 'DESCARTAR') then
    raise exception 'resultado de push desconocido'
      using errcode = '22023',
            hint = 'Los resultados son ENVIADO, REINTENTAR, TOKEN_INVALIDO y DESCARTAR.';
  end if;

  select e.* into v_e from push.evento e where e.id = p_evento_id and e.estado = 'PENDIENTE' for update;
  if not found then
    return false;
  end if;

  if p_resultado = 'ENVIADO' then
    update push.evento e
       set estado = 'ENVIADO', enviado_en = now(), reservado_hasta = null, ultimo_error = null
     where e.id = v_e.id;

  elsif p_resultado = 'TOKEN_INVALIDO' then
    update push.evento e
       set estado = 'DESCARTADO', motivo_descarte = 'TOKEN_INVALIDO', reservado_hasta = null, ultimo_error = v_error
     where e.id = v_e.id;
    if p_token is not null then
      update public.usuario u set fcm_token = null where u.id = v_e.usuario_id and u.fcm_token = p_token;
    end if;

  elsif p_resultado = 'DESCARTAR' then
    update push.evento e
       set estado = 'DESCARTADO', motivo_descarte = 'RECHAZADO_POR_FCM', reservado_hasta = null, ultimo_error = v_error
     where e.id = v_e.id;

  elsif v_e.intentos >= 6 then
    update push.evento e
       set estado = 'DESCARTADO', motivo_descarte = 'AGOTADO', reservado_hasta = null, ultimo_error = v_error
     where e.id = v_e.id;

  else
    update push.evento e
       set enviar_desde = now() + make_interval(mins => least(power(2, v_e.intentos - 1)::integer, 30)),
           reservado_hasta = null,
           ultimo_error = v_error
     where e.id = v_e.id;
  end if;
  return true;
end;
$$;

comment on function public.push_resultado(uuid, text, text, text) is
  'Para la Edge Function push-fcm (0162): cómo salió un aviso (ENVIADO, REINTENTAR con espera creciente '
  'hasta 6 intentos, TOKEN_INVALIDO que borra el token, DESCARTAR). Un aviso que ya no está PENDIENTE no se '
  'toca (false). Solo service_role.';

revoke all on function public.push_resultado(uuid, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.push_resultado(uuid, text, text, text) to service_role;
