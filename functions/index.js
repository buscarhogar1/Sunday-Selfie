const functions = require("firebase-functions");
const {setGlobalOptions} = require("firebase-functions/v2");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {defineSecret} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const {getDownloadURL} = require("firebase-admin/storage");
const crypto = require("crypto");

setGlobalOptions({
  cpu: "gcf_gen1",
  memory: "256MiB",
  maxInstances: 5,
});

admin.initializeApp();

const CALLABLE_DEFAULT_OPTIONS = {
  enforceAppCheck: true,
};

function callable(optionsOrHandler, maybeHandler) {
  const hasOptions = typeof optionsOrHandler !== "function";
  const options = hasOptions ? optionsOrHandler : {};
  const handler = hasOptions ? maybeHandler : optionsOrHandler;
  const callableOptions = {
    ...CALLABLE_DEFAULT_OPTIONS,
    ...options,
  };

  return functions.https.onCall(callableOptions, async (request) => {
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

function truncateString(value, maxLength) {
  if (typeof value !== "string") return "";

  const clean = value.trim();
  return clean.length > maxLength ? clean.slice(0, maxLength) : clean;
}

function cleanOptionalEmail(value) {
  if (typeof value !== "string") return null;

  const clean = value.trim();
  if (clean.length === 0 || clean.length > 320) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(clean)) return null;
  return clean;
}

function configuredSuggestionRecipientEmail() {
  const defaultProjectEmail = "sundayselfie2026@gmail.com";
  const envEmail = cleanOptionalEmail(
    process.env.SUNDAY_SELFIE_CEO_EMAIL || process.env.SUGGESTIONS_TO_EMAIL
  );
  if (envEmail) return envEmail;

  let firebaseConfig = {};
  try {
    firebaseConfig = functions.config ? functions.config() : {};
  } catch (_) {
    firebaseConfig = {};
  }
  const candidates = [
    firebaseConfig
      && firebaseConfig.sunday_selfie
      && firebaseConfig.sunday_selfie.ceo_email,
    firebaseConfig && firebaseConfig.sunday && firebaseConfig.sunday.ceo_email,
    firebaseConfig
      && firebaseConfig.suggestions
      && firebaseConfig.suggestions.to_email,
    firebaseConfig && firebaseConfig.email && firebaseConfig.email.suggestions_to,
  ];

  for (const candidate of candidates) {
    const clean = cleanOptionalEmail(candidate);
    if (clean) return clean;
  }

  return defaultProjectEmail;
}

function configuredSuggestionSenderEmail() {
  const defaultProjectEmail = "sundayselfie2026@gmail.com";
  const envEmail = cleanOptionalEmail(
    process.env.SUNDAY_SELFIE_FROM_EMAIL || process.env.SUGGESTIONS_FROM_EMAIL
  );
  if (envEmail) return envEmail;

  let firebaseConfig = {};
  try {
    firebaseConfig = functions.config ? functions.config() : {};
  } catch (_) {
    firebaseConfig = {};
  }
  const candidates = [
    firebaseConfig
      && firebaseConfig.sunday_selfie
      && firebaseConfig.sunday_selfie.from_email,
    firebaseConfig && firebaseConfig.sunday && firebaseConfig.sunday.from_email,
    firebaseConfig
      && firebaseConfig.suggestions
      && firebaseConfig.suggestions.from_email,
    firebaseConfig && firebaseConfig.email && firebaseConfig.email.suggestions_from,
  ];

  for (const candidate of candidates) {
    const clean = cleanOptionalEmail(candidate);
    if (clean) return clean;
  }

  return defaultProjectEmail;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function isUserProfileStoragePathForUid(uid, storagePath) {
  if (typeof storagePath !== "string") return false;

  const prefix = `users/${uid}/profile/base_`;
  if (!storagePath.startsWith(prefix)) return false;

  const fileName = storagePath.slice(prefix.length);
  return /^[0-9]+\.jpg$/.test(fileName);
}

async function deleteStoragePathCompletely(bucket, storagePath) {
  const file = bucket.file(storagePath);

  await file.delete({ignoreNotFound: true});

  const [exists] = await file.exists();
  if (exists) {
    throw new Error(`Storage object still exists after delete: ${storagePath}`);
  }
}

async function deleteStoragePathsCompletely(bucket, paths) {
  const uniquePaths = new Set(
    paths.filter((path) => typeof path === "string" && path.trim().length > 0)
  );

  for (const path of uniquePaths) {
    await deleteStoragePathCompletely(bucket, path);
  }
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

function cleanInviteCode(value) {
  return cleanString(value, "").toUpperCase();
}

function isValidInviteCode(value) {
  return typeof value === "string" && /^[A-Z2-9]{10}$/.test(value);
}

function isValidInviteCodeForGroup(inviteCode, groupId) {
  return isValidInviteCode(inviteCode) || inviteCode === `TEMP-${groupId}`;
}

function madridDateParts(date = new Date()) {
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

  return values;
}

function formatUtcDayKey(date) {
  return [
    date.getUTCFullYear(),
    String(date.getUTCMonth() + 1).padStart(2, "0"),
    String(date.getUTCDate()).padStart(2, "0"),
  ].join("-");
}

function dayKeyOrder(dayKey) {
  if (typeof dayKey !== "string") return null;

  const match = dayKey.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;

  return Number(`${match[1]}${match[2]}${match[3]}`);
}

function timestampToDate(value) {
  if (value instanceof Date) return value;
  if (value && typeof value.toDate === "function") return value.toDate();
  return null;
}

function memberJoinedByMadridDay(memberData, dayKey) {
  const joinedAt = timestampToDate(memberData && memberData.joinedAt);
  if (joinedAt === null) return false;

  const joinedDayOrder = dayKeyOrder(currentMadridDayKey(joinedAt));
  const latestAllowedOrder = dayKeyOrder(dayKey);

  return joinedDayOrder !== null
    && latestAllowedOrder !== null
    && joinedDayOrder <= latestAllowedOrder;
}

function currentMadridWeekInfo(date = new Date()) {
  const values = madridDateParts(date);
  const madridDate = new Date(Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day)
  ));
  const {isoYear, isoWeek} = currentIsoWeekParts(madridDate);
  const previousSundayDate = new Date(
    madridDate.getTime() - 24 * 60 * 60 * 1000
  );

  return {
    isSunday: values.weekday === "Sun",
    isMonday: values.weekday === "Mon",
    isoYear,
    isoWeek,
    weekKey: `${isoYear}-W${String(isoWeek).padStart(2, "0")}`,
    previousWeekKey: previousWeekKey(madridDate),
    previousSundayDayKey: formatUtcDayKey(previousSundayDate),
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
const reactionEmojiSegmenter = new Intl.Segmenter("es", {
  granularity: "grapheme",
});
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
const JOIN_REQUESTS_PER_DAY_LIMIT = 5;
const REPORTS_PER_DAY_LIMIT = 10;
const REACTION_COOLDOWN_SECONDS = 5;

function isEmojiBaseCodePoint(value) {
  return value === 0x00A9
    || value === 0x00AE
    || value === 0x203C
    || value === 0x2049
    || value === 0x2122
    || value === 0x2139
    || value === 0x3030
    || value === 0x303D
    || value === 0x3297
    || value === 0x3299
    || (value >= 0x1F000 && value <= 0x1FAFF)
    || (value >= 0x2194 && value <= 0x21AA)
    || (value >= 0x231A && value <= 0x231B)
    || value === 0x2328
    || value === 0x23CF
    || (value >= 0x23E9 && value <= 0x23F3)
    || (value >= 0x23F8 && value <= 0x23FA)
    || value === 0x24C2
    || (value >= 0x25AA && value <= 0x25AB)
    || value === 0x25B6
    || value === 0x25C0
    || (value >= 0x25FB && value <= 0x25FE)
    || (value >= 0x2600 && value <= 0x27BF)
    || (value >= 0x2934 && value <= 0x2935)
    || (value >= 0x2B05 && value <= 0x2B55);
}

function isEmojiSequenceCodePoint(value) {
  return isEmojiBaseCodePoint(value)
    || value === 0x200D
    || value === 0x20E3
    || value === 0xFE0E
    || value === 0xFE0F
    || (value >= 0x0030 && value <= 0x0039)
    || (value >= 0xE0020 && value <= 0xE007F)
    || value === 0x0023
    || value === 0x002A;
}

function isKeycapEmojiSequence(codePoints) {
  if (codePoints.length < 2 || !codePoints.includes(0x20E3)) return false;

  const first = codePoints[0];
  const validFirst = (first >= 0x0030 && first <= 0x0039)
    || first === 0x0023
    || first === 0x002A;

  return validFirst
    && codePoints.every((value) => {
      return value === first || value === 0xFE0F || value === 0x20E3;
    });
}

function isReactionEmoji(value) {
  if (typeof value !== "string") return false;

  const emoji = value.trim();
  if (!emoji || emoji.length > 32) return false;

  const segments = Array.from(
    reactionEmojiSegmenter.segment(emoji),
    (segment) => segment.segment
  );
  if (segments.length !== 1 || segments[0] !== emoji) return false;

  const codePoints = Array.from(emoji, (character) => {
    return character.codePointAt(0);
  });
  const hasEmojiBase = codePoints.some(isEmojiBaseCodePoint);
  const isKeycap = isKeycapEmojiSequence(codePoints);

  return (hasEmojiBase || isKeycap)
    && codePoints.every(isEmojiSequenceCodePoint);
}

function currentMadridDayKey(date = new Date()) {
  const values = {};
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Madrid",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });

  formatter.formatToParts(date).forEach((part) => {
    values[part.type] = part.value;
  });

  return `${values.year}-${values.month}-${values.day}`;
}

function userRateLimitRef(firestore, uid, bucket, key) {
  return firestore
    .collection("users")
    .doc(uid)
    .collection("rateLimits")
    .doc(`${bucket}_${key}`);
}

function readRateLimitCount(rateLimitDoc) {
  const count = rateLimitDoc.exists ? rateLimitDoc.data().count : 0;
  return Number.isInteger(count) && count > 0 ? count : 0;
}

function assertRateLimitAvailable(rateLimitDoc, limit, message) {
  if (readRateLimitCount(rateLimitDoc) >= limit) {
    throw new functions.https.HttpsError("resource-exhausted", message);
  }
}

function writeRateLimitIncrement(transaction, rateLimitRef, rateLimitDoc, data) {
  transaction.set(
    rateLimitRef,
    {
      ...data,
      count: readRateLimitCount(rateLimitDoc) + 1,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    {merge: true}
  );
}

const GIPHY_DEFAULT_LIMIT = 24;
const GIPHY_MAX_LIMIT = 36;
const GIPHY_MAX_QUERY_LENGTH = 50;
const GIPHY_MAX_OFFSET = 4999;
const GIPHY_SEARCHES_PER_HOUR_LIMIT = 100;
const GIPHY_API_KEY_SECRET = defineSecret("GIPHY_API_KEY");

function configuredGiphyApiKey() {
  const envKey = GIPHY_API_KEY_SECRET.value()
    || process.env.GIPHY_API_KEY
    || process.env.SUNDAY_GIPHY_API_KEY;
  if (typeof envKey === "string" && envKey.trim().length > 0) {
    return envKey.trim();
  }

  let firebaseConfig = {};
  try {
    firebaseConfig = functions.config ? functions.config() : {};
  } catch (_) {
    firebaseConfig = {};
  }
  const configKey = firebaseConfig
    && firebaseConfig.giphy
    && firebaseConfig.giphy.key;
  return typeof configKey === "string" && configKey.trim().length > 0
    ? configKey.trim()
    : null;
}

function cleanGifString(value, maxLength) {
  if (typeof value !== "string") return "";
  return value.trim().slice(0, maxLength);
}

function isValidGiphyMediaUrl(value) {
  if (typeof value !== "string") return false;

  let uri;
  try {
    uri = new URL(value);
  } catch (_) {
    return false;
  }

  return uri.protocol === "https:"
    && /^media\d*\.giphy\.com$/.test(uri.hostname)
    && uri.pathname.length > 1;
}

function giphyMediaUrl(images) {
  if (!images || typeof images !== "object") return null;

  for (const format of [
    "fixed_width_downsampled",
    "fixed_width",
    "fixed_height_downsampled",
    "fixed_height",
    "downsized",
    "original",
  ]) {
    const image = images[format];
    const url = image && typeof image.url === "string" ? image.url.trim() : "";
    if (url && isValidGiphyMediaUrl(url)) return url;
  }

  return null;
}

function giphyGifFromResponse(responseObject) {
  if (!responseObject || typeof responseObject !== "object") return null;

  const url = giphyMediaUrl(responseObject.images);
  if (!url) return null;

  const title = cleanGifString(responseObject.title, 80);
  const slug = cleanGifString(responseObject.slug, 120);
  const keywords = `${title} ${slug}`
    .split(/[\s_-]+/)
    .map((keyword) => keyword.trim().toLowerCase())
    .filter(Boolean)
    .slice(0, 8);
  const label = title || keywords[0] || "GIF";

  return {
    id: cleanGifString(responseObject.id, 80),
    label,
    url,
    keywords,
  };
}

function cleanGiphyOffset(value) {
  const clean = cleanGifString(value, 8);
  if (clean.length === 0) return 0;
  if (!/^\d+$/.test(clean)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "La paginación de GIFs no es válida"
    );
  }

  return Math.min(Number(clean), GIPHY_MAX_OFFSET);
}

function nextGiphyOffset(pagination) {
  if (!pagination || typeof pagination !== "object") return "";

  const offset = Number(pagination.offset);
  const count = Number(pagination.count);
  const totalCount = Number(pagination.total_count);
  if (!Number.isFinite(offset) || !Number.isFinite(count) || count <= 0) {
    return "";
  }

  const next = offset + count;
  if (Number.isFinite(totalCount) && next >= totalCount) return "";
  if (next > GIPHY_MAX_OFFSET) return "";

  return String(next);
}

async function fetchGiphyGifs({apiKey, query, offset, limit}) {
  const endpoint = "/v1/gifs/search";
  const params = new URLSearchParams({
    api_key: apiKey,
    q: query || "reacciones",
    limit: String(limit),
    offset: String(offset),
    rating: "pg-13",
    lang: "es",
    bundle: "messaging_non_clips",
    country_code: "ES",
  });

  const url = `https://api.giphy.com${endpoint}?${params.toString()}`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);

  try {
    const response = await fetch(url, {signal: controller.signal});
    if (response.status !== 200) {
      logger.warn("GIPHY respondió con estado no exitoso", {
        status: response.status,
      });
      throw new functions.https.HttpsError(
        "unavailable",
        "No se pudo cargar la biblioteca de GIFs"
      );
    }

    const payload = await response.json();
    const rawResults = Array.isArray(payload.data) ? payload.data : [];
    const seenUrls = new Set();
    const gifs = rawResults
      .map(giphyGifFromResponse)
      .filter((gif) => gif && !seenUrls.has(gif.url) && seenUrls.add(gif.url));

    return {
      gifs,
      next: nextGiphyOffset(payload.pagination),
      source: "giphy",
    };
  } catch (error) {
    if (error instanceof functions.https.HttpsError) throw error;

    logger.error("Error consultando GIPHY", {message: error.message});
    throw new functions.https.HttpsError(
      "unavailable",
      "No se pudo cargar la biblioteca de GIFs"
    );
  } finally {
    clearTimeout(timeout);
  }
}
const RECENT_AUTH_MAX_AGE_SECONDS = 15 * 60;

function formatUtcHourKey(date) {
  return [
    date.getUTCFullYear(),
    String(date.getUTCMonth() + 1).padStart(2, "0"),
    String(date.getUTCDate()).padStart(2, "0"),
    String(date.getUTCHours()).padStart(2, "0"),
  ].join("-");
}

async function assertGiphySearchRateLimit(firestore, uid) {
  const hourKey = formatUtcHourKey(new Date());
  const rateLimitRef = userRateLimitRef(
    firestore,
    uid,
    "giphyGifSearches",
    hourKey
  );

  await firestore.runTransaction(async (transaction) => {
    const rateLimitDoc = await transaction.get(rateLimitRef);
    assertRateLimitAvailable(
      rateLimitDoc,
      GIPHY_SEARCHES_PER_HOUR_LIMIT,
      "Has buscado muchos GIFs en poco tiempo. Prueba otra vez en unos minutos"
    );
    writeRateLimitIncrement(transaction, rateLimitRef, rateLimitDoc, {
      bucket: "giphyGifSearches",
      hourKey,
      limit: GIPHY_SEARCHES_PER_HOUR_LIMIT,
    });
  });
}

exports.buscarGifsTenor = callable(
  {enforceAppCheck: false, secrets: [GIPHY_API_KEY_SECRET]},
  async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Usuario no autenticado"
      );
    }

    const query = cleanGifString(
      data && data.query,
      GIPHY_MAX_QUERY_LENGTH + 1
    );
    if (query.length > GIPHY_MAX_QUERY_LENGTH) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "La búsqueda es demasiado larga"
      );
    }

    const offset = cleanGiphyOffset(data && data.pos);

    const rawLimit = data && data.limit;
    const limit = Number.isInteger(rawLimit)
      ? Math.min(Math.max(rawLimit, 1), GIPHY_MAX_LIMIT)
      : GIPHY_DEFAULT_LIMIT;
    const apiKey = configuredGiphyApiKey();

    if (!apiKey) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "GIPHY no está configurado"
      );
    }

    await assertGiphySearchRateLimit(admin.firestore(), context.auth.uid);

    return fetchGiphyGifs({apiKey, query, offset, limit});
  }
);

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

  if (groupEmoji !== null && !isReactionEmoji(groupEmoji)) {
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

exports.registrarSelfie = callable({enforceAppCheck: false}, async (
  data,
  context
) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const requestedWeekKey = cleanString(data && data.weekKey, "");
  const rewardedAdWatched = data && data.rewardedAdWatched === true;
  const replaceExisting = data && data.replaceExisting === true;
  const replacementUploadId = cleanString(data && data.replacementUploadId, "");

  if (
    !isValidDocumentId(groupId)
    || (requestedWeekKey && !isValidWeekKey(requestedWeekKey))
    || (replaceExisting && !/^[0-9]+$/.test(replacementUploadId))
    || (!replaceExisting && replacementUploadId)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const weekInfo = currentMadridWeekInfo();
  const isRegularSundayUpload = weekInfo.isSunday
    && (!requestedWeekKey || requestedWeekKey === weekInfo.weekKey);
  const isLateMondayUpload = weekInfo.isMonday
    && rewardedAdWatched
    && requestedWeekKey === weekInfo.previousWeekKey;
  const isRewardedReplacement = isRegularSundayUpload
    && replaceExisting
    && rewardedAdWatched;

  if (!isRegularSundayUpload && !isLateMondayUpload) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "La ventana de subida está cerrada"
    );
  }

  if (replaceExisting && !isRewardedReplacement) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Completa el anuncio para reemplazar tu selfie"
    );
  }

  const authorUid = context.auth.uid;
  const weekKey = isLateMondayUpload ? requestedWeekKey : weekInfo.weekKey;
  const replacementFileName = `${authorUid}_${replacementUploadId}.jpg`;
  const storagePath = isRewardedReplacement
    ? `groups/${groupId}/weeks/${weekKey}/replacements/${replacementFileName}`
    : `groups/${groupId}/weeks/${weekKey}/${authorUid}.jpg`;
  const thumbStoragePath = isRewardedReplacement
    ? `groups/${groupId}/weeks/${weekKey}/replacements/thumbs/${replacementFileName}`
    : `groups/${groupId}/weeks/${weekKey}/thumbs/${authorUid}.jpg`;
  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
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
  const validReplacementMetadata = !isRewardedReplacement
    || (
      customMetadata.replacement === "true"
      && customMetadata.rewardedAdWatched === "true"
      && customMetadata.replacementUploadId === replacementUploadId
    );

  if (
    !contentType.startsWith("image/")
    || fileSize <= 0
    || fileSize >= 10 * 1024 * 1024
    || customMetadata.groupId !== groupId
    || customMetadata.weekKey !== weekKey
    || customMetadata.uid !== authorUid
    || (
      isLateMondayUpload
      && (
        customMetadata.lateUpload !== "true"
        || customMetadata.rewardedAdWatched !== "true"
      )
    )
    || !validReplacementMetadata
  ) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "La imagen subida no es válida"
    );
  }

  let imageUrl;
  let thumbUrl;
  let storagePathThumb = storagePath;

  try {
    imageUrl = await getDownloadURL(file);
    thumbUrl = imageUrl;
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

  try {
    const thumbFile = bucket.file(thumbStoragePath);
    const [thumbExists] = await thumbFile.exists();

    if (thumbExists) {
      const [thumbMetadata] = await thumbFile.getMetadata();
      const thumbCustomMetadata = thumbMetadata.metadata || {};
      const thumbSize = Number(thumbMetadata.size || 0);
      const thumbContentType = cleanString(thumbMetadata.contentType, "");
      const validLateMetadata = !isLateMondayUpload
        || (
          thumbCustomMetadata.lateUpload === "true"
          && thumbCustomMetadata.rewardedAdWatched === "true"
        );
      const validReplacementThumbMetadata = !isRewardedReplacement
        || (
          thumbCustomMetadata.replacement === "true"
          && thumbCustomMetadata.rewardedAdWatched === "true"
          && thumbCustomMetadata.replacementUploadId === replacementUploadId
        );

      if (
        thumbContentType === "image/jpeg"
        && thumbSize > 0
        && thumbSize < 2 * 1024 * 1024
        && thumbCustomMetadata.groupId === groupId
        && thumbCustomMetadata.weekKey === weekKey
        && thumbCustomMetadata.uid === authorUid
        && thumbCustomMetadata.kind === "selfieThumb"
        && validLateMetadata
        && validReplacementThumbMetadata
      ) {
        thumbUrl = await getDownloadURL(thumbFile);
        storagePathThumb = thumbStoragePath;
      } else {
        logger.warn("Miniatura de selfie inválida; usando original", {
          groupId,
          weekKey,
          authorUid,
          thumbStoragePath,
        });
      }
    }
  } catch (error) {
    logger.warn("No se pudo preparar la miniatura; usando original", {
      groupId,
      weekKey,
      authorUid,
      error,
    });
  }

  const firestore = admin.firestore();
  const groupRef = firestore.collection("groups").doc(groupId);
  const memberRef = groupRef.collection("members").doc(authorUid);
  const membersRef = groupRef.collection("members");
  const weekRef = groupRef.collection("weeks").doc(weekKey);
  const postsRef = weekRef.collection("posts");
  const postRef = postsRef.doc(authorUid);
  let oldStoragePathsToDelete = [];

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      memberDoc,
      weekDoc,
      postsSnapshot,
      membersSnapshot,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(memberRef),
      transaction.get(weekRef),
      transaction.get(postsRef),
      transaction.get(membersRef),
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

    const existingPostDoc = postsSnapshot.docs.find((postDoc) => {
      return postDoc.id === authorUid;
    });

    if (existingPostDoc && !isRewardedReplacement) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Ya has publicado tu selfie de esta semana"
      );
    }

    const memberData = memberDoc.data() || {};
    const existingPostData = existingPostDoc ? existingPostDoc.data() || {} : null;

    if (isRewardedReplacement && !existingPostData) {
      throw new functions.https.HttpsError(
        "not-found",
        "No se encontró una selfie para reemplazar"
      );
    }

    if (
      existingPostData
      && existingPostData.uid
      && existingPostData.uid !== authorUid
    ) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo puedes reemplazar tu propia selfie"
      );
    }

    if (
      isLateMondayUpload
      && !memberJoinedByMadridDay(memberData, weekInfo.previousSundayDayKey)
    ) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Solo puedes subir con retraso si ya pertenecías al grupo el domingo anterior"
      );
    }

    const authorName = cleanString(memberData.effectiveName, "Usuario");
    const authorPhotoUrl = cleanString(memberData.effectivePhotoUrl, null);
    const now = admin.firestore.FieldValue.serverTimestamp();
    const postCount = isRewardedReplacement
      ? postsSnapshot.size
      : postsSnapshot.size + 1;

    if (isRewardedReplacement && existingPostData) {
      oldStoragePathsToDelete = [
        `groups/${groupId}/weeks/${weekKey}/${authorUid}.jpg`,
        cleanString(existingPostData.storagePathFull, null),
        cleanString(existingPostData.storagePathThumb, null),
      ].filter((path) => path !== storagePath && path !== storagePathThumb);
    }

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

    if (isRewardedReplacement) {
      transaction.update(postRef, {
        uid: authorUid,
        authorName,
        authorPhotoUrl,
        updatedAt: now,
        replacedAt: now,
        replacementCount: admin.firestore.FieldValue.increment(1),
        rewardedReplacementUsed: true,
        imageUrl,
        thumbUrl,
        storagePathFull: storagePath,
        storagePathThumb,
      });
    } else {
      transaction.create(postRef, {
        uid: authorUid,
        authorName,
        authorPhotoUrl,
        createdAt: now,
        updatedAt: now,
        imageUrl,
        thumbUrl,
        storagePathFull: storagePath,
        storagePathThumb,
        hasAnyReactions: false,
        selfReactionEmoji: null,
      });
    }

    for (const groupMemberDoc of membersSnapshot.docs) {
      const memberUserGroupRef = firestore
        .collection("users")
        .doc(groupMemberDoc.id)
        .collection("groups")
        .doc(groupId);

      transaction.set(
        memberUserGroupRef,
        {
          groupId,
          lastActivityAt: now,
          lastSelfieOrChatActivityAt: now,
        },
        {merge: true}
      );
    }

    transaction.update(groupRef, {
      lastActivityAt: now,
      lastSelfieOrChatActivityAt: now,
    });
  });

  if (oldStoragePathsToDelete.length > 0) {
    try {
      await deleteStoragePaths(bucket, oldStoragePathsToDelete);
    } catch (error) {
      logger.warn("No se pudieron borrar rutas antiguas de selfie reemplazada", {
        groupId,
        weekKey,
        authorUid,
        oldStoragePathsToDelete,
        error,
      });
    }
  }

  return {
    success: true,
    groupId,
    weekKey,
    replaced: isRewardedReplacement,
  };
});

exports.resolverInvitacionGrupo = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const inviteCodeUsed = cleanInviteCode(
    (data && data.inviteCode) || (data && data.inviteCodeUsed)
  );

  if (
    !isValidInviteCode(inviteCodeUsed)
    && !inviteCodeUsed.startsWith("TEMP-")
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Invitación no válida"
    );
  }

  const uid = context.auth.uid;
  const firestore = admin.firestore();
  let groupId = null;
  let inviteCodeDoc = null;

  if (isValidInviteCode(inviteCodeUsed)) {
    inviteCodeDoc = await firestore
      .collection("inviteCodes")
      .doc(inviteCodeUsed)
      .get();

    if (
      !inviteCodeDoc.exists
      || inviteCodeDoc.data().active !== true
      || !isValidDocumentId(inviteCodeDoc.data().groupId)
    ) {
      throw new functions.https.HttpsError(
        "not-found",
        "Invitación no válida"
      );
    }

    groupId = inviteCodeDoc.data().groupId;
  } else {
    groupId = inviteCodeUsed.slice("TEMP-".length);

    if (!isValidDocumentId(groupId)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Invitación no válida"
      );
    }
  }

  const groupRef = firestore.collection("groups").doc(groupId);
  const memberRef = groupRef.collection("members").doc(uid);
  const joinRequestRef = groupRef.collection("joinRequests").doc(uid);
  const [
    groupDoc,
    memberDoc,
    joinRequestDoc,
  ] = await Promise.all([
    groupRef.get(),
    memberRef.get(),
    joinRequestRef.get(),
  ]);

  if (!groupDoc.exists || groupDoc.data().deleted === true) {
    throw new functions.https.HttpsError(
      "not-found",
      "El grupo ya no está disponible"
    );
  }

  const groupData = groupDoc.data() || {};
  const activeModernInvite = inviteCodeDoc
    && inviteCodeDoc.exists
    && inviteCodeDoc.data().active === true
    && inviteCodeDoc.data().groupId === groupId;
  const activeLegacyInvite = inviteCodeUsed === `TEMP-${groupId}`
    && groupData.inviteCode === inviteCodeUsed;

  if (!activeModernInvite && !activeLegacyInvite) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Invitación no válida"
    );
  }

  const memberCount = Number.isInteger(groupData.memberCount)
    ? groupData.memberCount
    : 0;

  return {
    groupId,
    name: cleanString(groupData.name, "Grupo").slice(0, 80),
    memberCount,
    emoji: cleanString(groupData.emoji, null),
    colorValue: Number.isInteger(groupData.colorValue)
      ? groupData.colorValue
      : DEFAULT_GROUP_COLOR_VALUE,
    isMember: memberDoc.exists,
    hasRequest: joinRequestDoc.exists,
  };
});

exports.solicitarEntradaGrupo = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const inviteCodeUsed = cleanInviteCode(data && data.inviteCodeUsed);

  if (
    !isValidDocumentId(groupId)
    || !isValidInviteCodeForGroup(inviteCodeUsed, groupId)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Invitación no válida"
    );
  }

  const uid = context.auth.uid;
  const firestore = admin.firestore();
  const dayKey = currentMadridDayKey();
  const groupRef = firestore.collection("groups").doc(groupId);
  const userRef = firestore.collection("users").doc(uid);
  const memberRef = groupRef.collection("members").doc(uid);
  const blockedUserRef = groupRef.collection("blockedUsers").doc(uid);
  const joinRequestRef = groupRef.collection("joinRequests").doc(uid);
  const userGroupRef = userRef.collection("groups").doc(groupId);
  const rateLimitRef = userRateLimitRef(
    firestore,
    uid,
    "joinRequests",
    dayKey
  );
  const inviteCodeRef = firestore.collection("inviteCodes").doc(inviteCodeUsed);

  let joinRequestNotificationData = null;

  await firestore.runTransaction(async (transaction) => {
    joinRequestNotificationData = null;

    const [
      groupDoc,
      userDoc,
      memberDoc,
      blockedUserDoc,
      joinRequestDoc,
      userGroupDoc,
      rateLimitDoc,
      inviteCodeDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(userRef),
      transaction.get(memberRef),
      transaction.get(blockedUserRef),
      transaction.get(joinRequestRef),
      transaction.get(userGroupRef),
      transaction.get(rateLimitRef),
      transaction.get(inviteCodeRef),
    ]);

    if (!groupDoc.exists || groupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    const groupData = groupDoc.data() || {};
    const isActiveInvite = inviteCodeDoc.exists
      && inviteCodeDoc.data().active === true
      && inviteCodeDoc.data().groupId === groupId;
    const isLegacyInvite = inviteCodeUsed === `TEMP-${groupId}`
      && groupData.inviteCode === inviteCodeUsed;

    if (!isActiveInvite && !isLegacyInvite) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Invitación no válida"
      );
    }

    if (memberDoc.exists || userGroupDoc.exists) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Ya perteneces a este grupo"
      );
    }

    if (blockedUserDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Fuiste expulsado de este grupo y no puedes volver a solicitar entrada"
      );
    }

    if (joinRequestDoc.exists) {
      throw new functions.https.HttpsError(
        "already-exists",
        "Ya has enviado una solicitud"
      );
    }

    const memberCount = Number.isInteger(groupData.memberCount)
      ? groupData.memberCount
      : 0;

    if (memberCount >= 30) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Este grupo ya tiene el límite de 30 miembros"
      );
    }

    assertRateLimitAvailable(
      rateLimitDoc,
      JOIN_REQUESTS_PER_DAY_LIMIT,
      "Has enviado demasiadas solicitudes hoy. Prueba otra vez mañana."
    );

    const userData = userDoc.exists ? userDoc.data() || {} : {};
    const baseName = cleanString(userData.baseName, "Usuario").slice(0, 80);
    const basePhotoUrl = cleanString(userData.basePhotoUrl, null);
    const groupName = cleanString(groupData.name, "Grupo");
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.create(joinRequestRef, {
      uid,
      baseName,
      basePhotoUrl,
      status: "pending",
      inviteCodeUsed,
      requestedAt: now,
      updatedAt: now,
    });

    writeRateLimitIncrement(transaction, rateLimitRef, rateLimitDoc, {
      kind: "join_request",
      key: dayKey,
      limit: JOIN_REQUESTS_PER_DAY_LIMIT,
    });

    joinRequestNotificationData = {
      groupId,
      groupName,
      requestUid: uid,
      requestName: baseName,
    };
  });

  if (joinRequestNotificationData) {
    try {
      await sendJoinRequestNotification(joinRequestNotificationData);
    } catch (error) {
      logger.error("No se pudo enviar la notificación de solicitud de entrada", {
        groupId,
        requestUid: uid,
        error,
      });
    }
  }

  return {success: true};
});

// Las reacciones siguen requiriendo Firebase Auth y comprueban en la
// transacción que el usuario es miembro del grupo. No exigimos App Check aquí:
// Play Integrity está rechazando instalaciones válidas antes de llegar a esas
// comprobaciones, por lo que impedía reaccionar a usuarios autenticados.
exports.reaccionarASelfie = callable({enforceAppCheck: false}, async (data, context) => {
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
    || !isReactionEmoji(emoji)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Reacción no válida"
    );
  }

  const reactorUid = context.auth.uid;
  const currentWeekInfo = currentMadridWeekInfo();
  const isCurrentSundayWeek =
    currentWeekInfo.isSunday && weekKey === currentWeekInfo.weekKey;

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

    if (reactionDoc.exists) {
      if (!isCurrentSundayWeek) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Las reacciones de semanas anteriores no se pueden cambiar"
        );
      }

      const updatedAt = reactionDoc.data().updatedAt;
      const updatedAtMillis = updatedAt && typeof updatedAt.toMillis === "function"
        ? updatedAt.toMillis()
        : 0;

      if (
        updatedAtMillis > 0
        && Date.now() - updatedAtMillis < REACTION_COOLDOWN_SECONDS * 1000
        && !isCurrentSundayWeek
      ) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          "Espera unos segundos antes de cambiar tu reacción"
        );
      }
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

// El zumbido comprueba Auth y la pertenencia al grupo dentro de la transacción.
// No imponemos App Check: Play Integrity puede rechazar instalaciones válidas
// antes de que lleguen a esas comprobaciones, igual que ocurría con reacciones.
exports.enviarZumbidoSelfie = callable({enforceAppCheck: false}, async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const targetUid = data && data.targetUid;
  const rewardedAdWatched = data && data.rewardedAdWatched === true;

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
  let reminderRef = weekRef
    .collection("reminders")
    .doc(`${senderUid}_${targetUid}`);
  const targetRemindersQuery = weekRef
    .collection("reminders")
    .where("targetUid", "==", targetUid)
    .limit(1);
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
      targetRemindersSnapshot,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(senderMemberRef),
      transaction.get(targetMemberRef),
      transaction.get(targetPostRef),
      transaction.get(reminderRef),
      transaction.get(targetRemindersQuery),
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

    const targetAlreadyReminded = !targetRemindersSnapshot.empty;
    const requiresRewardedAd = reminderDoc.exists || targetAlreadyReminded;

    if (requiresRewardedAd && !rewardedAdWatched) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Para enviar otro zumbido a este miembro tienes que ver un anuncio"
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

    const reminderCreateRef = reminderDoc.exists
      ? weekRef.collection("reminders").doc()
      : reminderRef;
    reminderRef = reminderCreateRef;

    reminderData = {
      groupId,
      groupName,
      weekKey: weekInfo.weekKey,
      senderUid,
      senderName,
      targetUid,
      rewardedAdUsed: requiresRewardedAd,
    };

    transaction.create(reminderCreateRef, {
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
      rewardedAdUsed: requiresRewardedAd,
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
    rewardedAdUsed: reminderData ? reminderData.rewardedAdUsed : false,
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

  let newMemberNotificationData = null;
  let acceptedNotificationData = null;

  await firestore.runTransaction(async (transaction) => {
    newMemberNotificationData = null;
    acceptedNotificationData = null;

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
    const groupName = cleanString(groupData.name, "Grupo");
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

    newMemberNotificationData = {
      groupId,
      groupName,
      memberUid: requestUid,
      memberName,
    };
    acceptedNotificationData = {
      groupId,
      groupName,
      memberUid: requestUid,
      memberName,
    };
  });

  if (newMemberNotificationData) {
    try {
      await sendNewMemberNotification(newMemberNotificationData);
    } catch (error) {
      logger.error("No se pudo enviar la notificación de nuevo miembro", {
        groupId,
        requestUid,
        error,
      });
    }
  }

  if (acceptedNotificationData) {
    try {
      await sendJoinAcceptedNotification(acceptedNotificationData);
    } catch (error) {
      logger.error("No se pudo enviar la notificación de solicitud aceptada", {
        groupId,
        requestUid,
        error,
      });
    }
  }

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
  const dayKey = currentMadridDayKey();
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
  const reportLimitRef = userRateLimitRef(
    firestore,
    reporterUid,
    "reports",
    dayKey
  );

  let alreadyReported = false;

  await firestore.runTransaction(async (transaction) => {
    const [
      groupDoc,
      reporterMemberDoc,
      postDoc,
      reportDoc,
      reportLimitDoc,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(reporterMemberRef),
      transaction.get(postRef),
      transaction.get(reportRef),
      transaction.get(reportLimitRef),
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

    assertRateLimitAvailable(
      reportLimitDoc,
      REPORTS_PER_DAY_LIMIT,
      "Has enviado demasiados reportes hoy. Prueba otra vez mañana."
    );

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

    writeRateLimitIncrement(transaction, reportLimitRef, reportLimitDoc, {
      kind: "content_report",
      key: dayKey,
      limit: REPORTS_PER_DAY_LIMIT,
    });
  });

  return {
    success: true,
    alreadyReported,
  };
});

exports.borrarSelfie = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const groupId = data && data.groupId;
  const weekKey = data && data.weekKey;
  const postUid = data && data.postUid;

  if (
    !isValidDocumentId(groupId)
    || !isValidWeekKey(weekKey)
    || !isValidDocumentId(postUid)
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Solicitud no válida"
    );
  }

  const uid = context.auth.uid;

  if (uid !== postUid) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Solo puedes borrar tu propia selfie"
    );
  }

  const firestore = admin.firestore();
  const bucket = admin.storage().bucket();
  const groupRef = firestore.collection("groups").doc(groupId);
  const memberRef = groupRef.collection("members").doc(uid);
  const weekRef = groupRef.collection("weeks").doc(weekKey);
  const postRef = weekRef.collection("posts").doc(uid);

  const [groupDoc, memberDoc, postDoc] = await Promise.all([
    groupRef.get(),
    memberRef.get(),
    postRef.get(),
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

  if (!postDoc.exists || postDoc.data().uid !== uid) {
    throw new functions.https.HttpsError(
      "not-found",
      "La selfie ya no está disponible"
    );
  }

  const postData = postDoc.data() || {};
  const storagePathsToDelete = [
    `groups/${groupId}/weeks/${weekKey}/${uid}.jpg`,
    postData.storagePathFull,
    postData.storagePathThumb,
  ];

  try {
    await deleteStoragePathsCompletely(bucket, storagePathsToDelete);
  } catch (error) {
    logger.error("No se pudo borrar completamente la selfie de Storage", {
      groupId,
      weekKey,
      uid,
      storagePathsToDelete,
      error,
    });
    throw new functions.https.HttpsError(
      "internal",
      "No se pudo borrar la selfie de la nube; inténtalo de nuevo"
    );
  }

  await firestore.runTransaction(async (transaction) => {
    const [
      currentGroupDoc,
      currentMemberDoc,
      currentWeekDoc,
      currentPostDoc,
      postsSnapshot,
    ] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(memberRef),
      transaction.get(weekRef),
      transaction.get(postRef),
      transaction.get(weekRef.collection("posts")),
    ]);

    if (!currentGroupDoc.exists || currentGroupDoc.data().deleted === true) {
      throw new functions.https.HttpsError(
        "not-found",
        "El grupo ya no está disponible"
      );
    }

    if (!currentMemberDoc.exists) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "No perteneces a este grupo"
      );
    }

    if (!currentPostDoc.exists) return;

    const currentPostData = currentPostDoc.data() || {};
    if (currentPostData.uid !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Solo puedes borrar tu propia selfie"
      );
    }

    const weekData = currentWeekDoc.data() || {};
    const currentPostCount = Number.isInteger(weekData.postCount)
      ? weekData.postCount
      : postsSnapshot.size;
    const now = admin.firestore.FieldValue.serverTimestamp();

    transaction.delete(postRef);
    transaction.set(
      weekRef,
      {
        postCount: Math.max(currentPostCount - 1, 0),
      },
      {merge: true}
    );
    transaction.update(groupRef, {lastActivityAt: now});
  });

  try {
    await firestore.recursiveDelete(postRef);
  } catch (error) {
    logger.warn("No se pudieron borrar subdatos de la selfie eliminada", {
      groupId,
      weekKey,
      uid,
      postPath: postRef.path,
      error,
    });
  }

  await markPendingReportsForDeletedSelfie({
    firestore,
    groupId,
    weekKey,
    postUid: uid,
    resolvedByUid: uid,
  });

  return {
    success: true,
    groupId,
    weekKey,
    postUid: uid,
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

async function markPendingReportsForDeletedSelfie({
  firestore,
  groupId,
  weekKey,
  postUid,
  resolvedByUid,
}) {
  const reportsSnapshot = await firestore
    .collection("reports")
    .where("groupId", "==", groupId)
    .get();
  const now = admin.firestore.FieldValue.serverTimestamp();
  const linkedReports = reportsSnapshot.docs.filter((doc) => {
    const data = doc.data() || {};

    return cleanString(data.status, "pending") === "pending"
      && cleanString(data.weekKey, "") === weekKey
      && cleanString(data.reportedUid, "") === postUid;
  });

  for (let index = 0; index < linkedReports.length; index += 400) {
    const batch = firestore.batch();

    linkedReports.slice(index, index + 400).forEach((doc) => {
      batch.update(doc.ref, {
        status: "removed",
        decision: "remove_selfie",
        resolvedAt: now,
        resolvedByUid,
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
  consumeAppCheckToken: true,
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

exports.borrarFotoPerfilAnterior = callable(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Usuario no autenticado"
    );
  }

  const uid = context.auth.uid;
  const storagePath = cleanString(data && data.storagePath, "");

  if (!isUserProfileStoragePathForUid(uid, storagePath)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Ruta de foto anterior inválida"
    );
  }

  const firestore = admin.firestore();
  const userDoc = await firestore.collection("users").doc(uid).get();
  const activeStoragePath = cleanString(
    userDoc.data() && userDoc.data().profilePhotoStoragePath,
    null
  );

  if (activeStoragePath === storagePath) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "No se puede borrar la foto de perfil activa"
    );
  }

  try {
    await deleteStoragePathCompletely(admin.storage().bucket(), storagePath);
  } catch (error) {
    logger.error("No se pudo borrar completamente la foto anterior", {
      uid,
      storagePath,
      error,
    });
    throw new functions.https.HttpsError(
      "internal",
      "No se pudo borrar la foto anterior; inténtalo de nuevo"
    );
  }

  return {deleted: true};
});

const SUGGESTION_MIN_LENGTH = 5;
const SUGGESTION_MAX_LENGTH = 1000;
const SUGGESTION_MAIL_COLLECTION = "mail";

async function queueSuggestionEmail(firestore, suggestion) {
  const recipientEmail = configuredSuggestionRecipientEmail();
  const senderEmail = configuredSuggestionSenderEmail();

  if (!recipientEmail) {
    logger.warn("Sugerencia guardada sin correo de CEO configurado", {
      suggestionId: suggestion.suggestionId,
    });
    return false;
  }

  const authorLine = suggestion.authorEmail
    ? `${suggestion.authorName} (${suggestion.authorEmail})`
    : suggestion.authorName;
  const subject = "Nueva sugerencia en Sunday Selfie";
  const textBody = [
    "Nueva sugerencia recibida en Sunday Selfie.",
    "",
    `Usuario: ${authorLine}`,
    `UID: ${suggestion.uid}`,
    "",
    suggestion.text,
  ].join("\n");
  const htmlBody = [
    "<p>Nueva sugerencia recibida en <strong>Sunday Selfie</strong>.</p>",
    "<ul>",
    `<li><strong>Usuario:</strong> ${escapeHtml(authorLine)}</li>`,
    `<li><strong>UID:</strong> ${escapeHtml(suggestion.uid)}</li>`,
    "</ul>",
    `<p>${escapeHtml(suggestion.text).replace(/\n/g, "<br>")}</p>`,
  ].join("");

  await firestore
    .collection(SUGGESTION_MAIL_COLLECTION)
    .doc(`suggestion_${suggestion.suggestionId}`)
    .set({
      from: senderEmail,
      to: [recipientEmail],
      replyTo: suggestion.authorEmail || senderEmail,
      message: {
        subject,
        text: textBody,
        html: htmlBody,
      },
      metadata: {
        type: "suggestion",
        suggestionId: suggestion.suggestionId,
        uid: suggestion.uid,
      },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  return true;
}

exports.enviarSugerencia = callable(
  {enforceAppCheck: false},
  async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Usuario no autenticado"
      );
    }

    const text = cleanString(data && data.text, "");
    if (text.length < SUGGESTION_MIN_LENGTH) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Escribe un poco más para enviar la sugerencia"
      );
    }

    if (text.length > SUGGESTION_MAX_LENGTH) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "La sugerencia no puede superar 1000 caracteres"
      );
    }

    const uid = context.auth.uid;
    const authorName = truncateString(
      cleanString(data && data.authorName, "Usuario"),
      80
    ) || "Usuario";
    const tokenEmail = cleanOptionalEmail(
      context.auth.token && context.auth.token.email
    );
    const clientEmail = cleanOptionalEmail(data && data.authorEmail);
    const authorEmail = tokenEmail || clientEmail;
    const firestore = admin.firestore();
    const suggestionRef = firestore.collection("suggestions").doc();
    const suggestionData = {
      uid,
      authorName,
      authorEmail: authorEmail || null,
      text,
      status: "new",
      source: "profile",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await suggestionRef.set(suggestionData);

    let emailStatus = "not_configured";
    try {
      const emailQueued = await queueSuggestionEmail(firestore, {
        suggestionId: suggestionRef.id,
        uid,
        authorName,
        authorEmail,
        text,
      });
      emailStatus = emailQueued ? "queued" : "not_configured";
    } catch (error) {
      emailStatus = "failed";
      logger.error("No se pudo poner en cola el correo de sugerencia", {
        suggestionId: suggestionRef.id,
        uid,
        error,
      });
    }

    await suggestionRef.set({
      emailQueued: emailStatus === "queued",
      emailStatus,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});

    if (emailStatus !== "queued") {
      logger.warn("Sugerencia guardada sin correo en cola", {
        suggestionId: suggestionRef.id,
        uid,
        emailStatus,
      });
    }

    return {
      success: true,
      suggestionId: suggestionRef.id,
      emailStatus,
    };
  }
);

const SUNDAY_TIME_REGION = "europe-west1";
const SUNDAY_TIME_ZONE = "Europe/Madrid";
const SUNDAY_TIME_SCHEDULE = "0 17 * * 0";
const MAX_TOKENS_PER_MULTICAST = 500;
const SUNDAY_TIME_LOG_COLLECTION = "systemLogs";
const SUNDAY_TIME_LOG_DOCUMENT = "sundayTimeRuns";
const WEEKLY_SUMMARY_REGION = "europe-west1";
const WEEKLY_SUMMARY_TIME_ZONE = "Europe/Madrid";
const WEEKLY_SUMMARY_SCHEDULE = "0 10 * * 1";
const WEEKLY_SUMMARY_LOG_COLLECTION = "systemLogs";
const WEEKLY_SUMMARY_LOG_DOCUMENT = "weeklySummaryRuns";

const invalidTokenCodes = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered",
  "messaging/invalid-argument",
]);
const DEFAULT_NOTIFICATION_SETTINGS = {
  globalEnabled: true,
  sundayTimeEnabled: true,
  newSelfiesEnabled: true,
  friendRemindersEnabled: true,
  reactionsEnabled: true,
  newMembersEnabled: true,
  weeklySummaryEnabled: false,
  chatMessagesEnabled: false,
  soundEnabled: true,
  vibrationEnabled: true,
};

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

function weekKeyForDate(date) {
  const {isoYear, isoWeek} = currentIsoWeekParts(date);
  return `${isoYear}-W${String(isoWeek).padStart(2, "0")}`;
}

function previousWeekKey(date = new Date()) {
  return weekKeyForDate(new Date(date.getTime() - 7 * 24 * 60 * 60 * 1000));
}

function sundayTimeEnabledForUser(userData) {
  return notificationTypeEnabledForUser(userData, "sundayTimeEnabled");
}

function resolvedNotificationSettings(userData) {
  const rawSettings = userData && userData.notificationSettings
    ? userData.notificationSettings
    : {};

  return Object.fromEntries(
    Object.entries(DEFAULT_NOTIFICATION_SETTINGS).map(([key, fallback]) => [
      key,
      typeof rawSettings[key] === "boolean" ? rawSettings[key] : fallback,
    ])
  );
}

function notificationTypeEnabledForUser(userData, settingKey) {
  const settings = resolvedNotificationSettings(userData);

  if (settings.globalEnabled === false) return false;
  if (settings[settingKey] === false) return false;

  return true;
}

function notificationDeliveryOptionsForUser(userData) {
  const settings = resolvedNotificationSettings(userData);

  return {
    soundEnabled: settings.soundEnabled !== false,
    vibrationEnabled: settings.vibrationEnabled !== false,
  };
}

function deliveryOptionsKey(options) {
  return [
    options.soundEnabled ? "sound" : "silent",
    options.vibrationEnabled ? "vibrate" : "still",
  ].join("_");
}

function groupEntriesByDeliveryOptions(entries) {
  const grouped = new Map();

  entries.forEach((entry) => {
    const options = {
      soundEnabled: entry.soundEnabled !== false,
      vibrationEnabled: entry.vibrationEnabled !== false,
    };
    const key = deliveryOptionsKey(options);

    if (!grouped.has(key)) {
      grouped.set(key, {
        options,
        entries: [],
      });
    }

    grouped.get(key).entries.push(entry);
  });

  return Array.from(grouped.values());
}

function platformNotificationConfig({
  channelId = null,
  soundEnabled = true,
  vibrationEnabled = true,
}) {
  const androidNotification = {
    priority: "high",
  };

  if (channelId) {
    androidNotification.channelId = channelId;
  }

  if (soundEnabled) {
    androidNotification.sound = "default";
  }

  if (vibrationEnabled) {
    androidNotification.defaultVibrateTimings = true;
  } else {
    androidNotification.vibrateTimingsMillis = [0];
  }

  const config = {
    android: {
      priority: "high",
      notification: androidNotification,
    },
  };

  if (soundEnabled) {
    config.apns = {
      payload: {
        aps: {
          sound: "default",
        },
      },
    };
  }

  return config;
}

async function sendNotificationToEntries({
  entries,
  notification,
  data,
  channelId = null,
  logLabel,
  logContext = {},
}) {
  let successCount = 0;
  let failureCount = 0;
  let invalidTokenCount = 0;

  for (const deliveryGroup of groupEntriesByDeliveryOptions(entries)) {
    for (
      const batch of chunkArray(deliveryGroup.entries, MAX_TOKENS_PER_MULTICAST)
    ) {
      const deliveryData = {
        ...data,
        soundEnabled: deliveryGroup.options.soundEnabled ? "true" : "false",
        vibrationEnabled: deliveryGroup.options.vibrationEnabled
          ? "true"
          : "false",
      };
      const response = await admin.messaging().sendEachForMulticast({
        tokens: batch.map((entry) => entry.token),
        notification,
        data: deliveryData,
        ...platformNotificationConfig({
          channelId,
          ...deliveryGroup.options,
        }),
      });

      successCount += response.successCount;
      failureCount += response.failureCount;

      const disablePromises = [];

      response.responses.forEach((result, index) => {
        if (result.success) return;

        const errorCode = result.error && result.error.code
          ? result.error.code
          : "unknown";

        logger.warn(`Error enviando ${logLabel}`, {
          ...logContext,
          errorCode,
          tokenIndex: index,
        });

        if (invalidTokenCodes.has(errorCode)) {
          invalidTokenCount += 1;
          disablePromises.push(disableInvalidToken(batch[index], errorCode));
        }
      });

      await Promise.all(disablePromises);
    }
  }

  return {
    tokenCount: entries.length,
    successCount,
    failureCount,
    invalidTokenCount,
  };
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

  const deliveryOptions = notificationDeliveryOptionsForUser(userDoc.data());
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
      ...deliveryOptions,
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

  const result = await sendNotificationToEntries({
    entries,
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
    logLabel: "notificación de zumbido",
    logContext: {
        groupId,
        weekKey,
        senderUid,
        targetUid,
    },
  });

  logger.info("Notificación de zumbido procesada", {
    groupId,
    weekKey,
    senderUid,
    targetUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
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

  const result = await sendNotificationToEntries({
    entries,
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
    logLabel: "notificación de reacción",
    logContext: {
        groupId,
        weekKey,
        postUid,
        reactorUid,
    },
  });

  logger.info("Notificación de reacción procesada", {
    groupId,
    weekKey,
    postUid,
    reactorUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
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

    const deliveryOptions = notificationDeliveryOptionsForUser(userData);

    if (!tokensByValue.has(token)) {
      tokensByValue.set(token, {
        token,
        ref: doc.ref,
        uid: userDoc.id,
        platform: data.platform || "unknown",
        ...deliveryOptions,
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

function buildSundayTimeNotificationData(weekKey) {
  return {
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
    channelId: "sunday_time",
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

    const messageData = buildSundayTimeNotificationData(weekKey);
    const result = await sendNotificationToEntries({
      entries,
      notification: messageData.notification,
      data: messageData.data,
      channelId: messageData.channelId,
      logLabel: "Sunday Time",
    });

    stats.successCount += result.successCount;
    stats.failureCount += result.failureCount;
    stats.invalidTokenCount += result.invalidTokenCount;

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

async function markSelfieOrChatActivityForGroup(firestore, groupId) {
  const groupRef = firestore.collection("groups").doc(groupId);
  const membersSnapshot = await groupRef.collection("members").get();
  const now = admin.firestore.FieldValue.serverTimestamp();
  const batch = firestore.batch();

  batch.set(
    groupRef,
    {
      lastActivityAt: now,
      lastSelfieOrChatActivityAt: now,
    },
    {merge: true}
  );

  for (const memberDoc of membersSnapshot.docs) {
    const userGroupRef = firestore
      .collection("users")
      .doc(memberDoc.id)
      .collection("groups")
      .doc(groupId);

    batch.set(
      userGroupRef,
      {
        groupId,
        lastActivityAt: now,
        lastSelfieOrChatActivityAt: now,
      },
      {merge: true}
    );
  }

  await batch.commit();
}

async function loadGroupRecipientTokens(
  groupId,
  excludedUid,
  settingKey,
  options = {}
) {
  const firestore = admin.firestore();
  const requiredRole = options.requiredRole || null;

  const membersSnapshot = await firestore
    .collection("groups")
    .doc(groupId)
    .collection("members")
    .get();

  const tokensByValue = new Map();

  for (const memberDoc of membersSnapshot.docs) {
    const recipientUid = memberDoc.id;
    const memberData = memberDoc.data() || {};

    if (excludedUid && recipientUid === excludedUid) continue;
    if (requiredRole && memberData.role !== requiredRole) continue;

    const userRef = firestore.collection("users").doc(recipientUid);

    const [
      userDoc,
      userGroupDoc,
      tokensSnapshot,
    ] = await Promise.all([
      userRef.get(),
      userRef.collection("groups").doc(groupId).get(),
      userRef.collection("notificationTokens").where("enabled", "==", true).get(),
    ]);

    if (!userDoc.exists) continue;

    if (!notificationTypeEnabledForUser(userDoc.data(), settingKey)) {
      continue;
    }

    if (userGroupDoc.exists) {
      const userGroupData = userGroupDoc.data();
      const override = userGroupData.notificationsOverride;

      if (override === "off") continue;
    }

    const deliveryOptions = notificationDeliveryOptionsForUser(userDoc.data());

    tokensSnapshot.docs.forEach((tokenDoc) => {
      const data = tokenDoc.data();
      const token = data.token;

      if (typeof token !== "string") return;
      if (token.trim().length === 0) return;

      if (!tokensByValue.has(token)) {
        tokensByValue.set(token, {
          token,
          ref: tokenDoc.ref,
          uid: recipientUid,
          platform: data.platform || "unknown",
          ...deliveryOptions,
        });
      }
    });
  }

  return Array.from(tokensByValue.values());
}

async function sendJoinRequestNotification({
  groupId,
  groupName,
  requestUid,
  requestName,
}) {
  const entries = await loadGroupRecipientTokens(
    groupId,
    requestUid,
    "newMembersEnabled",
    {requiredRole: "admin"}
  );

  if (entries.length === 0) {
    logger.info("Solicitud de entrada sin administradores activos", {
      groupId,
      requestUid,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const result = await sendNotificationToEntries({
    entries,
    notification: {
      title: groupName,
      body: `${requestName} ha solicitado unirse al grupo`,
    },
    data: {
      type: "join_request",
      target: "group",
      groupId,
      requestUid,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    logLabel: "notificación de solicitud de entrada",
    logContext: {
      groupId,
      requestUid,
    },
  });

  logger.info("Notificación de solicitud de entrada enviada", {
    groupId,
    requestUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
}

async function sendJoinAcceptedNotification({
  groupId,
  groupName,
  memberUid,
}) {
  const entries = await loadUserNotificationTokens(
    memberUid,
    groupId,
    "newMembersEnabled"
  );

  if (entries.length === 0) {
    logger.info("Solicitud aceptada sin destinatarios activos", {
      groupId,
      memberUid,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const result = await sendNotificationToEntries({
    entries,
    notification: {
      title: groupName,
      body: "Te han aceptado en el grupo",
    },
    data: {
      type: "join_accepted",
      target: "group",
      groupId,
      memberUid,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    logLabel: "notificación de solicitud aceptada",
    logContext: {
      groupId,
      memberUid,
    },
  });

  logger.info("Notificación de solicitud aceptada enviada", {
    groupId,
    memberUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
}

async function sendNewMemberNotification({
  groupId,
  groupName,
  memberUid,
  memberName,
}) {
  const entries = await loadGroupRecipientTokens(
    groupId,
    memberUid,
    "newMembersEnabled"
  );

  if (entries.length === 0) {
    logger.info("Nuevo miembro sin destinatarios activos", {
      groupId,
      memberUid,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const result = await sendNotificationToEntries({
    entries,
    notification: {
      title: groupName,
      body: `${memberName} se ha unido al grupo`,
    },
    data: {
      type: "new_member",
      target: "group",
      groupId,
      memberUid,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    logLabel: "notificación de nuevo miembro",
    logContext: {
      groupId,
      memberUid,
    },
  });

  logger.info("Notificación de nuevo miembro enviada", {
    groupId,
    memberUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
}

async function sendNewSelfieNotification({
  groupId,
  weekKey,
  authorUid,
  authorName,
  groupName,
}) {
  const entries = await loadGroupRecipientTokens(
    groupId,
    authorUid,
    "newSelfiesEnabled"
  );

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

  const result = await sendNotificationToEntries({
    entries,
    notification: {
      title: groupName,
      body: `${authorName} ha publicado su Sunday Selfie`,
    },
    data: {
      type: "new_selfie",
      target: "group",
      groupId,
      weekKey,
      postUid: authorUid,
      authorUid,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    logLabel: "notificación de nuevo selfie",
    logContext: {
        groupId,
        weekKey,
        authorUid,
    },
  });

  logger.info("Notificación de nuevo selfie enviada", {
    groupId,
    weekKey,
    authorUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
}

function notificationSnippet(value, maxLength = 110) {
  const clean = cleanString(value, "").replace(/\s+/g, " ").trim();
  if (clean.length <= maxLength) return clean;
  return `${clean.slice(0, Math.max(0, maxLength - 3)).trim()}...`;
}

function chatMessageNotificationBody({
  authorName,
  text,
  gifUrl,
}) {
  const cleanText = notificationSnippet(text);
  const hasGif = typeof gifUrl === "string" && gifUrl.trim().length > 0;

  if (cleanText.length > 0) {
    return `${authorName}: ${cleanText}`;
  }

  if (hasGif) {
    return `${authorName} ha enviado un GIF en el chat`;
  }

  return `${authorName} ha enviado un mensaje en el chat`;
}

async function sendChatMessageNotification({
  groupId,
  weekKey,
  messageId,
  authorUid,
  authorName,
  groupName,
  text,
  gifUrl,
}) {
  const entries = await loadGroupRecipientTokens(
    groupId,
    authorUid,
    "chatMessagesEnabled"
  );

  if (entries.length === 0) {
    logger.info("Mensaje de chat sin destinatarios activos", {
      groupId,
      weekKey,
      messageId,
      authorUid,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const result = await sendNotificationToEntries({
    entries,
    notification: {
      title: groupName,
      body: chatMessageNotificationBody({authorName, text, gifUrl}),
    },
    data: {
      type: "chat_message",
      target: "group",
      groupId,
      weekKey,
      messageId,
      authorUid,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    logLabel: "notificación de mensaje de chat",
    logContext: {
      groupId,
      weekKey,
      messageId,
      authorUid,
    },
  });

  logger.info("Notificación de mensaje de chat enviada", {
    groupId,
    weekKey,
    messageId,
    authorUid,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
}

async function sendWeeklySummaryNotification({
  groupId,
  groupName,
  weekKey,
  postCount,
}) {
  const entries = await loadGroupRecipientTokens(
    groupId,
    null,
    "weeklySummaryEnabled"
  );

  if (entries.length === 0) {
    logger.info("Resumen semanal sin destinatarios activos", {
      groupId,
      weekKey,
      postCount,
    });

    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const selfieText = postCount === 1 ? "1 selfie" : `${postCount} selfies`;
  const result = await sendNotificationToEntries({
    entries,
    notification: {
      title: `Resumen de ${groupName}`,
      body: `${selfieText} compartidas esta semana`,
    },
    data: {
      type: "weekly_summary",
      target: "group",
      groupId,
      weekKey,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    logLabel: "resumen semanal",
    logContext: {
      groupId,
      weekKey,
    },
  });

  logger.info("Resumen semanal enviado", {
    groupId,
    weekKey,
    postCount,
    tokenCount: entries.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return result;
}

async function sendWeeklySummaryNotifications() {
  const firestore = admin.firestore();
  const weekKey = previousWeekKey();
  const runId = new Date().toISOString().replace(/[.:]/g, "-");
  const logRef = firestore
    .collection(WEEKLY_SUMMARY_LOG_COLLECTION)
    .doc(WEEKLY_SUMMARY_LOG_DOCUMENT)
    .collection("runs")
    .doc(runId);

  const stats = {
    groupsLoaded: 0,
    groupsConsidered: 0,
    groupsWithPosts: 0,
    notificationsAttempted: 0,
    successCount: 0,
    failureCount: 0,
    invalidTokenCount: 0,
  };

  await logRef.set({
    type: "weekly_summary",
    status: "running",
    weekKey,
    schedule: WEEKLY_SUMMARY_SCHEDULE,
    timeZone: WEEKLY_SUMMARY_TIME_ZONE,
    startedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  try {
    const groupsSnapshot = await firestore.collection("groups").get();
    stats.groupsLoaded = groupsSnapshot.size;

    for (const groupDoc of groupsSnapshot.docs) {
      const groupData = groupDoc.data() || {};

      if (groupData.deleted === true) continue;

      stats.groupsConsidered += 1;

      const weekDoc = await groupDoc.ref.collection("weeks").doc(weekKey).get();

      if (!weekDoc.exists) continue;

      const weekData = weekDoc.data() || {};
      const postCount = Number.isInteger(weekData.postCount)
        ? weekData.postCount
        : 0;

      if (postCount <= 0) continue;

      stats.groupsWithPosts += 1;

      const result = await sendWeeklySummaryNotification({
        groupId: groupDoc.id,
        groupName: cleanString(groupData.name, "Sunday Selfie"),
        weekKey,
        postCount,
      });

      stats.notificationsAttempted += result.tokenCount;
      stats.successCount += result.successCount;
      stats.failureCount += result.failureCount;
      stats.invalidTokenCount += result.invalidTokenCount;
    }

    await logRef.set({
      status: "completed",
      finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...stats,
    }, {merge: true});

    logger.info("Resumen semanal completado", stats);
    return stats;
  } catch (error) {
    await logRef.set({
      status: "error",
      finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      errorMessage: error && error.message ? error.message : String(error),
      ...stats,
    }, {merge: true});

    logger.error("Resumen semanal falló", error);
    throw error;
  }
}

exports.weeklySummaryReminder = onSchedule(
  {
    region: WEEKLY_SUMMARY_REGION,
    timeZone: WEEKLY_SUMMARY_TIME_ZONE,
    schedule: WEEKLY_SUMMARY_SCHEDULE,
    memory: "256MiB",
    timeoutSeconds: 540,
  },
  async () => {
    await sendWeeklySummaryNotifications();
  }
);

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

exports.notifyChatMessage = onDocumentCreated(
  {
    region: NEW_SELFIE_REGION,
    document: "groups/{groupId}/weeks/{weekKey}/chatMessages/{messageId}",
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async (event) => {
    const snapshot = event.data;

    if (!snapshot) {
      logger.warn("notifyChatMessage sin snapshot");
      return;
    }

    const params = event.params;
    const groupId = params.groupId;
    const weekKey = params.weekKey;
    const messageId = params.messageId;
    const messageData = snapshot.data() || {};
    const authorUid = cleanString(messageData.uid, "");

    if (!isValidDocumentId(authorUid)) {
      logger.warn("notifyChatMessage sin autor válido", {
        groupId,
        weekKey,
        messageId,
      });
      return;
    }

    const groupDoc = await admin.firestore()
      .collection("groups")
      .doc(groupId)
      .get();
    const groupData = groupDoc.exists ? groupDoc.data() || {} : {};

    if (groupData.deleted === true) {
      return;
    }

    try {
      await markSelfieOrChatActivityForGroup(admin.firestore(), groupId);
    } catch (error) {
      logger.error("No se pudo marcar actividad de chat del grupo", {
        groupId,
        weekKey,
        messageId,
        error,
      });
    }

    await sendChatMessageNotification({
      groupId,
      weekKey,
      messageId,
      authorUid,
      authorName: cleanString(messageData.authorName, "Alguien"),
      groupName: cleanString(groupData.name, "Sunday Selfie"),
      text: messageData.text,
      gifUrl: messageData.gifUrl,
    });
  }
);
