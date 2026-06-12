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

async function getAttioKey() {
  if (cachedAttioKey) return cachedAttioKey;
  const out = await secretsClient.send(
    new GetSecretValueCommand({ SecretId: process.env.ATTIO_SECRET_ARN }),
  );
  const key = (out.SecretString ?? "").trim();
  if (!key || key === "REPLACE_ME") {
    throw new Error("Attio API key secret is not configured");
  }
  cachedAttioKey = key;
  return key;
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
  const res = await fetch(`${ATTIO_BASE}${path}`, {
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
  const apiKey = (process.env.LOOPS_API_KEY ?? "").trim();
  if (!apiKey) return;
  try {
    const body = { email, source: `honua.io ${formType}` };
    const name = fields.name ? splitName(fields.name) : null;
    if (name?.first_name) body.firstName = name.first_name;
    if (name?.last_name) body.lastName = name.last_name;
    const res = await fetch(LOOPS_CONTACT_CREATE, {
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
