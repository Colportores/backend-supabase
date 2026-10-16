-- ============================================================================
-- 0035 · «Marcar como duplicado»: el servidor redirige B a A, guarda la unión y la casa pasa a
--        edificio sola (backend-supabase#69; HU-UBI-006, decisiones de Cristian del 06/10)
--
-- Cambia lo que hace 0026 (que no se edita) por dos decisiones de Cristian del 06/10 sobre la vista
-- 10 (https://github.com/Colportores/backend-supabase/pull/65#issuecomment-6019007830, detalle en
-- docs-organizacion#31):
--
--   · «Venta ajena»: el servidor redirige B a A. La misma operación reapunta a A lo que nombra a B,
--     guarda que B se unió a A, y lo que llegue DESPUÉS nombrando a B, a su espacio único ya fundido
--     o a un vínculo de B ya fundido (por push o por RPC) se guarda en A, en su espacio único o en su
--     vínculo. Reemplaza el «barrido con reintento» de 0026. Nada se rechaza por eso ni se pierde, y
--     el contrato del motor no cambia (no se toca sync.push, sync.pull ni sync.entidad).
--   · «Unir tipos»: si A es CASA y después de la unión queda con más de un espacio vivo, en la misma
--     transacción A pasa a EDIFICIO. S17 (de EDIFICIO a CASA con espacios, se bloquea) no cambia:
--     este cambio va en la dirección contraria.
--
-- ## El registro de la unión (el nombre y la forma los propone este issue)
--
--   · public.ubicacion_union: una fila por ubicación unida (B → A). `duplicada_id` es único: a B se la
--     une una sola vez. `created_by` es quien la unió (null si fue el servidor). Es la fuente de la
--     idempotencia (`ya_unida`), de la cadena (si A ya se unió a C, B va a C) y de la redirección.
--   · public.espacio_union: los espacios únicos de B que se fundieron en el único de A en esa unión
--     (espacio de B → espacio de A). Hace falta porque el espacio fundido queda dado de baja en B, y
--     lo que llegue después apuntándole tiene que saber adónde fue. El vínculo fundido no necesita
--     fila propia: se encuentra por (espacio de A, persona), que es única.
--   · Son solo de la nube: NO están en sync.entidad ni en Realtime, así que no van al pull ni al
--     push y el contrato no cambia. Sin personas ni notas: solo ids de ubicaciones y espacios.
--
-- ## Cómo se redirige lo que llega después (triggers BEFORE, sin tocar el motor)
--
-- Los triggers corren en toda escritura (push, RPC, PostgREST) ANTES de las políticas y de las FK, y
-- reescriben la referencia a la ubicación que vale hoy. Se llaman `<tabla>_0_union_redirige` para
-- correr antes que los otros BEFORE (orden alfabético): los demás ven la fila ya redirigida.
--
--   espacio.ubicacion_id                              B → A (y si A es CASA y el espacio es vivo y A
--                                                      ya tiene otro vivo, A pasa a EDIFICIO)
--   espacio_persona.espacio_id                        espacio fundido → el único de A; un espacio
--                                                      que se quedó en B (de baja y vacío) pasa a A
--   espacio_persona.ubicacion_cobranza_alt_id         B → A
--   visita/venta/agenda.espacio_persona_id            vínculo fundido → el de A (misma persona)
--   agenda.ubicacion_alt_id                           B → A
--   ubicacion_par_decidido.ubicacion_a_id / _b_id     B → A, reordenando el par (a < b)
--
-- Casos: (1) un vínculo que sube tarde al espacio único fundido de B y cuya persona ya está en el de
-- A queda dado de baja donde llegó (fundido) y reactiva/hereda al de A, sin chocar con el unique
-- (espacio_id, persona_id); sus visitas y ventas, que nombran su id, se guardan en el vínculo de A.
-- (2) Un par de ubicacion_par_decidido que ya se unió consigo mismo ((A, B) o dos que se unieron a la
-- misma) se guarda dado de baja con sus dos ids tal cual: la decisión ya no tiene sentido y no se
-- pierde. (3) Si el mismo colportor ya decidió (A, X) y decidió (B, X), queda viva una: «Conservar
-- ambos» gana sobre «Ignorar» (que solo esconde el aviso 30 días) y, entre dos iguales, la más
-- reciente (`decidido_en`; «decidir de nuevo pisa la decisión y la fecha», 0032); la otra se da de
-- baja. (4) Quedan fuera
-- house_status (la fila de B se da de baja con B y la de A la recalcula la app, ADR-003) y la propia
-- fila de ubicacion de B (su versión de sync ya cambió: el teléfono que la edita tarde recibe
-- `conflict` y adopta la baja).
--
-- Carreras: cada trigger toma `FOR KEY SHARE` sobre la fila de la ubicación antes de mirar el
-- registro. La unión la tiene `FOR UPDATE`: una escritura que llega a mitad de la unión espera a que
-- termine y después ve el registro. Sin esto, algo que llegara en esa ventana quedaría colgando de B.
-- Dos transacciones que mezclen A y B pueden interbloquearse; Postgres aborta una (40P01) y se
-- reintenta, como cualquier error transitorio del push.
--
-- ## marcar_como_duplicado (misma firma que 0026)
--
-- Respuesta (jsonb): lo de 0026 más `destino_id` (la ubicación que de verdad recibió: A, o aquella a
-- la que A ya se unió), `tipo_conservada` (su tipo al terminar) y `paso_a_edificio` (true si esta
-- unión la pasó de CASA a EDIFICIO). `conservada_id` sigue siendo el A que se pidió.
--
--   · Quién: igual que 0026 (`puedo_escribir_en_ubicacion()` en las dos). Si A ya se unió a C, también
--     en C (se escribe ahí), si no, 42501.
--   · Cruces. B ya unida (a A o a cualquier otra) → `ya_unida`. A ya se unió a B, o a algo que se
--     unió a B (sentido contrario) → `ya_unida`. A ya se unió a C → B va a C. A de baja sin registro →
--     UB003, como antes. Con B de baja y nada colgado se registra la unión y responde `ya_unida`.
--   · Unir tipos: después de pasar los espacios, si la que recibe es CASA y tiene más de un espacio
--     vivo, pasa a EDIFICIO (por los triggers de 0021 como el resto: CG001 / 42501 si corresponde).
--     Casa con casa, o casa con un negocio de un espacio: el único se funde y sigue CASA. Un NEGOCIO
--     que recibe varios sigue NEGOCIO.
--   · Los reapuntados de lo que nombraba a B: `espacio_persona.ubicacion_cobranza_alt_id`,
--     `agenda.ubicacion_alt_id` y `ubicacion_par_decidido` (todas las filas, de todos los colportores,
--     también las dadas de baja). El registro se escribe antes de reapuntar.
--
-- ## Permisos (para la revisión)
--
--   · Las tablas del registro: RLS con una sola política, SELECT para el ADMIN. Ningún otro rol las
--     lee ni las escribe (authenticated sin INSERT/UPDATE/DELETE; anon, nada; service_role, todo).
--   · Las funciones nuevas son SECURITY DEFINER con search_path vacío, sin EXECUTE para PUBLIC, anon
--     ni authenticated (los triggers corren igual): leen el registro y mueven filas sin pasar por la
--     RLS de quien escribe. La fila que escribe sigue pasando por sus políticas, ya redirigida. Con
--     UNA excepción acotada, en las políticas de INSERT y UPDATE de espacio (decisión del 16/10): un
--     espacio que llega nombrando a una ubicación ya unida se guarda en la que recibió si quien lo
--     sube podía escribir en la nombrada (aunque esté de baja), aunque no escriba en la que recibió;
--     sin ella, el depto de un colportor que sube tarde se rechazaría (42501) y con él los clientes
--     y las ventas que cuelgan de él. El trigger deja una marca de transacción con el id del
--     espacio y su destino; la política la compara con la fila final. Quien no podía escribir donde
--     nombró sigue con 42501, y escribir en A sin nombrar a una B unida no cambia.
--   · marcar_como_duplicado conserva sus privilegios de 0026 (authenticated y service_role).
--
-- ## Lo que queda fuera
--
--   · El espacio nuevo que sube tarde con número vacío NO se funde en el único de A (su id viaja en
--     los vínculos que lo nombran): queda como otro espacio de A, y A pasa a EDIFICIO si era CASA.
--     (Decisión del 16/10: se acepta así; ver el pendiente de Cristian sobre el segundo vínculo.)
--   · Si en el espacio fundido de B ya existe OTRO vínculo de la misma persona con otro id, el alta
--     tardía sigue chocando con el unique (espacio_id, persona_id) (23505, `invalid`).
--   · La unión como trabajo del motor (sync_push) es de #70; el contrato, de Bruno.
--
-- ## Para otros repos
--
--   · docs-organizacion: HU-UBI-006 y esquema-datos.md («Registro de la unión»: ubicacion_union y
--     espacio_union, solo en la nube, sin columnas nuevas en las tablas que se sincronizan).
--   · front-colportores-mobile (#284, #285): la respuesta trae `paso_a_edificio` y `tipo_conservada`
--     para reflejar el cambio de tipo; `ya_unida` también cuando A se unió a B antes, y B ya unida a
--     otra distinta de A (`destino_id` dice adónde quedó; el aviso de la vista 10 cuando difiere de
--     `conservada_id` es del móvil).
--   · Bruno (front-colportores-mobile#178, el trabajo de la unión): `destino_id` viaja en la respuesta
--     del trabajo, y `40P01` (interbloqueo entre dos uniones o una unión y un lote tardío) se trata
--     como transitorio y se reintenta, no como `invalid`.
--
-- Datos: ninguno cambia. Se suman tablas, funciones y triggers, se reemplaza una función y dos
-- políticas de espacio (la misma condición de 0021 más una rama). Nada se borra ni se recrea. Las uniones hechas con 0026 antes de esta migración no tienen registro: se
-- registran la próxima vez que se llame a la función con ese par.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El registro de la unión
-- ----------------------------------------------------------------------------

-- Con las columnas de auditoría y el cursor de todas las tablas de public (los tests de 0001 y 0002
-- lo exigen), aunque no esté en el sync. `created_by` sin FK: quien unió, aunque el usuario se borre
-- (tg_auditoria_update anularía un ON DELETE SET NULL; ver #62).
create table public.ubicacion_union (
  id             uuid primary key default public.uuid_generate_v7(),
  duplicada_id   uuid not null references public.ubicacion(id),
  conservada_id  uuid not null references public.ubicacion(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  deleted_at     timestamptz,
  sync_version   bigint not null default 0,
  xmin_w         xid8 not null default pg_current_xact_id(),
  constraint ubicacion_union_distintas check (duplicada_id <> conservada_id)
);

-- A B se la une una sola vez; de ahí sale `ya_unida` y la cadena.
create unique index ubicacion_union_duplicada_uidx on public.ubicacion_union (duplicada_id);
-- Las FK se indexan (quién se unió a una ubicación).
create index ubicacion_union_conservada_idx on public.ubicacion_union (conservada_id);

comment on table public.ubicacion_union is
  'Registro de «Marcar como duplicado» (0035, backend-supabase#69): B (duplicada_id) se unió a A '
  '(conservada_id). Idempotencia, cadena (si A se unió a C, B va a C) y redirección de lo que llega '
  'después nombrando a B. Solo en la nube (no está en sync.entidad). Solo ids; lo lee el ADMIN.';
comment on column public.ubicacion_union.duplicada_id is 'La ubicación que se dio de baja por duplicada (B). Una sola unión por B.';
comment on column public.ubicacion_union.conservada_id is 'La ubicación que recibió lo de B (A, o aquella a la que A ya se había unido).';
comment on column public.ubicacion_union.created_by is 'Quién unió el par; null si fue el servidor (service_role).';

create trigger ubicacion_union_auditoria_insert before insert on public.ubicacion_union
  for each row execute function public.tg_auditoria_insert();
create trigger ubicacion_union_auditoria_update before update on public.ubicacion_union
  for each row execute function public.tg_auditoria_update();

create table public.espacio_union (
  id          uuid primary key default public.uuid_generate_v7(),
  union_id    uuid not null references public.ubicacion_union(id),
  espacio_id  uuid not null references public.espacio(id),
  destino_id  uuid not null references public.espacio(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  deleted_at  timestamptz,
  sync_version bigint not null default 0,
  xmin_w      xid8 not null default pg_current_xact_id(),
  constraint espacio_union_distintos check (espacio_id <> destino_id)
);

-- Un espacio se funde una sola vez.
create unique index espacio_union_espacio_uidx on public.espacio_union (espacio_id);
create index espacio_union_destino_idx on public.espacio_union (destino_id);
create index espacio_union_union_idx on public.espacio_union (union_id);

comment on table public.espacio_union is
  'Espacios únicos de B que se fundieron en el único de A en una unión (0035): espacio_id (de baja, en '
  'B) → destino_id (el de A). Lo que llegue después nombrando a espacio_id se guarda en destino_id. '
  'Solo en la nube. Solo ids; lo lee el ADMIN.';

create trigger espacio_union_auditoria_insert before insert on public.espacio_union
  for each row execute function public.tg_auditoria_insert();
create trigger espacio_union_auditoria_update before update on public.espacio_union
  for each row execute function public.tg_auditoria_update();

alter table public.ubicacion_union enable row level security;
alter table public.espacio_union enable row level security;

-- Solo el ADMIN las lee (soporte y auditoría). Las escriben únicamente las funciones SECURITY DEFINER
-- de esta migración: nadie tiene política de INSERT, UPDATE ni DELETE.
create policy ubicacion_union_select_admin on public.ubicacion_union
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')));
create policy espacio_union_select_admin on public.espacio_union
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')));

revoke all on public.ubicacion_union from anon, authenticated;
grant select on public.ubicacion_union to authenticated;
grant all on public.ubicacion_union to service_role;
revoke all on public.espacio_union from anon, authenticated;
grant select on public.espacio_union to authenticated;
grant all on public.espacio_union to service_role;

-- ----------------------------------------------------------------------------
-- 2. A qué ubicación, espacio o vínculo hay que escribir hoy
-- ----------------------------------------------------------------------------

-- La ubicación a la que quedó una unida, siguiendo la cadena (B → A → C): ella misma si no se unió a
-- ninguna. Solo mira el registro, sin bloquear nada: la usan la unión (que ya tiene las filas
-- bloqueadas) y las pruebas.
create function public.ubicacion_vigente(p_ubicacion_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actual    uuid := p_ubicacion_id;
  v_siguiente uuid;
  v_saltos    integer := 0;
begin
  loop
    select un.conservada_id into v_siguiente
      from public.ubicacion_union un
     where un.duplicada_id = v_actual;
    exit when not found;
    v_actual := v_siguiente;
    v_saltos := v_saltos + 1;
    if v_saltos > 100 then
      raise exception using
        errcode = 'XX000',
        message = 'La cadena de uniones de ubicaciones da la vuelta.';
    end if;
  end loop;
  return v_actual;
end;
$$;

comment on function public.ubicacion_vigente(uuid) is
  'La ubicación a la que quedó p_ubicacion_id tras «Marcar como duplicado», siguiendo la cadena '
  '(B → A → C); ella misma si no se unió a ninguna. No bloquea (0035).';

-- Lo mismo para los triggers: antes de mirar el registro, toma FOR KEY SHARE sobre la fila de cada
-- ubicación del camino. Una unión en curso la tiene FOR UPDATE: se espera a que termine y se ve su
-- registro. Sin esa espera, algo que llegue a mitad de la unión quedaría colgando de B.
create function public.redirigir_ubicacion(p_ubicacion_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actual    uuid := p_ubicacion_id;
  v_siguiente uuid;
  v_saltos    integer := 0;
begin
  if p_ubicacion_id is null then
    return null;
  end if;
  loop
    perform 1 from public.ubicacion u where u.id = v_actual for key share;
    select un.conservada_id into v_siguiente
      from public.ubicacion_union un
     where un.duplicada_id = v_actual;
    exit when not found;
    v_actual := v_siguiente;
    v_saltos := v_saltos + 1;
    if v_saltos > 100 then
      raise exception using
        errcode = 'XX000',
        message = 'La cadena de uniones de ubicaciones da la vuelta.';
    end if;
  end loop;
  return v_actual;
end;
$$;

comment on function public.redirigir_ubicacion(uuid) is
  'ubicacion_vigente() para los triggers: espera a una unión en curso (FOR KEY SHARE sobre cada '
  'ubicación del camino) antes de mirar el registro (0035). Null si le pasan null.';

-- El espacio donde hay que escribir: si se fundió en el único de otra, el de esa (y así la cadena);
-- si sigue en una ubicación que se unió (de baja y vacío, que la unión dejó en B), pasa a la ubicación
-- vigente y sigue siendo él. Sin espacio: devuelve lo que le pasan y que lo diga la FK.
create function public.redirigir_espacio(p_espacio_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actual uuid := p_espacio_id;
  v_ubic   uuid;
  v_destino uuid;
  v_vigente uuid;
  v_vueltas integer := 0;
begin
  loop
    v_vueltas := v_vueltas + 1;
    if v_vueltas > 100 then
      raise exception using
        errcode = 'XX000',
        message = 'La cadena de espacios fundidos da la vuelta.';
    end if;

    select e.ubicacion_id into v_ubic from public.espacio e where e.id = v_actual;
    if not found then
      return v_actual;
    end if;
    perform 1 from public.ubicacion u where u.id = v_ubic for key share;

    select eu.destino_id into v_destino from public.espacio_union eu where eu.espacio_id = v_actual;
    if found then
      v_actual := v_destino;
      continue;
    end if;

    v_vigente := public.ubicacion_vigente(v_ubic);
    if v_vigente <> v_ubic then
      -- Se quedó en una ubicación que ya se unió (de baja y vacío): pasa a la vigente, intacto.
      update public.espacio set ubicacion_id = v_vigente where id = v_actual;
      continue;
    end if;

    return v_actual;
  end loop;
end;
$$;

comment on function public.redirigir_espacio(uuid) is
  'El espacio donde hay que escribir algo que nombra a p_espacio_id: el de A si se fundió (0035), o él '
  'mismo, movido a la ubicación vigente si se quedó en una unida. Para los triggers.';

-- El vínculo donde hay que escribir una visita, venta o agenda que nombra a p_vinculo_id: él mismo, o
-- el de la misma persona en el espacio de A si el suyo se fundió.
create function public.redirigir_vinculo(p_vinculo_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_espacio  uuid;
  v_persona  uuid;
  v_nuevo    uuid;
  v_vinculo  uuid;
begin
  select ep.espacio_id, ep.persona_id into v_espacio, v_persona
    from public.espacio_persona ep
   where ep.id = p_vinculo_id;
  if not found then
    return p_vinculo_id;
  end if;

  v_nuevo := public.redirigir_espacio(v_espacio);
  if v_nuevo = v_espacio then
    return p_vinculo_id;
  end if;

  -- Su espacio se fundió: la misma persona en el espacio de A (única por (espacio_id, persona_id)).
  select ep.id into v_vinculo
    from public.espacio_persona ep
   where ep.espacio_id = v_nuevo and ep.persona_id = v_persona;
  if found then
    return v_vinculo;
  end if;

  -- No tenía vínculo allá (no pasa si se fundió por la unión, que lo deja en uno u otro): se muda.
  update public.espacio_persona set espacio_id = v_nuevo where id = p_vinculo_id;
  return p_vinculo_id;
end;
$$;

comment on function public.redirigir_vinculo(uuid) is
  'El vínculo (espacio_persona) donde hay que escribir una visita, venta o agenda que nombra a '
  'p_vinculo_id: el de la misma persona en el espacio de A si el suyo se fundió (0035).';

-- ----------------------------------------------------------------------------
-- 3. Los triggers que redirigen lo que llega después
-- ----------------------------------------------------------------------------

-- espacio.ubicacion_id: B → A. Si A es CASA y este espacio vivo la deja con más de uno, pasa a
-- EDIFICIO (la misma regla de «Unir tipos»).
create function public.tg_espacio_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombrada uuid := new.ubicacion_id;
  v_destino  uuid := public.redirigir_ubicacion(new.ubicacion_id);
begin
  if v_destino is distinct from v_nombrada then
    -- La excepción acotada de las políticas de espacio (sección 3b): quien nombraba a la ubicación
    -- unida y podía escribir ahí (aunque esté de baja) puede dejar este espacio en la que recibió. Se
    -- marca la fila, con su destino, hasta el fin de la transacción: la política lo compara con la
    -- fila final. Lo que no se nombró unida, o quien no podía escribir donde la nombró, no lo recibe.
    if auth.uid() is not null
       and (case when tg_op = 'INSERT' then public.puedo_cargar_en_ubicacion(v_nombrada)
                 else public.puedo_escribir_en_ubicacion(v_nombrada) end) then
      perform set_config('colportores.union_espacio', new.id::text || ':' || v_destino::text, true);
    end if;
    new.ubicacion_id := v_destino;
    if new.deleted_at is null
       and exists (select 1 from public.ubicacion u where u.id = v_destino and u.tipo = 'CASA')
       and exists (select 1 from public.espacio e
                    where e.ubicacion_id = v_destino and e.deleted_at is null and e.id <> new.id) then
      update public.ubicacion set tipo = 'EDIFICIO' where id = v_destino;
    end if;
  end if;
  return new;
end;
$$;

comment on function public.tg_espacio_union_redirige() is
  'BEFORE INSERT / UPDATE OF ubicacion_id de espacio: lo que sube tarde nombrando a una ubicación '
  'unida se guarda en la vigente; una CASA que queda con más de un espacio vivo pasa a EDIFICIO (0035).';

create trigger espacio_0_union_redirige
  before insert or update of ubicacion_id on public.espacio
  for each row execute function public.tg_espacio_union_redirige();

-- 3b. Las políticas de escritura de espacio (0021) con una sola rama más: la marca que deja el trigger.
-- Se guarda en A lo que llega nombrando a una B ya unida, y solo si quien lo sube podía escribir en B
-- (el mismo permiso que ya tenía: dueño de la casa o ciudad de su campaña). Nada más se ensancha: lo
-- que nombra a A directamente sigue pasando por puedo_cargar_en_ubicacion / puedo_escribir_en_ubicacion.
-- La marca es una variable de la transacción (`colportores.union_espacio` = «<espacio>:<destino>»)
-- que solo escribe tg_espacio_union_redirige(): la API no ejecuta set_config, y como incluye el
-- destino no sirve para mover la misma fila a otro lado después.
drop policy espacio_por_ubicacion_insert on public.espacio;
create policy espacio_por_ubicacion_insert on public.espacio
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and (public.puedo_cargar_en_ubicacion(ubicacion_id)
                   or current_setting('colportores.union_espacio', true) = id::text || ':' || ubicacion_id::text));

drop policy espacio_por_ubicacion_update on public.espacio;
create policy espacio_por_ubicacion_update on public.espacio
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id)
         or exists (select 1 from public.ubicacion u where u.id = ubicacion_id))
  with check (public.puedo_escribir_en_ubicacion(ubicacion_id)
              or current_setting('colportores.union_espacio', true) = id::text || ':' || ubicacion_id::text);

comment on policy espacio_por_ubicacion_insert on public.espacio is
  'Alta: quien la carga y puede cargar en la ubicación (0021), o un espacio que llegó nombrando a una '
  'ubicación ya unida a esta y quien lo sube podía cargar en la nombrada (marca de tg_espacio_union_redirige, 0035).';
comment on policy espacio_por_ubicacion_update on public.espacio is
  'Corrección: USING como en 0021; WITH CHECK: puede escribir en la ubicación, o el espacio se movió '
  'a la que recibió una ubicación unida que nombraba y en la que podía escribir (0035).';

-- espacio_persona.espacio_id (espacio fundido → el de A) y ubicacion_cobranza_alt_id (B → A).
create function public.tg_espacio_persona_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_destino   uuid;
  v_existente public.espacio_persona%rowtype;
begin
  if new.ubicacion_cobranza_alt_id is not null then
    new.ubicacion_cobranza_alt_id := public.redirigir_ubicacion(new.ubicacion_cobranza_alt_id);
  end if;

  v_destino := public.redirigir_espacio(new.espacio_id);
  if v_destino is distinct from new.espacio_id then
    -- ¿La misma persona ya tiene su vínculo en el espacio de A? (es único por espacio y persona,
    -- de quien sea: la unión de 0026 también funde los de distintos colportores)
    select * into v_existente
      from public.espacio_persona ep
     where ep.espacio_id = v_destino and ep.persona_id = new.persona_id
       and ep.id <> new.id;
    if found then
      -- Se funde: este queda donde llegó, dado de baja; el de A se reactiva y hereda la cobranza.
      -- Sus visitas y ventas nombran este id, y redirigir_vinculo() las lleva al de A.
      if new.deleted_at is null then
        new.deleted_at := now();
        update public.espacio_persona
           set deleted_at = null,
               ubicacion_cobranza_alt_id = coalesce(ubicacion_cobranza_alt_id, new.ubicacion_cobranza_alt_id)
         where id = v_existente.id
           and (deleted_at is not null
                or (ubicacion_cobranza_alt_id is null and new.ubicacion_cobranza_alt_id is not null));
      end if;
    else
      new.espacio_id := v_destino;
    end if;
  end if;
  return new;
end;
$$;

comment on function public.tg_espacio_persona_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_id, ubicacion_cobranza_alt_id de espacio_persona: lo que sube '
  'tarde al espacio fundido de B va al único de A (o se funde en el vínculo de la misma persona), y '
  'la cobranza alternativa que nombra a B pasa a A (0035).';

create trigger espacio_persona_0_union_redirige
  before insert or update of espacio_id, ubicacion_cobranza_alt_id on public.espacio_persona
  for each row execute function public.tg_espacio_persona_union_redirige();

-- visita y venta: espacio_persona_id (vínculo fundido → el de A).
create function public.tg_vinculo_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.espacio_persona_id := public.redirigir_vinculo(new.espacio_persona_id);
  return new;
end;
$$;

comment on function public.tg_vinculo_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_persona_id de visita y venta: lo que sube tarde nombrando a un '
  'vínculo fundido se guarda en el de A (0035).';

create trigger visita_0_union_redirige
  before insert or update of espacio_persona_id on public.visita
  for each row execute function public.tg_vinculo_union_redirige();
create trigger venta_0_union_redirige
  before insert or update of espacio_persona_id on public.venta
  for each row execute function public.tg_vinculo_union_redirige();

-- agenda: el vínculo y la casa alternativa.
create function public.tg_agenda_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.espacio_persona_id := public.redirigir_vinculo(new.espacio_persona_id);
  if new.ubicacion_alt_id is not null then
    new.ubicacion_alt_id := public.redirigir_ubicacion(new.ubicacion_alt_id);
  end if;
  return new;
end;
$$;

comment on function public.tg_agenda_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_persona_id, ubicacion_alt_id de agenda: el vínculo fundido y la '
  'casa alternativa que nombra a B pasan a A (0035).';

create trigger agenda_0_union_redirige
  before insert or update of espacio_persona_id, ubicacion_alt_id on public.agenda
  for each row execute function public.tg_agenda_union_redirige();

-- ubicacion_par_decidido: el par se reapunta a las vigentes y se reordena (a < b).
create function public.tg_par_decidido_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a     uuid;
  v_b     uuid;
  v_dueno uuid;
  v_otro  public.ubicacion_par_decidido%rowtype;
begin
  -- Siempre en el mismo orden (por id): dos escritores que mezclen A y B no se interbloquean acá.
  v_a := public.redirigir_ubicacion(least(new.ubicacion_a_id, new.ubicacion_b_id));
  v_b := public.redirigir_ubicacion(greatest(new.ubicacion_a_id, new.ubicacion_b_id));
  if (v_a = new.ubicacion_a_id and v_b = new.ubicacion_b_id)
     or (v_a = new.ubicacion_b_id and v_b = new.ubicacion_a_id) then
    return new;
  end if;

  if v_a = v_b then
    -- El par se unió consigo mismo ((A, B) o dos que se unieron a la misma): la decisión ya no tiene
    -- sentido. Se guarda dada de baja con sus dos ids, sin reapuntar (a < b no admite (A, A)).
    new.deleted_at := coalesce(new.deleted_at, now());
    return new;
  end if;

  new.ubicacion_a_id := least(v_a, v_b);
  new.ubicacion_b_id := greatest(v_a, v_b);

  -- Un solo par vivo por colportor (0032): si el mismo ya decidió el par nuevo, queda una. Gana
  -- «Conservar ambos» sobre «Ignorar» (decisión del 16/10: B y X son lugares distintos para siempre,
  -- y «Ignorar» solo esconde el aviso 30 días); entre dos iguales, la más reciente (`decidido_en`,
  -- como en 0032). La que pierde queda dada de baja, no se borra.
  if new.deleted_at is null then
    if tg_op = 'UPDATE' then
      v_dueno := old.created_by;
    else
      v_dueno := new.created_by;
    end if;
    select * into v_otro
      from public.ubicacion_par_decidido d
     where d.created_by is not distinct from v_dueno
       and d.ubicacion_a_id = new.ubicacion_a_id and d.ubicacion_b_id = new.ubicacion_b_id
       and d.deleted_at is null and d.id <> new.id
     for update;
    if found then
      if (v_otro.decision = 'CONSERVAR_AMBOS' and new.decision = 'IGNORAR')
         or (v_otro.decision = new.decision and v_otro.decidido_en >= new.decidido_en) then
        new.deleted_at := now();
      else
        update public.ubicacion_par_decidido set deleted_at = now() where id = v_otro.id;
      end if;
    end if;
  end if;
  return new;
end;
$$;

comment on function public.tg_par_decidido_union_redirige() is
  'BEFORE INSERT / UPDATE OF ubicacion_a_id, ubicacion_b_id de ubicacion_par_decidido: reapunta el par '
  'a las ubicaciones vigentes y lo reordena (a < b). El par consigo mismo se da de baja; si el mismo '
  'colportor ya decidió el par nuevo, gana «Conservar ambos» sobre «Ignorar» y, entre iguales, la más '
  'reciente (0035).';

create trigger ubicacion_par_decidido_0_union_redirige
  before insert or update of ubicacion_a_id, ubicacion_b_id on public.ubicacion_par_decidido
  for each row execute function public.tg_par_decidido_union_redirige();

-- ----------------------------------------------------------------------------
-- 4. La respuesta de la unión
-- ----------------------------------------------------------------------------

create function public.union_respuesta(
  p_duplicada_id     uuid,
  p_conservada_id    uuid,
  p_destino_id       uuid,
  p_ya_unida         boolean,
  p_espacios_pasados integer,
  p_espacios_unidos  integer,
  p_personas         integer,
  p_visitas          integer,
  p_ventas           integer,
  p_cobranzas        integer,
  p_paso_a_edificio  boolean
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'duplicada_id', p_duplicada_id, 'conservada_id', p_conservada_id, 'destino_id', p_destino_id,
    'ya_unida', p_ya_unida,
    'espacios_pasados', p_espacios_pasados, 'espacios_unidos', p_espacios_unidos,
    'personas', p_personas, 'visitas', p_visitas, 'ventas', p_ventas, 'cobranzas', p_cobranzas,
    'tipo_conservada', (select u.tipo from public.ubicacion u where u.id = p_destino_id),
    'paso_a_edificio', p_paso_a_edificio);
$$;

comment on function public.union_respuesta(uuid, uuid, uuid, boolean, integer, integer, integer, integer, integer, integer, boolean) is
  'La respuesta jsonb de marcar_como_duplicado (0035): lo de 0026 más destino_id, tipo_conservada y paso_a_edificio.';

-- ----------------------------------------------------------------------------
-- 5. marcar_como_duplicado: cruces, registro, redirección y paso a edificio
-- ----------------------------------------------------------------------------

-- Misma firma que en 0026 (create or replace conserva privilegios y se vuelve a comentar abajo). Lo
-- que cambia: el destino puede ser aquella a la que A ya se unió; el registro (se escribe al final de
-- los movimientos, para que los triggers no redirijan lo que la propia unión mueve); el paso a
-- edificio; los reapuntados; y la respuesta.
create or replace function public.marcar_como_duplicado(p_duplicada_id uuid, p_conservada_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid              uuid := auth.uid();
  v_b                public.ubicacion%rowtype;  -- la duplicada
  v_d                public.ubicacion%rowtype;  -- la que recibe: A, o aquella a la que A ya se unió
  v_destino          uuid;
  v_siguiente        uuid;
  v_une_unicos       boolean;
  v_espacios         uuid[];
  v_unico_d          uuid;
  v_id               uuid;
  v_e                public.espacio%rowtype;
  v_ep               public.espacio_persona%rowtype;
  v_ep_a             public.espacio_persona%rowtype;
  v_fundidos_de      uuid[] := '{}'::uuid[];
  v_fundidos_a       uuid[] := '{}'::uuid[];
  v_espacios_pasados integer := 0;
  v_espacios_unidos  integer := 0;
  v_personas         integer;
  v_visitas          integer;
  v_ventas           integer;
  v_cobranzas        integer;
  v_vivos            integer;
  v_a_edificio       boolean := false;
  v_union            uuid;
begin
  if p_duplicada_id is null or p_conservada_id is null then
    raise exception using
      errcode = '22023',
      message = 'Faltan las dos ubicaciones del par.';
  end if;

  if p_duplicada_id = p_conservada_id then
    raise exception using
      errcode = 'UB004',
      message = 'Una ubicación no puede ser el duplicado de sí misma.',
      hint    = 'Revisá el par de nuevo.';
  end if;

  -- 1. Quién: escribe en las dos. Sin usuario autenticado (service_role) no se exige.
  if v_uid is not null
     and not (public.puedo_escribir_en_ubicacion(p_conservada_id)
              and public.puedo_escribir_en_ubicacion(p_duplicada_id)) then
    raise exception using
      errcode = '42501',
      message = 'No podés marcar como duplicado este par: no escribís en alguna de las dos ubicaciones. '
                'Todo queda como estaba.',
      hint    = 'Revisá el par de nuevo.';
  end if;

  -- 2. Las dos filas bloqueadas, siempre por id: dos llamadas sobre el mismo par (o cruzadas) se
  --    hacen cola sin interbloquearse, y la segunda ve lo que dejó la primera.
  perform u.id
     from public.ubicacion u
    where u.id in (p_duplicada_id, p_conservada_id)
    order by u.id
      for update;

  perform 1 from public.ubicacion u where u.id = p_conservada_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'La ubicación que ibas a conservar no existe.';
  end if;
  select * into v_b from public.ubicacion where id = p_duplicada_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'La ubicación duplicada no existe.';
  end if;

  -- 3. B ya se unió (a A o a cualquier otra): éxito, no se hace nada de más.
  if exists (select 1 from public.ubicacion_union un where un.duplicada_id = p_duplicada_id) then
    return public.union_respuesta(p_duplicada_id, p_conservada_id, public.ubicacion_vigente(p_duplicada_id),
                                  true, 0, 0, 0, 0, 0, 0, false);
  end if;

  -- 4. Adónde va: A, o aquella a la que A ya se unió (B va a C). Ahí se escribe: hay que poder, y se
  --    bloquea. Si A ya se unió a B, o a algo que se unió a B (sentido contrario): ya_unida.
  v_destino := public.ubicacion_vigente(p_conservada_id);
  if v_destino <> p_conservada_id then
    loop
      if v_destino = p_duplicada_id then
        return public.union_respuesta(p_duplicada_id, p_conservada_id, p_duplicada_id,
                                      true, 0, 0, 0, 0, 0, 0, false);
      end if;
      if v_uid is not null and not public.puedo_escribir_en_ubicacion(v_destino) then
        raise exception using
          errcode = '42501',
          message = 'No podés marcar como duplicado este par: no escribís en la ubicación a la que se unió '
                    'la que ibas a conservar. Todo queda como estaba.',
          hint    = 'Revisá el par de nuevo.';
      end if;
      perform 1 from public.ubicacion u where u.id = v_destino for update;
      -- Por si, mientras esperaba el bloqueo, esa también se unió a otra.
      v_siguiente := public.ubicacion_vigente(v_destino);
      exit when v_siguiente = v_destino;
      v_destino := v_siguiente;
    end loop;
  end if;
  select * into v_d from public.ubicacion where id = v_destino;

  -- La que recibe tiene que estar viva.
  if v_d.deleted_at is not null then
    raise exception using
      errcode = 'UB003',
      message = 'La ubicación que ibas a conservar ya está dada de baja. Revisá el par de nuevo.',
      hint    = 'No se aplicó nada.';
  end if;

  -- 5. Los espacios de B que importan: los vivos, y los dados de baja que todavía tienen un
  --    vínculo con una persona vivo o eventos colgando.
  select coalesce(array_agg(e.id order by e.created_at, e.id), '{}')
    into v_espacios
    from public.espacio e
   where e.ubicacion_id = p_duplicada_id
     and (e.deleted_at is null
          or exists (select 1
                       from public.espacio_persona ep
                      where ep.espacio_id = e.id
                        and (ep.deleted_at is null
                             or exists (select 1 from public.visita vi where vi.espacio_persona_id = ep.id)
                             or exists (select 1 from public.agenda ag where ag.espacio_persona_id = ep.id)
                             or exists (select 1 from public.venta v where v.espacio_persona_id = ep.id))));

  -- B ya estaba de baja y no queda nada colgado (una baja común, o una unión de 0026 que no dejó
  -- registro): no hay nada que mover, pero se registra para que lo que llegue después vaya a A.
  if v_b.deleted_at is not null and cardinality(v_espacios) = 0 then
    insert into public.ubicacion_union (duplicada_id, conservada_id) values (p_duplicada_id, v_d.id);
    return public.union_respuesta(p_duplicada_id, p_conservada_id, v_d.id, true, 0, 0, 0, 0, 0, 0, false);
  end if;

  -- Lo que pasa a A (para la respuesta), contado antes de moverlo.
  select count(*) filter (where ep.deleted_at is null)
    into v_personas
    from public.espacio_persona ep
   where ep.espacio_id = any (v_espacios);
  select count(*)
    into v_visitas
    from public.visita vi
    join public.espacio_persona ep on ep.id = vi.espacio_persona_id
   where ep.espacio_id = any (v_espacios);
  select count(*)
    into v_ventas
    from public.venta v
    join public.espacio_persona ep on ep.id = v.espacio_persona_id
   where ep.espacio_id = any (v_espacios);
  select count(*)
    into v_cobranzas
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
    join public.espacio_persona ep on ep.id = v.espacio_persona_id
   where ep.espacio_id = any (v_espacios);

  -- 6. Pasar los espacios; los únicos se funden en el único de la que recibe.
  v_une_unicos := v_d.tipo in ('CASA', 'NEGOCIO') and v_b.tipo in ('CASA', 'NEGOCIO');
  if v_une_unicos then
    select e.id
      into v_unico_d
      from public.espacio e
     where e.ubicacion_id = v_d.id
       and e.deleted_at is null
       and nullif(btrim(e.numero_depto), '') is null
     order by e.created_at, e.id
     limit 1;
  end if;

  foreach v_id in array v_espacios loop
    select * into v_e from public.espacio e where e.id = v_id;

    if v_une_unicos and nullif(btrim(v_e.numero_depto), '') is null and v_unico_d is not null then
      -- El único de B se funde en el de A: persona por persona.
      for v_ep in
        select * from public.espacio_persona ep where ep.espacio_id = v_e.id order by ep.created_at, ep.id
      loop
        select * into v_ep_a
          from public.espacio_persona ep
         where ep.espacio_id = v_unico_d and ep.persona_id = v_ep.persona_id;

        if not found then
          -- Solo en B: su vínculo se muda al único de A, con el mismo id.
          update public.espacio_persona set espacio_id = v_unico_d where id = v_ep.id;
        else
          -- En las dos: lo de B cuelga ahora del vínculo de A (el unique espacio_id+persona_id
          -- no admite dos, vivos o dados de baja).
          update public.visita set espacio_persona_id = v_ep_a.id where espacio_persona_id = v_ep.id;
          update public.agenda set espacio_persona_id = v_ep_a.id where espacio_persona_id = v_ep.id;
          update public.venta  set espacio_persona_id = v_ep_a.id where espacio_persona_id = v_ep.id;

          if v_ep.deleted_at is null then
            if v_ep_a.deleted_at is not null
               or (v_ep_a.ubicacion_cobranza_alt_id is null and v_ep.ubicacion_cobranza_alt_id is not null) then
              update public.espacio_persona
                 set deleted_at = null,
                     ubicacion_cobranza_alt_id = coalesce(ubicacion_cobranza_alt_id, v_ep.ubicacion_cobranza_alt_id)
               where id = v_ep_a.id;
            end if;
            update public.espacio_persona set deleted_at = now() where id = v_ep.id;
          end if;
        end if;
      end loop;

      if v_e.deleted_at is null then
        update public.espacio set deleted_at = now() where id = v_e.id;
      end if;
      v_espacios_unidos := v_espacios_unidos + 1;
      v_fundidos_de := v_fundidos_de || v_e.id;
      v_fundidos_a := v_fundidos_a || v_unico_d;
    else
      -- Pasa tal cual: con él viaja todo lo que cuelga de sus vínculos.
      update public.espacio set ubicacion_id = v_d.id where id = v_e.id;
      v_espacios_pasados := v_espacios_pasados + 1;
      -- La que recibe no tenía único vivo: el de B pasa a serlo (los demás únicos de B se funden en él).
      if v_une_unicos and v_unico_d is null and v_e.deleted_at is null
         and nullif(btrim(v_e.numero_depto), '') is null then
        v_unico_d := v_e.id;
      end if;
    end if;
  end loop;

  -- 7. El estado de B se da de baja con ella; el de A lo recalcula la app (ADR-003).
  update public.house_status set deleted_at = now()
   where ubicacion_id = p_duplicada_id and deleted_at is null;

  -- 8. B se da de baja. Ya no cuelga nada de ella: UB001 y UB002 no se disparan.
  if v_b.deleted_at is null then
    update public.ubicacion set deleted_at = now() where id = p_duplicada_id;
  end if;

  -- 9. «Unir tipos»: una casa que queda con más de un espacio vivo pasa a edificio sola. Por los
  --    triggers de 0021, como el resto de la operación.
  if v_d.tipo = 'CASA' then
    select count(*) into v_vivos
      from public.espacio e
     where e.ubicacion_id = v_d.id and e.deleted_at is null;
    if v_vivos > 1 then
      update public.ubicacion set tipo = 'EDIFICIO' where id = v_d.id;
      v_a_edificio := true;
    end if;
  end if;

  -- 10. Se guarda que B se unió. Recién ahora, con todo movido: los triggers de redirección no
  --     tocan lo que la propia unión mueve.
  insert into public.ubicacion_union (duplicada_id, conservada_id)
  values (p_duplicada_id, v_d.id)
  returning id into v_union;
  insert into public.espacio_union (union_id, espacio_id, destino_id)
  select v_union, f.de, f.a
    from unnest(v_fundidos_de, v_fundidos_a) as f(de, a);

  -- 11. Lo que nombra a B pasa a nombrar a la que recibe (de todos los colportores, también lo dado
  --     de baja). Las decisiones sobre pares se reapuntan por su trigger, que reordena el par, da de
  --     baja el par consigo mismo y se queda con la más reciente si ya había una sobre el par nuevo.
  update public.espacio_persona set ubicacion_cobranza_alt_id = v_d.id
   where ubicacion_cobranza_alt_id = p_duplicada_id;
  update public.agenda set ubicacion_alt_id = v_d.id
   where ubicacion_alt_id = p_duplicada_id;
  update public.ubicacion_par_decidido set ubicacion_a_id = ubicacion_a_id
   where ubicacion_a_id = p_duplicada_id or ubicacion_b_id = p_duplicada_id;

  return public.union_respuesta(p_duplicada_id, p_conservada_id, v_d.id, false,
                                v_espacios_pasados, v_espacios_unidos,
                                v_personas, v_visitas, v_ventas, v_cobranzas, v_a_edificio);
end;
$$;

comment on function public.marcar_como_duplicado(uuid, uuid) is
  'HU-UBI-006 (0026, 0035): pasa a A (p_conservada_id; o aquella a la que A ya se unió) los espacios de B '
  '(p_duplicada_id) con sus personas, visitas, agendas, ventas y cobranzas, también las de otros '
  'colportores; los espacios únicos (CASA/NEGOCIO) se funden en el de A; da de baja el estado de B y a B; '
  'una CASA que queda con más de un espacio pasa a EDIFICIO; guarda la unión (ubicacion_union) y '
  'reapunta a A lo que nombraba a B; lo que llegue después nombrando a B se guarda en A. Una sola '
  'transacción e idempotente (ya_unida, también en sentido contrario). Escribe en las dos casas '
  '(puedo_escribir_en_ubicacion); los triggers de 0021 (42501, CG001) valen. Errores: UB003 (A de baja), '
  'UB004 (misma ubicación). No toca el house_status de A (lo recalcula la app).';

-- ----------------------------------------------------------------------------
-- 6. Privilegios
-- ----------------------------------------------------------------------------

-- Solo las llaman los triggers y marcar_como_duplicado (todos SECURITY DEFINER): ni siquiera
-- authenticated. `authenticated` va en el revoke porque los default privileges de la imagen le dan
-- EXECUTE sobre cada función nueva de public (ver 0008). Un trigger corre igual sin EXECUTE.
revoke all on function
  public.ubicacion_vigente(uuid),
  public.redirigir_ubicacion(uuid),
  public.redirigir_espacio(uuid),
  public.redirigir_vinculo(uuid),
  public.union_respuesta(uuid, uuid, uuid, boolean, integer, integer, integer, integer, integer, integer, boolean),
  public.tg_espacio_union_redirige(),
  public.tg_espacio_persona_union_redirige(),
  public.tg_vinculo_union_redirige(),
  public.tg_agenda_union_redirige(),
  public.tg_par_decidido_union_redirige()
  from public, anon, authenticated;
