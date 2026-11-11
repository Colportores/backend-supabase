-- ============================================================================
-- 0134 · Las fotos de los tickets van a Cloudflare R2: los permisos salen de la base y la foto vencida se suelta
--        sola (backend-supabase#182, HU-COB-007 y HU-COB-009, RF-CO08A; decisión de Cristian del 27/10,
--        «Foto cifrada» y «Borrar foto»).
--
-- Qué cambia respecto de la 0113:
--   · La foto ya no vive en el bucket `tickets` de Supabase Storage sino en un bucket PRIVADO de Cloudflare R2.
--     El teléfono y el panel no hablan con R2: le piden un enlace firmado que vence en minutos a la Edge Function
--     `foto-ticket` (supabase/functions/foto-ticket), que corre con la sesión de quien pide y es la única que tiene
--     las claves de R2 (secretos de la función, nunca en el código ni en los logs).
--   · Los permisos NO los decide la función: los decide la base, con la sesión de quien pregunta. Las dos
--     funciones de abajo son la regla de lo que antes eran las políticas de `storage.objects`:
--       - `ruta_para_ver_foto_de_ticket(ticket)`: lo que permitía `tickets_ver` (la dueña, el ADMIN y quien coordina
--         la campaña del ticket: la misma regla de `ticket_select`, que es INVOKER y manda la RLS) y la ruta que
--         guarda `ticket.url_cloud`.
--       - `ruta_para_subir_foto_de_ticket(ticket, extensión)`: lo que permitía `tickets_subir_propia` (cada
--         colportora sube a su carpeta `<usuario_id>/<ticket_id>.<ext>`; la carpeta sale de `auth.uid()`, no del pedido).
--   · La foto se borra a los 4 meses por una regla de ciclo de vida del bucket de R2 (sin tarea propia que borre
--     archivos). Lo que sí hace falta es que la BASE deje de apuntar a la foto vencida: `soltar_fotos_vencidas()`
--     corre a diario (pg_cron) y deja el ticket sin ruta con `soltar_foto_de_ticket()` (0113), sin tocar los datos
--     del ticket. Mientras no corra, las dos funciones de arriba ya dan la foto por vencida por la fecha (FT003).
--   · El bucket `tickets` de Supabase deja de usarse: se quitan sus dos políticas, así que ni subir ni ver. No se
--     migran archivos (datos simulados hasta diciembre). La fila del bucket queda vacía y privada; borrarla es
--     manual desde el panel de Supabase, porque un DELETE por SQL no borra archivos.
--
-- Errores propios (SQLSTATE; el mensaje le dice a la persona qué pasó y qué hacer):
--   FT001 el ticket no existe o no es suyo para ver (no se distingue: no se averigua qué tickets existen);
--   FT002 el ticket todavía no tiene foto;
--   FT003 la foto ya venció (4 meses desde que se subió el ticket);
--   42501 sin sesión; 22023 un argumento que no es de la API.
--
-- Qué no hace: no crea el bucket de R2 ni sus claves (las crea Cristian), no migra archivos y no cambia ninguna
-- columna ni la regla del push (`url_cloud` sigue guardando `<usuario_id>/<ticket_id>.<ext>`: la misma ruta es la
-- clave del objeto en R2).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Cuándo vence una foto: una sola definición
-- ----------------------------------------------------------------------------

-- Vence a los 4 meses calendario desde que se subió el ticket (RF-CO08A); justo a los 4 meses ya venció. STABLE y no
-- IMMUTABLE: sumar meses a un timestamptz depende de la zona horaria de la sesión.
create function public.foto_de_ticket_vencida(p_subido_en timestamptz, p_ahora timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(p_subido_en <= p_ahora - interval '4 months', false);
$$;

comment on function public.foto_de_ticket_vencida(timestamptz, timestamptz) is
  'true si la foto de un ticket subido en p_subido_en ya pasó los 4 meses (RF-CO08A) a la hora p_ahora. Es la única '
  'definición del plazo: la usan tickets_con_foto_vencida y las dos funciones de la foto (0134).';

revoke all on function public.foto_de_ticket_vencida(timestamptz, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.foto_de_ticket_vencida(timestamptz, timestamptz) to authenticated, service_role;

-- Misma firma y mismas columnas que en la 0113; solo cambia de dónde sale el plazo.
create or replace function public.tickets_con_foto_vencida(p_ahora timestamptz default now())
returns table (ticket_id uuid, ruta text)
language sql
stable
set search_path = ''
as $$
  select t.id, t.url_cloud
    from public.ticket t
   where t.url_cloud is not null
     and public.foto_de_ticket_vencida(t.subido_en, p_ahora)
   order by t.subido_en, t.id;
$$;

comment on function public.tickets_con_foto_vencida(timestamptz) is
  'Tickets con foto subidos hace 4 meses o más (0113, RF-CO08A; el plazo, de foto_de_ticket_vencida, 0134): id y ruta. '
  'Solo service_role. La foto en R2 la borra la regla de ciclo de vida del bucket; soltar_foto_de_ticket() libera la ruta.';

-- ----------------------------------------------------------------------------
-- 2. Ver la foto: la ruta del objeto, si quien pregunta puede verla
-- ----------------------------------------------------------------------------

-- SECURITY INVOKER a propósito: el `select` sobre `ticket` pasa por `ticket_select` (la dueña, el ADMIN y el
-- coordinador de la campaña del ticket, 0113 y 0131), que es el permiso de la foto. Un ticket que la RLS esconde y
-- uno que no existe dan el mismo error. La función de borde (Edge Function) llama esto con el JWT de quien pide.
create function public.ruta_para_ver_foto_de_ticket(p_ticket_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_ruta   text;
  v_subido timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Tu sesión terminó. Iniciá sesión de nuevo para ver la foto del ticket.'
      using errcode = '42501';
  end if;

  select t.url_cloud, t.subido_en
    into v_ruta, v_subido
    from public.ticket t
   where t.id = p_ticket_id;
  if not found then
    raise exception 'No encontramos ese ticket o no tenés permiso para ver su foto.'
      using errcode = 'FT001';
  end if;

  -- Vencida primero: pasado el plazo la ruta ya puede estar suelta (null) y el aviso útil es «venció», no «no tiene».
  if public.foto_de_ticket_vencida(v_subido) then
    raise exception 'La foto de este ticket ya venció: se guarda 4 meses. Los datos del ticket siguen en el historial.'
      using errcode = 'FT003';
  end if;
  if v_ruta is null then
    raise exception 'Este ticket todavía no tiene foto. Si ya la sacó la colportora, aparece cuando su teléfono termine de subirla.'
      using errcode = 'FT002';
  end if;
  return v_ruta;
end;
$$;

comment on function public.ruta_para_ver_foto_de_ticket(uuid) is
  'La ruta (clave del objeto en R2) de la foto de un ticket, si quien llama lo ve por ticket_select: la dueña, el ADMIN o '
  'el coordinador de la campaña del ticket. SECURITY INVOKER: manda la RLS. FT001 no existe o no lo ve, FT003 venció, '
  'FT002 sin foto, 42501 sin sesión. La usa la Edge Function foto-ticket para firmar el enlace (0134).';

revoke all on function public.ruta_para_ver_foto_de_ticket(uuid) from public, anon, authenticated, service_role;
grant execute on function public.ruta_para_ver_foto_de_ticket(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Subir la foto: la ruta a la que sube quien llama
-- ----------------------------------------------------------------------------

-- La carpeta es la de quien llama (auth.uid()): nadie sube a la carpeta de otra, que era lo que cuidaba
-- `tickets_subir_propia`. Subir no exige que el ticket ya exista (el motor puede subir la foto antes o después del
-- ticket); si existe y es suyo y su foto ya venció, no hay nada que subir (FT003).
create function public.ruta_para_subir_foto_de_ticket(p_ticket_id uuid, p_extension text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_subido timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Tu sesión terminó. Iniciá sesión de nuevo para subir la foto del ticket.'
      using errcode = '42501';
  end if;
  if p_ticket_id is null or p_extension is null or p_extension not in ('jpg', 'png', 'webp') then
    raise exception 'La foto del ticket tiene que ser una imagen JPG, PNG o WebP.'
      using errcode = '22023';
  end if;

  select t.subido_en
    into v_subido
    from public.ticket t
   where t.id = p_ticket_id
     and t.usuario_id = auth.uid();
  if found and public.foto_de_ticket_vencida(v_subido) then
    raise exception 'La foto de este ticket ya venció: se guarda 4 meses. No hace falta subirla.'
      using errcode = 'FT003';
  end if;

  return auth.uid()::text || '/' || p_ticket_id::text || '.' || p_extension;
end;
$$;

comment on function public.ruta_para_subir_foto_de_ticket(uuid, text) is
  'La ruta <usuario_id>/<ticket_id>.<jpg|png|webp> a la que quien llama sube la foto de su ticket (la carpeta sale de '
  'auth.uid()). FT003 si el ticket suyo ya pasó los 4 meses, 22023 extensión o ticket inválidos, 42501 sin sesión. '
  'La usa la Edge Function foto-ticket para firmar el enlace de subida (0134).';

revoke all on function public.ruta_para_subir_foto_de_ticket(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.ruta_para_subir_foto_de_ticket(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. La base deja de apuntar a la foto vencida (a diario)
-- ----------------------------------------------------------------------------

-- Suelta la ruta de cada ticket con la foto vencida y devuelve cuántas soltó. El archivo en R2 lo borra la regla del
-- bucket: acá no hay nada que borrar. DEFINER porque la corre pg_cron, no un usuario; no recibe nada de afuera.
create function public.soltar_fotos_vencidas(p_ahora timestamptz default now())
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_soltadas integer := 0;
  r          record;
begin
  for r in select f.ticket_id from public.tickets_con_foto_vencida(p_ahora) f loop
    if public.soltar_foto_de_ticket(r.ticket_id) then
      v_soltadas := v_soltadas + 1;
    end if;
  end loop;
  return v_soltadas;
end;
$$;

comment on function public.soltar_fotos_vencidas(timestamptz) is
  'Deja sin ruta (url_cloud = null) a cada ticket con la foto vencida y devuelve cuántos: los datos del ticket no se '
  'tocan. La corre pg_cron a diario (tickets-soltar-fotos-vencidas); el archivo en R2 lo borra la regla de ciclo de '
  'vida del bucket. Solo service_role (0134).';

revoke all on function public.soltar_fotos_vencidas(timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.soltar_fotos_vencidas(timestamptz) to service_role;

-- Agendada en la misma migración (patrón de la 0002 §12): una regla documentada y no ejecutada es una foto que sigue
-- apuntada. 4:47 UTC, de madrugada en Uruguay y lejos de las purgas del sync (4:17 y 4:32). Idempotente.
do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning
      'pg_cron no está disponible: agendá `select public.soltar_fotos_vencidas();` a diario por fuera, o los tickets siguen apuntando a fotos vencidas.';
    return;
  end if;

  create extension if not exists pg_cron;

  perform cron.unschedule('tickets-soltar-fotos-vencidas')
   where exists (select 1 from cron.job where jobname = 'tickets-soltar-fotos-vencidas');
  perform cron.schedule('tickets-soltar-fotos-vencidas', '47 4 * * *',
                        $cmd$ select public.soltar_fotos_vencidas(); $cmd$);
end
$cron$;

-- ----------------------------------------------------------------------------
-- 5. El bucket `tickets` de Supabase deja de usarse
-- ----------------------------------------------------------------------------

-- Sin las dos políticas de la 0113, `storage.objects` no deja subir ni ver nada de ese bucket (RLS activa y ninguna
-- política que lo nombre). Donde no existe el servicio Storage (el job `migraciones` de CI) no hay nada que quitar.
do $storage$
begin
  if to_regclass('storage.objects') is null then
    raise notice '0134: no existe storage.objects (la base no tiene el servicio Storage); no hay politicas del bucket tickets que quitar.';
    return;
  end if;

  drop policy if exists tickets_subir_propia on storage.objects;
  drop policy if exists tickets_ver on storage.objects;
end
$storage$;
