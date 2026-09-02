-- Las 18 entidades de V1 (§2), y las dos que no están.

\set QUIET on
\set ON_ERROR_STOP on

begin;

create or replace function assert(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  -- `is not true` y no `not p_cond`: con p_cond NULL, `not NULL` es NULL, el
  -- IF no entra y el assert pasa en silencio. Y NULL es justo lo que devuelve
  -- una comparación contra un campo que no vino —`jsonb_array_length(NULL) = 2`
  -- da NULL, no false— así que la forma ingenua deja pasar exactamente los
  -- fallos que este archivo existe para encontrar.
  if p_cond is not true then raise exception 'FALLÓ: %', p_msg; end if;
end $$;

-- ---------------------------------------------------------------------------
do $$
declare v_faltan text := '';
begin
  -- La lista de §2. Si alguien agrega una entidad al contrato y se olvida de
  -- la migración, esto lo dice con nombre y apellido.
  select string_agg(e, ' ') into v_faltan
  from unnest(array['pais','ciudad','zona','coleccion','producto','campania',
                    'precio_por_zona','visita','agenda','venta','venta_item',
                    'entrega','entrega_item','cobranza','espacio','house_status',
                    'jornada','ubicacion']) e
  where not exists (select 1 from sync.entidad where nombre = e);

  perform assert(coalesce(v_faltan,'') = '', 'sin registrar: ' || v_faltan);
  raise notice 'OK  las 18 entidades de V1 están registradas';
end $$;

-- ---------------------------------------------------------------------------
do $$
begin
  -- P2 del contrato de datos: sin datos personales en el cloud. Que `persona` y
  -- `nota` no tengan tabla no es un olvido, es el requisito.
  perform assert(not exists (select 1 from sync.entidad where nombre in ('persona','nota')),
    'persona/nota no pueden estar registradas para sync');
  perform assert(to_regclass('public.persona') is null, 'persona no puede tener tabla en el cloud');
  perform assert(to_regclass('public.nota') is null, 'nota tampoco');
  raise notice 'OK  persona y nota no existen en el cloud (P2)';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare v_rows jsonb;
begin
  -- Un catálogo no tiene dueño: le baja igual a cualquier colportor.
  v_rows := sync.pull('99999999-9999-4999-8999-999999999999'::uuid,
                      array['producto','precio_por_zona']) -> 'rows';

  perform assert(jsonb_array_length(v_rows -> 'producto') = 4,
    'el catálogo baja aunque el colportor no tenga nada propio');
  perform assert(jsonb_typeof(v_rows -> 'precio_por_zona' -> 0 -> 'precio') = 'string',
    'y los precios como texto');
  raise notice 'OK  los catálogos son globales';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','01a0490a-0000-7000-8000-000000000001',
      'entity','producto','op','insert',
      'payload', jsonb_build_object('id','01a04904-0000-7000-8000-0000000000f1',
                                    'nombre','pirata','precio_compra','1.00'))));

  perform assert(r -> 'results' -> 0 ->> 'code' = 'ENTIDAD_DE_SOLO_LECTURA',
    'el servidor rechaza escribir un catálogo, no alcanza con que el cliente se porte bien');
  perform assert((select count(*) from producto) = 4, 'y no entró nada');
  raise notice 'OK  las réplicas son de solo lectura del lado del servidor';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  -- La pregunta abierta del contrato: qué pasa con un item sin su venta.
  -- La FK responde: `invalid`, visible, corregible. Es la salida que costaba
  -- cero y ahora está verificada.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','01a0490a-0000-7000-8000-000000000002',
      'entity','venta_item','op','insert',
      'payload', jsonb_build_object('id','01a04908-0000-7000-8000-0000000000f1',
                                    'pk_venta','01a04909-0000-7000-8000-0000000000ff',
                                    'cantidad',1,'precio_unitario','575.00'))));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'invalid',
    'un venta_item sin su venta no puede entrar');
  perform assert(left(r -> 'results' -> 0 ->> 'code', 2) = '23',
    'y el código es una violación de integridad, no un 500');
  raise notice 'OK  un item huérfano lo frena la FK (dependencias entre entidades)';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; v_venta uuid := '01a04909-0000-7000-8000-000000000001';
begin
  -- Y con su venta delante, en el mismo lote, entra.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','01a0490a-0000-7000-8000-000000000003',
      'entity','venta','op','insert',
      'payload', jsonb_build_object('id', v_venta, 'total','575.00',
        'entregado','0.00','estado','PENDIENTE_DE_COBRO','fecha','2026-11-13T14:00:00Z')),
    jsonb_build_object('client_op_id','01a0490a-0000-7000-8000-000000000004',
      'entity','venta_item','op','insert',
      'payload', jsonb_build_object('id','01a04908-0000-7000-8000-000000000002',
        'pk_venta', v_venta, 'pk_producto','01a04904-0000-7000-8000-000000000001',
        'cantidad',1,'precio_unitario','575.00'))));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'accepted', 'la venta entra');
  perform assert(r -> 'results' -> 1 ->> 'outcome' = 'accepted',
    'y el item detrás también: §5.5 garantiza el orden dentro del lote');
  raise notice 'OK  venta e items en el mismo lote, en orden';
end $$;

rollback;
