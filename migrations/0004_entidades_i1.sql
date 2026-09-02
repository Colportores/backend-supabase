-- Las entidades del hito I1 (§11): "jornada y ubicacion suben a Supabase vía
-- BFF desde la app".
--
-- El esquema de negocio es de Cristian (§4); esto es el mínimo para que la
-- infra de sync se pueda probar de punta a punta, y sirve de molde: toda tabla
-- sincronizable necesita las cuatro columnas de abajo.

create table jornada (
  id            uuid primary key,          -- UUID v7 del dispositivo (§7)
  pk_usuario    uuid not null,
  inicio        timestamptz not null,
  fin           timestamptz,
  km_recorridos numeric(10,2),

  -- El contrato de toda tabla sincronizable:
  sync_version  int not null default 1,    -- LWW (§5.4)
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false
);

create table ubicacion (
  id           uuid primary key,
  pk_usuario   uuid not null,
  -- Sin calle ni número: son datos personales y no salen del dispositivo (P2).
  -- Lo que sube es la geometría y el estado, que es lo que el coordinador ve.
  lat          numeric(9,6),
  lon          numeric(9,6),
  estado       text,

  sync_version int not null default 1,
  updated_at   timestamptz not null default now(),
  deleted      boolean not null default false
);

-- El índice que hace barato el delta: es el mismo orden que usa sync.pull().
create index on jornada  (pk_usuario, updated_at, id);
create index on ubicacion (pk_usuario, updated_at, id);

insert into sync.entidad (nombre, tabla) values
  ('jornada',   'jornada'::regclass),
  ('ubicacion', 'ubicacion'::regclass);
