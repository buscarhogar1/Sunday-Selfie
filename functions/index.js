const functions = require("firebase-functions");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
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
const MAX_TOKENS_PER_MULTICAST = 500;
const SUNDAY_TIME_LOG_COLLECTION = "systemLogs";
const SUNDAY_TIME_LOG_DOCUMENT = "sundayTimeRuns";

const invalidTokenCodes = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered",
  "messaging/invalid-argument",
]);

function chunkArray(items, size) {
  const chunks = [];

  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }

  return chunks;
}

function currentIsoWeekParts(date) {
  const utcDate = new Date(Date.UTC(
    date.getUTCFullYear(),
    date.getUTCMonth(),
    date.getUTCDate()
  ));
  const dayNum = utcDate.getUTCDay() || 7;
  utcDate.setUTCDate(utcDate.getUTCDate() + 4 - dayNum);
  const isoYear = utcDate.getUTCFullYear();
  const yearStart = new Date(Date.UTC(isoYear, 0, 1));
  const isoWeek = Math.ceil((((utcDate - yearStart) / 86400000) + 1) / 7);

  return {isoYear, isoWeek};
}

function currentWeekKey() {
  const {isoYear, isoWeek} = currentIsoWeekParts(new Date());
  return `${isoYear}-W${String(isoWeek).padStart(2, "0")}`;
}

function sundayTimeEnabledForUser(userData) {
  const settings = userData && userData.notificationSettings
    ? userData.notificationSettings
    : {};

  if (settings.globalEnabled === false) return false;
  if (settings.sundayTimeEnabled === false) return false;

  return true;
}

function userRefFromTokenDoc(tokenDoc) {
  return tokenDoc.ref.parent.parent;
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

async function loadActiveNotificationTokens() {
  const firestore = admin.firestore();

  const snapshot = await firestore
    .collectionGroup("notificationTokens")
    .where("enabled", "==", true)
    .get();

  const tokensByValue = new Map();
  const userDocCache = new Map();
  let tokensWithoutUser = 0;
  let usersDisabled = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data() || {};
    const token = typeof data.token === "string" ? data.token.trim() : "";
    const userRef = userRefFromTokenDoc(doc);

    if (!token || !userRef) {
      tokensWithoutUser += 1;
      continue;
    }

    let userDoc = userDocCache.get(userRef.path);

    if (!userDoc) {
      userDoc = await userRef.get();
      userDocCache.set(userRef.path, userDoc);
    }

    if (!userDoc.exists) {
      tokensWithoutUser += 1;
      continue;
    }

    const userData = userDoc.data() || {};

    if (!sundayTimeEnabledForUser(userData)) {
      usersDisabled += 1;
      continue;
    }

    if (!tokensByValue.has(token)) {
      tokensByValue.set(token, {
        token,
        ref: doc.ref,
        uid: userDoc.id,
        platform: data.platform || "unknown",
      });
    }
  }

  return {
    entries: Array.from(tokensByValue.values()),
    tokensLoaded: snapshot.size,
    consideredUsers: userDocCache.size,
    tokensWithoutUser,
    usersDisabled,
  };
}

function buildSundayTimeMessage(tokens, weekKey) {
  return {
    tokens,
    notification: {
      title: "Sunday Selfie",
      body: "¡Hoy toca subir tu selfie del domingo!",
    },
    data: {
      type: "sunday_time",
      target: "home",
      screen: "groups",
      weekKey,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    android: {
      priority: "high",
      notification: {
        channelId: "sunday_time",
        sound: "default",
        priority: "high",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  };
}

async function sendSundayTimeNotification() {
  const firestore = admin.firestore();
  const weekKey = currentWeekKey();
  const runId = new Date().toISOString().replace(/[.:]/g, "-");
  const logRef = firestore
    .collection(SUNDAY_TIME_LOG_COLLECTION)
    .doc(SUNDAY_TIME_LOG_DOCUMENT)
    .collection("runs")
    .doc(runId);

  const stats = {
    tokensLoaded: 0,
    consideredUsers: 0,
    uniqueTokens: 0,
    successCount: 0,
    failureCount: 0,
    invalidTokenCount: 0,
    tokensWithoutUser: 0,
    usersDisabled: 0,
  };

  await logRef.set({
    type: "sunday_time",
    status: "running",
    weekKey,
    schedule: SUNDAY_TIME_SCHEDULE,
    timeZone: SUNDAY_TIME_ZONE,
    startedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  try {
    const loaded = await loadActiveNotificationTokens();
    const entries = loaded.entries;

    stats.tokensLoaded = loaded.tokensLoaded;
    stats.consideredUsers = loaded.consideredUsers;
    stats.tokensWithoutUser = loaded.tokensWithoutUser;
    stats.usersDisabled = loaded.usersDisabled;
    stats.uniqueTokens = entries.length;

    if (entries.length === 0) {
      await logRef.set({
        status: "completed",
        finishedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...stats,
      }, {merge: true});

      logger.info("Sunday Time sin tokens activos", stats);
      return stats;
    }

    const batches = chunkArray(entries, MAX_TOKENS_PER_MULTICAST);

    for (const batch of batches) {
      const tokens = batch.map((entry) => entry.token);

      const response = await admin.messaging().sendEachForMulticast(
        buildSundayTimeMessage(tokens, weekKey)
      );

      stats.successCount += response.successCount;
      stats.failureCount += response.failureCount;

      const disablePromises = [];

      response.responses.forEach((result, index) => {
        if (result.success) return;

        const errorCode = result.error && result.error.code
          ? result.error.code
          : "unknown";

        logger.warn("Error enviando Sunday Time", {
          uid: batch[index].uid,
          platform: batch[index].platform,
          errorCode,
          tokenIndex: index,
        });

        if (invalidTokenCodes.has(errorCode)) {
          stats.invalidTokenCount += 1;
          disablePromises.push(disableInvalidToken(batch[index], errorCode));
        }
      });

      await Promise.all(disablePromises);
    }

    await logRef.set({
      status: "completed",
      finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...stats,
    }, {merge: true});

    logger.info("Sunday Time enviado", stats);
    return stats;
  } catch (error) {
    await logRef.set({
      status: "error",
      finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      errorMessage: error && error.message ? error.message : String(error),
      ...stats,
    }, {merge: true});

    logger.error("Sunday Time falló", error);
    throw error;
  }
}

exports.sundayTimeReminder = onSchedule(
  {
    region: SUNDAY_TIME_REGION,
    timeZone: SUNDAY_TIME_ZONE,
    schedule: SUNDAY_TIME_SCHEDULE,
    memory: "256MiB",
    timeoutSeconds: 540,
  },
  async () => {
    await sendSundayTimeNotification();
  }
);


const NEW_SELFIE_REGION = "europe-southwest1";

async function loadGroupRecipientTokens(groupId, authorUid) {
  const firestore = admin.firestore();

  const membersSnapshot = await firestore
    .collection("groups")
    .doc(groupId)
    .collection("members")
    .get();

  const tokensByValue = new Map();

  for (const memberDoc of membersSnapshot.docs) {
    const recipientUid = memberDoc.id;

    if (recipientUid === authorUid) continue;

    const userGroupDoc = await firestore
      .collection("users")
      .doc(recipientUid)
      .collection("groups")
      .doc(groupId)
      .get();

    if (userGroupDoc.exists) {
      const userGroupData = userGroupDoc.data();
      const override = userGroupData.notificationsOverride;

      if (override === "off") continue;
    }

    const tokensSnapshot = await firestore
      .collection("users")
      .doc(recipientUid)
      .collection("notificationTokens")
      .where("enabled", "==", true)
      .get();

    tokensSnapshot.docs.forEach((tokenDoc) => {
      const data = tokenDoc.data();
      const token = data.token;

      if (typeof token !== "string") return;
      if (token.trim().length === 0) return;

      if (!tokensByValue.has(token)) {
        tokensByValue.set(token, {
          token,
          ref: tokenDoc.ref,
        });
      }
    });
  }

  return Array.from(tokensByValue.values());
}

async function sendNewSelfieNotification({
  groupId,
  weekKey,
  authorUid,
  authorName,
  groupName,
}) {
  const entries = await loadGroupRecipientTokens(groupId, authorUid);

  if (entries.length === 0) {
    logger.info("Nuevo selfie sin destinatarios activos", {
      groupId,
      weekKey,
      authorUid,
    });

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
        title: groupName,
        body: `${authorName} ha publicado su Sunday Selfie`,
      },
      data: {
        type: "new_selfie",
        target: "group",
        groupId,
        weekKey,
        authorUid,
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

      logger.warn("Error enviando notificación de nuevo selfie", {
        groupId,
        weekKey,
        authorUid,
        errorCode,
        tokenIndex: index,
      });

      if (invalidTokenCodes.has(errorCode)) {
        disablePromises.push(disableInvalidToken(batch[index], errorCode));
      }
    });

    await Promise.all(disablePromises);
  }

  logger.info("Notificación de nuevo selfie enviada", {
    groupId,
    weekKey,
    authorUid,
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

exports.notifyNewSelfie = onDocumentCreated(
  {
    region: NEW_SELFIE_REGION,
    document: "groups/{groupId}/weeks/{weekKey}/posts/{authorUid}",
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async (event) => {
    const snapshot = event.data;

    if (!snapshot) {
      logger.warn("notifyNewSelfie sin snapshot");
      return;
    }

    const params = event.params;
    const groupId = params.groupId;
    const weekKey = params.weekKey;
    const authorUid = params.authorUid;

    const postData = snapshot.data() || {};
    const authorName = postData.authorName || "Alguien";

    const groupDoc = await admin.firestore()
      .collection("groups")
      .doc(groupId)
      .get();

    const groupData = groupDoc.exists ? groupDoc.data() : {};
    const groupName = groupData.name || "Sunday Selfie";

    await sendNewSelfieNotification({
      groupId,
      weekKey,
      authorUid,
      authorName,
      groupName,
    });
  }
);

