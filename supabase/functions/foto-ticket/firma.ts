/**
 * Enlaces prefirmados de S3 (AWS Signature Version 4, firma en la URL) para el bucket privado de Cloudflare R2.
 * R2 habla la API de S3: región «auto», servicio «s3», estilo de ruta `https://<cuenta>.r2.cloudflarestorage.com/<bucket>/<clave>`.
 *
 * Solo WebCrypto, sin dependencias: el algoritmo es corto y su resultado se compara contra el vector de pruebas que
 * publica AWS (`firma_test.ts`). La clave secreta entra y no sale: ni se devuelve ni se escribe en ningún lado; lo único
 * que sale es la URL con su firma.
 */

export interface ParametrosDeFirma {
  metodo: "GET" | "PUT" | "HEAD";
  /** El dominio, sin esquema ni ruta (`<cuenta>.r2.cloudflarestorage.com`). */
  host: string;
  /** La ruta ya codificada, con `/` al principio (`/<bucket>/<usuario>/<ticket>.jpg`). */
  ruta: string;
  region: string;
  servicio: string;
  claveDeAcceso: string;
  claveSecreta: string;
  fecha: Date;
  /** Cuánto vale el enlace, en segundos (R2 admite de 1 a 604800). */
  expiraEnSegundos: number;
  /**
   * Cabeceras que la firma ata además de `host` (por ejemplo `content-type` y `content-length` de una subida): quien use el
   * enlace tiene que mandarlas exactamente así, o R2 rechaza el pedido con 403.
   */
  cabecerasFirmadas?: Record<string, string>;
}

const codificador = new TextEncoder();

/** `encodeURIComponent` más lo que RFC 3986 también reserva (`! ' ( ) *`), como pide SigV4. */
export function codificar(texto: string): string {
  return encodeURIComponent(texto).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

/** Una clave de objeto (`a/b.jpg`) para ir en la ruta: cada tramo codificado, las barras quedan. */
export function codificarRuta(clave: string): string {
  return clave.split("/").map(codificar).join("/");
}

function hexadecimal(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(texto: string): Promise<string> {
  return hexadecimal(await crypto.subtle.digest("SHA-256", codificador.encode(texto)));
}

async function hmac(clave: ArrayBuffer | string, texto: string): Promise<ArrayBuffer> {
  const bruta = typeof clave === "string" ? codificador.encode(clave) : clave;
  const llave = await crypto.subtle.importKey("raw", bruta, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return await crypto.subtle.sign("HMAC", llave, codificador.encode(texto));
}

/** `20130524T000000Z`. */
function fechaCompacta(fecha: Date): string {
  return fecha.toISOString().replace(/[:-]|\.\d{3}/g, "");
}

/** La URL prefirmada. */
export async function firmarUrl(p: ParametrosDeFirma): Promise<string> {
  if (!Number.isInteger(p.expiraEnSegundos) || p.expiraEnSegundos < 1 || p.expiraEnSegundos > 604800) {
    throw new RangeError("El enlace tiene que vencer entre 1 segundo y 7 días.");
  }
  if (!p.ruta.startsWith("/")) throw new RangeError("La ruta tiene que empezar con «/».");

  const amz = fechaCompacta(p.fecha);
  const dia = amz.slice(0, 8);
  const alcance = `${dia}/${p.region}/${p.servicio}/aws4_request`;

  const cabeceras: Record<string, string> = { host: p.host };
  for (const [nombre, valor] of Object.entries(p.cabecerasFirmadas ?? {})) {
    cabeceras[nombre.toLowerCase()] = valor.trim();
  }
  const nombres = Object.keys(cabeceras).sort();
  const cabecerasCanonicas = nombres.map((n) => `${n}:${cabeceras[n]}\n`).join("");
  const cabecerasFirmadas = nombres.join(";");

  const consulta: [string, string][] = [
    ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
    ["X-Amz-Credential", `${p.claveDeAcceso}/${alcance}`],
    ["X-Amz-Date", amz],
    ["X-Amz-Expires", String(p.expiraEnSegundos)],
    ["X-Amz-SignedHeaders", cabecerasFirmadas],
  ];
  const consultaCanonica = consulta
    .map(([k, v]) => [codificar(k), codificar(v)] as const)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([k, v]) => `${k}=${v}`)
    .join("&");

  const pedidoCanonico = [p.metodo, p.ruta, consultaCanonica, cabecerasCanonicas, cabecerasFirmadas, "UNSIGNED-PAYLOAD"]
    .join("\n");
  const aFirmar = ["AWS4-HMAC-SHA256", amz, alcance, await sha256(pedidoCanonico)].join("\n");

  const claveDelDia = await hmac(
    await hmac(await hmac(await hmac("AWS4" + p.claveSecreta, dia), p.region), p.servicio),
    "aws4_request",
  );
  const firma = hexadecimal(await hmac(claveDelDia, aFirmar));

  return `https://${p.host}${p.ruta}?${consultaCanonica}&X-Amz-Signature=${firma}`;
}
