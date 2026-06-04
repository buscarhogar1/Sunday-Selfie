#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

node --check functions/index.js
node --test functions/callable_contracts.test.js
node --test tool/security_contracts.test.js
git diff --check -- \
  firebase.json \
  firestore.rules \
  storage.rules \
  functions/index.js \
  lib/main.dart \
  test/widget_test.dart \
  tool \
  firebase_test \
  package.json \
  README.md

echo "Comprobaciones locales completadas."
