-- Las entidades de V1 (§2 del contrato del motor).
--
-- Aparece acá una distinción que `0004` no necesitaba: hay tablas **de un
-- colportor** y tablas **globales**. Una venta tiene dueño; el catálogo de
-- productos no. `sync.pull` filtraba todo por `pk_usuario`, así que un catálogo
-- registrado tal cual no le habría bajado nunca a nadie.

alter table sync.entidad
  add column por_usuario  boolean not null default true,
  -- Las entidades `pull` del contrato son réplica de solo lectura: la app nunca
  -- las escribe. El servidor lo hace cumplir; no alcanza con que el cliente se
  -- porte bien.
  add column permite_push boolean not null default true;

comment on column sync.entidad.por_usuario is
  'false = tabla global sin pk_usuario (catálogos). El delta no la filtra por '
  'usuario y la RLS la deja leer a cualquier autenticado.';

-- ---------------------------------------------------------------------------
-- Catálogos: bajan del cloud, nadie los escribe desde el celular
-- ---------------------------------------------------------------------------

create table pais (
  id uuid primary key, nombre text not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table ciudad (
  id uuid primary key, pk_pais uuid references pais(id), nombre text not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table zona (
  id uuid primary key, pk_ciudad uuid references ciudad(id), nombre text not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table coleccion (
  id uuid primary key, nombre text not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table producto (
  id uuid primary key, pk_coleccion uuid references coleccion(id),
  nombre text not null,
  -- Decimal, nunca float: viaja como string (0001).
  precio_compra numeric(12,2) not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table campania (
  id uuid primary key, nombre text not null,
  desde date not null, hasta date not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table precio_por_zona (
  id uuid primary key,
  pk_producto uuid not null references producto(id),
  pk_zona uuid not null references zona(id),
  precio numeric(12,2) not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

-- ---------------------------------------------------------------------------
-- Lo que sube el colportor
-- ---------------------------------------------------------------------------
--
-- Ninguna de estas tablas tiene nombre, teléfono ni dirección: P2 del contrato
-- de datos —"sin datos personales en el cloud"— no es una recomendación. La
-- `persona` y la `nota` viven solo en el celular y solo salen en el backup E2E,
-- así que **no tienen tabla acá**: no es un olvido.

create table visita (
  id uuid primary key, pk_usuario uuid not null,
  pk_ubicacion uuid, resultado text not null, fecha timestamptz not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table agenda (
  id uuid primary key, pk_usuario uuid not null,
  pk_ubicacion uuid, cuando timestamptz not null, motivo text,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table venta (
  id uuid primary key, pk_usuario uuid not null,
  pk_ubicacion uuid, pk_campania uuid references campania(id),
  total numeric(12,2) not null, entregado numeric(12,2) not null default 0,
  estado text not null, fecha timestamptz not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table venta_item (
  id uuid primary key, pk_usuario uuid not null,
  -- La FK es lo que hace que un item no pueda entrar sin su venta. Ver
  -- "Dependencias entre entidades" en el contrato: es la salida barata.
  pk_venta uuid not null references venta(id),
  pk_producto uuid references producto(id),
  cantidad int not null, precio_unitario numeric(12,2) not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table entrega (
  id uuid primary key, pk_usuario uuid not null,
  pk_venta uuid references venta(id), cantidad int not null,
  fecha timestamptz not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table cobranza (
  id uuid primary key, pk_usuario uuid not null,
  pk_venta uuid references venta(id), monto numeric(12,2) not null,
  medio text, fecha timestamptz not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table espacio (
  id uuid primary key, pk_usuario uuid not null,
  pk_ubicacion uuid, tipo text, referencia text,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table house_status (
  id uuid primary key, pk_usuario uuid not null,
  pk_ubicacion uuid, estado text not null,
  sync_version int not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

-- El índice del delta, el mismo orden que usa sync.pull().
create index on visita       (pk_usuario, updated_at, id);
create index on agenda       (pk_usuario, updated_at, id);
create index on venta        (pk_usuario, updated_at, id);
create index on venta_item   (pk_usuario, updated_at, id);
create index on entrega      (pk_usuario, updated_at, id);
create index on cobranza     (pk_usuario, updated_at, id);
create index on espacio      (pk_usuario, updated_at, id);
create index on house_status (pk_usuario, updated_at, id);
create index on pais            (updated_at, id);
create index on ciudad          (updated_at, id);
create index on zona            (updated_at, id);
create index on coleccion       (updated_at, id);
create index on producto        (updated_at, id);
create index on campania        (updated_at, id);
create index on precio_por_zona (updated_at, id);

-- ---------------------------------------------------------------------------
-- El registro
-- ---------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, por_usuario, permite_push) values
  -- pull: globales, solo lectura
  ('pais',            'pais'::regclass,            false, false),
  ('ciudad',          'ciudad'::regclass,          false, false),
  ('zona',            'zona'::regclass,            false, false),
  ('coleccion',       'coleccion'::regclass,       false, false),
  ('producto',        'producto'::regclass,        false, false),
  ('campania',        'campania'::regclass,        false, false),
  ('precio_por_zona', 'precio_por_zona'::regclass, false, false),
  -- push
  ('visita',       'visita'::regclass,       true, true),
  ('agenda',       'agenda'::regclass,       true, true),
  ('venta',        'venta'::regclass,        true, true),
  ('venta_item',   'venta_item'::regclass,   true, true),
  ('entrega',      'entrega'::regclass,      true, true),
  ('cobranza',     'cobranza'::regclass,     true, true),
  ('espacio',      'espacio'::regclass,      true, true),
  ('house_status', 'house_status'::regclass, true, true);

-- `persona` y `nota` no están, y no van a estar: son `local` (§2).
