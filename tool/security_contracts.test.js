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
const pubspecSource = read("pubspec.yaml");
const gitignoreSource = read(".gitignore");
const androidManifest = read("android/app/src/main/AndroidManifest.xml");
const androidMainActivity = read(
  "android/app/src/main/kotlin/com/example/sunday_selfie/MainActivity.kt"
);
const iosEntitlements = read("ios/Runner/Runner.entitlements");
const iosInfoPlist = read("ios/Runner/Info.plist");
const iosProject = read("ios/Runner.xcodeproj/project.pbxproj");
const hostingIndex = read("public/index.html");
const androidAssetLinks = read("public/.well-known/assetlinks.json");

const ignoredSecretScanDirs = new Set([
  ".git",
  ".dart_tool",
  ".firebase",
  "build",
  "coverage",
  "node_modules",
  "Pods",
]);

const ignoredSecretScanExtensions = new Set([
  ".ico",
  ".jpg",
  ".jpeg",
  ".lock",
  ".png",
  ".webp",
]);

function sourceFilesForSecretScan(relativeDir = ".") {
  const absoluteDir = path.join(root, relativeDir);
  const entries = fs.readdirSync(absoluteDir, {withFileTypes: true});
  const files = [];

  for (const entry of entries) {
    if (ignoredSecretScanDirs.has(entry.name)) continue;

    const relativePath = path
      .join(relativeDir, entry.name)
      .replace(/\\/g, "/")
      .replace(/^\.\//, "");
    const absolutePath = path.join(root, relativePath);

    if (entry.isDirectory()) {
      files.push(...sourceFilesForSecretScan(relativePath));
      continue;
    }

    if (!entry.isFile()) continue;
    if (ignoredSecretScanExtensions.has(path.extname(entry.name))) continue;

    files.push(relativePath);
  }

  return files;
}

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
    /match \/suggestions\/\{suggestionId\} \{[\s\S]*?allow create: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/members\/\{memberUid\} \{[\s\S]*?allow create: if false;/
  );
  assert.match(
    firestoreRules,
    /match \/joinRequests\/\{requestUid\} \{[\s\S]*?allow create: if false;/
  );
});

test("Firestore and Storage Sunday windows open together at Madrid midnight", () => {
  const madridMidnightWindow =
    /request\.time\.dayOfWeek\(\) == 6[\s\S]*?request\.time\.time\(\) >= duration\.time\(22, 0, 0, 0\)[\s\S]*?\|\| request\.time\.dayOfWeek\(\) == 7/;

  assert.match(firestoreRules, madridMidnightWindow);
  assert.match(storageRules, madridMidnightWindow);
});

test("sensitive Storage writes cannot replace or delete selfies", () => {
  assert.match(
    storageRules,
    /match \/groups\/\{groupId\}\/weeks\/\{weekKey\}\/\{fileName\} \{[\s\S]*?allow create: if isValidSelfieUpload[\s\S]*?allow update, delete: if false;/
  );
  assert.match(storageRules, /&& resource == null/);
  assert.match(storageRules, /request\.resource\.contentType == "image\/jpeg"/);
  assert.doesNotMatch(storageRules, /contentType\.matches\("image\/\.\*"\)/);
  assert.match(storageRules, /request\.resource\.metadata\.kind == "profilePhoto"/);
  assert.match(storageRules, /request\.resource\.metadata\.kind == "groupPhoto"/);
  assert.match(storageRules, /request\.resource\.metadata\.kind == "selfieThumb"/);
  assert.match(
    storageRules,
    /match \/groups\/\{groupId\}\/weeks\/\{weekKey\}\/thumbs\/\{fileName\}/
  );
  assert.match(
    storageRules,
    /match \/groups\/\{groupId\}\/weeks\/\{weekKey\}\/replacements\/\{fileName\}/
  );
  assert.match(storageRules, /request\.resource\.metadata\.replacement == "true"/);
  assert.match(storageRules, /request\.resource\.metadata\.replacementUploadId/);
});

test("Flutter delegates sensitive actions to Cloud Functions", () => {
  const callables = [
    "crearGrupo",
    "resolverInvitacionGrupo",
    "aceptarSolicitud",
    "solicitarEntradaGrupo",
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
    "borrarSelfie",
    "listarReportesGrupo",
    "resolverReporte",
    "borrarCuenta",
    "borrarFotoPerfilAnterior",
    "enviarSugerencia",
  ];

  for (const callable of callables) {
    assert.match(functionsSource, new RegExp(`exports\\.${callable}\\s*=`));
    assert.match(
      flutterSource,
      new RegExp(
        `(?:httpsCallable\\(\\s*'${callable}'|llamarCallableAutenticadoConReintento\\(\\s*name:\\s*'${callable}')`
      )
    );
  }
});

test("Flutter has no direct post, reaction, or reminder transaction writes", () => {
  assert.doesNotMatch(flutterSource, /transaction\.(set|update|delete)\(postRef/);
  assert.doesNotMatch(flutterSource, /transaction\.(set|update|delete)\(reactionRef/);
  assert.doesNotMatch(flutterSource, /transaction\.(set|update|delete)\(reminderRef/);
  assert.doesNotMatch(flutterSource, /collection\('joinRequests'\)\.doc\([^)]*\)\.set\(/);
  assert.doesNotMatch(flutterSource, /currentUser\?*\.delete\(\)/);
});

test("private group metadata is not exposed by direct reads", () => {
  assert.match(
    firestoreRules,
    /match \/groups\/\{groupId\} \{[\s\S]*?allow get: if isSignedIn\(\)[\s\S]*?&& isMember\(groupId, uid\(\)\);/
  );
  assert.doesNotMatch(firestoreRules, /resource\.data\.deleted != true/);

  const previewStart = functionsSource.indexOf("exports.resolverInvitacionGrupo");
  const previewEnd = functionsSource.indexOf("exports.solicitarEntradaGrupo");
  assert.ok(previewStart >= 0, "resolverInvitacionGrupo exists");
  assert.ok(previewEnd > previewStart, "preview function is before join function");

  const previewSource = functionsSource.slice(previewStart, previewEnd);
  assert.doesNotMatch(previewSource, /photoUrl|photoStoragePath|inviteLink/);
  assert.match(
    flutterSource,
    /llamarCallableAutenticadoConReintento\(\s*name:\s*'resolverInvitacionGrupo'/
  );

  const previewCardStart = flutterSource.indexOf("class JoinGroupPreviewCard");
  const previewCardEnd = flutterSource.indexOf("class JoinPreviewMessageCard");
  assert.ok(previewCardStart >= 0, "JoinGroupPreviewCard exists");
  assert.ok(previewCardEnd > previewCardStart, "preview card block is bounded");
  const previewCardSource = flutterSource.slice(previewCardStart, previewCardEnd);
  assert.doesNotMatch(previewCardSource, /collection\('groups'\)/);
  assert.doesNotMatch(previewCardSource, /photoUrl:\s*data/);
});

test("chat GIF messages are constrained to trusted GIF media URLs", () => {
  assert.match(firestoreRules, /function isValidTrustedGifUrl\(value\)/);
  assert.match(
    firestoreRules,
    /request\.resource\.data\.gifUrl == null[\s\S]*?\|\| isValidTrustedGifUrl\(request\.resource\.data\.gifUrl\)/
  );
  assert.ok(
    firestoreRules.includes('value.matches("^https://media\\\\.tenor\\\\.com/[^\\\\s]+$")')
  );
  assert.ok(
    firestoreRules.includes('value.matches("^https://media[0-9]*\\\\.giphy\\\\.com/[^\\\\s]+$")')
  );
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

test("profile photo replacement deletes the previous object server-side", () => {
  assert.match(functionsSource, /exports\.borrarFotoPerfilAnterior\s*=/);
  assert.match(functionsSource, /function isUserProfileStoragePathForUid/);
  assert.match(functionsSource, /await deleteStoragePathCompletely\(admin\.storage\(\)\.bucket\(\), storagePath\);/);
  assert.match(functionsSource, /activeStoragePath === storagePath/);
  assert.match(flutterSource, /httpsCallable\(\s*'borrarFotoPerfilAnterior'/);
  assert.match(flutterSource, /await borrarFotoPerfilAnterior\(oldPath\);/);
  assert.match(flutterSource, /await borrarFotoPerfilAnterior\(previousStoragePath\);/);
  assert.doesNotMatch(
    flutterSource,
    /storage\.ref\(\)\.child\([^)]*previousStoragePath[^)]*\)\.delete\(\)/
  );
});

test("moderation reviews reports privately and removes content server-side", () => {
  assert.match(functionsSource, /exports\.listarReportesGrupo\s*=/);
  assert.match(functionsSource, /exports\.resolverReporte\s*=/);
  assert.match(functionsSource, /Solo un administrador puede revisar reportes/);
  assert.match(functionsSource, /Solo un administrador puede resolver reportes/);
  assert.match(functionsSource, /transaction\.delete\(postRef\);/);
  assert.match(functionsSource, /await firestore\.recursiveDelete\(postRefToDelete\);/);
  assert.match(functionsSource, /await deleteStoragePaths\(bucket, storagePathsToDelete\);/);
  assert.doesNotMatch(flutterSource, /collection\('reports'\)\.snapshots\(/);
  assert.doesNotMatch(flutterSource, /collection\('reports'\)\.get\(/);
});

test("users delete their own selfies through Cloud Functions", () => {
  assert.match(functionsSource, /exports\.borrarSelfie\s*=/);
  assert.match(functionsSource, /uid !== postUid/);
  assert.match(functionsSource, /await deleteStoragePathsCompletely\(bucket, storagePathsToDelete\);/);
  assert.match(functionsSource, /transaction\.delete\(postRef\);/);
  assert.match(functionsSource, /await firestore\.recursiveDelete\(postRef\);/);
  assert.match(flutterSource, /httpsCallable\(\s*'borrarSelfie'/);
  assert.match(flutterSource, /_SelfieViewerAction \{[\s\S]*downloadSelfie[\s\S]*replaceProfilePhoto[\s\S]*report[\s\S]*deleteSelfie[\s\S]*\}/);
  assert.match(flutterSource, /'Esta selfie se eliminará definitivamente, también de la nube/);
  assert.doesNotMatch(flutterSource, /FirebaseStorage\.instance[\s\S]{0,200}\.delete\(\)/);
});

test("selfie registration retries protected callable authentication", () => {
  const start = flutterSource.indexOf("Future<void> publicarSelfieReal");
  const end = flutterSource.indexOf("Future<void> reaccionarASelfie");
  assert.ok(start >= 0, "publicarSelfieReal exists");
  assert.ok(end > start, "publicarSelfieReal block is bounded");

  const selfieUploadSource = flutterSource.slice(start, end);
  assert.match(
    selfieUploadSource,
    /llamarCallableAutenticadoConReintento\(\s*name:\s*'registrarSelfie'/
  );
  assert.doesNotMatch(
    selfieUploadSource,
    /FirebaseFunctions\.instance\.httpsCallable\(\s*'registrarSelfie'/
  );
});

test("selfie registration tolerates app check attestation outages", () => {
  assert.match(
    functionsSource,
    /exports\.registrarSelfie\s*=\s*callable\(\{enforceAppCheck:\s*false\}/
  );
  assert.match(
    functionsSource,
    /exports\.registrarSelfie[\s\S]*if \(!context\.auth\)/
  );
  assert.match(
    functionsSource,
    /exports\.registrarSelfie[\s\S]*customMetadata\.groupId !== groupId[\s\S]*customMetadata\.uid !== authorUid/
  );
});

test("abuse protection is configured in backend and Flutter", () => {
  assert.match(functionsSource, /JOIN_REQUESTS_PER_DAY_LIMIT\s*=\s*5/);
  assert.match(functionsSource, /REPORTS_PER_DAY_LIMIT\s*=\s*10/);
  assert.doesNotMatch(functionsSource, /REMINDERS_PER_WEEK_LIMIT/);
  assert.match(functionsSource, /REACTION_COOLDOWN_SECONDS\s*=\s*5/);
  assert.match(functionsSource, /collection\("rateLimits"\)/);
  assert.match(functionsSource, /exports\.solicitarEntradaGrupo\s*=/);
  assert.match(functionsSource, /CALLABLE_DEFAULT_OPTIONS[\s\S]*enforceAppCheck:\s*true/);
  assert.match(functionsSource, /exports\.borrarCuenta = callable\(\{[\s\S]*consumeAppCheckToken:\s*true/);
  assert.match(flutterSource, /FirebaseAppCheck\.instance\.activate/);
  assert.match(flutterSource, /AndroidPlayIntegrityProvider\(\)/);
  assert.match(flutterSource, /AppleAppAttestWithDeviceCheckFallbackProvider\(\)/);
  assert.match(flutterSource, /FirebaseAppCheck\.instance\.getToken\(true\)/);
  assert.match(flutterSource, /prepararReintentoCallableProtegida/);
  assert.match(androidManifest, /android:allowBackup="false"/);
  assert.match(androidManifest, /android:usesCleartextTraffic="false"/);
  assert.match(
    flutterSource,
    /llamarCallableAutenticadoConReintento\(\s*name:\s*'solicitarEntradaGrupo'/
  );
});

test("invitation links are wired for app links", () => {
  assert.doesNotMatch(pubspecSource, /app_links:/);
  assert.match(flutterSource, /class SundayDeepLinks/);
  assert.match(flutterSource, /MethodChannel deepLinksMethodChannel/);
  assert.match(flutterSource, /EventChannel deepLinksEventChannel/);
  assert.match(flutterSource, /getInitialLink\(\)/);
  assert.match(flutterSource, /uriLinkStream/);
  assert.match(flutterSource, /obtenerInvitacionDesdeDeepLink/);
  assert.match(flutterSource, /JoinGroupScreen\([\s\S]*initialInviteInput:/);
  assert.match(flutterSource, /Solicitud de acceso/);
  assert.match(flutterSource, /Enviar solicitud de acceso/);
  assert.match(androidManifest, /android:autoVerify="true"/);
  assert.match(androidManifest, /android:name="flutter_deeplinking_enabled"[\s\S]*?android:value="false"/);
  assert.match(androidManifest, /android:host="sundayselfie\.app"/);
  assert.match(androidManifest, /android:pathPrefix="\/j"/);
  assert.match(androidMainActivity, /handleDeepLinkIntent/);
  assert.match(androidMainActivity, /isSundaySelfieDeepLink/);
  assert.match(androidMainActivity, /sunday_selfie\/deep_links/);
  assert.match(iosEntitlements, /applinks:sundayselfie\.app/);
  assert.match(iosInfoPlist, /<key>FlutterDeepLinkingEnabled<\/key>\s*<false\/>/);
  assert.match(iosProject, /CODE_SIGN_ENTITLEMENTS = Runner\/Runner\.entitlements;/);
  assert.equal(firebaseConfig.hosting.public, "public");
  assert.match(
    JSON.stringify(firebaseConfig.hosting.rewrites),
    /\/j\/\*\*/
  );
  assert.match(hostingIndex, /Invitaci\u00f3n a un grupo privado/);
  assert.match(hostingIndex, /PLAY_STORE_URL/);
  assert.match(hostingIndex, /APP_STORE_URL/);
  assert.match(hostingIndex, /intent:\/\//);
  assert.match(androidAssetLinks, /delegate_permission\/common\.handle_all_urls/);
  assert.match(androidAssetLinks, /"package_name": "app\.sundayselfie"/);
});

test("hosting sets defensive browser headers", () => {
  const headers = JSON.stringify(firebaseConfig.hosting.headers);
  assert.match(headers, /Content-Security-Policy/);
  assert.match(headers, /X-Content-Type-Options/);
  assert.match(headers, /X-Frame-Options/);
  assert.match(headers, /Referrer-Policy/);
  assert.match(headers, /Permissions-Policy/);
});

test("notification navigation validates stale destinations", () => {
  assert.match(flutterSource, /validateNotificationGroupDestination/);
  assert.match(flutterSource, /groupData\?\['deleted'\]\s*==\s*true/);
  assert.match(flutterSource, /collection\('members'\)\s*\.doc\(widget\.user\.uid\)/);
  assert.match(flutterSource, /Ese selfie ya no está disponible/);
  assert.match(flutterSource, /Ya no perteneces a este grupo/);
  assert.match(flutterSource, /GroupUnavailableScreen/);
  assert.match(functionsSource, /type: "new_selfie"[\s\S]*postUid: authorUid/);
  assert.match(functionsSource, /type: "new_selfie"[\s\S]*click_action: "FLUTTER_NOTIFICATION_CLICK"/);
});

test("notification types and delivery preferences are implemented", () => {
  assert.match(functionsSource, /function notificationDeliveryOptionsForUser/);
  assert.match(functionsSource, /soundEnabled: settings\.soundEnabled !== false/);
  assert.match(functionsSource, /vibrationEnabled: settings\.vibrationEnabled !== false/);
  assert.match(functionsSource, /function platformNotificationConfig/);
  assert.match(functionsSource, /defaultVibrateTimings = true/);
  assert.match(functionsSource, /vibrateTimingsMillis = \[0\]/);
  assert.match(functionsSource, /sendNewMemberNotification/);
  assert.match(functionsSource, /type: "new_member"/);
  assert.match(functionsSource, /newMembersEnabled/);
  assert.match(functionsSource, /sendJoinRequestNotification/);
  assert.match(functionsSource, /type: "join_request"/);
  assert.match(functionsSource, /requiredRole: "admin"/);
  assert.match(functionsSource, /sendJoinAcceptedNotification/);
  assert.match(functionsSource, /type: "join_accepted"/);
  assert.match(functionsSource, /exports\.weeklySummaryReminder\s*=/);
  assert.match(functionsSource, /type: "weekly_summary"/);
  assert.match(functionsSource, /weeklySummaryEnabled/);
  assert.match(functionsSource, /newSelfiesEnabled/);
  assert.match(functionsSource, /sendChatMessageNotification/);
  assert.match(functionsSource, /type: "chat_message"/);
  assert.match(functionsSource, /chatMessagesEnabled/);
  assert.match(flutterSource, /'new_member'/);
  assert.match(flutterSource, /'join_request'/);
  assert.match(flutterSource, /'join_accepted'/);
  assert.match(flutterSource, /'weekly_summary'/);
  assert.match(flutterSource, /'chat_message'/);
});

test("functions keep regional CPU quota bounded", () => {
  assert.match(functionsSource, /setGlobalOptions\(\{/);
  assert.match(functionsSource, /cpu:\s*"gcf_gen1"/);
  assert.match(functionsSource, /maxInstances:\s*5/);
});

test("repository blocks accidental secret leaks", () => {
  assert.match(gitignoreSource, /^\.env$/m);
  assert.match(gitignoreSource, /^backups\/$/m);
  assert.match(gitignoreSource, /^service-account\*\.json$/m);
  assert.match(gitignoreSource, /^\*serviceAccount\*\.json$/m);
  assert.match(gitignoreSource, /^\.firebase\/$/m);

  const allowedFirebaseClientConfigFiles = new Set([
    "android/app/google-services.json",
    "ios/Runner/GoogleService-Info.plist",
    "lib/firebase_options.dart",
  ]);
  const secretPatterns = [
    {
      name: "Firebase client API key",
      regex: /AIza[0-9A-Za-z_-]{35}/g,
      allowedFiles: allowedFirebaseClientConfigFiles,
    },
    {
      name: "private key block",
      regex: new RegExp("-----BEGIN [A-Z ]*PRIVATE " + "KEY-----", "g"),
      allowedFiles: new Set(),
    },
    {
      name: "Google service-account private key",
      regex: new RegExp(
        "\"private_key\"\\s*:\\s*\"-----BEGIN PRIVATE " + "KEY-----",
        "g"
      ),
      allowedFiles: new Set(),
    },
    {
      name: "GitHub token",
      regex: /(ghp|github_pat)_[A-Za-z0-9_]{20,}/g,
      allowedFiles: new Set(),
    },
    {
      name: "OpenAI API key",
      regex: /sk-[A-Za-z0-9]{20,}/g,
      allowedFiles: new Set(),
    },
    {
      name: "Slack token",
      regex: /xox[baprs]-[A-Za-z0-9-]{20,}/g,
      allowedFiles: new Set(),
    },
    {
      name: "Stripe secret key",
      regex: /(sk|rk)_(live|test)_[A-Za-z0-9]{20,}/g,
      allowedFiles: new Set(),
    },
  ];

  const findings = [];

  for (const relativePath of sourceFilesForSecretScan()) {
    const source = fs.readFileSync(path.join(root, relativePath), "utf8");

    for (const pattern of secretPatterns) {
      pattern.regex.lastIndex = 0;
      if (!pattern.regex.test(source)) continue;
      if (pattern.allowedFiles.has(relativePath)) continue;
      findings.push(`${relativePath}: ${pattern.name}`);
    }
  }

  assert.deepEqual(findings, []);
});
