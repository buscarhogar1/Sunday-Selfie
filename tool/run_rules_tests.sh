#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d node_modules/@firebase/rules-unit-testing || ! -d node_modules/firebase ]]; then
  echo "Faltan las dependencias locales de pruebas."
  echo "Ejecuta una vez: npm install"
  exit 1
fi

if command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
  :
elif [[ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  export PATH="$JAVA_HOME/bin:$PATH"
else
  echo "No se ha encontrado Java. Los emuladores de Firebase necesitan Java 11 o superior."
  exit 1
fi

firebase emulators:exec \
  --project demo-sunday-selfie \
  --only firestore,storage \
  "node --test firebase_test/security_rules.test.mjs"
