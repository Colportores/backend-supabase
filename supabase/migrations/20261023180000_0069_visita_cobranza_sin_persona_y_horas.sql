-- ============================================================================
-- 0069 · Visita: resultado COBRANZA, visita sin persona y hora de entrada y de salida de la entrevista
--        (backend-supabase#132)
--
-- Decisiones de Cristian del 23/10 (front-colportores-mobile#151): «Visita cobro» («Sí, como resultado»),
-- «Sin persona» («De la casa o el depto») y «Horas entrev» («Suben con la visita»). Caso de uso: Ana,
-- colportora, en la hoja de la casa (vista 39) pasa a cobrar la cuota y María no le paga (queda una
-- visita con resultado Cobranza); toca «No contestó» en Grecia 3307 sin elegir a nadie; toca «Empezar» y
-- «Finalizar» en lo de Pedro y el historial muestra cuánto duró la entrevista.
--
-- ## Qué cambia en `visita`
--
--   · `tipo_resultado` acepta `COBRANZA`. La visita de cobro es un resultado más: el historial muestra la
--     pasada y la cita de cobranza se cumple con esa visita (`agenda.visita_id`, que ya existe). NO es una
--     presentación: los tableros y reportes del panel cuentan presentaciones con la lista explícita
--     `c_presentacion` (VENTA, ENTREVISTA) de 0054, 0055 y 0061, así que ninguna lectura cambia; lo prueba
--     el pgTAP 0069.
--   · `espacio_id` (NOT NULL) y `espacio_persona_id` opcional («Sin persona»): la visita cuelga del
--     espacio (la casa o el depto) y la persona es opcional. Mismo modelo que la cita de la agenda (0068).
--     Con persona, el espacio es el de su vínculo (el trigger lo completa si falta y lo corrige si no
--     coincide: un teléfono que todavía no manda `espacio_id` sigue funcionando). Sin persona no sube nada
--     de ninguna persona: solo el espacio, que ya sube. Las filas que ya tienen persona toman el espacio
--     de su vínculo; ninguna se pierde.
--   · `entrevista_entrada` y `entrevista_salida` (timestamptz, opcionales): cuándo empezó y terminó la
--     entrevista (vista 39, R·05 a R·07). Suben con la visita, en la entidad del push (sync.entidad sale
--     del catálogo: no hace falta registrar columnas), y bajan en el pull, así que un teléfono nuevo no las
--     pierde. Las lee solo la colportora dueña: la RLS de `visita` es la de siempre (colportor_id = el
--     usuario) y ninguna lectura del panel las toca. Una sola regla de forma: si están las dos, la salida
--     no es anterior a la entrada (23514). El tope de duración (12 h, como la jornada) lo valida la app.
--
-- ## Cuando dos casas se unen (HU-UBI-006)
--
-- El trigger de unión de visita (0035) también redirige `espacio_id` (un espacio fundido en el único de A
-- va al de A). `marcar_como_duplicado()` mueve al único de A las visitas que colgaban del espacio que se
-- funde, con o sin persona, antes de dar de baja a B (la baja de una casa con visitas de otro colportor,
-- UB002 de 0018, las ve por su espacio: sin moverlas, la unión se rechazaría); y si un vínculo cambia de
-- espacio, sus visitas lo siguen. Nada se pierde ni se rechaza.
--
-- ## Los datos
--
-- Solo se suma; no se borra nada. El espacio de cada visita se escribe con un solo UPDATE, así que esas
-- filas suben su `sync_version` una vez (un teléfono con una edición vieja de la visita recibe `conflict`
-- y adopta la del servidor). Lo prueba el caso `tests_migracion/0069_ok`.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: la tabla local de `visita` suma `espacio_id`, `entrevista_entrada` y
--     `entrevista_salida`, deja `espacio_persona_id` en null y acepta `COBRANZA` en `tipo_resultado`
--     (también su CHECK). Las horas viajan en el payload de la visita (entidad `visita`).
--   · docs-organizacion: `esquema-datos.md` (visita) y `contrato-sync-engine.md` (la entidad `visita`
--     con sus columnas nuevas).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. visita: columnas, resultado y reglas de forma
-- ----------------------------------------------------------------------------

alter table public.visita drop constraint visita_tipo_resultado_check;

alter table public.visita
  add column espacio_id           uuid references public.espacio(id),
  add column entrevista_entrada   timestamptz,
  add column entrevista_salida    timestamptz;

-- Un solo UPDATE (una sola subida de sync_version): el espacio de cada visita es el de su vínculo.
update public.visita vi
   set espacio_id = ep.espacio_id
  from public.espacio_persona ep
 where ep.id = vi.espacio_persona_id;

alter table public.visita
  alter column espacio_id set not null,
  alter column espacio_persona_id drop not null;

alter table public.visita
  add constraint visita_tipo_resultado_check
    check (tipo_resultado in ('VENTA','NO_CONTESTO','RECHAZO','ENTREVISTA','COBRANZA')),
  add constraint visita_entrevista_horas_check
    check (entrevista_entrada is null
           or entrevista_salida is null
           or entrevista_salida >= entrevista_entrada);

create index visita_espacio_idx on public.visita (espacio_id);

comment on table public.visita is
  'Una pasada de la colportora por una casa o un depto, con su resultado. Cuelga del espacio; la persona '
  'es opcional (0069). Sin columna notas: contiene PII y queda local.';
comment on column public.visita.tipo_resultado is
  'VENTA, NO_CONTESTO, RECHAZO, ENTREVISTA o COBRANZA (0069: la pasada a cobrar). Solo VENTA y ENTREVISTA '
  'son presentaciones (S62): COBRANZA no cuenta.';
comment on column public.visita.espacio_id is
  'La casa o el depto de la visita (obligatorio). Con persona es el espacio de su vínculo: lo completa el '
  'trigger visita_0_union_redirige (0069).';
comment on column public.visita.espacio_persona_id is
  'El vínculo con la persona; opcional: una visita puede colgar solo del espacio (0069). La persona no sube.';
comment on column public.visita.entrevista_entrada is
  'Cuándo empezó la entrevista (vista 39, R·05 a R·07). Opcional. Solo la ve su dueña (RLS de visita).';
comment on column public.visita.entrevista_salida is
  'Cuándo terminó la entrevista. Opcional; si está la entrada, no es anterior a ella. El tope de '
  'duración lo valida la app (12 h, como la jornada).';

-- ----------------------------------------------------------------------------
-- 2. El espacio de la visita: con persona, el de su vínculo; si se funde, el de A
-- ----------------------------------------------------------------------------

-- Igual que tg_vinculo_union_redirige() (0035), que sigue sirviendo a venta, más el espacio. Corre antes
-- que los otros BEFORE (por el nombre).
create function public.tg_visita_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_espacio uuid;
begin
  new.espacio_persona_id := public.redirigir_vinculo(new.espacio_persona_id);

  -- Con persona, la visita cuelga del espacio de su vínculo (el que mande el teléfono, o ninguno, da
  -- igual).
  if new.espacio_persona_id is not null then
    select ep.espacio_id into v_espacio
      from public.espacio_persona ep
     where ep.id = new.espacio_persona_id;
    if not found then
      -- El vínculo no existe (todavía): es el mismo error de clave foránea de siempre (23503) y no un
      -- NOT NULL del espacio que este trigger no pudo completar (23502). El push lo necesita así: un
      -- 23503 de algo que cuelga de un alta en conflicto queda en espera (0017) y no se pierde.
      raise exception using
        errcode = '23503',
        constraint = 'visita_espacio_persona_id_fkey',
        message = 'insert or update on table "visita" violates foreign key constraint "visita_espacio_persona_id_fkey"';
    end if;
    new.espacio_id := v_espacio;
  end if;

  -- Un espacio fundido en el único de A va al de A (null se queda null: lo dice el NOT NULL).
  new.espacio_id := public.redirigir_espacio(new.espacio_id);
  return new;
end;
$$;

comment on function public.tg_visita_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_persona_id, espacio_id de visita: el vínculo fundido que nombra a B '
  'pasa a A (0035); el espacio sale del vínculo si hay persona y el espacio fundido pasa al de A (0069).';

drop trigger visita_0_union_redirige on public.visita;
create trigger visita_0_union_redirige
  before insert or update of espacio_persona_id, espacio_id on public.visita
  for each row execute function public.tg_visita_union_redirige();

-- Si un vínculo cambia de espacio (hoy lo hace la unión de dos casas, cuando el vínculo de B se muda al
-- único de A), sus visitas lo siguen: el espacio de una visita con persona es siempre el de su vínculo.
-- Corre para cualquier colportor (DEFINER): las visitas de los demás también se mudan con el vínculo.
create function public.tg_espacio_persona_mueve_visitas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.visita
     set espacio_id = new.espacio_id
   where espacio_persona_id = new.id
     and espacio_id is distinct from new.espacio_id;
  return null;
end;
$$;

comment on function public.tg_espacio_persona_mueve_visitas() is
  'AFTER UPDATE OF espacio_id de espacio_persona: las visitas de ese vínculo pasan a su espacio nuevo '
  '(0069).';

create trigger espacio_persona_mueve_visitas
  after update of espacio_id on public.espacio_persona
  for each row
  when (old.espacio_id is distinct from new.espacio_id)
  execute function public.tg_espacio_persona_mueve_visitas();

-- Los triggers corren sin EXECUTE para nadie (0035): las funciones son internas.
revoke all on function public.tg_visita_union_redirige() from public, anon, authenticated;
revoke all on function public.tg_espacio_persona_mueve_visitas() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. La baja de una casa con visitas de otro colportor: también las que no tienen persona
-- ----------------------------------------------------------------------------

-- Igual que en 0018; la visita se une a su espacio y no a través de su vínculo (con persona es el mismo:
-- ver arriba). Sus privilegios y su trigger siguen (create or replace los conserva).
create or replace function public.tg_ubicacion_baja_con_ventas_o_visitas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;

  if exists (select 1
               from public.venta v
               join public.espacio_persona ep on ep.id = v.espacio_persona_id
               join public.espacio e on e.id = ep.espacio_id
              where e.ubicacion_id = new.id) then
    raise exception using
      errcode = 'UB001',
      message = 'No se puede dar de baja esta casa: tiene ventas registradas. La casa queda como estaba.',
      hint    = 'Si está repetida, marcala como duplicado de la otra desde la vista 10 (sus personas '
                'y ventas pasan a esa); si se cargó con un error, corregí su dirección o su posición.';
  end if;

  if exists (select 1
               from public.visita vi
               join public.espacio e on e.id = vi.espacio_id
              where e.ubicacion_id = new.id
                and vi.colportor_id <> (select auth.uid())) then
    raise exception using
      errcode = 'UB002',
      message = 'No se puede dar de baja esta casa: otro colportor registró visitas en ella. La casa '
                'queda como estaba.',
      hint    = 'Si se cargó con un error, corregí su dirección o su posición.';
  end if;

  return new;
end;
$$;

comment on function public.tg_ubicacion_baja_con_ventas_o_visitas() is
  'BEFORE UPDATE OF deleted_at de ubicacion: no se da de baja una casa con ventas (UB001) ni con '
  'visitas de otro colportor (UB002), con o sin persona (0069). SECURITY DEFINER: ve las ventas y visitas '
  'ajenas. Sin usuario autenticado no se exige (0018, decisión del 02/10).';

-- ----------------------------------------------------------------------------
-- 4. marcar_como_duplicado: las visitas sin persona viajan con su espacio
-- ----------------------------------------------------------------------------

-- Igual que en 0035 (sus privilegios siguen), con tres cambios. Una visita sin persona no cuelga de
-- ningún vínculo, así que hay que moverla por su espacio: (a) un espacio dado de baja con visitas
-- colgando también cuenta como «espacio que importa»; (b) la respuesta cuenta también esas visitas; y
-- (c) al fundir el único de B en el de A, sus visitas pasan al de A ANTES de la baja de B: sin esto, la
-- baja de B (paso 8) vería en una casa de B la visita sin persona de otro colportor y daría UB002, y la
-- unión no se podría hacer. El resto de la función no cambia.
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
          or exists (select 1 from public.visita vi where vi.espacio_id = e.id)
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
   where vi.espacio_id = any (v_espacios);
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

      -- Las visitas que cuelgan de este espacio (las sin persona, y las de un vínculo que se mudó) pasan
      -- al único de A: sin esto, la baja de B (paso 8) las vería en una casa de B y daría UB002.
      update public.visita set espacio_id = v_unico_d where espacio_id = v_e.id;

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
  'UB004 (misma ubicación). No toca el house_status de A (lo recalcula la app). Desde 0069 las '
  'visitas sin persona (colgadas del espacio) viajan con su espacio.';
