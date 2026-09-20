const DB_NAME = "openhealth-holder-keys";
const DB_VERSION = 1;
const STORE_NAME = "holders";

function requireWebCrypto() {
  if (!window.isSecureContext || !window.crypto?.subtle) {
    throw new Error("webcrypto_secure_context_required");
  }
}

function openDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME, { keyPath: "principal" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function withStore(mode, operation) {
  const db = await openDb();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction(STORE_NAME, mode);
      const store = transaction.objectStore(STORE_NAME);
      let request;
      try {
        request = operation(store);
      } catch (error) {
        reject(error);
        return;
      }
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  } finally {
    db.close();
  }
}

function bytesToBase64Url(bytes) {
  let binary = "";
  for (const value of bytes) {
    binary += String.fromCharCode(value);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function utf8Base64Url(value) {
  return bytesToBase64Url(new TextEncoder().encode(value));
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    const entries = Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`);
    return `{${entries.join(",")}}`;
  }
  return JSON.stringify(value);
}

async function publicIdentity(publicKey) {
  const jwk = await crypto.subtle.exportKey("jwk", publicKey);
  if (jwk.kty !== "OKP" || jwk.crv !== "Ed25519" || !jwk.x) {
    throw new Error("unexpected_holder_public_key");
  }

  const publicJwk = {
    kty: "OKP",
    crv: "Ed25519",
    x: jwk.x,
  };
  const thumbprintInput = new TextEncoder().encode(
    canonicalJson(publicJwk)
  );
  const thumbprint = new Uint8Array(
    await crypto.subtle.digest("SHA-256", thumbprintInput)
  );

  return {
    publicJwk,
    pub_b64: jwk.x,
    jkt: bytesToBase64Url(thumbprint),
  };
}

export async function getHolderIdentity(principal) {
  requireWebCrypto();
  return withStore("readonly", (store) => store.get(principal));
}

export async function createHolderIdentity(principal) {
  requireWebCrypto();
  const subject = String(principal || "").trim();
  if (!subject) {
    throw new Error("missing_principal");
  }

  const existing = await getHolderIdentity(subject);
  if (existing) {
    return existing;
  }

  const { publicKey, privateKey } = await crypto.subtle.generateKey(
    { name: "Ed25519" },
    false,
    ["sign", "verify"]
  );
  const identity = await publicIdentity(publicKey);
  const record = {
    principal: subject,
    privateKey,
    publicKey,
    publicJwk: identity.publicJwk,
    pub_b64: identity.pub_b64,
    jkt: identity.jkt,
    created_at: new Date().toISOString(),
  };

  await withStore("readwrite", (store) => store.put(record));
  return record;
}

export async function deleteHolderIdentity(principal) {
  requireWebCrypto();
  await withStore("readwrite", (store) => store.delete(principal));
}

export async function holderEnrollmentRecord(principal, orgId) {
  const identity = await getHolderIdentity(principal);
  if (!identity) {
    throw new Error(`holder_key_missing:${principal}`);
  }
  return {
    org_id: orgId,
    member_id: principal,
    sub: principal,
    pub_b64: identity.pub_b64,
    jkt: identity.jkt,
  };
}

export async function signHolderDpop(
  principal,
  {
    htu,
    htm = "POST",
    jti,
    nonce,
    envelopeId,
    governedValueId = null,
  }
) {
  const identity = await getHolderIdentity(principal);
  if (!identity) {
    throw new Error(`holder_key_missing:${principal}`);
  }
  if (!htu || !jti || !nonce || !envelopeId) {
    throw new Error("missing_dpop_binding");
  }

  const header = {
    typ: "dpop+jwt",
    alg: "EdDSA",
    jwk: identity.publicJwk,
  };
  const claims = {
    htu,
    htm: String(htm).toUpperCase(),
    iat: Math.floor(Date.now() / 1000),
    jti,
    nonce,
    envelope_id: envelopeId,
    ...(governedValueId
      ? { governed_value_id: governedValueId }
      : {}),
  };
  const encodedHeader = utf8Base64Url(canonicalJson(header));
  const encodedClaims = utf8Base64Url(canonicalJson(claims));
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "Ed25519" },
      identity.privateKey,
      new TextEncoder().encode(signingInput)
    )
  );
  return `${signingInput}.${bytesToBase64Url(signature)}`;
}

export async function getHolderCredential(principal, envelopeId) {
  const identity = await getHolderIdentity(principal);
  if (!identity) {
    return null;
  }
  return identity.credentials?.[envelopeId] || null;
}

export async function putHolderCredential(
  principal,
  envelopeId,
  credential
) {
  const identity = await getHolderIdentity(principal);
  if (!identity) {
    throw new Error(`holder_key_missing:${principal}`);
  }
  if (!envelopeId || !credential?.ect) {
    throw new Error("invalid_holder_credential");
  }

  const record = {
    ...identity,
    credentials: {
      ...(identity.credentials || {}),
      [envelopeId]: {
        ect: credential.ect,
        expires_at: credential.expires_at || null,
        stored_at: new Date().toISOString(),
      },
    },
  };
  await withStore("readwrite", (store) => store.put(record));
  return record.credentials[envelopeId];
}

export async function deleteHolderCredential(principal, envelopeId) {
  const identity = await getHolderIdentity(principal);
  if (!identity) {
    return;
  }
  const credentials = { ...(identity.credentials || {}) };
  delete credentials[envelopeId];
  await withStore(
    "readwrite",
    (store) => store.put({ ...identity, credentials })
  );
}
