/**
 * FCM HTTP v1 sin el SDK Admin (ADR-014, backend-supabase#237): firma el JWT de la cuenta de servicio de Google con
 * WebCrypto, lo cambia por un token de acceso de OAuth2 y manda cada mensaje a `messages:send`. Solo manda `data`
 * (el tipo, el `event_id` y UUIDs): el texto lo arma la app (R-NO02). Nada de esto toca la base ni el teléfono.
 */

/** Lo que usa de la cuenta de servicio del proyecto de Firebase (el JSON que baja la consola, sin lo demás). */
export interface CuentaDeServicio {
  project_id: string;
  client_email: string;
  private_key: string;
}

/** Cómo salió un envío. Son los cuatro resultados que entiende `public.push_resultado()` (migración 0162). */
export type ResultadoDeEnvio =
  | { resultado: "ENVIADO" }
  | { resultado: "REINTENTAR"; codigo: string }
  | { resultado: "TOKEN_INVALIDO"; codigo: string }
  | { resultado: "DESCARTAR"; codigo: string };

export const URL_DEL_TOKEN_DE_ACCESO = "https://oauth2.googleapis.com/token";
const ALCANCE = "https://www.googleapis.com/auth/firebase.messaging";
/** Cuánto antes de que venza se pide un token de acceso nuevo. */
const MARGEN_DEL_TOKEN_MS = 60_000;

const CODIGO_CORTO = /^[A-Z][A-Z0-9_]{0,39}$/;

/** Un código para guardar en la base: mayúsculas, números y guion bajo, hasta 40; si no, el de reserva. */
export function codigoCorto(valor: unknown, reserva: string): string {
  const texto = typeof valor === "string" ? valor.trim().toUpperCase().replace(/[^A-Z0-9_]/g, "_") : "";
  return CODIGO_CORTO.test(texto) ? texto : reserva;
}

/** La cuenta de servicio desde el secreto (el JSON tal cual lo baja Firebase), o `null` si no sirve. */
export function leerCuentaDeServicio(texto: string | undefined): CuentaDeServicio | null {
  if (!texto || texto.trim() === "") return null;
  try {
    const json = JSON.parse(texto);
    if (typeof json !== "object" || json === null) return null;
    const { project_id, client_email, private_key } = json as Record<string, unknown>;
    if (typeof project_id !== "string" || project_id === "") return null;
    if (typeof client_email !== "string" || client_email === "") return null;
    if (typeof private_key !== "string" || !private_key.includes("BEGIN PRIVATE KEY")) return null;
    return { project_id, client_email, private_key };
  } catch {
    return null;
  }
}

function base64Url(bytes: Uint8Array): string {
  let binario = "";
  for (const b of bytes) binario += String.fromCharCode(b);
  return btoa(binario).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function textoABase64Url(texto: string): string {
  return base64Url(new TextEncoder().encode(texto));
}

async function importarClave(pem: string): Promise<CryptoKey> {
  const cuerpo = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(cuerpo), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

/** El JWT que se cambia por un token de acceso: RS256 con la clave de la cuenta de servicio, vale una hora. */
export async function firmarJwt(cuenta: CuentaDeServicio, ahora: Date): Promise<string> {
  const emitido = Math.floor(ahora.getTime() / 1000);
  const cabecera = textoABase64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const reclamos = textoABase64Url(JSON.stringify({
    iss: cuenta.client_email,
    scope: ALCANCE,
    aud: URL_DEL_TOKEN_DE_ACCESO,
    iat: emitido,
    exp: emitido + 3600,
  }));
  const firmado = `${cabecera}.${reclamos}`;
  const firma = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    await importarClave(cuenta.private_key),
    new TextEncoder().encode(firmado),
  );
  return `${firmado}.${base64Url(new Uint8Array(firma))}`;
}

/** No se pudo conseguir el token de acceso: no es culpa del aviso ni del token del teléfono. */
export class ErrorDeAutenticacion extends Error {
  constructor(readonly codigo: string) {
    super(`No se pudo autenticar con Google (${codigo})`);
    this.name = "ErrorDeAutenticacion";
  }
}

interface ErrorDeFcm {
  status?: string;
  message?: string;
  details?: { errorCode?: string }[];
}

/**
 * Qué hacer con la respuesta de FCM. Un token se declara inválido SOLO cuando FCM lo dice con todas las letras
 * (`UNREGISTERED`, `SENDER_ID_MISMATCH`, o `INVALID_ARGUMENT` que nombra al token de registro): ante un error
 * ambiguo (un 404 sin `UNREGISTERED` es un proyecto mal configurado) el aviso se reintenta y no se borra ningún token.
 */
export function clasificarRespuesta(estado: number, cuerpo: unknown): ResultadoDeEnvio {
  if (estado >= 200 && estado < 300) return { resultado: "ENVIADO" };

  const error: ErrorDeFcm =
    (typeof cuerpo === "object" && cuerpo !== null && (cuerpo as { error?: ErrorDeFcm }).error) || {};
  const detalle = error.details?.map((d) => d.errorCode).find((c) => typeof c === "string");
  const nombre = codigoCorto(detalle ?? error.status, `HTTP_${estado}`);

  if (detalle === "UNREGISTERED" || detalle === "SENDER_ID_MISMATCH") {
    return { resultado: "TOKEN_INVALIDO", codigo: nombre };
  }
  if (estado === 400 && error.status === "INVALID_ARGUMENT") {
    const hablaDelToken = /registration token/i.test(error.message ?? "");
    return hablaDelToken
      ? { resultado: "TOKEN_INVALIDO", codigo: "INVALID_ARGUMENT" }
      : { resultado: "DESCARTAR", codigo: "INVALID_ARGUMENT" };
  }
  if (estado === 401 || estado === 403 || estado === 404 || estado === 408 || estado === 429 || estado >= 500) {
    return { resultado: "REINTENTAR", codigo: nombre };
  }
  return { resultado: "DESCARTAR", codigo: nombre };
}

/** El mensaje: solo `data` (todo texto) más lo que hace falta para que llegue con la app cerrada. */
export function armarMensaje(token: string, datos: Record<string, string>) {
  return {
    message: {
      token,
      data: datos,
      android: { priority: "HIGH" },
      // iOS: un aviso de solo datos llega como «silencioso» (content-available) y con prioridad 5.
      apns: {
        headers: { "apns-priority": "5", "apns-push-type": "background" },
        payload: { aps: { "content-available": 1 } },
      },
    },
  };
}

export class ClienteFcm {
  #acceso: { valor: string; venceEn: number } | null = null;

  constructor(
    private readonly cuenta: CuentaDeServicio,
    private readonly llamar: typeof fetch,
    private readonly ahora: () => Date,
  ) {}

  /** Un token de acceso vigente (se reutiliza hasta un minuto antes de que venza). */
  async tokenDeAcceso(): Promise<string> {
    const ahora = this.ahora().getTime();
    if (this.#acceso && this.#acceso.venceEn - MARGEN_DEL_TOKEN_MS > ahora) return this.#acceso.valor;

    let respuesta: Response;
    try {
      const jwt = await firmarJwt(this.cuenta, this.ahora());
      respuesta = await this.llamar(URL_DEL_TOKEN_DE_ACCESO, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
      });
    } catch {
      throw new ErrorDeAutenticacion("RED_O_CLAVE");
    }
    if (!respuesta.ok) throw new ErrorDeAutenticacion(`HTTP_${respuesta.status}`);
    let json: { access_token?: unknown; expires_in?: unknown };
    try {
      json = await respuesta.json();
    } catch {
      throw new ErrorDeAutenticacion("SIN_JSON");
    }
    if (typeof json.access_token !== "string" || json.access_token === "") throw new ErrorDeAutenticacion("SIN_TOKEN");
    const segundos = typeof json.expires_in === "number" && json.expires_in > 0 ? json.expires_in : 3600;
    this.#acceso = { valor: json.access_token, venceEn: ahora + segundos * 1000 };
    return json.access_token;
  }

  /** Manda un aviso. Nunca lanza: todo lo que pueda pasar vuelve como un `ResultadoDeEnvio`. */
  async enviar(token: string, datos: Record<string, string>): Promise<ResultadoDeEnvio> {
    let acceso: string;
    try {
      acceso = await this.tokenDeAcceso();
    } catch {
      // Sin token de acceso no se puede mandar nada; no es culpa del aviso ni del token del teléfono.
      return { resultado: "REINTENTAR", codigo: "FCM_AUTH" };
    }

    let respuesta: Response;
    try {
      respuesta = await this.llamar(`https://fcm.googleapis.com/v1/projects/${this.cuenta.project_id}/messages:send`, {
        method: "POST",
        headers: { "Authorization": `Bearer ${acceso}`, "Content-Type": "application/json" },
        body: JSON.stringify(armarMensaje(token, datos)),
      });
    } catch {
      return { resultado: "REINTENTAR", codigo: "RED" };
    }

    let cuerpo: unknown = null;
    if (!respuesta.ok) {
      try {
        cuerpo = await respuesta.json();
      } catch {
        cuerpo = null;
      }
      // 401: el token de acceso ya no vale (se revocó antes de vencer): el próximo envío pide uno nuevo.
      if (respuesta.status === 401) this.#acceso = null;
    }
    return clasificarRespuesta(respuesta.status, cuerpo);
  }
}
