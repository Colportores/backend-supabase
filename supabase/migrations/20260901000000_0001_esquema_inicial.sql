-- ============================================================================
-- 0001 · Esquema inicial de backend-supabase (Sprint 1 · Fase 0)
--
-- Fuente de verdad: docs-organizacion/docs/esquema-datos.md y contrato-sync-engine.md §2.
-- Materializa TODAS las tablas V1 que viven en el cloud:
--   · pull  (cloud → app): pais, ciudad, zona, campania, producto, coleccion,
--                          producto_coleccion, precio_por_zona
--   · push  (app → cloud): jornada, visita, agenda, venta, venta_item, entrega, cobranza
--   · push + alsoPull    : ubicacion, espacio, espacio_persona (solo IDs), house_status
--   · identidad          : usuario (perfil de auth.users), rol, usuario_rol,
--                          horario_colportor, campania_colportor
--
-- Reglas que esta migración cumple y las siguientes deben respetar:
--   1. IDs uuid generados en el cliente (v7). El default uuid_generate_v7() es solo para seeds.
--   2. Toda tabla lleva created_at, updated_at, created_by, deleted_at (soft delete) y sync_version.
--   3. sync_version y updated_at los asigna el backend, nunca el cliente: trigger BEFORE INSERT
--      (sync_version = 0) y BEFORE UPDATE (+1). created_at/created_by son inmutables en UPDATE.
--      created_at SÍ lo provee el cliente en el INSERT: la fila nace offline y sube después (§8.1).
--   4. Dinero en centavos (integer). Nunca numeric/float para importes.
--   5. SIN DATOS DE PERSONA (Ley 18.331): no existen persona ni nota, ni columnas telefono/notas.
--      Un PR que las agregue se rechaza. espacio_persona.persona_id es un UUID opaco sin FK: la
--      persona vive solo en el dispositivo. La DIRECCIÓN de la casa (calle, numero, numero_depto)
--      sí vive acá: la frontera de privacidad es la persona, no la casa (ADR-018). Sin dirección
--      no funciona el traspaso de zona entre colportores ni el tablero del coordinador.
--   6. RLS habilitada en todas las tablas. La RLS es la autoridad de permisos (ADR-016).
--      Lo que RLS no alcanza por ser a nivel fila (columnas server-authoritative como zona_id)
--      se cierra con triggers, no con confianza en el cliente.
--   7. Forward-only: esta migración no se edita una vez aplicada en un entorno compartido.
--
-- Lo que NO está acá (dueño @BrunoFCapri, ADR-017): RPC de ingesta, cache de client_op_id,
-- sync_log. Llegan en Sprint 3 con su propia migración.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Funciones utilitarias
-- ----------------------------------------------------------------------------

-- UUID v7 (timestamp ms + aleatorio). Postgres 17 no lo trae nativo (llega en 18).
-- Solo para seeds y filas creadas del lado servidor; la app genera los suyos.
create or replace function public.uuid_generate_v7()
returns uuid
language sql
volatile
set search_path = ''
as $$
  select encode(
    set_bit(
      set_bit(
        overlay(
          uuid_send(gen_random_uuid())
          placing substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
          from 1 for 6
        ),
        52, 1
      ),
      53, 1
    ),
    'hex'
  )::uuid;
$$;

comment on function public.uuid_generate_v7() is
  'UUID v7 para seeds/servidor. Los clientes generan los suyos (esquema-datos.md §Principios).';

-- Auditoría en INSERT: sync_version arranca siempre en 0, lo mande el cliente o no.
-- El contrato del motor (§5.4) lo declara server-authoritative: si el cliente pudiera fijarlo,
-- desincronizaría desde la primera escritura el contador con el que se resuelven los conflictos.
create or replace function public.tg_auditoria_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.sync_version := 0;
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.tg_auditoria_insert() is
  'BEFORE INSERT: sync_version = 0 y updated_at = now(), los fije o no el cliente (contrato §5.4).';

-- Auditoría en UPDATE: updated_at y sync_version los pone el servidor, nunca el cliente.
-- created_at y created_by se preservan: el cliente manda la fila entera en el LWW y no debe poder
-- reescribir quién creó el registro ni cuándo. Se coercionan en silencio en vez de fallar, para no
-- mandar a INVALID un job de sync que por lo demás es válido (ADR-013 §Clasificación de errores).
create or replace function public.tg_auditoria_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.sync_version := old.sync_version + 1;
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  return new;
end;
$$;

comment on function public.tg_auditoria_update() is
  'BEFORE UPDATE: updated_at = now(), sync_version = old + 1, created_at/created_by inmutables.';

-- ----------------------------------------------------------------------------
-- 1. Geografía (pull)
-- ----------------------------------------------------------------------------

create table public.pais (
  id            uuid primary key default public.uuid_generate_v7(),
  nombre        text not null,
  iso_code      char(2) not null unique,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
comment on table public.pais is 'País administrativo. V1: solo Uruguay.';

create table public.ciudad (
  id            uuid primary key default public.uuid_generate_v7(),
  nombre        text not null,
  pais_id       uuid not null references public.pais(id),
  lat_centro    double precision not null,
  lon_centro    double precision not null,
  zoom_inicial  smallint not null default 13 check (zoom_inicial between 1 and 22),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
create index ciudad_pais_idx on public.ciudad (pais_id);

-- ----------------------------------------------------------------------------
-- 2. Identidad
-- ----------------------------------------------------------------------------

-- Perfil público del usuario. Su id ES auth.users.id; se crea por trigger al registrarse.
create table public.usuario (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text not null unique,
  nombre        text not null default '',
  apellido      text not null default '',
  zona_id       uuid,                                   -- FK más abajo (zona depende de campania)
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
comment on table public.usuario is
  'Perfil del usuario del sistema (colportor, coordinador, admin…). 1:1 con auth.users. No es PII de clientes.';

create table public.rol (
  id            uuid primary key default public.uuid_generate_v7(),
  codigo        text not null unique
                check (codigo in ('GUEST','COLPORTOR','COORDINADOR','ADMIN','ASISTENTE_FIN','ACOMPANANTE')),
  nombre        text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);

create table public.usuario_rol (
  id            uuid primary key default public.uuid_generate_v7(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  rol_id        uuid not null references public.rol(id),
  valido_desde  timestamptz,
  valido_hasta  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  check (valido_hasta is null or valido_desde is null or valido_hasta > valido_desde)
);
create index usuario_rol_usuario_idx on public.usuario_rol (usuario_id);

create table public.horario_colportor (
  id            uuid primary key default public.uuid_generate_v7(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  dia_semana    smallint not null check (dia_semana between 0 and 6),   -- 0 = domingo
  slot_codigo   text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
create index horario_colportor_usuario_idx on public.horario_colportor (usuario_id);

-- ----------------------------------------------------------------------------
-- 3. Campañas y zonas (pull)
-- ----------------------------------------------------------------------------

create table public.campania (
  id              uuid primary key default public.uuid_generate_v7(),
  nombre          text not null,
  tipo            text not null check (tipo in ('VERANO','INVIERNO','PERMANENTE')),
  fecha_inicio    date not null,
  fecha_fin       date,
  ciudad_id       uuid not null references public.ciudad(id),
  coordinador_id  uuid references public.usuario(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid references public.usuario(id) on delete set null,
  deleted_at      timestamptz,
  sync_version    bigint not null default 0,
  check (fecha_fin is null or fecha_fin >= fecha_inicio)
);
create index campania_ciudad_idx on public.campania (ciudad_id);

create table public.zona (
  id                uuid primary key default public.uuid_generate_v7(),
  nombre            text not null,
  ciudad_id         uuid not null references public.ciudad(id),
  campania_id       uuid references public.campania(id),
  poligono_geojson  jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.usuario(id) on delete set null,
  deleted_at        timestamptz,
  sync_version      bigint not null default 0
);
create index zona_ciudad_idx on public.zona (ciudad_id);
create index zona_campania_idx on public.zona (campania_id);

alter table public.usuario
  add constraint usuario_zona_fk foreign key (zona_id) references public.zona(id) on delete set null;
alter table public.pais
  add constraint pais_created_by_fk foreign key (created_by) references public.usuario(id) on delete set null;
alter table public.ciudad
  add constraint ciudad_created_by_fk foreign key (created_by) references public.usuario(id) on delete set null;

create table public.campania_colportor (
  id            uuid primary key default public.uuid_generate_v7(),
  campania_id   uuid not null references public.campania(id),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  zona_id       uuid references public.zona(id),
  meta_libros   integer check (meta_libros is null or meta_libros >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  unique (campania_id, usuario_id)
);
create index campania_colportor_usuario_idx on public.campania_colportor (usuario_id);

-- ----------------------------------------------------------------------------
-- 4. Catálogo (pull, realtime)
-- ----------------------------------------------------------------------------

create table public.producto (
  id                  uuid primary key default public.uuid_generate_v7(),
  nombre              text not null,
  descripcion         text,
  tipo                text not null check (tipo in ('LIBRO','REVISTA','MATERIAL','MISIONERO')),
  es_bonificable      boolean not null default false,
  es_misionero        boolean not null default false,
  precio_base_compra  integer check (precio_base_compra is null or precio_base_compra >= 0), -- centavos
  casa_editora        text,
  imagen_url          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.usuario(id) on delete set null,
  deleted_at          timestamptz,
  sync_version        bigint not null default 0
);

create table public.coleccion (
  id            uuid primary key default public.uuid_generate_v7(),
  nombre        text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);

create table public.producto_coleccion (
  id            uuid primary key default public.uuid_generate_v7(),
  producto_id   uuid not null references public.producto(id),
  coleccion_id  uuid not null references public.coleccion(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  unique (producto_id, coleccion_id)
);

create table public.precio_por_zona (
  id            uuid primary key default public.uuid_generate_v7(),
  producto_id   uuid references public.producto(id),
  coleccion_id  uuid references public.coleccion(id),
  zona_id       uuid not null references public.zona(id),
  precio_venta  integer not null check (precio_venta >= 0),                 -- centavos
  valido_desde  date not null default current_date,
  valido_hasta  date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  -- exactamente uno de producto_id / coleccion_id
  check ((producto_id is null) <> (coleccion_id is null)),
  check (valido_hasta is null or valido_hasta >= valido_desde)
);
create index precio_por_zona_zona_idx on public.precio_por_zona (zona_id);
create index precio_por_zona_producto_idx on public.precio_por_zona (producto_id);

-- Sin dos precios vigentes a la vez para lo mismo en la misma zona: "el precio actual" tiene que
-- ser una sola fila. Con valido_hasta null el rango queda abierto, así que sin esto dos filas
-- abiertas del mismo producto conviven y la app elige cualquiera. Una por producto y otra por
-- colección porque el check de arriba garantiza que solo una de las dos columnas está cargada.
create extension if not exists btree_gist with schema extensions;

alter table public.precio_por_zona
  add constraint precio_por_zona_producto_sin_solape
  exclude using gist (
    zona_id with =,
    producto_id with =,
    daterange(valido_desde, valido_hasta, '[]') with &&
  ) where (deleted_at is null and producto_id is not null);

alter table public.precio_por_zona
  add constraint precio_por_zona_coleccion_sin_solape
  exclude using gist (
    zona_id with =,
    coleccion_id with =,
    daterange(valido_desde, valido_hasta, '[]') with &&
  ) where (deleted_at is null and coleccion_id is not null);

-- ----------------------------------------------------------------------------
-- 5. Modelo Espacio (push + alsoPull) — ADR-001, ADR-012
-- ----------------------------------------------------------------------------

create table public.ubicacion (
  id            uuid primary key default public.uuid_generate_v7(),
  tipo          text not null check (tipo in ('CASA','NEGOCIO','EDIFICIO')),
  -- Nullable a propósito: el alta por marcador manual sobre el mapa (sin GPS ni dirección
  -- conocida) es un camino documentado, y HU-UBI los declara campos opcionales.
  calle         text,
  numero        text,
  lat           double precision not null check (lat between -90 and 90),
  lon           double precision not null check (lon between -180 and 180),
  ciudad_id     uuid not null references public.ciudad(id),
  zona_id       uuid references public.zona(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
comment on table public.ubicacion is
  'Casa del territorio, con su dirección. Sin datos de persona (ADR-018). Compartida por zona: '
  'al rotar el colportor, quien toma la zona recibe las casas ya trabajadas con su estado.';

-- Índice de deduplicación: NO es único. RF-UB08/R-UB08 definen la dedup como una advertencia del
-- cliente (misma ciudad + radio <= 30m + Levenshtein >= 0.85 + número exacto) que ofrece tres
-- salidas, y una de ellas es "crear igual con justificación". Un unique index rechazaría ese caso
-- de uso deliberado, y encima devolvería el error recién en el sync, sobre una fila ya guardada
-- en el dispositivo. Acá el índice solo acelera la búsqueda del cliente y de los reportes.
create index ubicacion_dedup_idx
  on public.ubicacion (ciudad_id, lower(calle), lower(numero)) where deleted_at is null;
create index ubicacion_zona_idx on public.ubicacion (zona_id);
create index ubicacion_created_by_idx on public.ubicacion (created_by);

create table public.espacio (
  id            uuid primary key default public.uuid_generate_v7(),
  ubicacion_id  uuid not null references public.ubicacion(id),
  numero_depto  text,
  piso          text,
  descripcion   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
comment on column public.espacio.numero_depto is
  'Va al cloud siempre. ADR-012 lo propagaba solo con operaciones financieras; ADR-018 eliminó '
  'esa política diferenciada junto con la de calle/numero.';
create index espacio_ubicacion_idx on public.espacio (ubicacion_id);
create index espacio_created_by_idx on public.espacio (created_by);

-- Solo IDs: persona_id es opaco, la persona existe únicamente en el dispositivo (Ley 18.331).
create table public.espacio_persona (
  id                        uuid primary key default public.uuid_generate_v7(),
  espacio_id                uuid not null references public.espacio(id),
  persona_id                uuid not null,
  ubicacion_cobranza_alt_id uuid references public.ubicacion(id),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  created_by                uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at                timestamptz,
  sync_version              bigint not null default 0,
  unique (espacio_id, persona_id)
);
comment on column public.espacio_persona.persona_id is
  'UUID opaco generado en el dispositivo. Sin FK a propósito: la tabla persona no existe en cloud.';
create index espacio_persona_espacio_idx on public.espacio_persona (espacio_id);
create index espacio_persona_created_by_idx on public.espacio_persona (created_by);

-- ----------------------------------------------------------------------------
-- 6. Operación de campo (push)
-- ----------------------------------------------------------------------------

create table public.jornada (
  id                    uuid primary key default public.uuid_generate_v7(),
  colportor_id          uuid not null default auth.uid() references public.usuario(id),
  inicio                timestamptz not null,
  fin                   timestamptz,
  acompaniante_id       uuid references public.usuario(id) on delete set null,
  tipo_acompaniamiento  text,
  total_visitas         integer not null default 0 check (total_visitas >= 0),
  total_ventas          integer not null default 0 check (total_ventas >= 0),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at            timestamptz,
  sync_version          bigint not null default 0,
  check (fin is null or fin >= inicio)
);
create index jornada_colportor_idx on public.jornada (colportor_id, inicio desc);

-- Sin columna `notas`: contiene PII y queda local (esquema-datos.md §Tablas que NO se sincronizan).
create table public.visita (
  id                  uuid primary key default public.uuid_generate_v7(),
  espacio_persona_id  uuid not null references public.espacio_persona(id),
  fecha               timestamptz not null,
  tipo_resultado      text not null check (tipo_resultado in ('VENTA','NO_CONTESTO','RECHAZO','ENTREVISTA')),
  colportor_id        uuid not null default auth.uid() references public.usuario(id),
  jornada_id          uuid references public.jornada(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at          timestamptz,
  sync_version        bigint not null default 0
);
create index visita_colportor_idx on public.visita (colportor_id, fecha desc);
create index visita_espacio_persona_idx on public.visita (espacio_persona_id);

create table public.agenda (
  id                  uuid primary key default public.uuid_generate_v7(),
  espacio_persona_id  uuid not null references public.espacio_persona(id),
  tipo                text not null check (tipo in ('ENTREVISTA','COBRANZA')),
  fecha_programada    timestamptz not null,
  slot_codigo         text,
  es_estricta         boolean not null default false,
  ubicacion_alt_id    uuid references public.ubicacion(id),
  estado              text not null default 'PENDIENTE' check (estado in ('PENDIENTE','COMPLETADA','CANCELADA')),
  colportor_id        uuid not null default auth.uid() references public.usuario(id),
  visita_id           uuid references public.visita(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at          timestamptz,
  sync_version        bigint not null default 0
);
create index agenda_colportor_idx on public.agenda (colportor_id, fecha_programada);

create table public.venta (
  id                  uuid primary key default public.uuid_generate_v7(),
  espacio_persona_id  uuid not null references public.espacio_persona(id),
  numero_talonario    text not null,
  monto_total         integer not null check (monto_total >= 0),          -- centavos
  fecha               timestamptz not null,
  colportor_id        uuid not null default auth.uid() references public.usuario(id),
  visita_id           uuid references public.visita(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at          timestamptz,
  sync_version        bigint not null default 0
);
create index venta_colportor_idx on public.venta (colportor_id, fecha desc);
create unique index venta_talonario_por_colportor_idx
  on public.venta (colportor_id, numero_talonario) where deleted_at is null;

create table public.venta_item (
  id               uuid primary key default public.uuid_generate_v7(),
  venta_id         uuid not null references public.venta(id),
  producto_id      uuid not null references public.producto(id),
  cantidad         integer not null check (cantidad > 0),
  precio_unitario  integer not null check (precio_unitario >= 0),         -- centavos
  subtotal         integer not null check (subtotal >= 0),                -- centavos
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at       timestamptz,
  sync_version     bigint not null default 0,
  -- El ítem es aritmética pura. El descuento informal del colportor (supuesto S38) se aplica en
  -- venta.monto_total, que por eso NO se ata a la suma de los ítems.
  check (subtotal = cantidad * precio_unitario)
);
create index venta_item_venta_idx on public.venta_item (venta_id);
create index venta_item_producto_idx on public.venta_item (producto_id);

create table public.entrega (
  id             uuid primary key default public.uuid_generate_v7(),
  venta_id       uuid not null references public.venta(id),
  producto_id    uuid not null references public.producto(id),
  cantidad       integer not null check (cantidad > 0),
  fecha_entrega  timestamptz,
  pendiente      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at     timestamptz,
  sync_version   bigint not null default 0
);
create index entrega_venta_idx on public.entrega (venta_id);
create index entrega_producto_idx on public.entrega (producto_id);

create table public.cobranza (
  id            uuid primary key default public.uuid_generate_v7(),
  venta_id      uuid not null references public.venta(id),
  monto         integer not null check (monto > 0),                       -- centavos
  medio         text not null check (medio in ('EFECTIVO','TARJETA','TRANSFERENCIA')),
  fecha         timestamptz not null,
  numero_cuota  smallint check (numero_cuota is null or numero_cuota > 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0
);
create index cobranza_venta_idx on public.cobranza (venta_id);

-- ----------------------------------------------------------------------------
-- 7. Cache de mapa (push + alsoPull) — ADR-010
-- ----------------------------------------------------------------------------

create table public.house_status (
  ubicacion_id    uuid primary key references public.ubicacion(id),
  lat             double precision not null,
  lon             double precision not null,
  tipo_ubicacion  text not null check (tipo_ubicacion in ('CASA','NEGOCIO','EDIFICIO')),
  zona_id         uuid references public.zona(id),
  color           text not null check (color in (
                    'ENTREGA_Y_COBRANZA_PENDIENTE',  -- 1
                    'COBRANZA_PENDIENTE',            -- 2
                    'ENTREVISTA_PROGRAMADA',         -- 3
                    'VENTA_COMPLETA',                -- 4
                    'ENTREVISTA_SIN_VENTA',          -- 5
                    'SIN_CONTESTAR',                 -- 6
                    'RECHAZO'                        -- 7
                  )),
  prioridad       smallint not null check (prioridad between 1 and 7),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at      timestamptz,
  sync_version    bigint not null default 0,
  -- color y prioridad son el mismo dato en dos formas: ADR-010 fija el mapeo 1:1. Se guardan
  -- ambos porque el cliente calcula la cache y sube la fila entera, pero no pueden contradecirse
  -- o el mapa pinta un pin de un color y lo ordena por otro.
  check (prioridad = case color
                       when 'ENTREGA_Y_COBRANZA_PENDIENTE' then 1
                       when 'COBRANZA_PENDIENTE'           then 2
                       when 'ENTREVISTA_PROGRAMADA'        then 3
                       when 'VENTA_COMPLETA'               then 4
                       when 'ENTREVISTA_SIN_VENTA'         then 5
                       when 'SIN_CONTESTAR'                then 6
                       when 'RECHAZO'                      then 7
                     end)
);
create index house_status_created_by_idx on public.house_status (created_by);
comment on table public.house_status is
  'Estado visual por ubicación, agregado (el último colportor que visitó manda). Única vista que recibe el coordinador.';
create index house_status_zona_idx on public.house_status (zona_id);

-- ----------------------------------------------------------------------------
-- 8. Triggers de auditoría (todas las tablas) y alta de perfil
-- ----------------------------------------------------------------------------

-- La lista de tablas vive UNA sola vez: este bloque cablea auditoría y habilita RLS en el mismo
-- recorrido. Estaba duplicada en dos loops idénticos y una tabla nueva podía entrar a uno y no al
-- otro, quedando sin trigger de auditoría o sin RLS sin que nada lo gritara.
do $$
declare
  t text;
begin
  foreach t in array array[
    'pais','ciudad','usuario','rol','usuario_rol','horario_colportor','campania','zona',
    'campania_colportor','producto','coleccion','producto_coleccion','precio_por_zona',
    'ubicacion','espacio','espacio_persona','jornada','visita','agenda','venta','venta_item',
    'entrega','cobranza','house_status'
  ] loop
    execute format(
      'create trigger %I before insert on public.%I for each row execute function public.tg_auditoria_insert()',
      t || '_auditoria_insert', t
    );
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.tg_auditoria_update()',
      t || '_auditoria_update', t
    );
    execute format('alter table public.%I enable row level security', t);
  end loop;
end
$$;

-- Al registrarse en Supabase Auth se crea el perfil público con el mismo id.
create or replace function public.tg_auth_usuario_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.usuario (id, email, nombre, apellido, created_by)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'nombre', ''),
    coalesce(new.raw_user_meta_data ->> 'apellido', ''),
    new.id
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.tg_auth_usuario_nuevo();

-- ----------------------------------------------------------------------------
-- 9. Helpers de autorización (usados por las políticas RLS)
-- ----------------------------------------------------------------------------

-- ¿El usuario autenticado tiene el rol de negocio vigente?
create or replace function public.tiene_rol(p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.usuario_rol ur
    join public.rol r on r.id = ur.rol_id
    join public.usuario u on u.id = ur.usuario_id
    where ur.usuario_id = auth.uid()
      and r.codigo = p_codigo
      and ur.deleted_at is null
      -- La baja administrativa (ADR-011) revoca las sesiones, pero eso pasa fuera de esta base.
      -- Si la revocación falla o llega tarde, el rol tiene que caerse igual acá.
      and u.deleted_at is null
      and r.deleted_at is null
      and (ur.valido_desde is null or ur.valido_desde <= now())
      and (ur.valido_hasta is null or ur.valido_hasta > now())
  );
$$;

-- Zonas en las que el usuario autenticado trabaja: asignación directa (usuario.zona_id, que fija
-- el coordinador — HU-CAM-006) más las campañas efectivamente vigentes hoy. La vigencia se filtra
-- por las fechas de la campaña: una inscripción de una campaña que terminó hace meses no se
-- soft-deletea sola, y sin este filtro seguiría dando acceso a la zona para siempre.
create or replace function public.mis_zonas()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.zona_id from public.usuario u
   where u.id = auth.uid() and u.zona_id is not null and u.deleted_at is null
  union
  select cc.zona_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and cc.deleted_at is null
     and cc.zona_id is not null
     and u.deleted_at is null
     and c.deleted_at is null
     and c.fecha_inicio <= current_date
     and (c.fecha_fin is null or c.fecha_fin >= current_date);
$$;

revoke execute on function public.tiene_rol(text), public.mis_zonas() from public, anon;
grant execute on function public.tiene_rol(text), public.mis_zonas() to authenticated, service_role;

-- 9.1 Guardas de columna: lo que RLS no puede expresar
--
-- RLS decide por fila, no por columna. Estas dos columnas deciden QUÉ FILAS ve el usuario, así que
-- dejarlas escribir libremente convierte a la RLS en una puerta con la llave puesta del lado de
-- afuera. Se coercionan al valor viejo en silencio (no se lanza excepción) para no mandar a INVALID
-- un job de sync que por lo demás es correcto: el cliente manda la fila entera en cada LWW.
--
-- auth.uid() null = service_role o proceso servidor (seeds, jobs, RPC de ingesta): no se toca.

-- usuario.zona_id lo asigna el coordinador (HU-CAM-006). R-SY04 lo declara campo crítico que
-- "siempre gana del backend": sin esto un colportor se auto-asigna cualquier zona con un update de
-- su propia fila y mis_zonas() le abre las casas y el avance de esa zona.
create or replace function public.tg_usuario_zona_servidor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.zona_id is distinct from old.zona_id
     and auth.uid() is not null
     and not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    new.zona_id := old.zona_id;
  end if;
  return new;
end;
$$;

create trigger usuario_zona_servidor
  before update on public.usuario
  for each row execute function public.tg_usuario_zona_servidor();

-- ubicacion/house_status son compartidas por zona: mover una fila a una zona ajena inyecta datos
-- en el mapa de otro colportor. El dueño sigue pudiendo editar su fila (R-CM04: la asignación de
-- zona es referencia, no restricción) — lo único que no puede es mandarla a una zona que no trabaja.
create or replace function public.tg_zona_propia()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.zona_id is distinct from old.zona_id
     and new.zona_id is not null
     and auth.uid() is not null
     and not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'))
     and new.zona_id not in (select public.mis_zonas()) then
    new.zona_id := old.zona_id;
  end if;
  return new;
end;
$$;

create trigger ubicacion_zona_propia
  before update on public.ubicacion
  for each row execute function public.tg_zona_propia();

create trigger house_status_zona_propia
  before update on public.house_status
  for each row execute function public.tg_zona_propia();

-- ----------------------------------------------------------------------------
-- 10. Privilegios y RLS
-- ----------------------------------------------------------------------------

-- La imagen de Supabase define default privileges que dan ALL a anon/authenticated sobre lo que
-- crea `postgres`. Se ajustan para esta y para las migraciones futuras:
--   · anon no ve nada: todo pasa por el BFF con el JWT del usuario (ADR-016).
--   · authenticated: nunca DELETE ni TRUNCATE (soft delete vía UPDATE).
--   · service_role: todo (seeds, jobs).
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke delete, truncate, references, trigger on tables from authenticated;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

revoke all on all tables in schema public from authenticated;
grant select, insert, update on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;

-- Las funciones se revocan de PUBLIC, no de anon. Postgres otorga EXECUTE al pseudo-rol PUBLIC en
-- cada CREATE FUNCTION, y anon lo hereda: revocarle a anon un grant directo que nunca tuvo deja el
-- privilegio heredado intacto. Con las funciones de hoy el impacto es nulo, pero el RPC de ingesta
-- de Sprint 3 llega con SECURITY DEFINER y ahí esto deja de ser cosmético.
alter default privileges for role postgres in schema public revoke all on functions from public, anon;
revoke all on all functions in schema public from public, anon;

-- uuid_generate_v7() se otorga explícito: es el default de casi toda PK, y evaluar un default
-- también chequea EXECUTE. Sin este grant, authenticated no puede insertar sin pasar el id.
grant execute on function public.uuid_generate_v7() to authenticated, service_role;
grant execute on function public.tiene_rol(text), public.mis_zonas() to authenticated, service_role;

-- RLS se habilita en el mismo loop que cablea la auditoría (sección 8), para que la lista de
-- tablas exista en un solo lugar.

-- 10.1 Tablas pull (catálogo, geografía, campañas): lectura para todo autenticado, incluidas
--      las bajas lógicas (la app necesita el tombstone para borrar su réplica). Escribe ADMIN.
do $$
declare
  t text;
begin
  foreach t in array array[
    'pais','ciudad','zona','campania','producto','coleccion','producto_coleccion','rol'
  ] loop
    execute format('create policy %I on public.%I for select to authenticated using (true)',
                   t || '_select_autenticado', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.tiene_rol(''ADMIN''))',
                   t || '_insert_admin', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.tiene_rol(''ADMIN'')) with check (public.tiene_rol(''ADMIN''))',
                   t || '_update_admin', t);
  end loop;
end
$$;

-- precio_por_zona queda fuera del loop de arriba: el precio de VENTA por zona lo define el
-- Coordinador, no el Admin (R-CT02, HU-CAT-005). El Admin define el precio de compra, que vive en
-- producto.precio_base_compra. Y el Coordinador solo toca las zonas de las campañas que coordina.
create policy precio_por_zona_select_autenticado on public.precio_por_zona
  for select to authenticated using (true);

create policy precio_por_zona_insert_staff on public.precio_por_zona
  for insert to authenticated
  with check (
    public.tiene_rol('ADMIN')
    or (public.tiene_rol('COORDINADOR') and exists (
          select 1 from public.zona z
            join public.campania c on c.id = z.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = auth.uid()))
  );

create policy precio_por_zona_update_staff on public.precio_por_zona
  for update to authenticated
  using (
    public.tiene_rol('ADMIN')
    or (public.tiene_rol('COORDINADOR') and exists (
          select 1 from public.zona z
            join public.campania c on c.id = z.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = auth.uid()))
  )
  with check (
    public.tiene_rol('ADMIN')
    or (public.tiene_rol('COORDINADOR') and exists (
          select 1 from public.zona z
            join public.campania c on c.id = z.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = auth.uid()))
  );

-- 10.2 Identidad
create policy usuario_select_propio_o_staff on public.usuario
  for select to authenticated
  using (id = auth.uid() or public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'));
create policy usuario_update_propio on public.usuario
  for update to authenticated
  using (id = auth.uid() or public.tiene_rol('ADMIN'))
  with check (id = auth.uid() or public.tiene_rol('ADMIN'));

create policy usuario_rol_select on public.usuario_rol
  for select to authenticated
  using (usuario_id = auth.uid() or public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'));
create policy usuario_rol_insert_admin on public.usuario_rol
  for insert to authenticated with check (public.tiene_rol('ADMIN'));
create policy usuario_rol_update_admin on public.usuario_rol
  for update to authenticated using (public.tiene_rol('ADMIN')) with check (public.tiene_rol('ADMIN'));

create policy horario_colportor_propio on public.horario_colportor
  for all to authenticated
  using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());
-- El coordinador arma la ruta de la campaña con los horarios de su gente: mismo bypass de lectura
-- que tienen usuario, usuario_rol y campania_colportor.
create policy horario_colportor_select_staff on public.horario_colportor
  for select to authenticated
  using (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'));

create policy campania_colportor_select on public.campania_colportor
  for select to authenticated
  using (usuario_id = auth.uid() or public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'));
create policy campania_colportor_insert_staff on public.campania_colportor
  for insert to authenticated
  with check (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'));
create policy campania_colportor_update_staff on public.campania_colportor
  for update to authenticated
  using (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'))
  with check (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR'));

-- 10.3 Modelo Espacio (compartido por zona, LWW): ve y escribe quien trabaja la zona.
create policy ubicacion_por_zona_select on public.ubicacion
  for select to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = auth.uid() or public.tiene_rol('COORDINADOR') or public.tiene_rol('ADMIN'));
create policy ubicacion_por_zona_insert on public.ubicacion
  for insert to authenticated
  with check (created_by = auth.uid() and (zona_id is null or zona_id in (select public.mis_zonas())));
create policy ubicacion_por_zona_update on public.ubicacion
  for update to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = auth.uid())
  with check (zona_id is null or zona_id in (select public.mis_zonas()) or created_by = auth.uid());

create policy espacio_por_zona_select on public.espacio
  for select to authenticated
  using (exists (select 1 from public.ubicacion u where u.id = ubicacion_id
                   and (u.zona_id in (select public.mis_zonas()) or u.created_by = auth.uid()))
         or public.tiene_rol('COORDINADOR') or public.tiene_rol('ADMIN'));
create policy espacio_por_zona_insert on public.espacio
  for insert to authenticated
  with check (created_by = auth.uid() and exists (select 1 from public.ubicacion u where u.id = ubicacion_id
                   and (u.zona_id in (select public.mis_zonas()) or u.created_by = auth.uid())));
create policy espacio_por_zona_update on public.espacio
  for update to authenticated
  using (exists (select 1 from public.ubicacion u where u.id = ubicacion_id
                   and (u.zona_id in (select public.mis_zonas()) or u.created_by = auth.uid())));

-- espacio_persona: cada colportor solo ve/escribe los vínculos que creó (la persona es suya).
create policy espacio_persona_propio on public.espacio_persona
  for all to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());

create policy house_status_por_zona_select on public.house_status
  for select to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = auth.uid() or public.tiene_rol('COORDINADOR') or public.tiene_rol('ADMIN'));
create policy house_status_por_zona_insert on public.house_status
  for insert to authenticated
  with check (created_by = auth.uid() and (zona_id is null or zona_id in (select public.mis_zonas())));
create policy house_status_por_zona_update on public.house_status
  for update to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = auth.uid());

-- 10.4 Operación de campo: solo el colportor dueño. (Lectura del coordinador: Fase 2.)
do $$
declare
  t text;
begin
  foreach t in array array['jornada','visita','agenda','venta'] loop
    execute format(
      'create policy %I on public.%I for all to authenticated using (colportor_id = auth.uid()) with check (colportor_id = auth.uid())',
      t || '_propio', t);
  end loop;
  foreach t in array array['venta_item','entrega','cobranza'] loop
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (exists (select 1 from public.venta v where v.id = venta_id and v.colportor_id = auth.uid()))
         with check (exists (select 1 from public.venta v where v.id = venta_id and v.colportor_id = auth.uid()))',
      t || '_propio', t);
  end loop;
end
$$;

-- ----------------------------------------------------------------------------
-- 11. Realtime: solo catálogo (ADR-002, contrato §2 `realtime: true`)
-- ----------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime
      add table public.producto, public.coleccion, public.producto_coleccion, public.precio_por_zona;
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 12. Datos de referencia (no son seeds de negocio: esos llegan en Sprint 4)
-- ----------------------------------------------------------------------------

-- Catálogo de roles con IDs fijos: los referencian seeds, tests y el panel.
insert into public.rol (id, codigo, nombre) values
  ('01920000-0000-7000-8000-000000000001', 'GUEST',         'Invitado'),
  ('01920000-0000-7000-8000-000000000002', 'COLPORTOR',     'Colportor'),
  ('01920000-0000-7000-8000-000000000003', 'COORDINADOR',   'Coordinador'),
  ('01920000-0000-7000-8000-000000000004', 'ADMIN',         'Administrador'),
  ('01920000-0000-7000-8000-000000000005', 'ASISTENTE_FIN', 'Asistente financiero'),
  ('01920000-0000-7000-8000-000000000006', 'ACOMPANANTE',   'Acompañante')
on conflict (codigo) do nothing;
