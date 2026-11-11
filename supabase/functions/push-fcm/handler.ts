import { ClienteFcm, codigoCorto, type CuentaDeServicio, type ResultadoDeEnvio } from "./fcm.ts";

/**
 * Edge Function `push-fcm` (backend-supabase#237, HU-NOT-003, ADR-014): manda por FCM los avisos que la base dejó en
 * su cola (`push.evento`, migración 0162). No decide nada: la base dice qué avisos hay, a qué token y con qué datos
 * (`push_tomar_pendientes`), y esta función solo los entrega y cuenta cómo salió cada uno (`push_resultado`). La
 * despierta `pg_cron` cada minuto por `pg_net` (migración 0163). Contrato completo en `README.md`.
 *
 * Los secretos (la cuenta de servicio de Firebase y la clave compartida) no salen en ninguna respuesta ni log, y
 * tampoco los tokens de los teléfonos.
 */

export interface Dependencias {
  fetch: typeof fetch;
  /** Dirección de la API del proyecto (`SUPABASE_URL`). */
  urlDeLaApi: string;
  /** La clave de servicio del proyecto (`SUPABASE_SERVICE_ROLE_KEY`): solo las dos RPC de la cola la aceptan. */
  claveDeServicio: string;
  /** La clave compartida con la base (`PUSH_CLAVE`), que `push.despertar()` manda en `x-push-clave`. */
  clavePush: string;
  /** `null` si falta o no sirve el secreto `FCM_CUENTA_DE_SERVICIO`: la función responde 503 y no manda nada. */
  cuenta: CuentaDeServicio | null;
  ahora: () => Date;
}

/** Cuántos avisos pide por vuelta, cuántas vueltas da como máximo por despertar y cuántos manda a la vez. */
export const AVISOS_POR_VUELTA = 50;
export const VUELTAS_MAXIMAS = 4;
export const ENVIOS_A_LA_VEZ = 10;

const TIPOS = [
  "pedido_autorizado",
  "ticket_validado",
  "ticket_rechazado",
  "asignacion_campania",
  "cuota_pendiente",
  "agenda_manana",
] as const;

/** Las únicas claves que pueden viajar al teléfono, además de `type` (R-NO02: solo tipo, event_id y UUIDs). */
export const CLAVES_DE_ID = ["event_id", "pedido_id", "ticket_id", "campania_id", "zona_id", "agenda_id"] as const;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const MENSAJES = {
  metodo: "Este servicio solo acepta pedidos POST.",
  no_autorizado: "Falta la clave de la base o no es la correcta.",
  sin_configurar: "Las push todavía no están configuradas: faltan secretos de la función.",
  no_se_pudo_leer: "No se pudo leer la cola de avisos de la base.",
} as const;

type CodigoDeError = keyof typeof MENSAJES;

const ESTADO_HTTP: Record<CodigoDeError, number> = {
  metodo: 405,
  no_autorizado: 401,
  sin_configurar: 503,
  no_se_pudo_leer: 502,
};

function json(estado: number, cuerpo: unknown): Response {
  return new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function errorJson(codigo: CodigoDeError): Response {
  return json(ESTADO_HTTP[codigo], { error: { codigo, mensaje: MENSAJES[codigo] } });
}

/** Compara dos textos sin que el tiempo que tarda diga cuántos caracteres coinciden. */
export function igualesSinFiltrar(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diferencia = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diferencia |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diferencia === 0;
}

/**
 * Los datos que se mandan, o `null` si no son los que prometimos: `type` es uno de los seis tipos y el resto son
 * claves conocidas con un UUID. Un campo de más (un nombre, un monto) frena el aviso entero: la base no los pone,
 * pero la app los descartaría como dato personal y ya habríamos mandado el dato.
 */
export function datosPermitidos(datos: unknown): Record<string, string> | null {
  if (typeof datos !== "object" || datos === null || Array.isArray(datos)) return null;
  const salida: Record<string, string> = {};
  for (const [clave, valor] of Object.entries(datos)) {
    if (typeof valor !== "string") return null;
    if (clave === "type") {
      if (!(TIPOS as readonly string[]).includes(valor)) return null;
    } else if ((CLAVES_DE_ID as readonly string[]).includes(clave)) {
      if (!UUID.test(valor)) return null;
    } else {
      return null;
    }
    salida[clave] = valor;
  }
  return "type" in salida && "event_id" in salida ? salida : null;
}

interface Pendiente {
  evento_id: string;
  token: string;
  datos: unknown;
  intento: number;
}

function esPendiente(fila: unknown): fila is Pendiente {
  if (typeof fila !== "object" || fila === null) return false;
  const f = fila as Record<string, unknown>;
  return typeof f.evento_id === "string" && UUID.test(f.evento_id) && typeof f.token === "string" && f.token !== "" &&
    typeof f.intento === "number";
}

export interface Resumen {
  tomados: number;
  enviados: number;
  reintentos: number;
  tokens_invalidos: number;
  descartados: number;
  sin_contar: number;
}

/** Una llamada a una RPC de la cola con la clave de servicio. Devuelve el JSON o `null` si la base no contestó bien. */
async function rpc(deps: Dependencias, nombre: string, argumentos: Record<string, unknown>): Promise<unknown | null> {
  try {
    const respuesta = await deps.fetch(`${deps.urlDeLaApi}/rest/v1/rpc/${nombre}`, {
      method: "POST",
      headers: {
        "apikey": deps.claveDeServicio,
        "Authorization": `Bearer ${deps.claveDeServicio}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(argumentos),
    });
    if (!respuesta.ok) return null;
    return await respuesta.json();
  } catch {
    return null;
  }
}

/** Manda un aviso y le cuenta a la base cómo salió. Nunca lanza. */
async function entregar(
  deps: Dependencias,
  fcm: ClienteFcm,
  pendiente: Pendiente,
  resumen: Resumen,
): Promise<void> {
  const datos = datosPermitidos(pendiente.datos);
  const resultado: ResultadoDeEnvio = datos
    ? await fcm.enviar(pendiente.token, datos)
    : { resultado: "DESCARTAR", codigo: "PAYLOAD_INVALIDO" };

  const codigo = resultado.resultado === "ENVIADO" ? null : codigoCorto(resultado.codigo, "ERROR");
  const contado = await rpc(deps, "push_resultado", {
    p_evento_id: pendiente.evento_id,
    p_resultado: resultado.resultado,
    // El token viaja solo para que la base lo borre si FCM lo rechazó y sigue siendo el de la cuenta.
    p_token: resultado.resultado === "TOKEN_INVALIDO" ? pendiente.token : null,
    p_error: codigo,
  });

  if (contado === null) {
    // El aviso queda reservado 2 minutos y vuelve a la cola; si FCM sí lo había aceptado, la app lo deduplica por event_id.
    resumen.sin_contar++;
    console.error(JSON.stringify({ evento: "push-fcm.sin_contar", resultado: resultado.resultado }));
    return;
  }
  if (resultado.resultado === "ENVIADO") resumen.enviados++;
  else if (resultado.resultado === "REINTENTAR") resumen.reintentos++;
  else if (resultado.resultado === "TOKEN_INVALIDO") resumen.tokens_invalidos++;
  else resumen.descartados++;

  if (resultado.resultado !== "ENVIADO") {
    console.error(JSON.stringify({
      evento: "push-fcm.no_enviado",
      resultado: resultado.resultado,
      codigo: resultado.codigo,
      intento: pendiente.intento,
    }));
  }
}

export async function manejar(pedido: Request, deps: Dependencias): Promise<Response> {
  if (pedido.method !== "POST") return errorJson("metodo");

  const faltan = [
    deps.urlDeLaApi === "" ? "SUPABASE_URL" : null,
    deps.claveDeServicio === "" ? "SUPABASE_SERVICE_ROLE_KEY" : null,
    deps.clavePush === "" ? "PUSH_CLAVE" : null,
    deps.cuenta === null ? "FCM_CUENTA_DE_SERVICIO" : null,
  ].filter((nombre) => nombre !== null);
  if (faltan.length > 0) {
    // Solo los NOMBRES de lo que falta; jamás un valor.
    console.error(JSON.stringify({ evento: "push-fcm.sin_configurar", faltan }));
    return errorJson("sin_configurar");
  }
  if (!igualesSinFiltrar(pedido.headers.get("x-push-clave") ?? "", deps.clavePush)) return errorJson("no_autorizado");

  const fcm = new ClienteFcm(deps.cuenta as CuentaDeServicio, deps.fetch, deps.ahora);
  const resumen: Resumen = {
    tomados: 0,
    enviados: 0,
    reintentos: 0,
    tokens_invalidos: 0,
    descartados: 0,
    sin_contar: 0,
  };

  for (let vuelta = 0; vuelta < VUELTAS_MAXIMAS; vuelta++) {
    const filas = await rpc(deps, "push_tomar_pendientes", { p_max: AVISOS_POR_VUELTA });
    if (!Array.isArray(filas)) {
      console.error(JSON.stringify({ evento: "push-fcm.no_se_pudo_leer", vuelta }));
      // Lo que ya salió en vueltas anteriores quedó contado; si no salió nada, es un error para quien despertó.
      return resumen.tomados === 0 ? errorJson("no_se_pudo_leer") : json(200, resumen);
    }
    const pendientes = filas.filter(esPendiente);
    resumen.tomados += pendientes.length;

    for (let i = 0; i < pendientes.length; i += ENVIOS_A_LA_VEZ) {
      await Promise.all(pendientes.slice(i, i + ENVIOS_A_LA_VEZ).map((p) => entregar(deps, fcm, p, resumen)));
    }
    if (filas.length < AVISOS_POR_VUELTA) break;
  }
  return json(200, resumen);
}
