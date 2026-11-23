-- ============================================================================
-- 0203 · Anular un cobro desde el panel: el detalle de «Otro» lo guarda el servidor y lo lee solo la
--        coordinación, y la anulación baja al teléfono con quién la hizo
--        (backend-supabase#306, seguimiento de front-coordinadores-web#81, HU-COB-006, vista 39)
-- ============================================================================
-- Caso 1: Marta, coordinadora, anula desde el panel un cobro de Ana con «Otro» y escribe «Cobré de más a otra persona».
-- Ese texto queda en el servidor y lo leen ella, los demás coordinadores de la campaña y la administración. Ana no lo ve:
-- ni en su teléfono, ni en el pull, ni en la fila que le devuelve el servidor al subir algo.
--
-- Caso 2: la misma anulación llega al teléfono de Ana con la sincronización: el cobro marcado como anulado, con la fecha,
-- el motivo de la lista y quién lo anuló, para que su saldo cierre. El motivo de la lista baja; el detalle de «Otro», no.
--
-- Decisiones de Cristian del 23/11 («Otro panel» y «Anul. al tel»), comentario de front-coordinadores-web#81.
--
-- ## Qué cambia
--
--   1. `anular_cobro(p_cobranza_id, p_motivo, p_detalle default null)` (reemplaza a la de dos argumentos: se suelta y se
--      crea la nueva; los privilegios son los mismos). El detalle es opcional, obligatorio con «Otro» y de hasta 200
--      caracteres visibles (se recortan los espacios y saltos de línea de los extremos; en blanco cuenta como ausente).
--      22023 si falta con «Otro» o pasa de 200, con un aviso que dice qué hacer. Se guarda en la tabla nueva (punto 2) en la
--      misma transacción que la anulación: si la anulación falla (pasaron las 72 h, CB001), no queda ningún detalle. Un
--      cobro que ya estaba anulado devuelve `ya_estaba` y no se toca (ni el detalle).
--   2. Tabla nueva `cobranza_anulacion_detalle` (una fila por cobro anulado con detalle; mismo molde que
--      `jornada_acompaniamiento`, 0133): INTERNA. La escribe SOLO el servidor (`anular_cobro`); la lee, por RLS, el ADMIN y
--      el coordinador (el de la campaña de la colportora, como `anular_cobro`, o el que lo escribió); ni anon ni la
--      colportora, tampoco la dueña del cobro. NO está en `sync.entidad`: no viaja por el sync. Se eligió una tabla aparte
--      y no una columna de `cobranza` porque `cobranza` baja al teléfono con TODAS sus columnas (`sync.expresion_json`) y la
--      dueña la lee por su RLS: una columna se le escaparía.
--   3. `cobranza.anulado_por` (uuid, FK a `usuario`, opcional): quién anuló el cobro. Lo fija el servidor al anular, con la
--      persona de la sesión (la colportora desde su teléfono, el coordinador o el ADMIN desde `anular_cobro`); no lo manda
--      el teléfono (`sync.entidad.columnas_servidor` de `cobranza`) ni se cambia después (trigger
--      `cobranza_anulado_por`). Sin sesión (service_role, migraciones) queda lo que se escriba. Los cobros anulados antes de
--      esta migración quedan con `anulado_por` null (no se sabe, y no se inventa): ninguna fila se toca, así que ningún
--      teléfono vuelve a bajar nada por esto.
--   4. La anulación baja al teléfono: no hace falta ningún cambio del servidor para eso. `cobranza` ya se puede pedir en el
--      pull, la RLS de `cobranza` ya deja ver solo los cobros de las ventas propias (0001 §10.4) y el UPDATE de
--      `anular_cobro` sube `sync_version` y `xmin_w`, así que el delta lo lleva. Lo que baja es lo que ya había
--      (`anulado_at`, `motivo_anulacion`, que son los de la lista) más `anulado_por`. Solo suma: no cambia quién ve qué. Lo
--      prueba `supabase/tests/0203_..._pull_test.sql`. Hay que actualizar el contrato §2 (la fila de `cobranza` pasa a
--      push + pull; antes era solo push) y el esquema: lo dice el cuerpo del PR (PR de docs desde `main`).
--
-- ## Los datos
--
-- Se suma una columna opcional y una tabla vacía: ninguna fila existente cambia, ningún `sync_version` ni `xmin_w` se mueve.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#81 (#201): manda `p_detalle` con «Otro» (y el aviso de no poner datos del cliente), y lo lee de
--     `cobranza_anulacion_detalle` por el Data API (la RLS lo deja a la coordinación).
--   · front-colportores-mobile#756: pide `cobranza` en el pull y muestra el cobro anulado con su motivo; `anulado_por` es un
--     id de usuario.
--   · docs-organizacion: `contrato-sync-engine.md` §2 (fila de `cobranza`: push + alsoPull, nueva columna), `esquema-datos.md`
--     (`cobranza.anulado_por`, tabla `cobranza_anulacion_detalle`) y HU-COB-006.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Quién anuló el cobro
-- ----------------------------------------------------------------------------

alter table public.cobranza
  add column anulado_por uuid references public.usuario(id) on delete set null;

-- Sin anulación no hay quién la hizo (al revés no: los cobros anulados de antes no tienen a quién nombrar).
alter table public.cobranza
  add constraint cobranza_anulado_por_con_anulacion
    check (anulado_por is null or anulado_at is not null);

comment on column public.cobranza.anulado_por is
  'Quién anuló el cobro (0203, #306): la persona de la sesión que lo anuló (la colportora desde su teléfono, el '
  'coordinador o el ADMIN desde anular_cobro). La fija el servidor, no se cambia después y baja al teléfono con el '
  'pull. Null en los cobros anulados antes de la 0203 y cuando anuló el servidor sin sesión.';

create or replace function public.tg_cobranza_anulado_por()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Sin anulación no hay anulador.
  if new.anulado_at is null then
    new.anulado_por := null;
    return new;
  end if;

  -- Sin sesión (service_role, migraciones, el editor SQL) queda lo que se escriba.
  if auth.uid() is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.anulado_at is not null then
    -- Ya estaba anulado: quien la anuló no cambia (un reintento del push del mismo valor es idempotente; cambiarla
    -- lo frena CB003 en tg_cobranza_anulacion).
    new.anulado_por := old.anulado_por;
  else
    -- La anulación nueva (un cobro que nace anulado o uno vivo que pasa a anulado): la hace quien tiene la sesión,
    -- diga lo que diga el payload.
    new.anulado_por := auth.uid();
  end if;
  return new;
end;
$$;

comment on function public.tg_cobranza_anulado_por() is
  'BEFORE INSERT / UPDATE de cobranza (0203, #306): fija anulado_por con la persona de la sesión al anular, no lo '
  'cambia después y lo deja null si el cobro no está anulado. Sin sesión no toca nada.';

revoke all on function public.tg_cobranza_anulado_por() from public, anon, authenticated;

create trigger cobranza_anulado_por
  before insert or update on public.cobranza
  for each row execute function public.tg_cobranza_anulado_por();

-- El teléfono no lo manda: se descarta del payload en silencio (contrato §5.4).
update sync.entidad
   set columnas_servidor = columnas_servidor || array['anulado_por']
 where nombre = 'cobranza'
   and not ('anulado_por' = any (columnas_servidor));

-- ----------------------------------------------------------------------------
-- 2. El detalle de «Otro»: interno de la coordinación
-- ----------------------------------------------------------------------------

create table public.cobranza_anulacion_detalle (
  id            uuid primary key default public.uuid_generate_v7(),
  cobranza_id   uuid not null references public.cobranza(id) on delete cascade,
  detalle       text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint cobranza_anulacion_detalle_cobranza_key unique (cobranza_id),
  -- «Caracteres visibles»: sin espacios ni saltos de línea en los extremos (la RPC los recorta) y hasta 200 caracteres
  -- (char_length cuenta caracteres, no bytes).
  constraint cobranza_anulacion_detalle_forma
    check (detalle ~ '^\S(.*\S)?$' and char_length(detalle) <= 200)
);

comment on table public.cobranza_anulacion_detalle is
  'Lo que escribió quien anuló un cobro con «Otro» desde el panel (0203, backend-supabase#306, decisión de Cristian del '
  '23/11 «Otro panel»): INTERNO, lo leen el ADMIN y los coordinadores; la colportora dueña del cobro no. Una fila por cobro '
  'anulado con detalle. Lo escribe SOLO el servidor (anular_cobro). No viaja por el sync.';
comment on column public.cobranza_anulacion_detalle.detalle is
  'Texto libre de hasta 200 caracteres, sin datos del cliente (lo dice el aviso del panel): contra la Ley 18.331 no se '
  'guarda nada que nombre a una persona.';

create trigger cobranza_anulacion_detalle_auditoria_insert
  before insert on public.cobranza_anulacion_detalle
  for each row execute function public.tg_auditoria_insert();
create trigger cobranza_anulacion_detalle_auditoria_update
  before update on public.cobranza_anulacion_detalle
  for each row execute function public.tg_auditoria_update();

alter table public.cobranza_anulacion_detalle enable row level security;
revoke all on public.cobranza_anulacion_detalle from anon, authenticated;
grant select on public.cobranza_anulacion_detalle to authenticated;
grant all on public.cobranza_anulacion_detalle to service_role;

-- Quién puede leer el detalle de un cobro: el ADMIN, y el coordinador que lo escribió o que coordina una campaña con la
-- colportora de la venta inscripta (la misma regla de `anular_cobro`). SECURITY DEFINER porque el coordinador no lee
-- `cobranza` ni `venta` por RLS. Usa auth.uid() y no recibe al usuario; un cobro inexistente y uno ajeno dan lo mismo.
create function public.puede_leer_el_detalle_de_anulacion(p_cobranza_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and (exists (select 1
                         from public.cobranza_anulacion_detalle d
                        where d.cobranza_id = p_cobranza_id
                          and d.created_by = auth.uid())
               or exists (select 1
                            from public.cobranza c
                            join public.venta v on v.id = c.venta_id
                            join public.campania_colportor cc on cc.usuario_id = v.colportor_id
                            join public.campania ca on ca.id = cc.campania_id
                           where c.id = p_cobranza_id
                             and cc.deleted_at is null
                             and ca.deleted_at is null
                             and public.coordina_la_campania(ca.id))))
$$;

comment on function public.puede_leer_el_detalle_de_anulacion(uuid) is
  'Interna de la RLS de cobranza_anulacion_detalle (0203, #306): si quien llama es ADMIN, o coordinador que escribió el '
  'detalle o que coordina una campaña con la colportora de la venta del cobro inscripta. Un cobro que no existe o es ajeno '
  'da false.';

revoke all on function public.puede_leer_el_detalle_de_anulacion(uuid) from public, anon, authenticated, service_role;
grant execute on function public.puede_leer_el_detalle_de_anulacion(uuid) to authenticated;

-- LEE: el ADMIN y la coordinación. Sin políticas de escritura: no escribe nadie con JWT.
create policy cobranza_anulacion_detalle_select on public.cobranza_anulacion_detalle
  for select to authenticated
  using ((select public.puede_leer_el_detalle_de_anulacion(cobranza_id)));

-- ----------------------------------------------------------------------------
-- 3. anular_cobro con el detalle
-- ----------------------------------------------------------------------------

-- Cambia la firma (suma p_detalle): se suelta la de dos argumentos y se crea la nueva. Cuerpo de la 0175 más el detalle.
drop function public.anular_cobro(uuid, text);

create function public.anular_cobro(p_cobranza_id uuid, p_motivo text, p_detalle text default null)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_cobro     public.cobranza;
  v_es_admin  boolean := public.tiene_rol('ADMIN');
  v_detalle   text;
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    raise exception using
      errcode = '42501',
      message = 'Solo un coordinador o un administrador puede anular un cobro. Entrá con tu cuenta de coordinador.';
  end if;

  if p_motivo is null or p_motivo not in ('Monto equivocado', 'Cliente equivocado', 'Lo registré dos veces', 'Otro') then
    raise exception using
      errcode = '22023',
      message = 'Elegí el motivo de la anulación: Monto equivocado, Cliente equivocado, Lo registré dos veces u Otro.';
  end if;

  -- El detalle: sin espacios ni saltos de línea en los extremos; en blanco es como no haberlo escrito.
  v_detalle := nullif(regexp_replace(coalesce(p_detalle, ''), '^\s+|\s+$', '', 'g'), '');
  if v_detalle is null and p_motivo = 'Otro' then
    raise exception using
      errcode = '22023',
      message = 'Con «Otro», contá qué pasó: escribí el detalle del motivo (hasta 200 caracteres). No pongas datos del cliente.';
  end if;
  if char_length(v_detalle) > 200 then
    raise exception using
      errcode = '22023',
      message = format('El detalle del motivo tiene %s caracteres y el máximo es 200. Acortalo.', char_length(v_detalle));
  end if;

  -- Un cobro que no existe, que está dado de baja o que no es de un colportor de su campaña da el mismo
  -- error: no se averigua qué cobros hay.
  select c.* into v_cobro
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
   where c.id = p_cobranza_id
     and c.deleted_at is null
     and (v_es_admin
          or exists (select 1
                       from public.campania_colportor cc
                       join public.campania ca on ca.id = cc.campania_id
                      where cc.usuario_id = v.colportor_id
                        and cc.deleted_at is null
                        and ca.deleted_at is null
                        and public.coordina_la_campania(ca.id)))
     for update of c;
  if not found then
    raise exception using
      errcode = 'CB004',
      message = 'No encontramos ese cobro entre los de tu equipo.';
  end if;

  if v_cobro.anulado_at is not null then
    return jsonb_build_object(
      'cobranza_id', v_cobro.id, 'anulado_at', v_cobro.anulado_at,
      'motivo', v_cobro.motivo_anulacion, 'ya_estaba', true);
  end if;

  update public.cobranza
     set anulado_at = now(), motivo_anulacion = p_motivo
   where id = v_cobro.id
  returning anulado_at into v_cobro.anulado_at;

  -- Después de anular: si la anulación falla (CB001), no queda ningún detalle.
  if v_detalle is not null then
    insert into public.cobranza_anulacion_detalle (cobranza_id, detalle)
    values (v_cobro.id, v_detalle);
  end if;

  return jsonb_build_object(
    'cobranza_id', v_cobro.id, 'anulado_at', v_cobro.anulado_at, 'motivo', p_motivo, 'ya_estaba', false);
end;
$$;

comment on function public.anular_cobro(uuid, text, text) is
  'La anulación del coordinador (0072, decisión de Cristian del 23/10, «Anular 72 h»; 0203, #306, «Otro panel»): ADMIN o el '
  'coordinador de una campaña con el colportor de la venta inscripto. Motivo de la lista (22023); detalle opcional, obligatorio '
  'con «Otro», hasta 200 caracteres (22023): se guarda en cobranza_anulacion_detalle, que lee solo la coordinación y no baja '
  'al teléfono; dentro de las 72 h desde el cobro (CB001); CB004 si el cobro no existe, está de baja o no es de su equipo; '
  'idempotente (ya_estaba). Devuelve {cobranza_id, anulado_at, motivo, ya_estaba}.';

revoke all on function public.anular_cobro(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.anular_cobro(uuid, text, text) to authenticated;
