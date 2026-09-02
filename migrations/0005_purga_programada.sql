-- Que la purga del cache ocurra de verdad.
--
-- `sync.purgar_cache()` existe desde 0001 pero no la llamaba nadie: el TTL de
-- 24 h del §4 estaba documentado y no ejecutado. Medido con los números de
-- RP-01 —150 colportores, ~140 registros por día— el cache pasa de **5 MB en
-- régimen a 945 MB en una temporada**. Y no es solo disco: la búsqueda del
-- `client_op_id` es lo primero que hace cada job de cada push, así que el
-- índice degradado se paga en cada sincronización.

do $$
begin
  -- Se pregunta si la extensión está disponible antes de crearla: un
  -- `create extension if not exists` igual falla si no está instalada en el
  -- sistema, y eso frenaría el despliegue en cualquier Postgres que no sea
  -- Supabase.
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning
      'pg_cron no está disponible: agendá `select sync.purgar_cache();` a '
      'diario por fuera (cron del host, timer de systemd, job del proveedor), '
      'o el cache crece sin límite (~945 MB en una temporada).';
    return;
  end if;

  create extension if not exists pg_cron;

  -- Idempotente: reaplicar la migración no duplica el job.
  perform cron.unschedule('sync-purgar-op-cache')
  where exists (select 1 from cron.job where jobname = 'sync-purgar-op-cache');

  perform cron.schedule(
    'sync-purgar-op-cache',
    '17 4 * * *',   -- 4:17 UTC: de madrugada en Argentina, lejos de la jornada
    $cmd$ select sync.purgar_cache(); $cmd$
  );
end;
$$;
