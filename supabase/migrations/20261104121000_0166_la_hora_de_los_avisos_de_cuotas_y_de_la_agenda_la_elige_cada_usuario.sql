-- ============================================================================
-- 0166 · La hora de los avisos de cuotas y de la agenda la elige cada usuario
--        (backend-supabase#242, seguimiento de #237; decisión de Cristian del 04/11, «Hora avisos»;
--        la pantalla es front-colportores-mobile#516)
--
-- El caso: Diego recibe «Tenés una cuota por cobrar» y «Mañana tenés visitas», que manda el servidor solo.
-- Hasta la 0163 salían a horas fijas para todos (09:00 y 20:00 de Montevideo). Cristian decidió que cada
-- usuario elige a qué hora, en Configuración › Notificaciones.
--
-- ## Dónde vive la hora
--
-- En `usuario.notif_preferences` (jsonb, sin datos personales; HU-NOT-004): el objeto que guarda la pantalla
-- de notificaciones, con los interruptores y estas dos horas. Las dos claves que lee el servidor:
--
--     hora_cuota    "HH:MM" (24 h, hora de Montevideo)   por defecto 09:00   «Tenés una cuota por cobrar»
--     hora_agenda   "HH:MM" (24 h, hora de Montevideo)   por defecto 20:00   «Mañana tenés visitas»
--
-- Si falta la clave (o la columna es null), vale el valor por defecto. Cualquier otra clave del objeto es de
-- la app (los interruptores) y el servidor no la mira. Lo que no tiene esa forma se rechaza con `23514`.
--
-- ## Quién la escribe
--
-- Misma regla que el token (0165, ADR-013): por una función, no por PATCH. `guardar_mis_preferencias_de_avisos`
-- recibe el objeto ENTERO (reemplaza el anterior; `null` vuelve a los valores por defecto) y lo guarda en la
-- fila de quien llama. Un PATCH a la fila no la cambia: un trigger descarta el cambio sin error.
--
-- ## Cómo sale el aviso a la hora de cada uno
--
-- Los trabajos de pg_cron pasan a correr cada 15 minutos (antes, una vez al día), y cada pasada anota el
-- aviso de quien YA pasó su hora y no lo recibió:
--
--   · Cuota pendiente: la cita de cobranza que cumple 3 días el día de la última vez que fue la hora de esa
--     colportora (hoy a esa hora, o ayer si todavía no llegó). Una vez por cita (clave `cuota_pendiente:<agenda_id>`): quien cambia
--     la hora después de recibirla no la recibe de nuevo. Si la pasada de ese día no corrió (la base estuvo
--     caída), la recupera hasta que pasen 24 horas de su hora; después no.
--   · Agenda de mañana: el aviso de las citas de mañana, desde la hora de hoy de esa colportora y hasta 4 horas
--     después, sin pasar la medianoche (pasada, el «mañana» ya es hoy: no sale y el aviso vence ahí). Una hora
--     posterior a las 23:45 sale en la última pasada del día, a las 23:45. Una por colportora y día de la agenda
--     (clave `agenda_manana:<colportora>:<día>`, la misma de la 0163).
--
-- Las funciones reciben el instante «ahora» como argumento (por defecto `now()`): así se prueban a cualquier
-- hora y el trabajo programado las llama sin argumentos.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La columna
-- ----------------------------------------------------------------------------

alter table public.usuario
  add column notif_preferences jsonb;

alter table public.usuario
  add constraint usuario_notif_preferences_forma
    check (notif_preferences is null
           or (jsonb_typeof(notif_preferences) = 'object'
               and length(notif_preferences::text) <= 4096
               and ((notif_preferences -> 'hora_cuota') is null
                    or (jsonb_typeof(notif_preferences -> 'hora_cuota') = 'string'
                        and (notif_preferences ->> 'hora_cuota') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'))
               and ((notif_preferences -> 'hora_agenda') is null
                    or (jsonb_typeof(notif_preferences -> 'hora_agenda') = 'string'
                        and (notif_preferences ->> 'hora_agenda') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'))));

comment on column public.usuario.notif_preferences is
  'Preferencias de notificaciones del usuario (0166, HU-NOT-004): un objeto json sin datos personales, de hasta 4096 '
  'caracteres. El servidor lee hora_cuota y hora_agenda ("HH:MM", hora de Montevideo; por defecto 09:00 y 20:00); el '
  'resto de las claves es de la app. null = todo por defecto. Se guarda con guardar_mis_preferencias_de_avisos().';

-- ----------------------------------------------------------------------------
-- 2. Se guarda con una función; el PATCH no la cambia
-- ----------------------------------------------------------------------------

create function public.guardar_mis_preferencias_de_avisos(p_preferencias jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Iniciá sesión para guardar tus preferencias de avisos.' using errcode = '42501';
  end if;

  update public.usuario u
     set notif_preferences = p_preferencias
   where u.id = (select auth.uid())
     and u.deleted_at is null
     and u.notif_preferences is distinct from p_preferencias;
end;
$$;

comment on function public.guardar_mis_preferencias_de_avisos(jsonb) is
  'Guarda en usuario.notif_preferences de quien llama (auth.uid()) el objeto ENTERO que arma la pantalla de '
  'notificaciones; null vuelve a los valores por defecto (0166). Sin sesión: 42501. Forma inválida (no es un objeto, '
  'hora_cuota u hora_agenda que no son "HH:MM", más de 4096 caracteres): 23514.';

revoke all on function public.guardar_mis_preferencias_de_avisos(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.guardar_mis_preferencias_de_avisos(jsonb) to authenticated;

create function public.tg_usuario_notif_preferences_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.notif_preferences is distinct from old.notif_preferences
     and current_user in ('authenticated', 'anon') then
    new.notif_preferences := old.notif_preferences;
  end if;
  return new;
end;
$$;

comment on function public.tg_usuario_notif_preferences_servidor() is
  'BEFORE UPDATE de usuario: descarta un cambio de notif_preferences hecho por authenticated o anon (se guardan con '
  'guardar_mis_preferencias_de_avisos(), 0166, ADR-013).';

revoke all on function public.tg_usuario_notif_preferences_servidor() from public, anon, authenticated, service_role;

create trigger usuario_notif_preferences_servidor
  before update on public.usuario
  for each row execute function public.tg_usuario_notif_preferences_servidor();

-- ----------------------------------------------------------------------------
-- 3. La última vez que fue la hora de alguien
-- ----------------------------------------------------------------------------

-- La hora de pared de Montevideo (timestamp sin zona) de la última vez que el reloj marcó p_hora: hoy a esa
-- hora si ya llegó, ayer si todavía no. Uruguay no tiene horario de verano (UTC-3 todo el año).
create function push.ultima_hora_de_aviso(p_ahora timestamptz, p_hora time)
returns timestamp
language sql
stable
set search_path = ''
as $$
  select case
           when (p_ahora at time zone 'America/Montevideo')::time >= p_hora
             then (p_ahora at time zone 'America/Montevideo')::date + p_hora
           else (p_ahora at time zone 'America/Montevideo')::date - 1 + p_hora
         end;
$$;

comment on function push.ultima_hora_de_aviso(timestamptz, time) is
  'La última vez (hora de pared de Montevideo) que el reloj marcó p_hora: hoy si ya pasó, ayer si no (0166).';

revoke all on function push.ultima_hora_de_aviso(timestamptz, time) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Las dos tareas, ahora a la hora de cada uno
-- ----------------------------------------------------------------------------

drop function push.encolar_cuotas_pendientes(date);
drop function push.encolar_agenda_manana(date);

create function push.encolar_cuotas_pendientes(p_ahora timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hoy    date := (p_ahora at time zone 'America/Montevideo')::date;
  v_nuevos integer;
begin
  with citas as (
    select a.id, a.colportor_id
      from public.agenda a
      join public.usuario u on u.id = a.colportor_id and u.deleted_at is null
     where a.tipo = 'COBRANZA'
       and a.estado = 'PROGRAMADA'
       and a.deleted_at is null
       -- Rango ancho, para el índice: el día de referencia es hoy o ayer según la hora de cada una, y la cita
       -- cumple 3 días hace ese día (hoy-3 o hoy-4).
       and a.fecha_programada >= ((v_hoy - 4)::timestamp at time zone 'America/Montevideo')
       and a.fecha_programada <  ((v_hoy - 2)::timestamp at time zone 'America/Montevideo')
       -- El día exacto: hace 3 días respecto del día en que fue la última hora de cuotas de esta usuaria.
       and (a.fecha_programada at time zone 'America/Montevideo')::date =
           push.ultima_hora_de_aviso(p_ahora, coalesce((u.notif_preferences ->> 'hora_cuota')::time, time '09:00'))::date - 3
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

comment on function push.encolar_cuotas_pendientes(timestamptz) is
  'Anota cuota_pendiente (con agenda_id) por cada cita de COBRANZA programada que cumple 3 días hace el día en que '
  'fue la última hora_cuota de su colportora (por defecto 09:00, Montevideo) y cuya venta aún tiene saldo; una vez '
  'por cita. Devuelve cuántos anotó. La corre pg_cron cada 15 minutos (push-cuotas-pendientes, 0166).';

revoke all on function push.encolar_cuotas_pendientes(timestamptz) from public, anon, authenticated, service_role;

create function push.encolar_agenda_manana(p_ahora timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_local  timestamp := p_ahora at time zone 'America/Montevideo';
  v_hoy    date := (p_ahora at time zone 'America/Montevideo')::date;
  v_nuevos integer;
begin
  with colportoras as (
    select distinct a.colportor_id,
           -- Desde cuándo sale su aviso de hoy. La última pasada del día es a las 23:45: una hora posterior sale en
           -- esa (si no, nunca saldría).
           (v_hoy + least(coalesce((u.notif_preferences ->> 'hora_agenda')::time, time '20:00'), time '23:45')) as desde
      from public.agenda a
      join public.usuario u on u.id = a.colportor_id and u.deleted_at is null
     where a.estado = 'PROGRAMADA'
       and a.deleted_at is null
       and a.fecha_programada >= ((v_hoy + 1)::timestamp at time zone 'America/Montevideo')
       and a.fecha_programada <  ((v_hoy + 2)::timestamp at time zone 'America/Montevideo')
  ), nuevos as (
    insert into push.evento (usuario_id, tipo, entidad_id, clave, vence_en)
    select c.colportor_id, 'agenda_manana', null, 'agenda_manana:' || c.colportor_id || ':' || (v_hoy + 1),
           -- 4 horas desde su hora, y nunca pasada la medianoche: ahí el «mañana» ya es hoy.
           least(c.desde + interval '4 hours', (v_hoy + 1)::timestamp) at time zone 'America/Montevideo'
      from colportoras c
     where v_local >= c.desde
       and v_local <  least(c.desde + interval '4 hours', (v_hoy + 1)::timestamp)
    on conflict (clave) do nothing
    returning 1
  )
  select count(*)::integer into v_nuevos from nuevos;
  return v_nuevos;
end;
$$;

comment on function push.encolar_agenda_manana(timestamptz) is
  'Anota agenda_manana (sin id de entidad) por cada colportora con al menos una cita programada mañana (Montevideo), '
  'desde su hora_agenda de hoy (por defecto 20:00; una hora posterior a 23:45 sale a las 23:45) y hasta 4 horas '
  'después o la medianoche; una por colportora y día, vigente hasta ese límite. Devuelve cuántas anotó. La corre '
  'pg_cron cada 15 minutos (push-agenda-manana, 0166).';

revoke all on function push.encolar_agenda_manana(timestamptz) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. pg_cron: cada 15 minutos
-- ----------------------------------------------------------------------------

-- Mismo patrón de la 0163: idempotente, y si pg_cron no está se avisa en vez de frenar el despliegue.
do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning
      'pg_cron no está disponible: agendá `push.encolar_cuotas_pendientes()` y `push.encolar_agenda_manana()` '
      'cada 15 minutos por fuera, o los avisos de cuotas y de la agenda no salen.';
    return;
  end if;

  create extension if not exists pg_cron;

  perform cron.unschedule(j.jobname)
     from cron.job j
    where j.jobname in ('push-cuotas-pendientes', 'push-agenda-manana');

  perform cron.schedule('push-cuotas-pendientes', '*/15 * * * *', $cmd$ select push.encolar_cuotas_pendientes(); $cmd$);
  perform cron.schedule('push-agenda-manana', '*/15 * * * *', $cmd$ select push.encolar_agenda_manana(); $cmd$);
end
$cron$;
