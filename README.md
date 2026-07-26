# Sunday Selfie

Aplicacion Flutter conectada a Firebase.

## Comprobaciones locales

Estas comprobaciones no escriben nada en Firebase produccion.

Primera preparacion, solo una vez:

```bash
npm install
```

Comprobaciones rapidas del codigo y de los contratos de seguridad:

```bash
npm run check:local
```

Pruebas reales de Firestore Rules y Storage Rules con emuladores:

```bash
npm run test:rules
```

Las pruebas de reglas usan siempre el proyecto local ficticio
`demo-sunday-selfie`. El script detecta automaticamente el Java incluido con
Android Studio.

Analisis de Flutter:

```bash
~/development/flutter_clean/bin/flutter analyze
```

Ejecucion en Flutter Web para el navegador integrado de Codex:

```bash
flutter pub get
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

Despues abre http://localhost:8080 en el navegador integrado de Codex. No uses
Android Studio, emulador Android ni dispositivo movil para esta forma de
ejecucion salvo que se pida explicitamente.

Pruebas de Flutter:

```bash
~/development/flutter_clean/bin/flutter test
```

No es necesario ejecutar un deploy para ninguna de estas comprobaciones.

## Seguridad

Consulta [SECURITY.md](SECURITY.md) antes de desplegar cambios de Firebase,
App Check o claves de configuracion.
