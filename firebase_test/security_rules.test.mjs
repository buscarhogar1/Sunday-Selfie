import {readFile} from "node:fs/promises";
import {after, before, beforeEach, test} from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} from "firebase/firestore";
import {
  deleteObject,
  getBytes,
  ref,
  uploadBytes,
} from "firebase/storage";

const projectId = "demo-sunday-selfie";
const groupId = "group-security-test";
const weekKey = "2026-W22";
const adminUid = "admin-user";
const memberUid = "member-user";
const authorUid = "author-user";
const outsiderUid = "outsider-user";
const inviteCode = "ABCDEFGHJK";

let testEnv;

function firestoreFor(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

function storageFor(uid) {
  return testEnv.authenticatedContext(uid).storage();
}

async function seedFirestore() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await Promise.all([
      setDoc(doc(db, "users", memberUid), {
        baseName: "Miembro",
      }),
      setDoc(doc(db, "groups", groupId), {
        name: "Grupo de prueba",
        deleted: false,
        memberCount: 3,
        adminsCount: 1,
        inviteCode,
      }),
      setDoc(doc(db, "groups", groupId, "members", adminUid), {
        role: "admin",
        effectiveName: "Admin",
        effectivePhotoUrl: null,
      }),
      setDoc(doc(db, "groups", groupId, "members", memberUid), {
        role: "member",
        effectiveName: "Miembro",
        effectivePhotoUrl: null,
      }),
      setDoc(doc(db, "groups", groupId, "members", authorUid), {
        role: "member",
        effectiveName: "Autor",
        effectivePhotoUrl: null,
      }),
      setDoc(doc(db, "groups", groupId, "weeks", weekKey), {
        weekKey,
        isoYear: 2026,
        isoWeek: 22,
        postCount: 1,
      }),
      setDoc(doc(db, "groups", groupId, "weeks", weekKey, "posts", authorUid), {
        uid: authorUid,
        authorName: "Autor",
        hasAnyReactions: false,
      }),
      setDoc(doc(db, "inviteCodes", inviteCode), {
        groupId,
        active: true,
      }),
      setDoc(doc(db, "reports", "private-report"), {
        type: "selfie",
        status: "pending",
        reporterUid: memberUid,
        reportedUid: authorUid,
      }),
    ]);
  });
}

async function seedStorageObject(objectPath) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await uploadBytes(
      ref(context.storage(), objectPath),
      new Uint8Array([1, 2, 3]),
      {contentType: "image/jpeg"}
    );
  });
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: await readFile("firestore.rules", "utf8"),
    },
    storage: {
      rules: await readFile("storage.rules", "utf8"),
    },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedFirestore();
});

after(async () => {
  await testEnv.cleanup();
});

test("members can read protected group content and outsiders cannot", async () => {
  const memberPost = doc(
    firestoreFor(memberUid),
    "groups",
    groupId,
    "weeks",
    weekKey,
    "posts",
    authorUid
  );
  const outsiderPost = doc(
    firestoreFor(outsiderUid),
    "groups",
    groupId,
    "weeks",
    weekKey,
    "posts",
    authorUid
  );

  await assertSucceeds(getDoc(memberPost));
  await assertFails(getDoc(outsiderPost));
});

test("group documents are private but active invite codes can be resolved", async () => {
  const memberGroup = doc(firestoreFor(memberUid), "groups", groupId);
  const outsiderGroup = doc(firestoreFor(outsiderUid), "groups", groupId);
  const outsiderInvite = doc(firestoreFor(outsiderUid), "inviteCodes", inviteCode);

  await assertSucceeds(getDoc(memberGroup));
  await assertFails(getDoc(outsiderGroup));
  await assertSucceeds(getDoc(outsiderInvite));
});

test("direct clients cannot perform server-only Firestore writes", async () => {
  const db = firestoreFor(memberUid);

  await assertFails(setDoc(doc(db, "groups", "client-created-group"), {
    name: "No permitido",
  }));
  await assertFails(setDoc(
    doc(db, "groups", groupId, "weeks", weekKey, "posts", memberUid),
    {uid: memberUid}
  ));
  await assertFails(setDoc(
    doc(db, "groups", groupId, "weeks", weekKey, "reminders", "fake-reminder"),
    {senderUid: memberUid}
  ));
  await assertFails(setDoc(
    doc(
      db,
      "groups",
      groupId,
      "weeks",
      weekKey,
      "posts",
      authorUid,
      "reactions",
      memberUid
    ),
    {uid: memberUid, emoji: "🔥"}
  ));
  await assertFails(setDoc(doc(db, "reports", "forged-client-report"), {
    reporterUid: memberUid,
    reportedUid: authorUid,
    reason: "otro",
  }));
  await assertFails(deleteDoc(doc(db, "groups", groupId, "members", memberUid)));
  await assertFails(deleteDoc(doc(db, "users", memberUid)));
});

test("members can change only their own name inside a group", async () => {
  const memberDb = firestoreFor(memberUid);
  const outsiderDb = firestoreFor(outsiderUid);
  const ownMemberRef = doc(
    memberDb,
    "groups",
    groupId,
    "members",
    memberUid
  );
  const otherMemberRef = doc(
    memberDb,
    "groups",
    groupId,
    "members",
    authorUid
  );
  const outsiderMemberRef = doc(
    outsiderDb,
    "groups",
    groupId,
    "members",
    memberUid
  );

  await assertSucceeds(updateDoc(ownMemberRef, {
    effectiveName: "Alias del grupo",
    groupNameOverride: "Alias del grupo",
    profileSyncedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(otherMemberRef, {
    effectiveName: "Nombre ajeno",
    groupNameOverride: "Nombre ajeno",
    profileSyncedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(outsiderMemberRef, {
    effectiveName: "Intruso",
    groupNameOverride: "Intruso",
    profileSyncedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(ownMemberRef, {
    role: "admin",
    profileSyncedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(ownMemberRef, {
    effectiveName: "",
    groupNameOverride: "",
    profileSyncedAt: serverTimestamp(),
  }));
});

test("security reports stay private even for their reporter", async () => {
  const reportRef = doc(firestoreFor(memberUid), "reports", "private-report");

  await assertFails(getDoc(reportRef));
});

test("direct clients cannot create private suggestions", async () => {
  const memberDb = firestoreFor(memberUid);
  const validSuggestion = {
    uid: memberUid,
    authorName: "Miembro",
    authorEmail: "member@example.com",
    text: "Me gustaría poder ordenar los grupos.",
    status: "new",
    source: "profile",
    createdAt: serverTimestamp(),
  };

  await assertFails(setDoc(
    doc(memberDb, "suggestions", "member-suggestion"),
    validSuggestion
  ));
  await assertFails(getDoc(doc(memberDb, "suggestions", "member-suggestion")));
});

test("direct clients cannot create join requests", async () => {
  const db = firestoreFor(outsiderUid);

  await assertFails(setDoc(
    doc(db, "groups", groupId, "joinRequests", outsiderUid),
    {
      uid: outsiderUid,
      baseName: "Invitado",
      basePhotoUrl: null,
      status: "pending",
      inviteCodeUsed: inviteCode,
      requestedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }
  ));
});

test("a blocked user cannot create a join request", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "groups", groupId, "blockedUsers", outsiderUid),
      {blockedAt: new Date()}
    );
  });

  const db = firestoreFor(outsiderUid);

  await assertFails(setDoc(
    doc(db, "groups", groupId, "joinRequests", outsiderUid),
    {
      uid: outsiderUid,
      baseName: "Bloqueado",
      basePhotoUrl: null,
      status: "pending",
      inviteCodeUsed: inviteCode,
      requestedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }
  ));
});

test("members can read stored selfies and outsiders cannot", async () => {
  const objectPath = `groups/${groupId}/weeks/${weekKey}/read-test.jpg`;
  await seedStorageObject(objectPath);

  await assertSucceeds(getBytes(ref(storageFor(memberUid), objectPath)));
  await assertFails(getBytes(ref(storageFor(outsiderUid), objectPath)));
});

test("direct clients cannot replace or delete a stored selfie", async () => {
  const objectPath = `groups/${groupId}/weeks/${weekKey}/${memberUid}.jpg`;
  await seedStorageObject(objectPath);

  const selfieRef = ref(storageFor(memberUid), objectPath);
  await assertFails(uploadBytes(
    selfieRef,
    new Uint8Array([4, 5, 6]),
    {
      contentType: "image/jpeg",
      customMetadata: {groupId, weekKey, uid: memberUid},
    }
  ));
  await assertFails(deleteObject(selfieRef));
});

test("members can upload a rewarded selfie replacement to a unique path", async () => {
  const replacementUploadId = "123456789";
  const objectPath =
    `groups/${groupId}/weeks/${weekKey}/replacements/${authorUid}_${replacementUploadId}.jpg`;
  const selfieRef = ref(storageFor(authorUid), objectPath);

  await assertSucceeds(uploadBytes(
    selfieRef,
    new Uint8Array([4, 5, 6]),
    {
      contentType: "image/jpeg",
      customMetadata: {
        groupId,
        weekKey,
        uid: authorUid,
        replacement: "true",
        rewardedAdWatched: "true",
        replacementUploadId,
      },
    }
  ));
});

test("users can upload only their own profile photo", async () => {
  const ownProfile = ref(storageFor(memberUid), `users/${memberUid}/profile/base_123.jpg`);
  const otherProfile = ref(storageFor(outsiderUid), `users/${memberUid}/profile/base_456.jpg`);
  const bytes = new Uint8Array([7, 8, 9]);
  const metadata = {
    contentType: "image/jpeg",
    customMetadata: {uid: memberUid, kind: "profilePhoto"},
  };

  await assertSucceeds(uploadBytes(ownProfile, bytes, metadata));
  await assertFails(uploadBytes(otherProfile, bytes, metadata));
});

test("only admins can upload a group photo", async () => {
  const bytes = new Uint8Array([10, 11, 12]);
  const adminPhoto = ref(storageFor(adminUid), `groups/${groupId}/profile/group_123.jpg`);
  const memberPhoto = ref(storageFor(memberUid), `groups/${groupId}/profile/group_456.jpg`);

  await assertSucceeds(uploadBytes(adminPhoto, bytes, {
    contentType: "image/jpeg",
    customMetadata: {groupId, uid: adminUid, kind: "groupPhoto"},
  }));
  await assertFails(uploadBytes(memberPhoto, bytes, {
    contentType: "image/jpeg",
    customMetadata: {groupId, uid: memberUid, kind: "groupPhoto"},
  }));
});
