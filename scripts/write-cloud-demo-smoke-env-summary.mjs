#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const args = new Map();

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) {
      throw new Error(`Unexpected positional argument: ${arg}`);
    }

    if (arg === "--strict-required-env") {
      args.set(arg, true);
      continue;
    }

    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${arg}`);
    }
    args.set(arg, value);
    index += 1;
  }

  return args;
}

function requireArg(args, name) {
  const value = args.get(name);
  if (!value || typeof value !== "string") {
    throw new Error(`Missing required argument: ${name}`);
  }
  return value;
}

function readEnv(name) {
  if (!name) return undefined;
  const value = process.env[name];
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

// Validate the manifest shape up front so a contract drift in the upstream SDK
// manifest fails with a clear, actionable error instead of an opaque
// "Cannot read properties of undefined" deep inside main().
function assertManifestShape(manifest, manifestPath) {
  const fail = (detail) => {
    throw new Error(`Cloud-demo manifest contract drift in ${manifestPath}: ${detail}`);
  };
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
    fail("expected a JSON object at the top level");
  }
  if (!Array.isArray(manifest.profiles)) {
    fail("`profiles` must be an array");
  }
  if (manifest.globalEnv === null || typeof manifest.globalEnv !== "object" || Array.isArray(manifest.globalEnv)) {
    fail("`globalEnv` must be an object");
  }
  if (typeof manifest.globalEnv.baseUrl !== "string" || manifest.globalEnv.baseUrl.trim() === "") {
    fail("`globalEnv.baseUrl` must be a non-empty string (the base-URL env var name)");
  }
}

function collectEnvNames(value, names = new Set()) {
  if (typeof value === "string") {
    if (/^(?:HONUA|VITE)_/.test(value)) {
      names.add(value);
    }
    return names;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      collectEnvNames(item, names);
    }
    return names;
  }

  if (value && typeof value === "object") {
    for (const nested of Object.values(value)) {
      collectEnvNames(nested, names);
    }
  }

  return names;
}

function unique(values) {
  return [...new Set(values)].sort();
}

function envPresence(name) {
  return {
    name,
    present: Boolean(readEnv(name)),
    browserExposed: name.startsWith("VITE_"),
  };
}

function appendStepSummary(summary, checks) {
  const summaryFile = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryFile) return;

  const missingProfiles = summary.profiles.filter((profile) => profile.missingRequiredEnv.length > 0);
  const lines = [
    "## Honua Cloud Demo Smoke Wiring",
    "",
    `- Manifest: \`${summary.manifest.format}\` from \`${summary.manifest.ownerRepo}\``,
    `- Profiles: ${summary.manifest.profileCount}`,
    `- Base URL env: \`${summary.baseUrl.env}\` ${summary.baseUrl.present ? "present" : "missing"}`,
    `- Writable smoke: ${summary.writable.writesEnabled ? "enabled" : "disabled"}`,
    "",
    "### Checks",
    "",
    ...checks.map((check) => `- ${check.ok ? "PASS" : "FAIL"} ${check.name}`),
    "",
  ];

  if (missingProfiles.length > 0) {
    lines.push("### Missing Profile Env", "");
    for (const profile of missingProfiles) {
      lines.push(`- \`${profile.id}\`: ${profile.missingRequiredEnv.map((name) => `\`${name}\``).join(", ")}`);
    }
    lines.push("");
  }

  fs.appendFileSync(summaryFile, `${lines.join("\n")}\n`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifestPath = requireArg(args, "--manifest");
  const outputPath = requireArg(args, "--out");
  const strictRequiredEnv = args.get("--strict-required-env") === true;

  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  assertManifestShape(manifest, manifestPath);
  const allManifestEnvNames = unique(collectEnvNames(manifest));
  const profiles = (manifest.profiles ?? []).map((profile) => ({
    id: profile.id,
    mode: profile.mode,
    requiredEnv: [...(profile.smoke?.requiresEnv ?? [])],
    missingRequiredEnv: (profile.smoke?.requiresEnv ?? []).filter((name) => !readEnv(name)),
  }));
  const missingRequiredEnv = unique(profiles.flatMap((profile) => profile.missingRequiredEnv));
  const writableProfile = manifest.profiles.find((profile) => profile.mode === "writable-guarded");
  const safeguards = writableProfile?.writeSafeguards;
  const writesEnabled =
    Boolean(safeguards) && readEnv(safeguards.allowWritesEnv) === safeguards.requiredAllowWritesValue;
  const writeSafeguardEnv = safeguards
    ? [safeguards.allowWritesEnv, safeguards.writeTokenEnv, safeguards.resetTokenEnv, safeguards.resetUrlEnv]
    : [];
  const missingWriteSafeguards =
    safeguards && writesEnabled
      ? [safeguards.writeTokenEnv, safeguards.resetTokenEnv, safeguards.resetUrlEnv].filter((name) => !readEnv(name))
      : [];
  const browserExposedSafeguards = writeSafeguardEnv.filter((name) => name.startsWith("VITE_"));
  const runtimeViteResetOrWriteEnv = Object.keys(process.env)
    .filter((name) => name.startsWith("VITE_"))
    .filter((name) => /(?:RESET|WRITE_TOKEN|ALLOW_WRITES)/.test(name))
    .filter((name) => Boolean(readEnv(name)))
    .sort();

  const readCredentialEnv = allManifestEnvNames.filter(
    (name) =>
      /(?:API_KEY|BEARER_TOKEN)$/.test(name) &&
      !/(?:WRITE_TOKEN|RESET_TOKEN)/.test(name),
  );
  const realtimeEnv = allManifestEnvNames.filter((name) => /(?:INCIDENT_TRANSPORT|INCIDENT_STREAM_URL)$/.test(name));
  const resetEnv = safeguards ? [safeguards.resetTokenEnv, safeguards.resetUrlEnv] : [];
  const writeEnv = safeguards ? [safeguards.allowWritesEnv, safeguards.writeTokenEnv] : [];

  const summary = {
    generatedAt: new Date().toISOString(),
    manifest: {
      path: manifestPath,
      format: manifest.format,
      issue: manifest.issue,
      ownerRepo: manifest.ownerRepo,
      defaultBaseUrl: manifest.defaultBaseUrl,
      profileCount: (manifest.profiles ?? []).length,
    },
    baseUrl: {
      env: manifest.globalEnv.baseUrl,
      present: Boolean(readEnv(manifest.globalEnv.baseUrl)),
    },
    credentials: {
      read: readCredentialEnv.map(envPresence),
      realtime: realtimeEnv.map(envPresence),
      write: writeEnv.map(envPresence),
      reset: resetEnv.map(envPresence),
    },
    writable: {
      profileId: writableProfile?.id ?? null,
      writesEnabled,
      allowWritesEnv: safeguards?.allowWritesEnv ?? null,
      missingWriteSafeguards,
      browserExposedSafeguards,
      runtimeViteResetOrWriteEnv,
    },
    profiles,
    missingRequiredEnv,
  };

  const checks = [
    {
      name: "write and reset safeguard env names are server-side",
      ok: browserExposedSafeguards.length === 0,
    },
    {
      name: "runtime has no populated VITE reset/write safeguard env",
      ok: runtimeViteResetOrWriteEnv.length === 0,
    },
    {
      name: "write/reset secrets are present when writable smoke is enabled",
      ok: missingWriteSafeguards.length === 0,
    },
    {
      name: "required seeded profile env is present",
      ok: missingRequiredEnv.length === 0,
      strict: strictRequiredEnv,
    },
  ];
  summary.checks = checks;

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(summary, null, 2)}\n`);
  appendStepSummary(summary, checks);

  console.log(`Cloud demo smoke env summary written to ${outputPath}`);
  if (missingRequiredEnv.length > 0) {
    console.log(`Missing required profile env: ${missingRequiredEnv.join(", ")}`);
  }

  const failedChecks = checks.filter((check) => !check.ok && (check.strict || check.name !== "required seeded profile env is present"));
  if (failedChecks.length > 0) {
    for (const check of failedChecks) {
      console.error(`Failed: ${check.name}`);
    }
    process.exit(1);
  }
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
