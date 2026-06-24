# Seguridad

## Claves y configuracion

Los archivos de configuracion cliente de Firebase (`google-services.json`,
`GoogleService-Info.plist` y `firebase_options.dart`) contienen identificadores
publicos de la app, no secretos de servidor. La proteccion real debe venir de:

- Firestore Rules y Storage Rules estrictas.
- Firebase App Check activado y exigido en Cloud Functions.
- Restricciones de las API keys en Google Cloud/Firebase por app, paquete,
  bundle id, SHA-1/SHA-256 y APIs permitidas.

No se deben subir al repositorio claves privadas, service accounts, `.env`,
certificados, respaldos de configuracion ni tokens. El chequeo local
`npm run check:local` falla si detecta patrones comunes de secretos.

## Antes de desplegar App Check

1. Registra la app Android con Play Integrity y la app iOS con App Attest
   en Firebase App Check.
2. Registra los tokens de depuracion necesarios para desarrollo local.
3. Activa enforcement para Firestore, Storage y Cloud Functions cuando los
   clientes instalados ya tengan App Check activo.

Si alguna API key ya estuvo expuesta en un respaldo o historial publico, rota
esa key en Google Cloud y limita la anterior hasta eliminarla.
