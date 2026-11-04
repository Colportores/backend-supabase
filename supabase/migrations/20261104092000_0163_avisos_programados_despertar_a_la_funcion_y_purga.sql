-- ============================================================================
-- 0163 · Avisos programados, el despertar de la Edge Function y la purga de la cola
--        (backend-supabase#237, HU-NOT-003, ADR-014; continúa la 0162)
--
-- El caso: Ana tiene una cita de cobranza que lleva 3 días vencida sin que cobre, y esta noche tiene tres
-- visitas agendadas para mañana. Ningún cambio en una fila lo dice: son dos preguntas que hay que hacerle
-- a la base todos los días. Y la Edge Function que manda los avisos (`push-fcm`) tiene que despertarse sola.
--
-- ## Las dos tareas programadas (pg_cron; horas en UTC, Uruguay es UTC-3 todo el año)
--
--   · `push-cuotas-pendientes`, 12:00 UTC (09:00 en Montevideo): `push.encolar_cuotas_pendientes()`. Una
--     cita de COBRANZA de la agenda, PROGRAMADA y sin dar de baja, cuyo día (en Montevideo) fue hace
--     exactamente 3 días, y cuya venta todavía tiene saldo (la venta menos sus cobros vivos, como en AG002;
--     una cita sin venta cuenta igual), anota `cuota_pendiente` con `agenda_id` para su colportora. Una
--     vez por cita (clave `cuota_pendiente:<agenda_id>`). Cada cuota es una cita de cobranza de la agenda
--     (decisión de Cristian, «Plan cuotas»). No recupera las que se vencieron hace más de 3 días antes de
--     que corriera la tarea (el día se recibe por argumento: `push.encolar_cuotas_pendientes(<fecha>)`).
--   · `push-agenda-manana`, 23:00 UTC (20:00 en Montevideo): `push.encolar_agenda_manana()`. Anota
--     `agenda_manana`, sin id de entidad, para cada colportora que tiene al menos una cita PROGRAMADA sin dar
--     de baja mañana (cualquier tipo). Una por colportora y día. Vale 4 horas: pasada la noche el «mañana»
--     ya es hoy y el aviso se descarta (VENCIDO). La app cuenta las citas de mañana en su base.
--
--   Las horas son un supuesto de esta migración (el issue dice «job nocturno» y no fija la hora): cambiarlas
--   es cambiar la expresión de `cron.schedule`, sin tocar nada más.
--
-- ## El despertar
--
--   `push.despertar()`, cada minuto (`push-despertar`): si hay algún aviso listo para salir, le hace un POST
--   a la Edge Function por `pg_net`. Sin avisos listos no hace nada (no gasta invocaciones). Necesita dos
--   secretos en Supabase Vault, que carga una vez por ambiente quien administra el proyecto (README de la
--   función, «Puesta en marcha»):
--
--     push_fcm_url    la dirección de la función: https://<ref>.supabase.co/functions/v1/push-fcm
--     push_fcm_clave  la clave compartida que la función exige en la cabecera `x-push-clave`
--                     (el mismo valor que el secreto PUSH_CLAVE de la función)
--
--   Mientras falte `pg_net` o alguno de los dos secretos, `despertar()` avisa con un WARNING en el log y
--   devuelve false: los avisos quedan en la cola esperando (vencen al día) y nada se rompe.
--
-- ## La purga
--
--   `push-purgar`, 04:57 UTC, borra de la cola los avisos de más de 14 días (los pendientes también).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Un índice para las preguntas de las tareas
-- ----------------------------------------------------------------------------

-- Las dos tareas buscan citas programadas por día en toda la tabla; sin esto leen todas las citas viejas.
create index agenda_programada_fecha_idx on public.agenda (fecha_programada)
  where estado = 'PROGRAMADA' and deleted_at is null;

-- ----------------------------------------------------------------------------
-- 2. La cita de cobranza que lleva 3 días vencida
-- ----------------------------------------------------------------------------

create function push.encolar_cuotas_pendientes(p_hoy date default public.hoy_montevideo())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nuevos integer;
begin
  with citas as (
    select a.id, a.colportor_id
      from public.agenda a
      join public.usuario u on u.id = a.colportor_id and u.deleted_at is null
     where a.tipo = 'COBRANZA'
       and a.estado = 'PROGRAMADA'
       and a.deleted_at is null
       -- El día de la cita fue hace exactamente 3 días. El rango deja usar el índice por fecha.
       and a.fecha_programada >= ((p_hoy - 3)::timestamp at time zone 'America/Montevideo')
       and a.fecha_programada <  ((p_hoy - 2)::timestamp at time zone 'America/Montevideo')
       -- «Sin cobro»: la venta de la cuota todavía debe algo (venta menos sus cobros vivos y no anulados, como AG002).
       and (a.venta_id is null
            or exists (
              select 1
                from public.venta v
               where v.id = a.venta_id
                 and v.deleted_at is null
                 and v.monto_total > coalesce((select sum(c.monto)
                                                 from public.cobranza c
                                                where c.venta_id = v.id and c.deleted_at is null
                                                  and c.anulado_at is null), 0)))
  ), nuevos as (
    insert into push.evento (usuario_id, tipo, entidad_id, clave)
    select c.colportor_id, 'cuota_pendiente', c.id, 'cuota_pendiente:' || c.id
      from citas c
    on conflict (clave) do nothing
    returning 1
  )
  select count(*)::integer into v_nuevos from nuevos;
  return v_nuevos;
end;
$$;

comment on function push.encolar_cuotas_pendientes(date) is
  'Anota cuota_pendiente (con agenda_id) por cada cita de COBRANZA programada cuyo día en Montevideo fue hace '
  'exactamente 3 días y cuya venta aún tiene saldo; una vez por cita. Devuelve cuántos anotó. La corre '
  'pg_cron a diario (push-cuotas-pendientes, 0163).';

revoke all on function push.encolar_cuotas_pendientes(date) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. La agenda de mañana
-- ----------------------------------------------------------------------------

create function push.encolar_agenda_manana(p_hoy date default public.hoy_montevideo())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nuevos integer;
begin
  with colportoras as (
    select distinct a.colportor_id
      from public.agenda a
      join public.usuario u on u.id = a.colportor_id and u.deleted_at is null
     where a.estado = 'PROGRAMADA'
       and a.deleted_at is null
       and a.fecha_programada >= ((p_hoy + 1)::timestamp at time zone 'America/Montevideo')
       and a.fecha_programada <  ((p_hoy + 2)::timestamp at time zone 'America/Montevideo')
  ), nuevos as (
    insert into push.evento (usuario_id, tipo, entidad_id, clave, vence_en)
    select c.colportor_id, 'agenda_manana', null, 'agenda_manana:' || c.colportor_id || ':' || (p_hoy + 1),
           now() + interval '4 hours'
      from colportoras c
    on conflict (clave) do nothing
    returning 1
  )
  select count(*)::integer into v_nuevos from nuevos;
  return v_nuevos;
end;
$$;

comment on function push.encolar_agenda_manana(date) is
  'Anota agenda_manana (sin id de entidad) por cada colportora con al menos una cita programada mañana en '
  'Montevideo; una por colportora y día, vigente 4 horas. Devuelve cuántas anotó. La corre pg_cron a diario '
  '(push-agenda-manana, 0163).';

revoke all on function push.encolar_agenda_manana(date) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Despertar a la Edge Function
-- ----------------------------------------------------------------------------

-- true si hizo el pedido (pg_net lo manda al confirmar la transacción de pg_cron); false si no había nada
-- que mandar o si falta pg_net o algún secreto. La función responde sola: acá no se espera nada.
-- `net.http_post` se llama dinámicamente: en una base sin pg_net esta función igual se crea y avisa.
create function push.despertar()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url   text;
  v_clave text;
begin
  if not exists (select 1
                   from push.evento e
                  where e.estado = 'PENDIENTE'
                    and e.enviar_desde <= now()
                    and (e.reservado_hasta is null or e.reservado_hasta <= now())) then
    return false;
  end if;

  if not exists (select 1
                   from pg_catalog.pg_proc p
                   join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'net' and p.proname = 'http_post') then
    raise warning 'push.despertar: pg_net no está instalado; los avisos esperan en push.evento hasta que se active.';
    return false;
  end if;

  select s.decrypted_secret into v_url   from vault.decrypted_secrets s where s.name = 'push_fcm_url';
  select s.decrypted_secret into v_clave from vault.decrypted_secrets s where s.name = 'push_fcm_clave';
  if coalesce(v_url, '') = '' or coalesce(v_clave, '') = '' then
    raise warning 'push.despertar: faltan los secretos push_fcm_url y push_fcm_clave en Vault; los avisos esperan en push.evento.';
    return false;
  end if;

  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := $4)'
    using v_url, '{}'::jsonb,
          jsonb_build_object('Content-Type', 'application/json', 'x-push-clave', v_clave),
          5000;
  return true;
end;
$$;

comment on function push.despertar() is
  'Si hay avisos listos en push.evento, le hace un POST a la Edge Function push-fcm por pg_net con la URL y la '
  'clave de Vault (push_fcm_url, push_fcm_clave). false si no hay nada que mandar o falta pg_net o un '
  'secreto (con WARNING). La corre pg_cron cada minuto (push-despertar, 0163).';

revoke all on function push.despertar() from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. La purga
-- ----------------------------------------------------------------------------

create function push.purgar()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_borrados integer;
begin
  delete from push.evento e where e.creado_en < now() - interval '14 days';
  get diagnostics v_borrados = row_count;
  return v_borrados;
end;
$$;

comment on function push.purgar() is
  'Borra de la cola los avisos de más de 14 días, con cualquier estado (0163). La corre pg_cron a diario (push-purgar).';

revoke all on function push.purgar() from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. pg_net y pg_cron
-- ----------------------------------------------------------------------------

-- pg_net viene activado en los proyectos de Supabase; se pide acá por si no lo está. Donde no existe la
-- extensión (un Postgres pelado) la migración sigue y `push.despertar()` avisa.
do $net$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  else
    raise warning 'pg_net no está disponible: sin ella la Edge Function push-fcm no se despierta sola (push.despertar()).';
  end if;
exception when others then
  raise warning 'no se pudo activar pg_net (%): activala desde el panel de Supabase.', sqlerrm;
end
$net$;

-- Patrón de la 0002 §12 y la 0134: idempotente, y si pg_cron no está se avisa en vez de frenar el despliegue.
do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning
      'pg_cron no está disponible: agendá `select push.despertar();` (cada minuto), `push.encolar_cuotas_pendientes()`, '
      '`push.encolar_agenda_manana()` y `push.purgar()` (a diario) por fuera, o las push no salen.';
    return;
  end if;

  create extension if not exists pg_cron;

  perform cron.unschedule(j.jobname)
     from cron.job j
    where j.jobname in ('push-despertar', 'push-cuotas-pendientes', 'push-agenda-manana', 'push-purgar');

  perform cron.schedule('push-despertar', '* * * * *', $cmd$ select push.despertar(); $cmd$);
  perform cron.schedule('push-cuotas-pendientes', '0 12 * * *', $cmd$ select push.encolar_cuotas_pendientes(); $cmd$);
  perform cron.schedule('push-agenda-manana', '0 23 * * *', $cmd$ select push.encolar_agenda_manana(); $cmd$);
  perform cron.schedule('push-purgar', '57 4 * * *', $cmd$ select push.purgar(); $cmd$);
end
$cron$;
