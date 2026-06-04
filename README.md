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

Pruebas de Flutter:

```bash
~/development/flutter_clean/bin/flutter test
```

No es necesario ejecutar un deploy para ninguna de estas comprobaciones.
