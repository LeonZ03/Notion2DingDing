import assert from "node:assert/strict";
import test from "node:test";

import {
  createRequest,
  isNativeResponse,
  PROTOCOL_VERSION,
} from "../../dist/edge-extension/protocol.js";

test("createRequest creates a versioned request", () => {
  const request = createRequest("health.check", {});

  assert.equal(request.protocolVersion, PROTOCOL_VERSION);
  assert.equal(request.method, "health.check");
  assert.ok(request.requestId.length > 0);
});

test("isNativeResponse rejects incompatible responses", () => {
  assert.equal(
    isNativeResponse({ protocolVersion: 2, requestId: "1", ok: true }),
    false,
  );
  assert.equal(
    isNativeResponse({ protocolVersion: 1, requestId: "1", ok: true }),
    true,
  );
});
