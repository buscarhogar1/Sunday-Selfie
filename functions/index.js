const functions = require("firebase-functions");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const {getDownloadURL} = require("firebase-admin/storage");
const crypto = require("crypto");

admin.initializeApp();

function callable(optionsOrHandler, maybeHandler) {
  const hasOptions = typeof optionsOrHandler !== "function";
  const options = hasOptions ? optionsOrHandler : {};
  const handler = hasOptions ? maybeHandler : optionsOrHandler;

  return functions.https.onCall(options, async (request) => {
    return handler(request.data, request);
  });
}

function isValidDocumentId(value) {
  return typeof value === "string"
    && value.trim().length > 0
    && !value.includes("/");
}

function isValidWeekKey(value) {
  return typeof value === "string"
    && /^\d{4}-W(0[1-9]|[1-4]\d|5[0-3])$/.test(value);
}

function cleanString(value, fallback) {
  if (typeof value !== "string") return fallback;

  const clean = value.trim();
  return clean.length > 0 ? clean : fallback;
}

function createInviteCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";

  for (let index = 0; index < 10; index += 1) {
    code += alphabet[crypto.randomInt(alphabet.length)];
  }

  return code;
}

function createInviteLink(inviteCode) {
  return `https://sundayselfie.app/j/${inviteCode}`;
}

function currentMadridWeekInfo(date = new Date()) {
  const values = {};
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Madrid",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    weekday: "short",
  });

  formatter.formatToParts(date).forEach((part) => {
    values[part.type] = part.value;
  });

  const madridDate = new Date(Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day)
  ));
  const {isoYear, isoWeek} = currentIsoWeekParts(madridDate);

  return {
    isSunday: values.weekday === "Sun",
    isoYear,
    isoWeek,
    weekKey: `${isoYear}-W${String(isoWeek).padStart(2, "0")}`,
  };
}

const DEFAULT_GROUP_COLOR_VALUE = 0xFFF4A261;
const GROUP_COLOR_VALUES = new Set([
  DEFAULT_GROUP_COLOR_VALUE,
  0xFF64B5F6,
  0xFFA8D8A8,
  0xFFB89AF2,
  0xFFF5C2D0,
  0xFFFFD36A,
  0xFF78CAD2,
  0xFFF27272,
  0xFF78A866,
  0xFFE5735A,
  0xFFA989C5,
  0xFF5AAAD0,
]);
const GROUP_EMOJI_VALUES = new Set([
  "👥", "🏠", "🌞", "📸", "💼", "🎓", "✈️", "⚽", "🎮", "🎉",
  "🐶", "🐱", "🍕", "☕", "🏖️", "❤️", "🔥", "⭐", "👑", "🫶",
]);
const REACTION_EMOJI_VALUES = new Set([
  "❤️", "😂", "😍", "🔥", "👏", "🙌", "🥰", "😎", "😊", "😄",
  "🥳", "🤩", "😮", "😢", "😭", "😜", "😇", "🤗", "😋", "😆",
  "👍", "👎", "💪", "🙏", "🤝", "👌", "✌️", "🫶", "💯", "✨",
  "⭐", "🌟", "💫", "🌞", "🌈", "🎉", "🎊", "🏆", "🥇", "👑",
  "🐶", "🐱", "🐵", "🦄", "🍕", "🍔", "🍟", "🍩", "🍰", "☕",
  "🏖️", "✈️", "🏠", "💼", "🎓", "⚽", "🏀", "🎾", "🎮", "🎵",
]);
const REPORT_REASON_VALUES = new Set([
  "contenido_inapropiado",
  "acoso",
  "spam",
  "otro",
]);
const MODERATION_DECISION_VALUES = new Set([
  "dismiss",
  "remove_selfie",
]);
const ACCOUNT_DELETE_CONFIRMATION = "BORRAR";
const RECENT_AUTH_MAX_AGE_SECONDS = 15 * 60;

exports.crearGrupo = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupName = cleanString(data && data.name, null);

  if (!groupName || groupName.length > 80) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "El nombre del grupo debe tener entre 1 y 80 caracteres"
    );
  }

  const rawEmoji = data && data.emoji;
  const groupEmoji = rawEmoji === null || rawEmoji === undefined
    ? null
    : cleanString(rawEmoji, null);

  if (groupEmoji !== null && !GROUP_EMOJI_VALUES.has(groupEmoji)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "El emoticono del grupo no es válido"
    );
  }

  const rawColorValue = data && data.colorValue;
  const groupColorValue = Number.isInteger(rawColorValue)
    ? rawColorValue
    : DEFAULT_GROUP_COLOR_VALUE;

  if (!GROUP_COLOR_VALUES.has(groupColorValue)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "El color del grupo no es válido"
    );
  }

  const creatorUid = context.auth.uid;
  const firestore = admin.firestore();
  const userRef = firestore.collection("users").doc(creatorUid);
  const groupRef = firestore.collection("groups").doc();
  const memberRef = groupRef.collection("members").doc(creatorUid);
  const userGroupRef = userRef.collection("groups").doc(groupRef.id);

  let result = null;

  await firestore.runTransaction(async (transaction) => {
    const userDoc = await transaction.get(userRef);

    if (!userDoc.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Completa tu perfil antes de crear un grupo"
      );
    }

    let inviteCode = null;
    let inviteCodeRef = null;

    for (let attempt = 0; attempt < 5; attempt += 1) {
      const candidateCode = createInviteCode();
      const candidateRef = firestore.collection("inviteCodes").doc(candidateCode);
      const candidateDoc = await transaction.get(candidateRef);

      if (!candidateDoc.exists) {
        inviteCode = candidateCode;
        inviteCodeRef = candidateRef;
        break;
      }
    }

    if (!inviteCode || !inviteCodeRef) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        "No se pudo generar una invitación para el grupo"
      );
    }

    const userData = userDoc.data() || {};
    const authName = context.auth.token && context.auth.token.name;
    const creatorName = cleanString(
      userData.baseName,
      cleanString(authName, "Usuario")
    ).slice(0, 80);
    const creatorPhotoUrl = cleanString(userData.basePhotoUrl, null);
    const inviteLink = createInviteLink(inviteCode);
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.set(groupRef, {
      name: groupName,
      photoUrl: null,
      photoStoragePath: null,
      emoji: groupEmoji,
      colorValue: groupColorValue,
      createdAt: now,
      lastActivityAt: now,
      createdByUid: creatorUid,
      timezone: "Europe/Madrid",
      inviteCode,
      inviteLink,
      inviteCodeVersion: 1,
      memberCount: 1,
      adminsCount: 1,
      memberLimit: 30,
      deleted: false,
      deletedAt: null,
      deletedReason: null,
    });

    transaction.set(memberRef, {
      role: "admin",
      joinedAt: now,
      statusThisSunday: false,
      effectiveName: creatorName,
      effectivePhotoUrl: creatorPhotoUrl,
      inviteCodeVersionAtJoin: 1,
    });

    transaction.set(userGroupRef, {
      groupId: groupRef.id,
      role: "admin",
      joinedAt: now,
      lastViewedAt: null,
      lastActivityAt: now,
      notificationsOverride: "on",
      autoDownloadEnabled: false,
      displayNameSnapshot: groupName,
      groupPhotoUrlSnapshot: null,
      groupEmojiSnapshot: groupEmoji,
      groupColorValueSnapshot: groupColorValue,
    });

    transaction.set(inviteCodeRef, {
      groupId: groupRef.id,
      active: true,
      version: 1,
      createdAt: now,
      createdByUid: creatorUid,
    });

    result = {
      groupId: groupRef.id,
      inviteCode,
      inviteLink,
    };
  });

  return result;
});

exports.registrarSelfie = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;

  if (!isValidDocumentId(groupId)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const weekInfo = currentMadridWeekInfo();

  if (!weekInfo.isSunday) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "La ventana de subida está cerrada"
    );
  }

  const authorUid = context.auth.uid;
  const weekKey = weekInfo.weekKey;
  const storagePath = `groups/${groupId}/weeks/${weekKey}/${authorUid}.jpg`;
  const file = admin.storage().bucket().file(storagePath);
  const [fileExists] = await file.exists();

  if (!fileExists) {
    throw new functions.https.HttpsError(
      "not-found",
      "No se ha encontrado la imagen que intentas publicar"
    );
  }

  const [fileMetadata] = await file.getMetadata();
  const customMetadata = fileMetadata.metadata || {};
  const fileSize = Number(fileMetadata.size || 0);
  const contentType = cleanString(fileMetadata.contentType, "");

  if (
    !contentType.startsWith("image/")
    || fileSize <= 0
    || fileSize >= 10 * 1024 * 1024
    || customMetadata.groupId !== groupId
    || customMetadata.weekKey !== weekKey
    || customMetadata.uid !== authorUid
  ) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "La imagen subida no es válida"
    );
  }

  let imageUrl;

  try {
    imageUrl = await getDownloadURL(file);
  } catch (error) {
    logger.error("No se pudo obtener la URL de la selfie", {
      groupId,
      weekKey,
      authorUid,
      error,
    });
    throw new functions.https.HttpsError(
      "internal",
      "No se pudo preparar la imagen publicada"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const memberRef = groupRef.collection("members").doc(authorUid);
  const weekRef = groupRef.collection("weeks").doc(weekKey);
  const postsRef = weekRef.collection("posts");
  const postRef = postsRef.doc(authorUid);
  const userGroupRef = firestore
    .collection("users")
    .doc(authorUid)
    .collection("groups")
    .doc(groupId);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      memberDoc,
      weekDoc,
      postsSnapshot,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(memberRef),
      transaction.get(weekRef),
      transaction.get(postsRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!memberDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "No perteneces a este grupo"
      );
    }

    if (postsSnapshot.docs.some((postDoc) => postDoc.id === authorUid)) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Ya has publicado tu selfie de este domingo"
      );
    }

    const memberData = memberDoc.data() || {};
    const authorName = cleanString(memberData.effectiveName, "Usuario");
    const authorPhotoUrl = cleanString(memberData.effectivePhotoUrl, null);
    const now = admin.firestore.FieldValue.serverTimestamp();
    const postCount = postsSnapshot.size + 1;

    if (weekDoc.exists) {
      transaction.update(weekRef, {
        postCount,
      });
    } else {
      transaction.set(weekRef, {
        weekKey,
        isoYear: weekInfo.isoYear,
        isoWeek: weekInfo.isoWeek,
        createdAt: now,
        postCount,
      });
    }

    transaction.create(postRef, {
      uid: authorUid,
      authorName,
      authorPhotoUrl,
      createdAt: now,
      updatedAt: now,
      imageUrl,
      thumbUrl: imageUrl,
      storagePathFull: storagePath,
      storagePathThumb: storagePath,
      hasAnyReactions: false,
      selfReactionEmoji: null,
    });

    transaction.set(
      userGroupRef,
      {
        groupId,
        lastActivityAt: now,
      },
      {merge: true}
    );

    transaction.update(groupRef, {
      lastActivityAt: now,
    });
  });

  return {
    success: true,
    groupId,
    weekKey,
  };
});

exports.reaccionarASelfie = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const weekKey = data && data.weekKey;
  const postUid = data && data.postUid;
  const emoji = cleanString(data && data.emoji, "");

  if (
    !isValidDocumentId(groupId)
    || !isValidWeekKey(weekKey)
    || !isValidDocumentId(postUid)
    || !REACTION_EMOJI_VALUES.has(emoji)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Reacción no válida"
    );
  }

  const reactorUid = context.auth.uid;

  if (reactorUid === postUid) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "No puedes reaccionar a tu propio selfie"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const reactorMemberRef = groupRef.collection("members").doc(reactorUid);
  const authorMemberRef = groupRef.collection("members").doc(postUid);
  const weekRef = groupRef.collection("weeks").doc(weekKey);
  const postRef = weekRef.collection("posts").doc(postUid);
  const reactorPostRef = weekRef.collection("posts").doc(reactorUid);
  const reactionRef = postRef.collection("reactions").doc(reactorUid);
  const reactorUserGroupRef = firestore
    .collection("users")
    .doc(reactorUid)
    .collection("groups")
    .doc(groupId);
  const authorUserGroupRef = firestore
    .collection("users")
    .doc(postUid)
    .collection("groups")
    .doc(groupId);

  let notificationData = null;

  await firestore.runTransaction(async (transaction) => {
    notificationData = null;

    const [
      groupDoc,
      reactorMemberDoc,
      authorMemberDoc,
      postDoc,
      reactorPostDoc,
      reactionDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(reactorMemberRef),
      transaction.get(authorMemberRef),
      transaction.get(postRef),
      transaction.get(reactorPostRef),
      transaction.get(reactionRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!reactorMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "No perteneces a este grupo"
      );
    }

    if (!authorMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "El autor ya no pertenece al grupo"
      );
    }

    if (!postDoc.exists || postDoc.data().uid !== postUid) {
      throw new functions.https.HttpsError(
        "not-found",
        "La selfie ya no está disponible"
      );
    }

    if (!reactorPostDoc.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Publica tu selfie semanal antes de reaccionar"
      );
    }

    if (reactionDoc.exists && reactionDoc.data().emoji === emoji) {
      return;
    }

    const groupData = groupDoc.data() || {};
    const reactorData = reactorMemberDoc.data() || {};
    const reactorName = cleanString(reactorData.effectiveName, "Alguien");
    const reactorPhotoUrl = cleanString(
      reactorData.effectivePhotoUrl,
      null
    );
    const now = admin.firestore.FieldValue.serverTimestamp();

    if (reactionDoc.exists) {
      transaction.update(reactionRef, {
        emoji,
        authorName: reactorName,
        authorPhotoUrl: reactorPhotoUrl,
        updatedAt: now,
      });
    } else {
      transaction.create(reactionRef, {
        uid: reactorUid,
        emoji,
        authorName: reactorName,
        authorPhotoUrl: reactorPhotoUrl,
        createdAt: now,
        updatedAt: now,
      });
      transaction.update(postRef, {
        hasAnyReactions: true,
      });

      notificationData = {
        groupId,
        groupName: cleanString(groupData.name, "Sunday Selfie"),
        weekKey,
        postUid,
        reactorUid,
        reactorName,
        emoji,
      };
    }

    transaction.update(groupRef, {
      lastActivityAt: now,
    });

    transaction.set(
      reactorUserGroupRef,
      {
        groupId,
        lastActivityAt: now,
      },
      {merge: true}
    );

    transaction.set(
      authorUserGroupRef,
      {
        groupId,
        lastActivityAt: now,
      },
      {merge: true}
    );
  });

  if (notificationData) {
    try {
      await sendReactionNotification(notificationData);
    } catch (error) {
      logger.error("No se pudo enviar la notificación de reacción", {
        groupId,
        weekKey,
        postUid,
        reactorUid,
        error,
      });
    }
  }

  return {
    success: true,
    groupId,
    weekKey,
    postUid,
  };
});

exports.enviarZumbidoSelfie = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const targetUid = data && data.targetUid;

  if (!isValidDocumentId(groupId) || !isValidDocumentId(targetUid)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const senderUid = context.auth.uid;

  if (senderUid === targetUid) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "No puedes enviarte un zumbido a ti mismo"
    );
  }

  const weekInfo = currentMadridWeekInfo();

  if (!weekInfo.isSunday) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Los zumbidos solo están disponibles los domingos"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const senderMemberRef = groupRef.collection("members").doc(senderUid);
  const targetMemberRef = groupRef.collection("members").doc(targetUid);
  const weekRef = groupRef.collection("weeks").doc(weekInfo.weekKey);
  const targetPostRef = weekRef.collection("posts").doc(targetUid);
  const reminderRef = weekRef
    .collection("reminders")
    .doc(`${senderUid}_${targetUid}`);
  const senderUserGroupRef = firestore
    .collection("users")
    .doc(senderUid)
    .collection("groups")
    .doc(groupId);
  const targetUserGroupRef = firestore
    .collection("users")
    .doc(targetUid)
    .collection("groups")
    .doc(groupId);

  let reminderData = null;

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      senderMemberDoc,
      targetMemberDoc,
      targetPostDoc,
      reminderDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(senderMemberRef),
      transaction.get(targetMemberRef),
      transaction.get(targetPostRef),
      transaction.get(reminderRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!senderMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "No perteneces a este grupo"
      );
    }

    if (!targetMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este usuario ya no pertenece al grupo"
      );
    }

    if (targetPostDoc.exists) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Este usuario ya ha publicado esta semana"
      );
    }

    if (reminderDoc.exists) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Ya le has enviado un zumbido esta semana"
      );
    }

    const groupData = groupDoc.data() || {};
    const senderData = senderMemberDoc.data() || {};
    const targetData = targetMemberDoc.data() || {};
    const groupName = cleanString(groupData.name, "Sunday Selfie");
    const senderName = cleanString(senderData.effectiveName, "Alguien");
    const targetName = cleanString(targetData.effectiveName, "Usuario");
    const senderPhotoUrl = cleanString(senderData.effectivePhotoUrl, null);
    const targetPhotoUrl = cleanString(targetData.effectivePhotoUrl, null);
    const now = admin.firestore.FieldValue.serverTimestamp();

    reminderData = {
      groupId,
      groupName,
      weekKey: weekInfo.weekKey,
      senderUid,
      senderName,
      targetUid,
    };

    transaction.create(reminderRef, {
      type: "friend_reminder",
      groupId,
      groupName,
      weekKey: weekInfo.weekKey,
      senderUid,
      senderName,
      senderPhotoUrl,
      targetUid,
      targetName,
      targetPhotoUrl,
      createdAt: now,
      updatedAt: now,
      notificationStatus: "pending",
      notificationSentAt: null,
      readAt: null,
    });

    transaction.update(groupRef, {
      lastActivityAt: now,
    });

    transaction.set(
      senderUserGroupRef,
      {
        groupId,
        lastActivityAt: now,
      },
      {merge: true}
    );

    transaction.set(
      targetUserGroupRef,
      {
        groupId,
        lastActivityAt: now,
      },
      {merge: true}
    );
  });

  try {
    await sendFriendReminderNotification(reminderData);
    await reminderRef.set(
      {
        notificationStatus: "processed",
        notificationSentAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
  } catch (error) {
    logger.error("No se pudo procesar la notificación del zumbido", {
      groupId,
      weekKey: weekInfo.weekKey,
      senderUid,
      targetUid,
      error,
    });
    await reminderRef.set(
      {
        notificationStatus: "failed",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
  }

  return {
    success: true,
    groupId,
    weekKey: weekInfo.weekKey,
  };
});

exports.aceptarSolicitud = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const requestUid = data && data.requestUid;

  if (!isValidDocumentId(groupId) || !isValidDocumentId(requestUid)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;

  if (adminUid === requestUid) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "No puedes aceptarte a ti mismo"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);
  const newMemberRef = groupRef.collection("members").doc(requestUid);
  const joinRequestRef = groupRef.collection("joinRequests").doc(requestUid);
  const blockedUserRef = groupRef.collection("blockedUsers").doc(requestUid);
  const userGroupRef = firestore
    .collection("users")
    .doc(requestUid)
    .collection("groups")
    .doc(groupId);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      adminMemberDoc,
      joinRequestDoc,
      newMemberDoc,
      blockedUserDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
      transaction.get(joinRequestRef),
      transaction.get(newMemberRef),
      transaction.get(blockedUserRef),
    ]);

    if (!groupDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no existe"
      );
    }

    const groupData = groupDoc.data() || {};

    if (groupData.deleted === true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede aceptar solicitudes"
      );
    }

    if (!joinRequestDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "La solicitud ya no está disponible"
      );
    }

    if (newMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Este usuario ya pertenece al grupo"
      );
    }

    if (blockedUserDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Este usuario fue expulsado y no puede volver a entrar"
      );
    }

    const requestData = joinRequestDoc.data() || {};

    if (requestData.uid && requestData.uid !== requestUid) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "La solicitud no coincide con el usuario"
      );
    }

    if (requestData.status && requestData.status !== "pending") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "La solicitud ya no está pendiente"
      );
    }

    const memberCount = Number.isInteger(groupData.memberCount)
      ? groupData.memberCount
      : 0;
    const memberLimit = Number.isInteger(groupData.memberLimit)
      ? groupData.memberLimit
      : 30;

    if (memberCount >= memberLimit || memberCount >= 30) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        "Este grupo ya tiene el límite de miembros"
      );
    }

    const inviteCodeVersion = Number.isInteger(groupData.inviteCodeVersion)
      && groupData.inviteCodeVersion > 0
      ? groupData.inviteCodeVersion
      : 1;
    const memberName = cleanString(requestData.baseName, "Usuario");
    const memberPhotoUrl = cleanString(requestData.basePhotoUrl, null);
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.set(newMemberRef, {
      role: "member",
      joinedAt: now,
      statusThisSunday: false,
      effectiveName: memberName,
      effectivePhotoUrl: memberPhotoUrl,
      inviteCodeVersionAtJoin: inviteCodeVersion,
    });

    transaction.set(userGroupRef, {
      groupId,
      role: "member",
      joinedAt: now,
      lastViewedAt: null,
      lastActivityAt: now,
      notificationsOverride: "on",
      autoDownloadEnabled: false,
      displayNameSnapshot: cleanString(groupData.name, "Grupo"),
      groupPhotoUrlSnapshot: cleanString(groupData.photoUrl, null),
      groupEmojiSnapshot: cleanString(groupData.emoji, null),
      groupColorValueSnapshot: Number.isInteger(groupData.colorValue)
        ? groupData.colorValue
        : null,
    });

    transaction.update(groupRef, {
      memberCount: admin.firestore.FieldValue.increment(1),
      lastActivityAt: now,
    });

    transaction.delete(joinRequestRef);
  });

  return {success: true};
});

exports.rechazarSolicitud = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const requestUid = data && data.requestUid;

  if (!isValidDocumentId(groupId) || !isValidDocumentId(requestUid)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;
  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);
  const joinRequestRef = groupRef.collection("joinRequests").doc(requestUid);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      adminMemberDoc,
      joinRequestDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
      transaction.get(joinRequestRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede rechazar solicitudes"
      );
    }

    if (!joinRequestDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "La solicitud ya no está disponible"
      );
    }

    const requestData = joinRequestDoc.data() || {};

    if (requestData.uid && requestData.uid !== requestUid) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "La solicitud no coincide con el usuario"
      );
    }

    transaction.delete(joinRequestRef);
  });

  return {success: true};
});

exports.promoverAdministrador = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const targetUid = data && data.targetUid;

  if (!isValidDocumentId(groupId) || !isValidDocumentId(targetUid)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;

  if (adminUid === targetUid) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Ya eres administrador"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);
  const targetMemberRef = groupRef.collection("members").doc(targetUid);
  const targetUserGroupRef = firestore
    .collection("users")
    .doc(targetUid)
    .collection("groups")
    .doc(groupId);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      adminMemberDoc,
      targetMemberDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
      transaction.get(targetMemberRef),
    ]);

    if (!groupDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no existe"
      );
    }

    const groupData = groupDoc.data() || {};

    if (groupData.deleted === true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede hacer administrador a otro usuario"
      );
    }

    if (!targetMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "Este usuario ya no pertenece al grupo"
      );
    }

    if (targetMemberDoc.data().role === "admin") {
      throw new functions.https.HttpsError(
        "already-exists",
        "Este usuario ya es administrador"
      );
    }

    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.update(targetMemberRef, {
      role: "admin",
      promotedAt: now,
      promotedByUid: adminUid,
    });

    transaction.set(
      targetUserGroupRef,
      {role: "admin"},
      {merge: true}
    );

    transaction.update(groupRef, {
      adminsCount: admin.firestore.FieldValue.increment(1),
      lastActivityAt: now,
    });
  });

  return {success: true};
});

exports.expulsarMiembro = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const targetUid = data && data.targetUid;

  if (!isValidDocumentId(groupId) || !isValidDocumentId(targetUid)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;

  if (adminUid === targetUid) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "No puedes expulsarte a ti mismo"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);
  const targetMemberRef = groupRef.collection("members").doc(targetUid);
  const blockedUserRef = groupRef.collection("blockedUsers").doc(targetUid);
  const targetJoinRequestRef = groupRef.collection("joinRequests").doc(targetUid);
  const targetUserGroupRef = firestore
    .collection("users")
    .doc(targetUid)
    .collection("groups")
    .doc(groupId);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      adminMemberDoc,
      targetMemberDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
      transaction.get(targetMemberRef),
    ]);

    if (!groupDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no existe"
      );
    }

    const groupData = groupDoc.data() || {};

    if (groupData.deleted === true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede expulsar usuarios"
      );
    }

    if (!targetMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "Este usuario ya no pertenece al grupo"
      );
    }

    const targetMemberData = targetMemberDoc.data() || {};

    if (targetMemberData.role === "admin") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "No puedes expulsar a otro administrador"
      );
    }

    const memberCount = Number.isInteger(groupData.memberCount)
      ? groupData.memberCount
      : 1;
    const nextMemberCount = Math.max(memberCount - 1, 1);
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.set(blockedUserRef, {
      uid: targetUid,
      blockedAt: now,
      blockedByUid: adminUid,
      reason: "expelled_by_admin",
      effectiveName: cleanString(targetMemberData.effectiveName, "Usuario"),
      effectivePhotoUrl: cleanString(targetMemberData.effectivePhotoUrl, null),
    });
    transaction.delete(targetMemberRef);
    transaction.delete(targetUserGroupRef);
    transaction.delete(targetJoinRequestRef);
    transaction.update(groupRef, {
      memberCount: nextMemberCount,
      lastActivityAt: now,
    });
  });

  return {success: true};
});

exports.permitirReingreso = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const targetUid = data && data.targetUid;

  if (!isValidDocumentId(groupId) || !isValidDocumentId(targetUid)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;
  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);
  const blockedUserRef = groupRef.collection("blockedUsers").doc(targetUid);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      adminMemberDoc,
      blockedUserDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
      transaction.get(blockedUserRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede permitir el reingreso"
      );
    }

    if (!blockedUserDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "Este usuario ya puede solicitar entrada"
      );
    }

    transaction.delete(blockedUserRef);
  });

  return {success: true};
});

exports.abandonarGrupo = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;

  if (!isValidDocumentId(groupId)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const uid = context.auth.uid;
  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const memberRef = groupRef.collection("members").doc(uid);
  const userGroupRef = firestore
    .collection("users")
    .doc(uid)
    .collection("groups")
    .doc(groupId);

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      memberDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(memberRef),
    ]);

    if (!groupDoc.exists || !memberDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "Ya no perteneces a este grupo"
      );
    }

    const groupData = groupDoc.data() || {};
    const memberData = memberDoc.data() || {};

    if (groupData.deleted === true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este grupo ya no está disponible"
      );
    }

    const role = memberData.role || "member";
    const memberCount = Number.isInteger(groupData.memberCount)
      ? groupData.memberCount
      : 1;
    const adminsCount = Number.isInteger(groupData.adminsCount)
      ? groupData.adminsCount
      : 1;

    if (role === "admin" && adminsCount <= 1 && memberCount > 1) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Antes de abandonar el grupo, haz administrador a otro miembro"
      );
    }

    const nextMemberCount = Math.max(memberCount - 1, 0);
    const nextAdminsCount = role === "admin"
      ? Math.max(adminsCount - 1, 0)
      : adminsCount;
    const now = admin.firestore.FieldValue.serverTimestamp();
    const groupUpdates = {
      memberCount: nextMemberCount,
      adminsCount: nextAdminsCount,
      lastActivityAt: now,
    };

    if (nextMemberCount === 0) {
      groupUpdates.deleted = true;
      groupUpdates.deletedAt = now;
      groupUpdates.deletedReason = "empty_group";
    }

    transaction.delete(memberRef);
    transaction.delete(userGroupRef);
    transaction.update(groupRef, groupUpdates);
  });

  return {success: true};
});

exports.regenerarInvitacion = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;

  if (!isValidDocumentId(groupId)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;
  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);

  let result = null;

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      adminMemberDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
    ]);

    if (!groupDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no existe"
      );
    }

    const groupData = groupDoc.data() || {};

    if (groupData.deleted === true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede regenerar la invitación"
      );
    }

    const oldInviteCode = cleanString(groupData.inviteCode, null);
    const inviteCodeVersion = Number.isInteger(groupData.inviteCodeVersion)
      ? groupData.inviteCodeVersion + 1
      : 2;
    let inviteCode = null;
    let inviteCodeRef = null;

    for (let attempt = 0; attempt < 5; attempt += 1) {
      const candidateCode = createInviteCode();
      const candidateRef = firestore.collection("inviteCodes").doc(candidateCode);
      const candidateDoc = await transaction.get(candidateRef);

      if (!candidateDoc.exists) {
        inviteCode = candidateCode;
        inviteCodeRef = candidateRef;
        break;
      }
    }

    if (!inviteCode || !inviteCodeRef) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        "No se pudo generar una invitación nueva"
      );
    }

    const inviteLink = createInviteLink(inviteCode);
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.set(inviteCodeRef, {
      groupId,
      active: true,
      version: inviteCodeVersion,
      createdAt: now,
      createdByUid: adminUid,
      regeneratedAt: now,
      regeneratedByUid: adminUid,
    });

    if (oldInviteCode && !oldInviteCode.startsWith("TEMP-")) {
      const oldInviteCodeRef = firestore.collection("inviteCodes").doc(oldInviteCode);
      transaction.set(
        oldInviteCodeRef,
        {
          active: false,
          replacedAt: now,
          replacedByUid: adminUid,
          replacedByCode: inviteCode,
        },
        {merge: true}
      );
    }

    transaction.update(groupRef, {
      inviteCode,
      inviteLink,
      inviteCodeVersion,
      updatedAt: now,
      lastActivityAt: now,
    });

    result = {
      inviteCode,
      inviteLink,
      inviteCodeVersion,
    };
  });

  return result;
});

exports.reportarContenido = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const weekKey = data && data.weekKey;
  const postUid = data && data.postUid;
  const reason = cleanString(data && data.reason, "");

  if (
    !isValidDocumentId(groupId)
    || !isValidWeekKey(weekKey)
    || !isValidDocumentId(postUid)
    || !REPORT_REASON_VALUES.has(reason)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Reporte no válido"
    );
  }

  const reporterUid = context.auth.uid;

  if (reporterUid === postUid) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "No puedes reportar tu propia selfie"
    );
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const reporterMemberRef = groupRef.collection("members").doc(reporterUid);
  const postRef = groupRef
    .collection("weeks")
    .doc(weekKey)
    .collection("posts")
    .doc(postUid);
  const reportId = crypto
    .createHash("sha256")
    .update(`${reporterUid}\0${groupId}\0${weekKey}\0${postUid}`)
    .digest("hex");
  const reportRef = firestore.collection("reports").doc(reportId);

  let alreadyReported = false;

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      reporterMemberDoc,
      postDoc,
      reportDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(reporterMemberRef),
      transaction.get(postRef),
      transaction.get(reportRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!reporterMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "No perteneces a este grupo"
      );
    }

    if (!postDoc.exists || postDoc.data().uid !== postUid) {
      throw new functions.https.HttpsError(
        "not-found",
        "La selfie ya no está disponible"
      );
    }

    if (reportDoc.exists) {
      alreadyReported = true;
      return;
    }

    const groupData = groupDoc.data() || {};
    const postData = postDoc.data() || {};
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.create(reportRef, {
      type: "selfie",
      status: "pending",
      reason,
      reporterUid,
      reportedUid: postUid,
      groupId,
      groupNameSnapshot: cleanString(groupData.name, "Grupo"),
      weekKey,
      postPath: postRef.path,
      authorNameSnapshot: cleanString(postData.authorName, "Usuario"),
      storagePathFull: cleanString(postData.storagePathFull, null),
      storagePathThumb: cleanString(postData.storagePathThumb, null),
      createdAt: now,
      updatedAt: now,
    });
  });

  return {
    success: true,
    alreadyReported,
  };
});

function timestampToMillis(value) {
  if (value && typeof value.toMillis === "function") {
    return value.toMillis();
  }

  if (value instanceof Date) {
    return value.getTime();
  }

  return null;
}

function buildModerationReportResponse(reportDoc, postDoc) {
  const reportData = reportDoc.data() || {};
  const postExists = Boolean(postDoc && postDoc.exists);
  const postData = postExists ? postDoc.data() || {} : {};
  const imageUrl = cleanString(
    postData.imageUrl,
    cleanString(postData.thumbUrl, "")
  );

  return {
    reportId: reportDoc.id,
    groupId: cleanString(reportData.groupId, ""),
    weekKey: cleanString(reportData.weekKey, ""),
    postUid: cleanString(reportData.reportedUid, ""),
    reason: cleanString(reportData.reason, "otro"),
    status: cleanString(reportData.status, "pending"),
    authorName: cleanString(
      reportData.authorNameSnapshot,
      cleanString(postData.authorName, "Usuario")
    ),
    authorPhotoUrl: cleanString(postData.authorPhotoUrl, null),
    imageUrl,
    thumbUrl: cleanString(postData.thumbUrl, imageUrl),
    postExists,
    createdAtMillis: timestampToMillis(reportData.createdAt),
    resolvedAtMillis: timestampToMillis(reportData.resolvedAt),
    decision: cleanString(reportData.decision, null),
  };
}

async function loadPostDocForReport(firestore, reportData) {
  const postPath = cleanString(reportData.postPath, "");
  const groupId = cleanString(reportData.groupId, "");

  if (isValidDocumentId(groupId) && postPath.startsWith(`groups/${groupId}/weeks/`)) {
    return firestore.doc(postPath).get();
  }

  const weekKey = cleanString(reportData.weekKey, "");
  const postUid = cleanString(reportData.reportedUid, "");

  if (
    !isValidDocumentId(groupId)
    || !isValidWeekKey(weekKey)
    || !isValidDocumentId(postUid)
  ) {
    return null;
  }

  return firestore
    .collection("groups")
    .doc(groupId)
    .collection("weeks")
    .doc(weekKey)
    .collection("posts")
    .doc(postUid)
    .get();
}

exports.listarReportesGrupo = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;

  if (!isValidDocumentId(groupId)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const adminUid = context.auth.uid;
  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const adminMemberRef = groupRef.collection("members").doc(adminUid);
  const [groupDoc, adminMemberDoc] = await Promise.all([
    groupRef.get(),
    adminMemberRef.get(),
  ]);

  if (!groupDoc.exists || groupDoc.data().deleted === true) {
    throw new functions.https.HttpsError(
      "not-found",
      "El grupo ya no está disponible"
    );
  }

  if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Solo un administrador puede revisar reportes"
    );
  }

  const reportsSnapshot = await firestore
    .collection("reports")
    .where("groupId", "==", groupId)
    .get();

  const pendingReports = reportsSnapshot.docs
    .filter((doc) => {
      const reportData = doc.data() || {};
      return cleanString(reportData.status, "pending") === "pending";
    })
    .sort((a, b) => {
      const bMillis = timestampToMillis(b.data().createdAt) || 0;
      const aMillis = timestampToMillis(a.data().createdAt) || 0;

      return bMillis - aMillis;
    })
    .slice(0, 50);

  const reports = [];

  for (const reportDoc of pendingReports) {
    const postDoc = await loadPostDocForReport(firestore, reportDoc.data() || {});
    reports.push(buildModerationReportResponse(reportDoc, postDoc));
  }

  return {reports};
});

async function resolveLinkedReports({
  decision,
  firestore,
  groupId,
  moderatorUid,
  reportId,
  weekKey,
  postUid,
}) {
  const reportsSnapshot = await firestore
    .collection("reports")
    .where("groupId", "==", groupId)
    .get();
  const now = admin.firestore.FieldValue.serverTimestamp();
  const linkedReports = reportsSnapshot.docs.filter((doc) => {
    const data = doc.data() || {};

    return doc.id !== reportId
      && cleanString(data.status, "pending") === "pending"
      && cleanString(data.weekKey, "") === weekKey
      && cleanString(data.reportedUid, "") === postUid;
  });

  for (let index = 0; index < linkedReports.length; index += 400) {
    const batch = firestore.batch();

    linkedReports.slice(index, index + 400).forEach((doc) => {
      batch.update(doc.ref, {
        status: decision === "remove_selfie" ? "removed" : "dismissed",
        decision,
        resolvedAt: now,
        resolvedByUid: moderatorUid,
        updatedAt: now,
      });
    });

    await batch.commit();
  }
}

exports.resolverReporte = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const reportId = data && data.reportId;
  const decision = cleanString(data && data.decision, "");

  if (
    !isValidDocumentId(reportId)
    || !MODERATION_DECISION_VALUES.has(decision)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Decisión de moderación no válida"
    );
  }

  const moderatorUid = context.auth.uid;
  const firestore = admin.firestore();
  const bucket = admin.storage().bucket();
  const reportRef = firestore.collection("reports").doc(reportId);
  let result = null;
  let postRefToDelete = null;
  let storagePathsToDelete = [];

  await firestore.runTransaction(async (transaction) => {
    const reportDoc = await transaction.get(reportRef);

    if (!reportDoc.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "El reporte ya no existe"
      );
    }

    const reportData = reportDoc.data() || {};
    const groupId = cleanString(reportData.groupId, "");
    const weekKey = cleanString(reportData.weekKey, "");
    const postUid = cleanString(reportData.reportedUid, "");

    if (
      reportData.type !== "selfie"
      || !isValidDocumentId(groupId)
      || !isValidWeekKey(weekKey)
      || !isValidDocumentId(postUid)
    ) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "El reporte no tiene datos válidos"
      );
    }

    const groupRef = firestore.collection("groups").doc(groupId);
    const adminMemberRef = groupRef.collection("members").doc(moderatorUid);
    const weekRef = groupRef.collection("weeks").doc(weekKey);
    const postRef = weekRef.collection("posts").doc(postUid);
    const postsRef = weekRef.collection("posts");
    const [
      groupDoc,
      adminMemberDoc,
      weekDoc,
      postDoc,
      postsSnapshot,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(adminMemberRef),
      transaction.get(weekRef),
      transaction.get(postRef),
      transaction.get(postsRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!adminMemberDoc.exists || adminMemberDoc.data().role !== "admin") {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo un administrador puede resolver reportes"
      );
    }

    if (cleanString(reportData.status, "pending") !== "pending") {
      result = {
        success: true,
        alreadyResolved: true,
        decision: cleanString(reportData.decision, null),
        groupId,
        weekKey,
        postUid,
      };
      return;
    }

    const now = admin.firestore.FieldValue.serverTimestamp();
    const reportUpdate = {
      status: decision === "remove_selfie" ? "removed" : "dismissed",
      decision,
      resolvedAt: now,
      resolvedByUid: moderatorUid,
      updatedAt: now,
    };

    if (decision === "remove_selfie") {
      const postData = postDoc.exists ? postDoc.data() || {} : {};
      const weekData = weekDoc.exists ? weekDoc.data() || {} : {};
      const currentPostCount = Number.isInteger(weekData.postCount)
        ? weekData.postCount
        : postsSnapshot.size;
      const storagePath = `groups/${groupId}/weeks/${weekKey}/${postUid}.jpg`;

      storagePathsToDelete = [
        storagePath,
        postData.storagePathFull,
        postData.storagePathThumb,
        reportData.storagePathFull,
        reportData.storagePathThumb,
      ];

      if (postDoc.exists) {
        transaction.delete(postRef);
        transaction.set(
          weekRef,
          {
            postCount: Math.max(currentPostCount - 1, 0),
          },
          {merge: true}
        );
        transaction.update(groupRef, {lastActivityAt: now});
        postRefToDelete = postRef;
      }

      reportUpdate.postRemovedAt = now;
      reportUpdate.postAlreadyMissing = !postDoc.exists;
    }

    transaction.update(reportRef, reportUpdate);

    result = {
      success: true,
      alreadyResolved: false,
      decision,
      groupId,
      weekKey,
      postUid,
      removedPost: decision === "remove_selfie",
    };
  });

  if (!result) {
    throw new functions.https.HttpsError(
      "internal",
      "No se pudo resolver el reporte"
    );
  }

  if (!result.alreadyResolved) {
    await resolveLinkedReports({
      decision,
      firestore,
      groupId: result.groupId,
      moderatorUid,
      reportId,
      weekKey: result.weekKey,
      postUid: result.postUid,
    });
  }

  if (postRefToDelete) {
    try {
      await firestore.recursiveDelete(postRefToDelete);
    } catch (error) {
      logger.warn("No se pudieron borrar subdatos de la selfie moderada", {
        reportId,
        postPath: postRefToDelete.path,
        error,
      });
    }
  }

  if (storagePathsToDelete.length > 0) {
    try {
      await deleteStoragePaths(bucket, storagePathsToDelete);
    } catch (error) {
      logger.warn("No se pudieron borrar archivos de la selfie moderada", {
        reportId,
        storagePathsToDelete,
        error,
      });
    }
  }

  return result;
});

async function deleteDocumentReferences(firestore, references) {
  const uniqueReferences = Array.from(
    new Map(references.map((reference) => [reference.path, reference])).values()
  );

  for (let index = 0; index < uniqueReferences.length; index += 400) {
    const batch = firestore.batch();

    uniqueReferences.slice(index, index + 400).forEach((reference) => {
      batch.delete(reference);
    });

    await batch.commit();
  }
}

async function deleteStoragePaths(bucket, paths) {
  const uniquePaths = new Set(
    paths.filter((path) => typeof path === "string" && path.trim().length > 0)
  );

  for (const path of uniquePaths) {
    try {
      await bucket.file(path).delete({ignoreNotFound: true});
    } catch (error) {
      if (error && error.code === 404) continue;
      throw error;
    }
  }
}

async function deleteUserContentFromGroup(firestore, bucket, groupId, uid) {
  const groupRef = firestore.collection("groups").doc(groupId);
  const weeksSnapshot = await groupRef.collection("weeks").get();

  for (const weekDoc of weeksSnapshot.docs) {
    const weekRef = weekDoc.ref;
    const postsSnapshot = await weekRef.collection("posts").get();
    const [
      chatMessagesSnapshot,
      sentRemindersSnapshot,
      receivedRemindersSnapshot,
    ] = await Promise.all([
      weekRef.collection("chatMessages").where("uid", "==", uid).get(),
      weekRef.collection("reminders").where("senderUid", "==", uid).get(),
      weekRef.collection("reminders").where("targetUid", "==", uid).get(),
    ]);
    const reactionRefs = postsSnapshot.docs.map((postDoc) => {
      return postDoc.ref.collection("reactions").doc(uid);
    });

    await deleteDocumentReferences(firestore, [
      ...chatMessagesSnapshot.docs.map((doc) => doc.ref),
      ...sentRemindersSnapshot.docs.map((doc) => doc.ref),
      ...receivedRemindersSnapshot.docs.map((doc) => doc.ref),
      ...reactionRefs,
    ]);

    const postRef = weekRef.collection("posts").doc(uid);
    const postDoc = await postRef.get();
    const postData = postDoc.data() || {};
    const storagePaths = [
      `groups/${groupId}/weeks/${weekDoc.id}/${uid}.jpg`,
      postData.storagePathFull,
      postData.storagePathThumb,
    ];

    if (postDoc.exists) {
      await firestore.runTransaction(async (transaction) => {
        const [currentPostDoc, currentWeekDoc] = await Promise.all([
          transaction.get(postRef),
          transaction.get(weekRef),
        ]);

        if (!currentPostDoc.exists) return;

        const weekData = currentWeekDoc.data() || {};
        const currentPostCount = Number.isInteger(weekData.postCount)
          ? weekData.postCount
          : postsSnapshot.size;

        transaction.delete(postRef);
        transaction.set(
          weekRef,
          {postCount: Math.max(currentPostCount - 1, 0)},
          {merge: true}
        );
      });

      await firestore.recursiveDelete(postRef);
    }

    await deleteStoragePaths(bucket, storagePaths);
  }
}

async function removeDeletedUserFromGroup(firestore, groupId, uid) {
  const groupRef = firestore.collection("groups").doc(groupId);
  const memberRef = groupRef.collection("members").doc(uid);
  const userGroupRef = firestore
    .collection("users")
    .doc(uid)
    .collection("groups")
    .doc(groupId);
  const joinRequestRef = groupRef.collection("joinRequests").doc(uid);
  const blockedUserRef = groupRef.collection("blockedUsers").doc(uid);

  await firestore.runTransaction(async (transaction) => {
    const [groupDoc, memberDoc, membersSnapshot] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(memberRef),
      transaction.get(groupRef.collection("members")),
    ]);

    transaction.delete(userGroupRef);
    transaction.delete(joinRequestRef);
    transaction.delete(blockedUserRef);

    if (!groupDoc.exists || !memberDoc.exists) {
      transaction.delete(memberRef);
      return;
    }

    const groupData = groupDoc.data() || {};
    const memberData = memberDoc.data() || {};
    const remainingMembers = membersSnapshot.docs.filter((doc) => doc.id !== uid);
    let remainingAdmins = remainingMembers.filter((doc) => {
      return doc.data().role === "admin";
    });
    const now = admin.firestore.FieldValue.serverTimestamp();

    if (
      memberData.role === "admin"
      && remainingMembers.length > 0
      && remainingAdmins.length === 0
    ) {
      const promotedMember = remainingMembers[0];
      const promotedUserGroupRef = firestore
        .collection("users")
        .doc(promotedMember.id)
        .collection("groups")
        .doc(groupId);

      transaction.set(
        promotedMember.ref,
        {
          role: "admin",
          promotedAt: now,
          promotedByUid: "account_deletion",
        },
        {merge: true}
      );
      transaction.set(
        promotedUserGroupRef,
        {role: "admin"},
        {merge: true}
      );
      remainingAdmins = [promotedMember];
    }

    const groupUpdates = {
      memberCount: remainingMembers.length,
      adminsCount: remainingAdmins.length,
      lastActivityAt: now,
    };

    if (groupData.createdByUid === uid) {
      groupUpdates.createdByUid = null;
    }

    remainingMembers
      .filter((document) => document.data().promotedByUid === uid)
      .forEach((document) => {
        transaction.set(
          document.ref,
          {promotedByUid: "deleted_user"},
          {merge: true}
        );
      });

    if (remainingMembers.length === 0) {
      groupUpdates.deleted = true;
      groupUpdates.deletedAt = now;
      groupUpdates.deletedReason = "empty_after_account_deletion";
    } else if (groupData.deleted !== true) {
      groupUpdates.deleted = false;
    }

    transaction.delete(memberRef);
    transaction.update(groupRef, groupUpdates);
  });
}

async function listGroupIdsForAccountDeletion(firestore, knownGroupIds) {
  const groupIds = new Set(knownGroupIds);
  const groupsSnapshot = await firestore.collection("groups").select().get();

  groupsSnapshot.docs.forEach((groupDoc) => groupIds.add(groupDoc.id));

  return Array.from(groupIds);
}

exports.borrarCuenta = callable({
  timeoutSeconds: 540,
  memory: "512MiB",
}, async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  if (cleanString(data && data.confirmation, "") !== ACCOUNT_DELETE_CONFIRMATION) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Escribe BORRAR para confirmar"
    );
  }

  const authTime = Number(context.auth.token && context.auth.token.auth_time);
  const authAgeSeconds = Math.floor(Date.now() / 1000) - authTime;

  if (
    !Number.isFinite(authTime)
    || authAgeSeconds < 0
    || authAgeSeconds > RECENT_AUTH_MAX_AGE_SECONDS
  ) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Por seguridad, cierra sesión, vuelve a entrar y repite el borrado"
    );
  }

  const uid = context.auth.uid;
  const firestore = admin.firestore();
  const bucket = admin.storage().bucket();
  const userRef = firestore.collection("users").doc(uid);
  let groupIds = [];

  try {
    const userGroupsSnapshot = await userRef.collection("groups").get();
    const knownGroupIds = Array.from(new Set(
      userGroupsSnapshot.docs
        .map((doc) => cleanString(doc.data().groupId, doc.id))
        .filter(isValidDocumentId)
    ));
    groupIds = await listGroupIdsForAccountDeletion(firestore, knownGroupIds);

    for (const groupId of groupIds) {
      await deleteUserContentFromGroup(firestore, bucket, groupId, uid);
      await removeDeletedUserFromGroup(firestore, groupId, uid);
    }

    await bucket.deleteFiles({prefix: `users/${uid}/`});
    await firestore.recursiveDelete(userRef);
    await admin.auth().deleteUser(uid);
  } catch (error) {
    logger.error("No se pudo completar el borrado de cuenta", {
      uid,
      groupIds,
      error,
    });
    throw new functions.https.HttpsError(
      "internal",
      "No se pudo completar el borrado. Tu cuenta sigue activa; inténtalo de nuevo"
    );
  }

  logger.info("Cuenta borrada correctamente", {
    uid,
    groupsProcessed: groupIds.length,
  });

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
  return notificationTypeEnabledForUser(userData, "sundayTimeEnabled");
}

function notificationTypeEnabledForUser(userData, settingKey) {
  const settings = userData && userData.notificationSettings
    ? userData.notificationSettings
    : {};

  if (settings.globalEnabled === false) return false;
  if (settings[settingKey] === false) return false;

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

async function loadUserNotificationTokens(userId, groupId, settingKey) {
  const firestore = admin.firestore();
  const userRef = firestore.collection("users").doc(userId);

  const [
    userDoc,
    userGroupDoc,
    tokensSnapshot,
  ] = await Promise.all([
    userRef.get(),
    userRef.collection("groups").doc(groupId).get(),
    userRef.collection("notificationTokens").where("enabled", "==", true).get(),
  ]);

  if (!userDoc.exists) return [];

  if (!notificationTypeEnabledForUser(userDoc.data(), settingKey)) {
    return [];
  }

  if (
    userGroupDoc.exists
    && userGroupDoc.data().notificationsOverride === "off"
  ) {
    return [];
  }

  const tokensByValue = new Map();

  tokensSnapshot.docs.forEach((tokenDoc) => {
    const tokenData = tokenDoc.data() || {};
    const token = typeof tokenData.token === "string"
      ? tokenData.token.trim()
      : "";

    if (!token || tokensByValue.has(token)) return;

    tokensByValue.set(token, {
      token,
      ref: tokenDoc.ref,
      uid: userId,
      platform: tokenData.platform || "unknown",
    });
  });

  return Array.from(tokensByValue.values());
}

async function sendFriendReminderNotification({
  groupId,
  groupName,
  weekKey,
  senderUid,
  senderName,
  targetUid,
}) {
  const entries = await loadUserNotificationTokens(
    targetUid,
    groupId,
    "friendRemindersEnabled"
  );

  if (entries.length === 0) {
    logger.info("Zumbido sin destinatarios activos", {
      groupId,
      weekKey,
      senderUid,
      targetUid,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  let successCount = 0;
  let failureCount = 0;

  for (const batch of chunkArray(entries, MAX_TOKENS_PER_MULTICAST)) {
    const response = await admin.messaging().sendEachForMulticast({
      tokens: batch.map((entry) => entry.token),
      notification: {
        title: groupName,
        body: `${senderName} te ha enviado un zumbido para subir tu selfie`,
      },
      data: {
        type: "friend_reminder",
        target: "group",
        groupId,
        weekKey,
        senderUid,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
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

      logger.warn("Error enviando notificación de zumbido", {
        groupId,
        weekKey,
        senderUid,
        targetUid,
        errorCode,
        tokenIndex: index,
      });

      if (invalidTokenCodes.has(errorCode)) {
        disablePromises.push(disableInvalidToken(batch[index], errorCode));
      }
    });

    await Promise.all(disablePromises);
  }

  logger.info("Notificación de zumbido procesada", {
    groupId,
    weekKey,
    senderUid,
    targetUid,
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

async function sendReactionNotification({
  groupId,
  groupName,
  weekKey,
  postUid,
  reactorUid,
  reactorName,
  emoji,
}) {
  const entries = await loadUserNotificationTokens(
    postUid,
    groupId,
    "reactionsEnabled"
  );

  if (entries.length === 0) {
    logger.info("Reacción sin destinatarios activos", {
      groupId,
      weekKey,
      postUid,
      reactorUid,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  let successCount = 0;
  let failureCount = 0;

  for (const batch of chunkArray(entries, MAX_TOKENS_PER_MULTICAST)) {
    const response = await admin.messaging().sendEachForMulticast({
      tokens: batch.map((entry) => entry.token),
      notification: {
        title: groupName,
        body: `${reactorName} ha reaccionado ${emoji} a tu Sunday Selfie`,
      },
      data: {
        type: "reaction",
        target: "group",
        groupId,
        weekKey,
        postUid,
        reactorUid,
        emoji,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
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

      logger.warn("Error enviando notificación de reacción", {
        groupId,
        weekKey,
        postUid,
        reactorUid,
        errorCode,
        tokenIndex: index,
      });

      if (invalidTokenCodes.has(errorCode)) {
        disablePromises.push(disableInvalidToken(batch[index], errorCode));
      }
    });

    await Promise.all(disablePromises);
  }

  logger.info("Notificación de reacción procesada", {
    groupId,
    weekKey,
    postUid,
    reactorUid,
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
