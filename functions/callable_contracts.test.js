const assert = require("node:assert/strict");
const test = require("node:test");

const callableFunctions = require("./index.js");

const callableNames = [
  "crearGrupo",
  "registrarSelfie",
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
  "listarReportesGrupo",
  "resolverReporte",
  "borrarCuenta",
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
