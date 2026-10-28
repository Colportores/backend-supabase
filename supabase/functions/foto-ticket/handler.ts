import { codificarRuta, firmarUrl } from "./firma.ts";

/**
 * Edge Function `foto-ticket` (backend-supabase#182, HU-COB-007 y HU-COB-009, RF-CO08A; decisión de Cristian del 27/10,
 * «Foto cifrada» y «Borrar foto»): las fotos de los tickets están en un bucket PRIVADO de Cloudflare R2 y esta función
 * es la única que habla con él. Comprueba la sesión y el permiso con la base (las dos funciones de la migración 0134,
 * llamadas con el JWT de quien pide: manda la RLS) y devuelve un enlace firmado de R2 que vence en minutos, para subir
 * o para ver. No guarda nada ni lleva lógica de negocio propia. Contrato completo en `README.md`.
 *
 * Las claves de R2 son secretos de la función (`R2_*`): no salen en ninguna respuesta ni en ningún log.
 */

export interface ConfiguracionDeR2 {
  /** El id de la cuenta de Cloudflare: forma el dominio `<cuenta>.r2.cloudflarestorage.com`. */
  cuenta: string;
  claveDeAcceso: string;
  claveSecreta: string;
  bucket: string;
}

export interface Dependencias {
  fetch: typeof fetch;
  /** Dirección de la API del proyecto (`SUPABASE_URL`). */
  urlDeLaApi: string;
  /** La clave pública (`SUPABASE_ANON_KEY`): identifica al proyecto, no da ningún permiso. */
  clavePublica: string;
  /** `null` si faltan los secretos de R2: la función responde 503 y no firma nada. */
  r2: ConfiguracionDeR2 | null;
  ahora: () => Date;
}

/** Lo más que pesa una foto (el mismo tope que tenía el bucket de Supabase). */
export const MAXIMO_DE_LA_FOTO = 2 * 1024 * 1024;
/** Cuánto valen los enlaces. Subir da más margen: es una foto de hasta 2 MiB por una conexión que puede ser mala. */
export const SEGUNDOS_PARA_SUBIR = 600;
export const SEGUNDOS_PARA_VER = 300;
/** El enlace del HEAD que la función se hace a sí misma antes de firmar una subida. */
const SEGUNDOS_PARA_COMPROBAR = 60;

const MAXIMO_DEL_CUERPO = 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** El tipo de imagen que acepta la subida y la extensión con la que sube (las mismas que admite la base, 0134). */
export const EXTENSION_DE: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

const CABECERAS_CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

/** Los textos son para la persona (el teléfono y el panel los muestran tal cual): qué pasó y qué hacer. */
const MENSAJES = {
  metodo: "Este servicio solo acepta pedidos POST.",
  pedido_invalido: "El pedido de la foto no es válido. Volvé a intentar; si sigue igual, avisá a Administración.",
  pedido_muy_grande: "El pedido de la foto es demasiado grande. Volvé a intentar.",
  foto_muy_grande: "La foto pesa más de 2 MB. Sacala de nuevo o comprimila e intentá otra vez.",
  tipo_no_permitido: "La foto tiene que ser una imagen JPG, PNG o WebP.",
  sin_sesion: "Tu sesión terminó. Iniciá sesión de nuevo para usar la foto del ticket.",
  ticket_no_encontrado: "No encontramos ese ticket o no tenés permiso para ver su foto.",
  sin_foto:
    "Este ticket todavía no tiene foto. Si ya la sacó la colportora, aparece cuando su teléfono termine de subirla.",
  foto_vencida: "La foto de este ticket ya venció: se guarda 4 meses. Los datos del ticket siguen en el historial.",
  no_se_pudo_leer: "No pudimos comprobar tu permiso. Esperá unos minutos y volvé a intentar.",
  no_se_pudo_firmar: "No pudimos preparar la foto. Volvé a intentar en unos minutos.",
  foto_ya_subida: "Este ticket ya tiene su foto: no se puede cambiar.",
  no_se_pudo_comprobar: "No pudimos comprobar si el ticket ya tiene foto. Esperá unos minutos y volvé a intentar.",
  sin_configurar: "Las fotos de los tickets todavía no están disponibles. Avisá a Administración.",
} as const;

type CodigoDeError = keyof typeof MENSAJES;

const ESTADO_HTTP: Record<CodigoDeError, number> = {
  metodo: 405,
  pedido_invalido: 400,
  pedido_muy_grande: 413,
  foto_muy_grande: 413,
  tipo_no_permitido: 415,
  sin_sesion: 401,
  ticket_no_encontrado: 404,
  sin_foto: 404,
  foto_vencida: 410,
  no_se_pudo_leer: 502,
  no_se_pudo_firmar: 500,
  foto_ya_subida: 409,
  no_se_pudo_comprobar: 502,
  sin_configurar: 503,
};

/** Los SQLSTATE propios de la migración 0134 y el aviso que les toca. */
const CODIGO_DE_LA_BASE: Record<string, CodigoDeError> = {
  FT001: "ticket_no_encontrado",
  FT002: "sin_foto",
  FT003: "foto_vencida",
};

export type PedidoDeFoto =
  | { accion: "ver"; ticketId: string }
  | { accion: "subir"; ticketId: string; tipoDeImagen: string; bytes: number };

function errorJson(codigo: CodigoDeError): Response {
  return new Response(JSON.stringify({ error: { codigo, mensaje: MENSAJES[codigo] } }), {
    status: ESTADO_HTTP[codigo],
    headers: { ...CABECERAS_CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function esObjeto(valor: unknown): valor is Record<string, unknown> {
  return typeof valor === "object" && valor !== null && !Array.isArray(valor);
}

/** El pedido, o el código del error si no es válido. */
export function leerPedido(cuerpo: unknown): PedidoDeFoto | CodigoDeError {
  if (!esObjeto(cuerpo)) return "pedido_invalido";
  const ticketId = cuerpo.ticketId;
  if (typeof ticketId !== "string" || !UUID.test(ticketId)) return "pedido_invalido";

  if (cuerpo.accion === "ver") return { accion: "ver", ticketId };
  if (cuerpo.accion !== "subir") return "pedido_invalido";

  const { tipoDeImagen, bytes } = cuerpo;
  if (typeof tipoDeImagen !== "string" || typeof bytes !== "number" || !Number.isInteger(bytes) || bytes < 1) {
    return "pedido_invalido";
  }
  if (!(tipoDeImagen in EXTENSION_DE)) return "tipo_no_permitido";
  if (bytes > MAXIMO_DE_LA_FOTO) return "foto_muy_grande";
  return { accion: "subir", ticketId, tipoDeImagen, bytes };
}

/** Una falla de la base, con el SQLSTATE de Postgres / PostgREST si lo hay. */
class ErrorDeLaBase extends Error {
  constructor(readonly codigo: string, readonly http: number) {
    super(`La base respondió ${http}`);
    this.name = "ErrorDeLaBase";
  }
}

/** Una falla al hablar con R2 que tiene su propio aviso. */
class ErrorDeR2 extends Error {
  constructor(readonly codigo: "foto_ya_subida" | "no_se_pudo_comprobar") {
    super(codigo);
    this.name = "ErrorDeR2";
  }
}

/**
 * Una foto subida es la prueba del ticket y no se pisa (como en el bucket de Supabase, que no tenía política de UPDATE):
 * antes de firmar una subida se pregunta a R2 con un HEAD firmado (vence en 60 s, no sale de la función) si la clave ya
 * existe. 404: no existe, se puede firmar. 200: ya está, 409 y no se firma. Cualquier otra cosa: no se sabe, y ante la
 * duda no se firma.
 */
async function laFotoYaEstaEnR2(dependencias: Dependencias, r2: ConfiguracionDeR2, ruta: string): Promise<boolean> {
  const url = await firmarUrl({
    metodo: "HEAD",
    host: `${r2.cuenta}.r2.cloudflarestorage.com`,
    ruta: `/${r2.bucket}/${codificarRuta(ruta)}`,
    region: "auto",
    servicio: "s3",
    claveDeAcceso: r2.claveDeAcceso,
    claveSecreta: r2.claveSecreta,
    fecha: dependencias.ahora(),
    expiraEnSegundos: SEGUNDOS_PARA_COMPROBAR,
  });
  let respuesta: Response;
  try {
    respuesta = await dependencias.fetch(url, { method: "HEAD" });
  } catch {
    throw new ErrorDeR2("no_se_pudo_comprobar");
  }
  if (respuesta.status === 200) return true;
  if (respuesta.status === 404) return false;
  throw new ErrorDeR2("no_se_pudo_comprobar");
}

/** Llama a una RPC con la sesión de quien pidió (`Authorization` tal cual llegó) y devuelve su resultado. */
async function llamarRpc(
  dependencias: Dependencias,
  autorizacion: string,
  nombre: string,
  argumentos: Record<string, unknown>,
): Promise<unknown> {
  let respuesta: Response;
  try {
    respuesta = await dependencias.fetch(`${dependencias.urlDeLaApi}/rest/v1/rpc/${nombre}`, {
      method: "POST",
      headers: {
        apikey: dependencias.clavePublica,
        Authorization: autorizacion,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(argumentos),
    });
  } catch {
    throw new ErrorDeLaBase("red", 0);
  }
  if (!respuesta.ok) {
    let codigo = String(respuesta.status);
    try {
      const cuerpo: unknown = await respuesta.json();
      if (esObjeto(cuerpo) && typeof cuerpo.code === "string") codigo = cuerpo.code;
    } catch {
      // Sin cuerpo entendible: queda el estado HTTP como código.
    }
    throw new ErrorDeLaBase(codigo, respuesta.status);
  }
  try {
    return await respuesta.json();
  } catch {
    throw new ErrorDeLaBase("respuesta_ilegible", respuesta.status);
  }
}

/** Qué le decimos a la persona según qué falló. */
function codigoDeError(error: unknown): CodigoDeError {
  if (error instanceof ErrorDeLaBase) {
    if (error.codigo in CODIGO_DE_LA_BASE) return CODIGO_DE_LA_BASE[error.codigo];
    // 42501: sin sesión (o sin permiso de ejecutar la función, que es lo mismo: anon). 401 / PGRST30x: JWT vencido o inválido.
    if (error.codigo === "42501" || error.http === 401 || error.codigo.startsWith("PGRST30")) return "sin_sesion";
    return "no_se_pudo_leer";
  }
  if (error instanceof ErrorDeR2) return error.codigo;
  return "no_se_pudo_firmar";
}

export async function manejar(pedido: Request, dependencias: Dependencias): Promise<Response> {
  if (pedido.method === "OPTIONS") return new Response(null, { status: 204, headers: CABECERAS_CORS });
  if (pedido.method !== "POST") return errorJson("metodo");

  const autorizacion = pedido.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(autorizacion)) return errorJson("sin_sesion");

  const largo = Number(pedido.headers.get("Content-Length") ?? "0");
  if (largo > MAXIMO_DEL_CUERPO) return errorJson("pedido_muy_grande");
  let crudo: string;
  try {
    crudo = await pedido.text();
  } catch {
    return errorJson("pedido_invalido");
  }
  if (crudo.length > MAXIMO_DEL_CUERPO) return errorJson("pedido_muy_grande");

  let cuerpo: unknown;
  try {
    cuerpo = JSON.parse(crudo);
  } catch {
    return errorJson("pedido_invalido");
  }
  const datosDelPedido = leerPedido(cuerpo);
  if (typeof datosDelPedido === "string") return errorJson(datosDelPedido);

  // Sin las claves de R2 no hay nada que firmar. Se dice antes de gastar una llamada a la base.
  const r2 = dependencias.r2;
  if (!r2) return errorJson("sin_configurar");

  try {
    // El permiso lo da la base, con la sesión de quien pide.
    const ruta = datosDelPedido.accion === "ver"
      ? await llamarRpc(dependencias, autorizacion, "ruta_para_ver_foto_de_ticket", {
        p_ticket_id: datosDelPedido.ticketId,
      })
      : await llamarRpc(dependencias, autorizacion, "ruta_para_subir_foto_de_ticket", {
        p_ticket_id: datosDelPedido.ticketId,
        p_extension: EXTENSION_DE[datosDelPedido.tipoDeImagen],
      });
    if (typeof ruta !== "string" || ruta === "") throw new ErrorDeLaBase("respuesta_inesperada", 200);

    if (datosDelPedido.accion === "subir" && await laFotoYaEstaEnR2(dependencias, r2, ruta)) {
      throw new ErrorDeR2("foto_ya_subida");
    }

    const ahora = dependencias.ahora();
    const subir = datosDelPedido.accion === "subir";
    const segundos = subir ? SEGUNDOS_PARA_SUBIR : SEGUNDOS_PARA_VER;
    const cabeceras: Record<string, string> = datosDelPedido.accion === "subir"
      ? { "Content-Type": datosDelPedido.tipoDeImagen, "Content-Length": String(datosDelPedido.bytes) }
      : {};
    const url = await firmarUrl({
      metodo: subir ? "PUT" : "GET",
      host: `${r2.cuenta}.r2.cloudflarestorage.com`,
      ruta: `/${r2.bucket}/${codificarRuta(ruta)}`,
      region: "auto",
      servicio: "s3",
      claveDeAcceso: r2.claveDeAcceso,
      claveSecreta: r2.claveSecreta,
      fecha: ahora,
      expiraEnSegundos: segundos,
      cabecerasFirmadas: cabeceras,
    });

    return new Response(
      JSON.stringify({
        accion: datosDelPedido.accion,
        metodo: subir ? "PUT" : "GET",
        url,
        ruta,
        // Lo que hay que mandar tal cual al usar el enlace de subida (la firma las ata).
        cabeceras,
        venceEn: new Date(ahora.getTime() + segundos * 1000).toISOString(),
      }),
      {
        status: 200,
        headers: { ...CABECERAS_CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
      },
    );
  } catch (error) {
    const codigo = codigoDeError(error);
    // Solo el tipo de falla y su código: nada del pedido (ids), de la ruta ni del enlace.
    console.error(JSON.stringify({
      evento: "foto-ticket.fallo",
      codigo,
      origen: error instanceof ErrorDeLaBase ? error.codigo : (error as Error)?.name,
    }));
    return errorJson(codigo);
  }
}
