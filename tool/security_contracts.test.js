const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

const firebaseConfig = JSON.parse(read("firebase.json"));
const firestoreRules = read("firestore.rules");
const storageRules = read("storage.rules");
const functionsSource = read("functions/index.js");
const flutterSource = read("lib/main.dart");

test("firebase.json uses local rule files and configured emulators", () => {
  assert.equal(firebaseConfig.firestore.rules, "firestore.rules");
  assert.equal(firebaseConfig.storage.rules, "storage.rules");
  assert.equal(firebaseConfig.emulators.firestore.port, 8080);
  assert.equal(firebaseConfig.emulators.storage.port, 9199);
  assert.equal(firebaseConfig.emulators.functions.port, 5001);
  assert.equal(firebaseConfig.emulators.auth.port, 9099);
});

test("sensitive Firestore writes stay closed to direct clients", () => {
  assert.match(
    firestoreRules,
    /match \/reminders\/\{reminderId\} \{[\s\S]*?allow create, update, delete: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/posts\/\{postUid\} \{[\s\S]*?allow create, update, delete: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/reactions\/\{reactionUid\} \{[\s\S]*?allow create, update, delete: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/groups\/\{groupId\} \{[\s\S]*?allow create: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/reports\/\{reportId\} \{[\s\S]*?allow read, create, update, delete: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/members\/\{memberUid\} \{[\s\S]*?allow create: if false;/
  );
});

test("sensitive Storage writes cannot replace or delete selfies", () => {
  assert.match(
    storageRules,
    /match \/groups\/\{groupId\}\/weeks\/\{weekKey\}\/\{fileName\} \{[\s\S]*?allow create: if isValidSelfieUpload[\s\S]*?allow update, delete: if false;/
  );
});

test("Flutter delegates sensitive actions to Cloud Functions", () => {
  const callables = [
    "crearGrupo",
    "aceptarSolicitud",
    "rechazarSolicitud",
    "promoverAdministrador",
    "expulsarMiembro",
    "permitirReingreso",
    "abandonarGrupo",
    "regenerarInvitacion",
    "registrarSelfie",
    "reaccionarASelfie",
    "enviarZumbidoSelfie",
    "reportarContenido",
    "borrarCuenta",
  ];

  for (const callable of callables) {
    assert.match(functionsSource, new RegExp(`exports\\.${callable}\\s*=`));
    assert.match(flutterSource, new RegExp(`httpsCallable\\(\\s*'${callable}'`));
  }
});

test("Flutter has no direct post, reaction, or reminder transaction writes", () => {
  assert.doesNotMatch(flutterSource, /transaction\.(set|update|delete)\(postRef/);
  assert.doesNotMatch(flutterSource, /transaction\.(set|update|delete)\(reactionRef/);
  assert.doesNotMatch(flutterSource, /transaction\.(set|update|delete)\(reminderRef/);
  assert.doesNotMatch(flutterSource, /currentUser\?*\.delete\(\)/);
});

test("account deletion removes personal data before deleting authentication", () => {
  assert.match(functionsSource, /async function deleteUserContentFromGroup/);
  assert.match(functionsSource, /async function listGroupIdsForAccountDeletion/);
  assert.match(functionsSource, /await firestore\.recursiveDelete\(userRef\);/);
  assert.match(functionsSource, /await admin\.auth\(\)\.deleteUser\(uid\);/);
  assert.ok(
    functionsSource.indexOf("await firestore.recursiveDelete(userRef);")
      < functionsSource.indexOf("await admin.auth().deleteUser(uid);")
  );
});
