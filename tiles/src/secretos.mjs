// Nada de lo que imprime el publicador puede llevar una clave. Los mensajes de error de HTTP incluyen
// parte de lo que respondió el servidor, y un servidor (o un proxy) puede devolver los encabezados que
// recibió, con el `Authorization`: por eso todo lo que sale a la consola pasa por acá.

/** `texto` con cada secreto reemplazado por `***`. Ignora los vacíos y los demasiado cortos para serlo. */
export function ocultar(texto, ...secretos) {
  let resultado = String(texto);
  for (const secreto of secretos) {
    if (typeof secreto === 'string' && secreto.length >= 8) resultado = resultado.split(secreto).join('***');
  }
  return resultado;
}
