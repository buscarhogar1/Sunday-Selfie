const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");

const callableFunctions = require("./index.js");

const callableNames = [
  "buscarGifsTenor",
  "crearGrupo",
  "registrarSelfie",
  "solicitarEntradaGrupo",
  "reaccionarASelfie",
  "enviarZumbidoSelfie",
  "aceptarSolicitud",
  "rechazarSolicitud",
  "promoverAdministrador",
  "expulsarMiembro",
  "permitirReingreso",
  "abandonarGrupo",
  "regenerarInvitacion",
  "reportarContenido",
  "borrarSelfie",
  "listarReportesGrupo",
  "resolverReporte",
  "borrarCuenta",
  "borrarFotoPerfilAnterior",
  "enviarSugerencia",
];

test("all callable functions receive authentication through the v2 request", async () => {
  for (const name of callableNames) {
    const callableFunction = callableFunctions[name];

    assert.equal(typeof callableFunction.run, "function", `${name} is callable`);
    await assert.rejects(
      () => callableFunction.run({data: {}, auth: null}),
      (error) => error && error.code === "unauthenticated",
      `${name} rejects unauthenticated calls`
    );
  }
});

test("content reports validate their target before accessing Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.reportarContenido.run({
      auth: {uid: "member-user", token: {}},
      data: {
        groupId: "group-id",
        weekKey: "2026-W22",
        postUid: "member-user",
        reason: "otro",
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("selfie deletion rejects deleting another user's post before Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.borrarSelfie.run({
      auth: {uid: "member-user", token: {}},
      data: {
        groupId: "group-id",
        weekKey: "2026-W22",
        postUid: "other-user",
      },
    }),
    (error) => error && error.code === "permission-denied"
  );
});

test("join requests validate basic arguments before accessing Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.solicitarEntradaGrupo.run({
      auth: {uid: "member-user", token: {}},
      data: {
        groupId: "",
        inviteCodeUsed: "",
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("group creation rejects text mixed with emoji before accessing Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.crearGrupo.run({
      auth: {uid: "member-user", token: {}},
      data: {
        name: "Grupo de prueba",
        emoji: "👩‍💻 texto extra",
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("reactions reject text mixed with emoji before accessing Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.reaccionarASelfie.run({
      auth: {uid: "member-user", token: {}},
      data: {
        groupId: "group-id",
        weekKey: "2026-W22",
        postUid: "other-user",
        emoji: "🔥 texto extra",
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("moderation calls validate basic arguments before accessing Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.listarReportesGrupo.run({
      auth: {uid: "admin-user", token: {}},
      data: {groupId: ""},
    }),
    (error) => error && error.code === "invalid-argument"
  );

  await assert.rejects(
    () => callableFunctions.resolverReporte.run({
      auth: {uid: "admin-user", token: {}},
      data: {
        reportId: "report-id",
        decision: "invented-decision",
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("account deletion requires explicit confirmation and recent authentication", async () => {
  const recentAuthTime = Math.floor(Date.now() / 1000);

  await assert.rejects(
    () => callableFunctions.borrarCuenta.run({
      auth: {uid: "member-user", token: {auth_time: recentAuthTime}},
      data: {},
    }),
    (error) => error && error.code === "invalid-argument"
  );

  await assert.rejects(
    () => callableFunctions.borrarCuenta.run({
      auth: {uid: "member-user", token: {auth_time: recentAuthTime - 3600}},
      data: {confirmation: "BORRAR"},
    }),
    (error) => error && error.code === "failed-precondition"
  );
});

test("profile photo deletion rejects paths outside the caller profile", async () => {
  await assert.rejects(
    () => callableFunctions.borrarFotoPerfilAnterior.run({
      auth: {uid: "member-user", token: {}},
      data: {storagePath: "users/other-user/profile/base_123.jpg"},
    }),
    (error) => error && error.code === "invalid-argument"
  );

  await assert.rejects(
    () => callableFunctions.borrarFotoPerfilAnterior.run({
      auth: {uid: "member-user", token: {}},
      data: {storagePath: "groups/group-id/weeks/2026-W22/member-user.jpg"},
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("suggestions validate text before accessing Firestore", async () => {
  await assert.rejects(
    () => callableFunctions.enviarSugerencia.run({
      auth: {uid: "member-user", token: {}},
      data: {
        authorName: "Miembro",
        text: "hey",
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );

  await assert.rejects(
    () => callableFunctions.enviarSugerencia.run({
      auth: {uid: "member-user", token: {}},
      data: {
        authorName: "Miembro",
        text: "x".repeat(1001),
      },
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

test("GIF search validates arguments before calling Tenor", async () => {
  await assert.rejects(
    () => callableFunctions.buscarGifsTenor.run({
      auth: {uid: "member-user", token: {}},
      data: {query: "x".repeat(81)},
    }),
    (error) => error && error.code === "invalid-argument"
  );

  await assert.rejects(
    () => callableFunctions.buscarGifsTenor.run({
      auth: {uid: "member-user", token: {}},
      data: {pos: "p".repeat(181)},
    }),
    (error) => error && error.code === "invalid-argument"
  );
});

class FakeDocumentSnapshot {
  constructor(ref, data) {
    this.ref = ref;
    this.id = ref.id;
    this._data = data;
  }

  get exists() {
    return this._data !== undefined;
  }

  data() {
    return this._data;
  }
}

class FakeQuerySnapshot {
  constructor(docs) {
    this.docs = docs;
    this.empty = docs.length === 0;
    this.size = docs.length;
  }
}

class FakeDocumentRef {
  constructor(firestore, path) {
    this.firestore = firestore;
    this.path = path;
    this.id = path.split("/").pop();
  }

  collection(name) {
    return new FakeCollectionRef(this.firestore, `${this.path}/${name}`);
  }

  async get() {
    return this.firestore.getDoc(this);
  }

  async set(data, options) {
    this.firestore.setDoc(this, data, options);
  }
}

class FakeCollectionRef {
  constructor(firestore, path) {
    this.firestore = firestore;
    this.path = path;
  }

  doc(id) {
    return new FakeDocumentRef(
      this.firestore,
      `${this.path}/${id || this.firestore.nextAutoId()}`
    );
  }

  where(field, op, value) {
    return new FakeQuery(this.firestore, this.path, [{field, op, value}]);
  }
}

class FakeQuery {
  constructor(firestore, path, filters, resultLimit = null) {
    this.firestore = firestore;
    this.path = path;
    this.filters = filters;
    this.resultLimit = resultLimit;
  }

  where(field, op, value) {
    return new FakeQuery(
      this.firestore,
      this.path,
      [...this.filters, {field, op, value}],
      this.resultLimit
    );
  }

  limit(value) {
    return new FakeQuery(this.firestore, this.path, this.filters, value);
  }

  async get() {
    return this.firestore.getQuery(this);
  }
}

class FakeTransaction {
  constructor(firestore) {
    this.firestore = firestore;
  }

  async get(refOrQuery) {
    if (refOrQuery instanceof FakeQuery) {
      return this.firestore.getQuery(refOrQuery);
    }

    return this.firestore.getDoc(refOrQuery);
  }

  create(ref, data) {
    if (this.firestore.hasDoc(ref.path)) {
      throw new Error(`Document already exists: ${ref.path}`);
    }

    this.firestore.setDoc(ref, data);
  }

  update(ref, data) {
    this.firestore.updateDoc(ref, data);
  }

  set(ref, data, options) {
    this.firestore.setDoc(ref, data, options);
  }
}

class FakeFirestore {
  constructor(seed = {}) {
    this.docs = new Map(
      Object.entries(seed).map(([path, data]) => [path, {...data}])
    );
    this.autoId = 0;
  }

  collection(name) {
    return new FakeCollectionRef(this, name);
  }

  async runTransaction(callback) {
    return callback(new FakeTransaction(this));
  }

  nextAutoId() {
    this.autoId += 1;
    return `auto-reminder-${this.autoId}`;
  }

  hasDoc(path) {
    return this.docs.has(path);
  }

  getDoc(ref) {
    const data = this.docs.get(ref.path);
    return new FakeDocumentSnapshot(
      ref,
      data === undefined ? undefined : {...data}
    );
  }

  getQuery(query) {
    const prefix = `${query.path}/`;
    const matches = [];

    for (const [path, data] of this.docs.entries()) {
      if (!path.startsWith(prefix)) continue;

      const childPath = path.slice(prefix.length);
      if (childPath.includes("/")) continue;

      const isMatch = query.filters.every(({field, op, value}) => {
        return op === "==" && data[field] === value;
      });
      if (!isMatch) continue;

      matches.push(new FakeDocumentSnapshot(
        new FakeDocumentRef(this, path),
        {...data}
      ));
      if (query.resultLimit !== null && matches.length >= query.resultLimit) {
        break;
      }
    }

    return new FakeQuerySnapshot(matches);
  }

  setDoc(ref, data, options = {}) {
    const existing = this.docs.get(ref.path);
    const nextData = options.merge && existing
      ? {...existing, ...data}
      : {...data};
    this.docs.set(ref.path, nextData);
  }

  updateDoc(ref, data) {
    const existing = this.docs.get(ref.path);
    if (!existing) {
      throw new Error(`Document does not exist: ${ref.path}`);
    }

    this.docs.set(ref.path, {...existing, ...data});
  }

  documentsUnder(collectionPath) {
    const prefix = `${collectionPath}/`;
    return Array.from(this.docs.entries())
      .filter(([path]) => {
        return path.startsWith(prefix)
          && !path.slice(prefix.length).includes("/");
      })
      .map(([path, data]) => ({
        ref: new FakeDocumentRef(this, path),
        data,
      }));
  }
}

async function withFakeFirestore(fakeFirestore, callback) {
  const originalDescriptor = Object.getOwnPropertyDescriptor(
    admin,
    "firestore"
  );
  const firestoreAccessor = () => fakeFirestore;
  firestoreAccessor.FieldValue = {
    serverTimestamp: () => ({serverTimestamp: true}),
    increment: (value) => ({increment: value}),
  };

  Object.defineProperty(admin, "firestore", {
    value: firestoreAccessor,
    configurable: true,
  });

  try {
    return await callback();
  } finally {
    if (originalDescriptor) {
      Object.defineProperty(admin, "firestore", originalDescriptor);
    } else {
      delete admin.firestore;
    }
  }
}

test("suggestions are stored and queue an email for the CEO", async () => {
  const previousRecipient = process.env.SUNDAY_SELFIE_CEO_EMAIL;
  process.env.SUNDAY_SELFIE_CEO_EMAIL = "ceo@example.com";

  try {
    const fakeFirestore = new FakeFirestore();
    const result = await withFakeFirestore(fakeFirestore, () => {
      return callableFunctions.enviarSugerencia.run({
        auth: {uid: "member-user", token: {email: "member@example.com"}},
        data: {
          authorName: "Miembro",
          text: "Me gustaría poder ordenar los grupos.",
        },
      });
    });

    assert.equal(result.success, true);
    assert.equal(result.emailStatus, "queued");

    const suggestions = fakeFirestore.documentsUnder("suggestions");
    assert.equal(suggestions.length, 1);
    assert.equal(suggestions[0].data.uid, "member-user");
    assert.equal(suggestions[0].data.authorName, "Miembro");
    assert.equal(suggestions[0].data.authorEmail, "member@example.com");
    assert.equal(
      suggestions[0].data.text,
      "Me gustaría poder ordenar los grupos."
    );
    assert.equal(suggestions[0].data.emailQueued, true);

    const mails = fakeFirestore.documentsUnder("mail");
    assert.equal(mails.length, 1);
    assert.deepEqual(mails[0].data.to, ["ceo@example.com"]);
    assert.equal(mails[0].data.message.subject, "Nueva sugerencia en Sunday Selfie");
    assert.match(mails[0].data.message.text, /ordenar los grupos/);
  } finally {
    if (previousRecipient === undefined) {
      delete process.env.SUNDAY_SELFIE_CEO_EMAIL;
    } else {
      process.env.SUNDAY_SELFIE_CEO_EMAIL = previousRecipient;
    }
  }
});

test("suggestions default to the project email when no recipient is configured", async () => {
  const previousRecipient = process.env.SUNDAY_SELFIE_CEO_EMAIL;
  const previousSuggestionsRecipient = process.env.SUGGESTIONS_TO_EMAIL;
  delete process.env.SUNDAY_SELFIE_CEO_EMAIL;
  delete process.env.SUGGESTIONS_TO_EMAIL;

  try {
    const fakeFirestore = new FakeFirestore();
    const result = await withFakeFirestore(fakeFirestore, () => {
      return callableFunctions.enviarSugerencia.run({
        auth: {uid: "member-user", token: {email: "member@example.com"}},
        data: {
          authorName: "Miembro",
          text: "Me gustaría que las sugerencias lleguen por correo.",
        },
      });
    });

    assert.equal(result.success, true);
    assert.equal(result.emailStatus, "queued");

    const mails = fakeFirestore.documentsUnder("mail");
    assert.equal(mails.length, 1);
    assert.deepEqual(mails[0].data.to, ["sundayselfie2026@gmail.com"]);
  } finally {
    if (previousRecipient === undefined) {
      delete process.env.SUNDAY_SELFIE_CEO_EMAIL;
    } else {
      process.env.SUNDAY_SELFIE_CEO_EMAIL = previousRecipient;
    }

    if (previousSuggestionsRecipient === undefined) {
      delete process.env.SUGGESTIONS_TO_EMAIL;
    } else {
      process.env.SUGGESTIONS_TO_EMAIL = previousSuggestionsRecipient;
    }
  }
});

test("suggestions fail visibly when email cannot be queued", async () => {
  const fakeFirestore = new FakeFirestore();
  const originalSetDoc = fakeFirestore.setDoc.bind(fakeFirestore);
  fakeFirestore.setDoc = (ref, data, options) => {
    if (ref.path.startsWith("mail/")) {
      throw new Error("mail write failed");
    }

    originalSetDoc(ref, data, options);
  };

  await assert.rejects(
    () => withFakeFirestore(fakeFirestore, () => {
      return callableFunctions.enviarSugerencia.run({
        auth: {uid: "member-user", token: {email: "member@example.com"}},
        data: {
          authorName: "Miembro",
          text: "Me gustaría saber si falla el correo.",
        },
      });
    }),
    (error) => {
      assert.equal(error.code, "internal");
      assert.match(error.message, /no se pudo preparar el correo/);
      return true;
    }
  );

  const suggestions = fakeFirestore.documentsUnder("suggestions");
  assert.equal(suggestions.length, 1);
  assert.equal(suggestions[0].data.emailQueued, false);
  assert.equal(suggestions[0].data.emailStatus, "failed");
});

test("rewarded ad allows sending another buzz to an already reminded member", async (t) => {
  t.mock.timers.enable({
    apis: ["Date"],
    now: new Date("2026-06-14T12:00:00.000Z"),
  });

  const weekKey = "2026-W24";
  const remindersPath = `groups/group-id/weeks/${weekKey}/reminders`;
  const existingReminderPath = `${remindersPath}/sender-user_target-user`;
  const fakeFirestore = new FakeFirestore({
    "groups/group-id": {
      name: "Sunday Selfie",
      deleted: false,
    },
    "groups/group-id/members/sender-user": {
      effectiveName: "Sender",
    },
    "groups/group-id/members/target-user": {
      effectiveName: "Target",
    },
    [existingReminderPath]: {
      type: "friend_reminder",
      groupId: "group-id",
      weekKey,
      senderUid: "sender-user",
      targetUid: "target-user",
      rewardedAdUsed: false,
    },
  });

  const result = await withFakeFirestore(fakeFirestore, () => {
    return callableFunctions.enviarZumbidoSelfie.run({
      auth: {uid: "sender-user", token: {}},
      data: {
        groupId: "group-id",
        targetUid: "target-user",
        rewardedAdWatched: true,
      },
    });
  });

  assert.deepEqual(result, {
    success: true,
    groupId: "group-id",
    weekKey,
    rewardedAdUsed: true,
  });

  const reminders = fakeFirestore.documentsUnder(remindersPath);
  assert.equal(reminders.length, 2);

  const extraReminder = reminders.find((doc) => {
    return doc.ref.path !== existingReminderPath;
  });
  assert.ok(extraReminder);
  assert.equal(extraReminder.data.senderUid, "sender-user");
  assert.equal(extraReminder.data.targetUid, "target-user");
  assert.equal(extraReminder.data.rewardedAdUsed, true);
});
