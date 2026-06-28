// honua.io lead-capture forms router.
//
// Receives form submissions (direct JSON/form-encoded POSTs, or FormSubmit
// `_webhook` forwards) and routes them into the Attio CRM:
//   POST /contact    -> upsert Person, upsert Company, attribution Note
//   POST /waitlist   -> upsert Person, upsert Company, add to "Cloud Waitlist" list
//   POST /newsletter -> upsert Person, add to "Newsletter" list
//
// No external dependencies: native fetch + the AWS SDK v3 bundled in the
// Node.js Lambda runtime (Secrets Manager client only).

import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";

const ATTIO_BASE = "https://api.attio.com/v2";
const LOOPS_CONTACT_CREATE = "https://app.loops.so/api/v1/contacts/create";
const MAX_BODY_BYTES = 32 * 1024;
// Outbound HTTP resiliency: bound every upstream call so a hung connection can
// never stall the Lambda, and retry transient failures (429/5xx/network) with
// backoff so a momentary upstream blip does not drop a lead.
const FETCH_TIMEOUT_MS = 3000;
const FETCH_MAX_ATTEMPTS = 3;
const FETCH_BACKOFF_MS = 250;
// Wall-clock budget shared by every upstream call within a single invocation.
// The Lambda timeout (main.tf) is 29s, leaving ample margin so the handler
// always returns its own structured 502 + "lead routing failed" log before
// Lambda hard-kills the function. A persistently slow/hung upstream therefore
// aborts the whole chain here -- under our control -- instead of letting the
// cumulative per-call retry budget (3 sequential chains for /contact, 4 for
// /waitlist) blow the Lambda deadline mid-retry, which would skip the handler's
// try/catch and surface a generic Lambda 502 to the client with no log line.
const INVOCATION_DEADLINE_MS = 12000;
// Set per invocation in handler(); shared by all fetchWithRetry calls so a
// single hung upstream cannot exhaust the Lambda deadline. AbortSignal-based,
// so it composes with the per-attempt timeout via AbortSignal.any().
let invocationDeadlineSignal;
const HONEYPOT_FIELDS = ["_honey", "_gotcha", "honeypot"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

// Common personal-email providers: submissions from these domains do not
// produce Company records.
const FREEMAIL_DOMAINS = new Set([
  "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk", "ymail.com",
  "hotmail.com", "hotmail.co.uk", "outlook.com", "live.com", "msn.com",
  "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com",
  "pm.me", "gmx.com", "gmx.de", "gmx.net", "mail.com", "yandex.com",
  "yandex.ru", "zoho.com", "fastmail.com", "hey.com", "duck.com", "qq.com",
  "163.com", "126.com", "naver.com", "web.de", "t-online.de", "comcast.net",
  "verizon.net", "att.net", "sbcglobal.net", "bellsouth.net", "cox.net",
  "btinternet.com", "orange.fr", "free.fr", "wanadoo.fr",
]);

const ATTRIBUTION_FIELDS = [
  "lead_landing_page", "lead_current_page", "lead_referrer",
  "lead_utm_source", "lead_utm_medium", "lead_utm_campaign",
  "lead_utm_term", "lead_utm_content",
  "lead_cta_label", "lead_cta_page", "lead_cta_href",
];

const secretsClient = new SecretsManagerClient({});
let cachedAttioKey;
let cachedLoopsKey;

async function readSecret(secretArn) {
  if (!secretArn) return "";
  const out = await secretsClient.send(
    new GetSecretValueCommand({ SecretId: secretArn }),
  );
  const value = (out.SecretString ?? "").trim();
  return value === "REPLACE_ME" ? "" : value;
}

async function getAttioKey() {
  if (cachedAttioKey) return cachedAttioKey;
  const key = await readSecret(process.env.ATTIO_SECRET_ARN);
  if (!key) {
    throw new Error("Attio API key secret is not configured");
  }
  cachedAttioKey = key;
  return key;
}

async function getLoopsKey() {
  if (cachedLoopsKey !== undefined) return cachedLoopsKey;
  cachedLoopsKey = await readSecret(process.env.LOOPS_SECRET_ARN);
  return cachedLoopsKey;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// fetch wrapper: per-attempt timeout via AbortSignal, plus bounded retry with
// exponential backoff on 429/5xx and network/timeout errors. Every attempt is
// also bounded by the shared per-invocation deadline (invocationDeadlineSignal)
// so the cumulative retry budget can never exceed the Lambda timeout. Returns
// the final Response (the caller decides how to treat non-retryable statuses
// like 4xx).
async function fetchWithRetry(url, options = {}) {
  let lastError;
  for (let attempt = 1; attempt <= FETCH_MAX_ATTEMPTS; attempt += 1) {
    // Stop before issuing a request we know the invocation deadline has already
    // passed for, so the handler's catch can run and emit its structured 502.
    if (invocationDeadlineSignal?.aborted) {
      throw invocationDeadlineSignal.reason ?? new Error("invocation deadline exceeded");
    }
    const signals = [AbortSignal.timeout(FETCH_TIMEOUT_MS)];
    if (invocationDeadlineSignal) signals.push(invocationDeadlineSignal);
    try {
      const res = await fetch(url, {
        ...options,
        signal: AbortSignal.any(signals),
      });
      if ((res.status === 429 || res.status >= 500) && attempt < FETCH_MAX_ATTEMPTS) {
        await sleep(FETCH_BACKOFF_MS * 2 ** (attempt - 1));
        continue;
      }
      return res;
    } catch (err) {
      lastError = err;
      // The overall deadline fired -- further retries are pointless and would
      // risk overrunning the Lambda timeout. Surface it to the handler now.
      if (invocationDeadlineSignal?.aborted) {
        throw invocationDeadlineSignal.reason ?? err;
      }
      if (attempt < FETCH_MAX_ATTEMPTS) {
        await sleep(FETCH_BACKOFF_MS * 2 ** (attempt - 1));
        continue;
      }
    }
  }
  throw lastError ?? new Error(`fetch failed after ${FETCH_MAX_ATTEMPTS} attempts`);
}

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

function parseBody(event) {
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body ?? "", "base64").toString("utf8")
    : (event.body ?? "");
  if (Buffer.byteLength(raw, "utf8") > MAX_BODY_BYTES) {
    return { error: "payload_too_large" };
  }
  const contentType =
    (event.headers?.["content-type"] ?? "").split(";")[0].trim().toLowerCase();

  let fields = {};
  if (contentType === "application/x-www-form-urlencoded") {
    fields = Object.fromEntries(new URLSearchParams(raw));
  } else {
    let parsed;
    try {
      parsed = JSON.parse(raw || "{}");
    } catch {
      return { error: "invalid_body" };
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { error: "invalid_body" };
    }
    // FormSubmit webhooks wrap the submission in `form_data`.
    if (parsed.form_data && typeof parsed.form_data === "object") {
      parsed = parsed.form_data;
    }
    fields = parsed;
  }

  const clean = {};
  for (const [key, value] of Object.entries(fields)) {
    if (typeof value === "string") clean[key] = value.trim();
    else if (typeof value === "number" || typeof value === "boolean") {
      clean[key] = String(value);
    }
  }
  return { fields: clean };
}

function resolveFormType(event, fields) {
  const path = (event.rawPath ?? "").replace(/\/+$/, "").toLowerCase();
  for (const type of ["contact", "waitlist", "newsletter"]) {
    if (path.endsWith(`/${type}`)) return type;
  }
  const explicit = (fields.form_type ?? "").toLowerCase();
  if (["contact", "waitlist", "newsletter"].includes(explicit)) return explicit;
  return null;
}

async function attioFetch(method, path, body) {
  const key = await getAttioKey();
  const res = await fetchWithRetry(`${ATTIO_BASE}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${key}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  if (!res.ok) {
    const err = new Error(
      `Attio ${method} ${path} failed: ${res.status} ${text.slice(0, 500)}`,
    );
    err.status = res.status;
    err.attioCode = json?.code;
    throw err;
  }
  return json;
}

function splitName(name) {
  const parts = name.split(/\s+/).filter(Boolean);
  if (parts.length === 0) return null;
  return {
    first_name: parts[0],
    last_name: parts.length > 1 ? parts.slice(1).join(" ") : "",
    full_name: name,
  };
}

async function upsertPerson(email, name) {
  const values = { email_addresses: [{ email_address: email }] };
  const personName = name ? splitName(name) : null;
  if (personName) values.name = [personName];
  const out = await attioFetch(
    "PUT",
    "/objects/people/records?matching_attribute=email_addresses",
    { data: { values } },
  );
  return out.data.id.record_id;
}

async function upsertCompany(email, companyName) {
  const domain = email.split("@")[1];
  if (!domain || FREEMAIL_DOMAINS.has(domain)) return null;
  const values = { domains: [{ domain }] };
  if (companyName) values.name = [{ value: companyName }];
  const out = await attioFetch(
    "PUT",
    "/objects/companies/records?matching_attribute=domains",
    { data: { values } },
  );
  return out.data.id.record_id;
}

async function createContactNote(personRecordId, fields) {
  const lines = [];
  if (fields.message) lines.push(`**Message**\n\n${fields.message}`, "");
  if (fields.company) lines.push(`**Company (as submitted):** ${fields.company}`, "");
  const attribution = ATTRIBUTION_FIELDS.filter((f) => fields[f]);
  if (attribution.length > 0) {
    lines.push("**Attribution**", "");
    // Backtick the field names so Attio's markdown parser does not treat
    // the underscores as emphasis markers.
    for (const field of attribution) lines.push(`- \`${field}\`: ${fields[field]}`);
  }
  if (lines.length === 0) lines.push("(no message or attribution captured)");
  const out = await attioFetch("POST", "/notes", {
    data: {
      parent_object: "people",
      parent_record_id: personRecordId,
      title: "Website contact form (migration assessment)",
      format: "markdown",
      content: lines.join("\n"),
    },
  });
  return out.data.id.note_id;
}

async function assertListEntry(listSlug, personRecordId, entryValues) {
  const body = {
    data: {
      parent_record_id: personRecordId,
      parent_object: "people",
      entry_values: entryValues ?? {},
    },
  };
  try {
    const out = await attioFetch("PUT", `/lists/${listSlug}/entries`, body);
    return out.data.id.entry_id;
  } catch (err) {
    // Record already has multiple entries in this list — treat as present.
    if (err.attioCode === "multiple_match_results" || /MULTIPLE_MATCH/i.test(err.message)) {
      console.log(JSON.stringify({ msg: "list entry already present (multiple matches)", list: listSlug }));
      return null;
    }
    // Bad entry value (e.g. unknown select option) — retry without values so
    // the lead still lands on the list.
    if (err.status === 400 && entryValues && Object.keys(entryValues).length > 0) {
      console.log(JSON.stringify({ msg: "retrying list entry without entry_values", list: listSlug, error: err.message.slice(0, 300) }));
      return assertListEntry(listSlug, personRecordId, {});
    }
    throw err;
  }
}

function waitlistEntryValues(fields) {
  const values = {};
  if (fields.workload_signal) values.workload_signal = fields.workload_signal;
  if (fields.source_stack) values.source_stack = fields.source_stack;
  return values;
}

async function subscribeToLoops(email, fields, formType) {
  let apiKey;
  try {
    apiKey = await getLoopsKey();
  } catch (err) {
    console.error(JSON.stringify({ msg: "loops secret read error", error: String(err).slice(0, 300) }));
    return;
  }
  if (!apiKey) return;
  try {
    const body = { email, source: `honua.io ${formType}` };
    const name = fields.name ? splitName(fields.name) : null;
    if (name?.first_name) body.firstName = name.first_name;
    if (name?.last_name) body.lastName = name.last_name;
    const res = await fetchWithRetry(LOOPS_CONTACT_CREATE, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    // 409 = contact already exists; not an error for our purposes.
    if (!res.ok && res.status !== 409) {
      console.error(JSON.stringify({ msg: "loops subscribe failed", status: res.status }));
    }
  } catch (err) {
    console.error(JSON.stringify({ msg: "loops subscribe error", error: String(err).slice(0, 300) }));
  }
}

export async function handler(event) {
  // Start the shared wall-clock budget for all upstream calls in this
  // invocation. Bounding the cumulative retry budget below the Lambda timeout
  // guarantees the handler's try/catch runs and returns a structured 502
  // (+ "lead routing failed" log) rather than being hard-killed mid-retry.
  invocationDeadlineSignal = AbortSignal.timeout(INVOCATION_DEADLINE_MS);

  const method = event.requestContext?.http?.method ?? "";
  if (method === "OPTIONS") return response(204, {});
  if (method !== "POST") return response(405, { ok: false, error: "method_not_allowed" });

  const { fields, error } = parseBody(event);
  if (error === "payload_too_large") return response(413, { ok: false, error });
  if (error) return response(400, { ok: false, error });

  const formType = resolveFormType(event, fields);
  if (!formType) return response(404, { ok: false, error: "unknown_form" });

  // Honeypot: accept silently, write nothing.
  if (HONEYPOT_FIELDS.some((f) => fields[f])) {
    console.log(JSON.stringify({ msg: "honeypot drop", formType }));
    return response(200, { ok: true });
  }

  const email = (fields.email ?? "").toLowerCase();
  if (!EMAIL_RE.test(email)) return response(400, { ok: false, error: "invalid_email" });

  try {
    const personRecordId = await upsertPerson(email, fields.name);

    let companyRecordId = null;
    if (formType !== "newsletter") {
      try {
        companyRecordId = await upsertCompany(email, fields.company);
      } catch (err) {
        // Company enrichment is best-effort; never lose the lead over it.
        console.error(JSON.stringify({ msg: "company upsert failed", error: String(err).slice(0, 300) }));
      }
    }

    let noteId = null;
    let entryId = null;
    if (formType === "contact") {
      noteId = await createContactNote(personRecordId, fields);
    } else if (formType === "waitlist") {
      entryId = await assertListEntry(
        process.env.ATTIO_WAITLIST_LIST,
        personRecordId,
        waitlistEntryValues(fields),
      );
      await subscribeToLoops(email, fields, formType);
    } else if (formType === "newsletter") {
      entryId = await assertListEntry(process.env.ATTIO_NEWSLETTER_LIST, personRecordId, {});
      await subscribeToLoops(email, fields, formType);
    }

    console.log(JSON.stringify({
      msg: "lead routed",
      formType,
      email,
      personRecordId,
      companyRecordId,
      noteId,
      entryId,
    }));
    return response(200, { ok: true });
  } catch (err) {
    console.error(JSON.stringify({ msg: "lead routing failed", formType, error: String(err).slice(0, 500) }));
    return response(502, { ok: false, error: "upstream_error" });
  }
}
