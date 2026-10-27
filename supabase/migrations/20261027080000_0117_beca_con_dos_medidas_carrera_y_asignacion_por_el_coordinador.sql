-- ============================================================================
-- 0117 · Beca con dos medidas y asignación por el coordinador: la carrera del colportor, las metas por
--        carrera y las RPC para elegir la carrera y asignar el tipo de beca (backend-supabase#112,
--        HU-BEC-006, HU-BEC-001, vista 33 «Equipo», R-BC01, R-BC06)
--
-- Origen: decisión de Cristian del 21/10 (reunión del 05/10, docs-organizacion#69, C8): una beca tiene DOS
-- medidas, libros bonificables y monto de compra a la casa editora (CES). Y decisión de Cristian del 25/10,
-- «Carrera»: la coordinadora de la campaña elige la carrera del colportor UNA sola vez en Becas (vista 33);
-- queda guardada en su cuenta (columna opcional, sigue a la persona en la próxima campaña) y solo el ADMIN la
-- corrige. La meta se copia en la inscripción de la campaña, como dice la HU.
--
-- 0067 ya dejó en `campania_colportor` las columnas `tipo_beca` (null | MEDIA | COMPLETA), `meta_libros` y
-- `meta_monto_ces` (centavos), y el trigger que solo deja cambiar `tipo_beca`, `meta_monto_ces` y
-- `limite_pedido` al ADMIN o al coordinador de la campaña. Faltaba lo que las llena.
--
-- ## Qué suma
--
--   1. `carrera` — el catálogo de carreras (de ahí elige el coordinador, vista 33).
--   2. `meta_beca` — las metas por carrera y tipo de campaña (HU-BEC-001): libros y monto, de media beca y de
--      beca completa. Solo lo carga el servidor (service_role): el panel del Administrador está fuera de la
--      Fase 1. Los números reales llegan en diciembre (C11); esta migración no carga ninguno.
--   3. `usuario.carrera_id` — la carrera del colportor. Un cliente con JWT NO la cambia por un UPDATE directo
--      (42501): la elige el coordinador por `elegir_carrera()` y la corrige el ADMIN.
--   4. `elegir_carrera(campania, usuario, carrera)` — el coordinador de la campaña (o un ADMIN) la elige UNA vez
--      para un colportor inscripto en ella. Si ya tenía una, el coordinador no la cambia (BC005); el ADMIN sí.
--   5. `asignar_beca(campania, usuarios[], tipo)` — «media beca», «beca completa» o «sin beca» (null) para uno o
--      varios colportores a la vez, todo o nada. Copia en la inscripción las metas de `meta_beca` de la carrera
--      del colportor y del tipo de la campaña: `meta_libros` y `meta_monto_ces`.
--   6. `becas_de_campania(campania)` — lo que la tabla de Becas necesita para dibujarse: por colportor, su
--      carrera, el tipo asignado, las dos metas copiadas y si la carrera tiene meta cargada.
--   7. El trigger de 0067 pasa a cuidar también `meta_libros` (la política de UPDATE de 0003 deja a cualquier
--      coordinador tocar cualquier inscripción: la meta de la beca no queda abierta a eso).
--   8. Auditoría: `carrera_del_colportor_cambiada` (usuario) y `beca_asignada` (inscripción), por trigger: queda
--      el registro también si el ADMIN cambia la fila a mano.
--
-- ## Reglas que implementa
--
--   · Las metas se COPIAN en la inscripción al asignar: editar `meta_beca` después no cambia becas ya
--     asignadas (S50). Volver a asignar el mismo tipo re-copia las metas vigentes.
--   · «Sin beca» (tipo null) deja el tipo y las dos metas en null (R-BC06: sin tipo no se calcula meta).
--   · Una carrera sin `meta_beca` para el tipo de la campaña (VERANO / INVIERNO) no se puede asignar: BC004,
--     «Falta configurar la meta de esta carrera» y a quién avisar (criterio de HU-BEC-006).
--   · Todo o nada: si uno de los colportores no se puede, ninguno cambia y el error dice cuál es el problema
--     (BC003/BC004), sin nombres de personas.
--   · Idempotente y sin escritura de más: lo que no cambia no se toca (ni `sync_version` ni el registro de
--     auditoría), así un doble toque no ensucia nada. Las filas se toman con candado en orden de id: dos
--     asignaciones al mismo tiempo se serializan y no se pisan.
--
-- ## Lo que NO hace (y por qué)
--
--   · No calcula el avance ni el estado «media / completa alcanzada» (HU-BEC-002, HU-BEC-005, y la lectura de
--     Inicio, #145): por eso «si ya alcanzó una meta, no se le quita» no tiene qué guardar acá todavía.
--   · No manda el push al colportor cuando se le asigna o cambia el tipo (HU-NOT-003 no existe todavía).
--   · No recalcula las metas de las inscripciones cuando el ADMIN corrige la carrera: queda en un archivo de
--     pendientes (decisión de negocio).
--   · No resuelve qué meta le toca a una campaña PERMANENTE (`meta_beca.tipo_campania` es VERANO / INVIERNO
--     como dice la HU-BEC-001): se avisa con BC004. Pendiente.
--
-- ## Permisos (ante la duda se bloquea)
--
--   · `carrera` y `meta_beca`: las lee cualquier usuario autenticado (no llevan datos personales); no las
--     escribe nadie con JWT.
--   · `usuario.carrera_id`: la lee quien ya lee su fila (el propio usuario y el ADMIN). El coordinador la ve
--     por `becas_de_campania()`, de los inscriptos de SU campaña.
--
-- ## Códigos de error nuevos (BC = beca / carrera)
--
--   42501 sin permiso · CZ001 campaña inexistente · CZ003 el colportor no está en la campaña · BC001 la
--   campaña ya terminó · BC002 carrera inexistente o sin elegir · BC003 al colportor le falta la carrera ·
--   BC004 la carrera no tiene meta cargada · BC005 la carrera ya está elegida · 22023 tipo de beca o lista de
--   colportores inválidos.
--
-- ## Los datos
--
--   Tablas nuevas vacías y una columna opcional en `usuario`: ninguna fila se modifica, ningún `sync_version`
--   ni `xmin_w` cambia. `usuario` no viaja por el sync; la beca de cada colportor sí (el pull de
--   `campania_colportor` ya serializa `tipo_beca`, `meta_libros` y `meta_monto_ces`).
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. carrera y meta_beca
-- ----------------------------------------------------------------------------

create table public.carrera (
  id            uuid primary key default public.uuid_generate_v7(),
  nombre        text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint carrera_nombre_check check (nombre ~ '\S')
);

-- Dos carreras vivas no se llaman igual (sin mayúsculas ni espacios de más).
create unique index carrera_nombre_vivo_key
  on public.carrera (lower(regexp_replace(nombre, '^\s+|\s+$', '', 'g')))
  where deleted_at is null;

comment on table public.carrera is
  'Catálogo de carreras (V2, HU-BEC-001, vista 33): de acá elige el coordinador la carrera del colportor. '
  'Solo lo escribe el servidor.';

create table public.meta_beca (
  id                   uuid primary key default public.uuid_generate_v7(),
  carrera_id           uuid not null references public.carrera(id),
  tipo_campania        text not null,
  meta_media           integer not null,
  meta_completa        integer not null,
  meta_media_monto     bigint not null,
  meta_completa_monto  bigint not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at           timestamptz,
  sync_version         bigint not null default 0,
  xmin_w               xid8 not null default pg_current_xact_id(),
  constraint meta_beca_tipo_campania_check check (tipo_campania in ('VERANO', 'INVIERNO')),
  constraint meta_beca_libros_check check (meta_media >= 0 and meta_completa >= meta_media),
  constraint meta_beca_monto_check check (meta_media_monto >= 0 and meta_completa_monto >= meta_media_monto)
);

create unique index meta_beca_carrera_tipo_vivo_key
  on public.meta_beca (carrera_id, tipo_campania)
  where deleted_at is null;

comment on table public.meta_beca is
  'Metas de la beca por carrera y tipo de campaña (V2, HU-BEC-001, R-BC01): libros bonificables y monto de '
  'compra a la casa editora (centavos), de media beca y de beca completa. Son dos medidas de la MISMA beca. '
  'Solo la carga el servidor; los números reales llegan en diciembre (C11). La meta de cada colportor se '
  'COPIA en su inscripción al asignarle el tipo, así que editar acá no cambia becas ya asignadas (S50).';

do $$
declare
  t text;
begin
  foreach t in array array['carrera', 'meta_beca']
  loop
    execute format(
      'create trigger %I before insert on public.%I for each row execute function public.tg_auditoria_insert()',
      t || '_auditoria_insert', t);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.tg_auditoria_update()',
      t || '_auditoria_update', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end
$$;

create policy carrera_select on public.carrera
  for select to authenticated
  using (true);

create policy meta_beca_select on public.meta_beca
  for select to authenticated
  using (true);

-- ----------------------------------------------------------------------------
-- 2. usuario.carrera_id
-- ----------------------------------------------------------------------------

alter table public.usuario
  add column carrera_id uuid references public.carrera(id),
  add column carrera_elegida_en timestamptz;

create index usuario_carrera_idx on public.usuario (carrera_id) where carrera_id is not null;

comment on column public.usuario.carrera_id is
  'La carrera del colportor (decisión de Cristian, 25/10, «Carrera»): la elige UNA vez el coordinador de su '
  'campaña desde Becas (elegir_carrera) y solo el ADMIN la corrige. Opcional; sigue a la persona de una '
  'campaña a la siguiente. Un cliente con JWT no la cambia con un UPDATE directo (42501).';

comment on column public.usuario.carrera_elegida_en is
  'Cuándo se eligió (o se corrigió) la carrera: lo pone el trigger usuario_carrera_servidor cada vez que cambia '
  'carrera_id (null si se la quita). La vista 33 lo muestra como «elegida el 01/09» (becas_de_campania). Un '
  'cliente con JWT no la escribe (42501).';

-- Quién la cambia: el servidor, las RPC SECURITY DEFINER (corren como su dueño) y el ADMIN. Un cliente
-- (authenticated / anon) que no es ADMIN, incluido el propio colportor o un coordinador que quiera saltearse
-- la RPC, recibe 42501 en vez de un cambio ignorado en silencio. INVOKER a propósito: `current_user` tiene que
-- ser el de quien ejecuta el UPDATE (patrón de 0053 y 0100).
create function public.tg_usuario_carrera_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.carrera_id is not distinct from old.carrera_id
     and new.carrera_elegida_en is not distinct from old.carrera_elegida_en then
    return new;
  end if;

  if current_user in ('authenticated', 'anon') and not public.tiene_rol('ADMIN') then
    raise exception 'La carrera la elige el coordinador de la campaña en Becas y solo un administrador la corrige.'
      using errcode = '42501';
  end if;

  -- La fecha sigue a la carrera: se estampa en cada elección o corrección, venga de la RPC, del ADMIN o del
  -- servidor, y no se puede mandar a mano junto con el cambio de carrera.
  if new.carrera_id is distinct from old.carrera_id then
    new.carrera_elegida_en := case when new.carrera_id is null then null else now() end;
  end if;

  return new;
end;
$$;

comment on function public.tg_usuario_carrera_servidor() is
  'BEFORE UPDATE OF carrera_id, carrera_elegida_en en usuario (0117, backend-supabase#112): un cliente con JWT '
  'que no es ADMIN no cambia la carrera ni su fecha (42501); sí el servidor, las RPC elegir_carrera() y el '
  'ADMIN. Al cambiar la carrera estampa carrera_elegida_en = now().';

revoke all on function public.tg_usuario_carrera_servidor() from public, anon, authenticated;

create trigger usuario_carrera_servidor
  before update of carrera_id, carrera_elegida_en on public.usuario
  for each row execute function public.tg_usuario_carrera_servidor();

-- La carrera elegida o corregida queda en audit_log, venga de la RPC o del UPDATE del ADMIN. El detalle lleva
-- solo ids (la carrera anterior y la nueva); sobre quién, va en target_user_id.
create function public.tg_usuario_carrera_auditar()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform auditoria.registrar(
    'carrera_del_colportor_cambiada', 'usuario', new.id, new.id,
    jsonb_build_object('carrera_anterior', old.carrera_id, 'carrera_nueva', new.carrera_id));
  return null;
end;
$$;

comment on function public.tg_usuario_carrera_auditar() is
  'AFTER UPDATE OF carrera_id en usuario (0117, backend-supabase#112): deja el evento '
  'carrera_del_colportor_cambiada en audit_log con la carrera anterior y la nueva (ids).';

revoke all on function public.tg_usuario_carrera_auditar() from public, anon, authenticated, service_role;

create trigger usuario_carrera_auditar
  after update of carrera_id on public.usuario
  for each row
  when (old.carrera_id is distinct from new.carrera_id)
  execute function public.tg_usuario_carrera_auditar();

-- ----------------------------------------------------------------------------
-- 3. La inscripción: meta_libros también es del coordinador de la campaña; la beca asignada queda registrada
-- ----------------------------------------------------------------------------

-- Igual que en 0067, salvo que `meta_libros` entra en la lista de lo que solo cambian el ADMIN o el
-- coordinador de ESA campaña, y el mensaje lo dice.
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
     and new.meta_monto_ces is not distinct from old.meta_monto_ces
     and new.limite_pedido is not distinct from old.limite_pedido then
    return new;
  end if;

  if public.tiene_rol('ADMIN')
     or (public.tiene_rol('COORDINADOR')
         and exists (select 1 from public.campania c
                      where c.id = new.campania_id and c.coordinador_id = auth.uid())) then
    return new;
  end if;

  raise exception 'La beca, la meta y el límite de pedido los fija el coordinador de la campaña'
    using errcode = '42501';
end;
$$;

comment on function public.tg_campania_colportor_beca_y_limite() is
  'BEFORE UPDATE OF tipo_beca, meta_libros, meta_monto_ces, limite_pedido en campania_colportor (0067, 0117): '
  'solo el ADMIN o el coordinador de esa campaña los cambian con un JWT (42501); el servidor, sin restricción.';

drop trigger campania_colportor_beca_y_limite on public.campania_colportor;

create trigger campania_colportor_beca_y_limite
  before update of tipo_beca, meta_libros, meta_monto_ces, limite_pedido on public.campania_colportor
  for each row execute function public.tg_campania_colportor_beca_y_limite();

-- La beca asignada o cambiada queda en audit_log (HU-BEC-006: «Audit log»): el tipo anterior y el nuevo y las
-- dos metas que quedaron. Solo ids, códigos y números.
create function public.tg_campania_colportor_beca_auditar()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform auditoria.registrar(
    'beca_asignada', 'campania_colportor', new.id, new.usuario_id,
    jsonb_build_object('campania_id', new.campania_id,
                       'tipo_anterior', old.tipo_beca, 'tipo_nuevo', new.tipo_beca,
                       'meta_libros', new.meta_libros, 'meta_monto_ces', new.meta_monto_ces));
  return null;
end;
$$;

comment on function public.tg_campania_colportor_beca_auditar() is
  'AFTER UPDATE OF tipo_beca, meta_libros, meta_monto_ces en campania_colportor (0117, backend-supabase#112): '
  'deja el evento beca_asignada en audit_log con el tipo anterior y el nuevo y las metas que quedaron.';

revoke all on function public.tg_campania_colportor_beca_auditar() from public, anon, authenticated, service_role;

create trigger campania_colportor_beca_auditar
  after update of tipo_beca, meta_libros, meta_monto_ces on public.campania_colportor
  for each row
  when (old.tipo_beca is distinct from new.tipo_beca
        or old.meta_libros is distinct from new.meta_libros
        or old.meta_monto_ces is distinct from new.meta_monto_ces)
  execute function public.tg_campania_colportor_beca_auditar();

-- ----------------------------------------------------------------------------
-- 4. El permiso común de las tres RPC
-- ----------------------------------------------------------------------------

-- 42501 si no hay sesión o quien llama no es ADMIN ni el coordinador de la campaña; CZ001 si la campaña no
-- existe; BC001 si ya terminó (en curso o por empezar sí, igual que las zonas, 0058). Interna: SECURITY
-- DEFINER para no depender de la RLS de lo que mira.
create function public.exigir_coordinador_de_campania_para_beca(p_campania_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);

  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver y asignar sus becas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  elsif v_motivo = 'CAMPANIA_INEXISTENTE' then
    raise exception 'La campaña no existe. Elegí otra campaña.' using errcode = 'CZ001';
  elsif v_motivo = 'CAMPANIA_NO_VIGENTE' then
    raise exception 'La campaña ya terminó y sus becas quedan como estaban. Elegí una campaña en curso o por empezar.'
      using errcode = 'BC001';
  end if;
end;
$$;

comment on function public.exigir_coordinador_de_campania_para_beca(uuid) is
  'Interna (0117): 42501 sin sesión o sin ser ADMIN ni el coordinador de p_campania_id; CZ001 si no existe; '
  'BC001 si ya terminó (una por empezar sí). La usan elegir_carrera(), asignar_beca() y becas_de_campania().';

revoke all on function public.exigir_coordinador_de_campania_para_beca(uuid)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. elegir_carrera
-- ----------------------------------------------------------------------------

create function public.elegir_carrera(p_campania_id uuid, p_usuario_id uuid, p_carrera_id uuid)
returns table (usuario_id uuid, carrera_id uuid, cambio boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actual   uuid;
  v_es_admin boolean;
begin
  perform public.exigir_coordinador_de_campania_para_beca(p_campania_id);
  v_es_admin := public.tiene_rol('ADMIN');

  if p_carrera_id is null
     or not exists (select 1 from public.carrera c where c.id = p_carrera_id and c.deleted_at is null) then
    raise exception 'Esa carrera no está en la lista. Elegí una de las que ofrece el panel.'
      using errcode = 'BC002';
  end if;

  -- La inscripción viva, con candado: sin ella el colportor no es de esta campaña.
  perform 1 from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id and cc.deleted_at is null
     for share;
  if not found then
    raise exception 'El colportor no está en esta campaña.' using errcode = 'CZ003';
  end if;

  -- El candado de la fila de la persona: el doble toque y dos pedidos juntos se serializan acá.
  select u.carrera_id into v_actual
    from public.usuario u
   where u.id = p_usuario_id and u.deleted_at is null
     for update;
  if not found then
    raise exception 'El colportor no está en esta campaña.' using errcode = 'CZ003';
  end if;

  if v_actual is not distinct from p_carrera_id then
    return query select p_usuario_id, p_carrera_id, false;
    return;
  end if;

  if v_actual is not null and not v_es_admin then
    raise exception 'La carrera de este colportor ya está elegida y no se cambia desde acá. Si fue un error, pedile a un administrador que la corrija.'
      using errcode = 'BC005';
  end if;

  update public.usuario u set carrera_id = p_carrera_id where u.id = p_usuario_id;

  return query select p_usuario_id, p_carrera_id, true;
end;
$$;

comment on function public.elegir_carrera(uuid, uuid, uuid) is
  'Vista 33, HU-BEC-006 (0117, backend-supabase#112, decisión «Carrera», 25/10): el coordinador de la campaña '
  '(o un ADMIN) elige UNA vez la carrera de un colportor inscripto en ella; queda en su cuenta y sigue a la '
  'persona. Si ya tenía otra, el coordinador no la cambia (BC005): la corrige el ADMIN. Idempotente (cambio = '
  'false si ya era esa). Queda en audit_log. Errores: 42501 sin permiso; CZ001 campaña inexistente; BC001 '
  'campaña terminada; CZ003 el colportor no está en la campaña; BC002 carrera inexistente; BC005 ya elegida.';

revoke all on function public.elegir_carrera(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.elegir_carrera(uuid, uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. asignar_beca
-- ----------------------------------------------------------------------------

create function public.asignar_beca(p_campania_id uuid, p_usuarios uuid[], p_tipo text)
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

  select coalesce(array_agg(distinct x order by x), array[]::uuid[]) into v_ids
    from unnest(p_usuarios) as x
   where x is not null;
  if cardinality(v_ids) = 0 then
    raise exception 'Elegí al menos un colportor para asignarle la beca.' using errcode = 'invalid_parameter_value';
  end if;

  select c.tipo into v_tipo_campania from public.campania c where c.id = p_campania_id;

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
  'Vista 33, HU-BEC-006 (0117, backend-supabase#112): el coordinador de la campaña (o un ADMIN) asigna MEDIA, '
  'COMPLETA o sin beca (null) a uno o varios colportores inscriptos, todo o nada. Copia en la inscripción las '
  'metas de meta_beca de la carrera del colportor y del tipo de la campaña (meta_libros y meta_monto_ces, '
  'centavos); sin beca las deja en null. Idempotente: lo que no cambia no se toca (cambio = false). Queda en '
  'audit_log. Errores: 42501 sin permiso; CZ001 campaña inexistente; BC001 campaña terminada; CZ003 alguno no '
  'está en la campaña; 22023 tipo o lista inválidos; BC003 a alguno le falta la carrera; BC004 la carrera no '
  'tiene meta cargada.';

revoke all on function public.asignar_beca(uuid, uuid[], text)
  from public, anon, authenticated, service_role;
grant execute on function public.asignar_beca(uuid, uuid[], text) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. becas_de_campania
-- ----------------------------------------------------------------------------

create function public.becas_de_campania(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text, carrera_id uuid, carrera_nombre text,
               carrera_elegida_en timestamptz, tipo_beca text, meta_libros integer, meta_monto_ces bigint, meta_configurada boolean)
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
                      and mb.deleted_at is null)
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.carrera ca on ca.id = u.carrera_id
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id;
end;
$$;

comment on function public.becas_de_campania(uuid) is
  'Vista 33, HU-BEC-004/006 (0117, backend-supabase#112): los inscriptos vivos de p_campania_id con su carrera '
  'y cuándo se eligió (carrera_elegida_en, para «elegida el 01/09»), el tipo de beca asignado, las dos metas copiadas (libros y monto en centavos) y si la carrera tiene meta '
  'cargada para el tipo de la campaña (meta_configurada). No trae el avance (HU-BEC-002, #145). Errores: 42501 '
  'sin permiso; CZ001 inexistente; BC001 terminada.';

revoke all on function public.becas_de_campania(uuid) from public, anon, authenticated, service_role;
grant execute on function public.becas_de_campania(uuid) to authenticated;
