#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

node --check functions/index.js
node --test functions/callable_contracts.test.js
node --test tool/security_contracts.test.js
git diff --check -- \
  .gitignore \
  SECURITY.md \
  firebase.json \
  firestore.rules \
  storage.rules \
  android \
  ios \
  functions/index.js \
  lib/main.dart \
  pubspec.yaml \
  test/widget_test.dart \
  tool \
  firebase_test \
  public \
  package.json \
  README.md

echo "Comprobaciones locales completadas."
