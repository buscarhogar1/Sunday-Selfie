const functions = require("firebase-functions");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

admin.initializeApp();

exports.aceptarSolicitud = functions.https.onCall(async (data, context) => {
  const {groupId, requestUid} = data;

  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const adminUid = context.auth.uid;

  const firestore = admin.firestore();

  const memberRef = firestore
    .collection("groups")
    .doc(groupId)
    .collection("members")
    .doc(adminUid);

  const memberDoc = await memberRef.get();

  if (!memberDoc.exists || memberDoc.data().role !== "admin") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "No eres admin"
    );
  }

  const groupRef = firestore.collection("groups").doc(groupId);
  const groupDoc = await groupRef.get();

  if (!groupDoc.exists) {
    throw new functions.https.HttpsError(
      "not-found",
      "Grupo no existe"
    );
  }

  const groupData = groupDoc.data();

  const batch = firestore.batch();

  const newMemberRef = groupRef.collection("members").doc(requestUid);

  batch.set(newMemberRef, {
    role: "member",
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    statusThisSunday: false,
    effectiveName: "Usuario",
    effectivePhotoUrl: null,
    inviteCodeVersionAtJoin: groupData.inviteCodeVersion || 1,
  });

  const userGroupRef = firestore
    .collection("users")
    .doc(requestUid)
    .collection("groups")
    .doc(groupId);

  batch.set(userGroupRef, {
    groupId: groupId,
    role: "member",
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    lastViewedAt: null,
    lastActivityAt: admin.firestore.FieldValue.serverTimestamp(),
    notificationsOverride: "default",
    autoDownloadEnabled: false,
    displayNameSnapshot: groupData.name,
    groupPhotoUrlSnapshot: groupData.photoUrl || null,
  });

  const joinRequestRef = groupRef
    .collection("joinRequests")
    .doc(requestUid);

  batch.delete(joinRequestRef);

  await batch.commit();

  return {success: true};
});

const SUNDAY_TIME_REGION = "europe-west1";
const SUNDAY_TIME_ZONE = "Europe/Madrid";
const SUNDAY_TIME_SCHEDULE = "0 17 * * 0";

const invalidTokenCodes = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered",
]);

function chunkArray(items, size) {
  const chunks = [];

  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }

  return chunks;
}

async function loadActiveNotificationTokens() {
  const firestore = admin.firestore();

  const snapshot = await firestore
    .collectionGroup("notificationTokens")
    .where("enabled", "==", true)
    .get();

  const tokensByValue = new Map();

  snapshot.docs.forEach((doc) => {
    const data = doc.data();
    const token = data.token;

    if (typeof token !== "string") return;
    if (token.trim().length === 0) return;

    if (!tokensByValue.has(token)) {
      tokensByValue.set(token, {
        token,
        ref: doc.ref,
      });
    }
  });

  return Array.from(tokensByValue.values());
}

async function disableInvalidToken(entry, reason) {
  await entry.ref.set(
    {
      enabled: false,
      disabledAt: admin.firestore.FieldValue.serverTimestamp(),
      disabledReason: reason,
      lastFailureAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    {
      merge: true,
    }
  );
}

async function sendSundayTimeNotification() {
  const entries = await loadActiveNotificationTokens();

  if (entries.length === 0) {
    logger.info("Sunday Time sin tokens activos");
    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  let successCount = 0;
  let failureCount = 0;

  const batches = chunkArray(entries, 500);

  for (const batch of batches) {
    const tokens = batch.map((entry) => entry.token);

    const response = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: {
        title: "Sunday Selfie",
        body: "Es domingo. Sube tu selfie semanal",
      },
      data: {
        type: "sunday_time",
        target: "home",
      },
      android: {
        priority: "high",
        notification: {
          sound: "default",
        },
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    });

    successCount += response.successCount;
    failureCount += response.failureCount;

    const disablePromises = [];

    response.responses.forEach((result, index) => {
      if (result.success) return;

      const errorCode = result.error && result.error.code
        ? result.error.code
        : "unknown";

      logger.warn("Error enviando Sunday Time", {
        errorCode,
        tokenIndex: index,
      });

      if (invalidTokenCodes.has(errorCode)) {
        disablePromises.push(disableInvalidToken(batch[index], errorCode));
      }
    });

    await Promise.all(disablePromises);
  }

  logger.info("Sunday Time enviado", {
    tokenCount: entries.length,
    successCount,
    failureCount,
  });

  return {
    tokenCount: entries.length,
    successCount,
    failureCount,
  };
}

exports.sundayTimeReminder = onSchedule(
  {
    region: SUNDAY_TIME_REGION,
    timeZone: SUNDAY_TIME_ZONE,
    schedule: SUNDAY_TIME_SCHEDULE,
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async () => {
    await sendSundayTimeNotification();
  }
);
