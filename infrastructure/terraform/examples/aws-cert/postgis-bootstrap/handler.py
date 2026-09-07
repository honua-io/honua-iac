# Copyright (c) Honua. All rights reserved.
# Licensed under the Elastic License 2.0. See LICENSE in the project root.
#
# One-shot, in-VPC PostGIS bootstrap for the aws-cert stack.
#
# Honua's first schema migration (001_CreateHonuaSchema.sql) creates GEOMETRY
# columns and therefore requires the postgis extension to already exist, but
# the cert RDS instance lives in private subnets — the apply host has no
# network path to run `CREATE EXTENSION`. This Lambda runs inside the VPC,
# reads the connection string from Secrets Manager (reached over the VPC's NAT
# gateway), and idempotently enables postgis + postgis_raster as the RDS master
# user. It is invoked once by Terraform (aws_lambda_invocation) right after the
# database is created and before the server is exercised.
#
# It has two additional modes, both invoked by Terraform for the same reason
# (the database is reachable only from inside the VPC):
#
#   statements/query — the maintenance escape hatch: a caller supplies explicit
#     statements and an optional trailing query.
#   script — apply a whole SQL file (e.g. honua-server's client-compat
#     certification fixture, tests/seed/client-compat-v1.sql) fetched from a
#     commit-pinned https URL and verified against a caller-supplied sha256,
#     as one all-or-nothing transaction. See postgis-bootstrap.tf.

import hashlib
import io
import os
import re
import ssl
import urllib.request

# Amazon RDS global CA bundle, vendored into the deployment zip at build time
# (see postgis-bootstrap.tf). Sits next to this module at the Lambda task root.
_RDS_CA_BUNDLE = os.path.join(os.path.dirname(__file__), "rds-global-bundle.pem")

# Guardrails for `script` mode. The certification fixture is ~52 KB; the cap is
# a sanity bound on what a single bootstrap invocation may pull over NAT, not a
# tuning knob.
_MAX_SCRIPT_BYTES = 8 * 1024 * 1024
_SCRIPT_FETCH_TIMEOUT_SECONDS = 60

# A statement that opens, closes or checkpoints a transaction would silently
# break the all-or-nothing contract this mode promises, so a script containing
# one at the top level is refused rather than half-applied.
_TRANSACTION_CONTROL_KEYWORDS = frozenset(
    {"begin", "start", "commit", "end", "rollback", "savepoint", "release", "abort"}
)


def _parse_connection_string(connection_string):
    """Parse an ADO.NET-style 'Key=Value;Key=Value' connection string."""
    parts = {}
    for chunk in connection_string.split(";"):
        if "=" in chunk:
            key, value = chunk.split("=", 1)
            parts[key.strip()] = value.strip()
    return parts


def _is_identifier_char(char):
    """True for characters PostgreSQL allows inside an unquoted identifier.

    PostgreSQL's lexer allows `$` inside (but not at the start of) an
    identifier, and its longest-match rule means `a$$b` lexes as the single
    identifier `a$$b`, not as an empty dollar-quote. The splitter reproduces
    that by only opening a dollar quote when the `$` does not directly follow
    an identifier character.
    """
    return char.isalnum() or char == "_" or char == "$" or ord(char) >= 128


def _match_dollar_quote_tag(script, index):
    """Return the dollar-quote delimiter starting at `index`, or None.

    A delimiter is `$`, an optional tag, and `$`. The tag follows identifier
    rules (it may not start with a digit), so `$1` is a parameter placeholder
    and `$2$` is not a delimiter either.
    """
    if script[index] != "$":
        return None
    cursor = index + 1
    while cursor < len(script):
        char = script[cursor]
        if char == "$":
            return script[index : cursor + 1]
        is_first = cursor == index + 1
        if char.isdigit() and is_first:
            return None
        if not (char.isalpha() or char == "_" or char.isdigit() or ord(char) >= 128):
            return None
        cursor += 1
    return None


def split_sql_statements(script):
    """Split a SQL script into individual statements on top-level semicolons.

    Semicolons inside single-quoted strings (including `''` and, for `E''`
    strings, backslash escapes), double-quoted identifiers, dollar-quoted
    bodies, `--` line comments and (nestable) `/* */` block comments do not
    terminate a statement. Whitespace/comment-only fragments are dropped, so a
    trailing `;` or a closing comment does not produce an empty statement.

    Raises ValueError if the script ends inside a string, identifier, dollar
    quote or block comment — an unterminated construct means the split is a
    guess, and guessing here would apply a truncated statement.
    """
    statements = []
    start = 0
    index = 0
    length = len(script)
    while index < length:
        char = script[index]

        if char == "-" and script.startswith("--", index):
            newline = script.find("\n", index)
            index = length if newline == -1 else newline + 1
            continue

        if char == "/" and script.startswith("/*", index):
            depth = 1
            index += 2
            while index < length and depth:
                if script.startswith("/*", index):
                    depth += 1
                    index += 2
                elif script.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError("unterminated block comment in SQL script")
            continue

        if char == "'":
            # `E'...'` (and `e'...'`) honour backslash escapes; plain literals
            # do not, under the standard_conforming_strings default.
            escapes = index > 0 and script[index - 1] in "Ee" and (
                index == 1 or not _is_identifier_char(script[index - 2])
            )
            index += 1
            while index < length:
                if escapes and script[index] == "\\" and index + 1 < length:
                    index += 2
                    continue
                if script[index] == "'":
                    if script.startswith("''", index):
                        index += 2
                        continue
                    index += 1
                    break
                index += 1
            else:
                raise ValueError("unterminated string literal in SQL script")
            continue

        if char == '"':
            index += 1
            while index < length:
                if script[index] == '"':
                    if script.startswith('""', index):
                        index += 2
                        continue
                    index += 1
                    break
                index += 1
            else:
                raise ValueError("unterminated quoted identifier in SQL script")
            continue

        if char == "$" and not (index > 0 and _is_identifier_char(script[index - 1])):
            tag = _match_dollar_quote_tag(script, index)
            if tag is not None:
                closing = script.find(tag, index + len(tag))
                if closing == -1:
                    raise ValueError(
                        f"unterminated dollar-quoted string ({tag}) in SQL script"
                    )
                index = closing + len(tag)
                continue

        if char == ";":
            statements.append(script[start:index])
            index += 1
            start = index
            continue

        index += 1

    statements.append(script[start:])
    trimmed = (fragment[_sql_start(fragment) :].strip() for fragment in statements)
    return [statement for statement in trimmed if statement]


def _sql_start(fragment):
    """Index of the first SQL character in `fragment`, past comments/whitespace.

    Returns len(fragment) for a fragment that is only whitespace and comments —
    what a trailing `;`, a file-ending comment or a blank line between
    statements produces. Splitting on the semicolon leaves the preceding
    statement's trailing comment attached to the NEXT fragment, so trimming
    here is also what keeps a statement's echoed summary the SQL rather than
    the banner comment above it.
    """
    index = 0
    length = len(fragment)
    while index < length:
        if fragment[index].isspace():
            index += 1
        elif fragment.startswith("--", index):
            newline = fragment.find("\n", index)
            index = length if newline == -1 else newline + 1
        elif fragment.startswith("/*", index):
            depth = 1
            index += 2
            while index < length and depth:
                if fragment.startswith("/*", index):
                    depth += 1
                    index += 2
                elif fragment.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            break
    return index


def _leading_keyword(statement):
    """First bare word of a statement, lowercased, skipping leading comments."""
    index = _sql_start(statement)
    end = index
    while end < len(statement) and (
        statement[end].isalpha() or statement[end] == "_"
    ):
        end += 1
    return statement[index:end].lower()


def _assert_no_transaction_control(statements):
    for position, statement in enumerate(statements):
        keyword = _leading_keyword(statement)
        # `PREPARE TRANSACTION` ends the current transaction; a plain `PREPARE`
        # (a prepared statement) does not, so only the two-word form counts.
        if keyword == "prepare" and re.match(
            r"prepare\s+transaction\b", " ".join(statement.split()), re.IGNORECASE
        ):
            keyword = "prepare transaction"
        if keyword in _TRANSACTION_CONTROL_KEYWORDS or keyword == "prepare transaction":
            raise ValueError(
                "SQL script manages transactions itself (statement "
                f"{position}: '{keyword}'); script mode applies the whole file "
                "in one transaction and refuses scripts that would break that"
            )


def _summarize(statement):
    """One-line, length-bounded echo of a statement for the invocation result."""
    collapsed = " ".join(statement.split())
    return collapsed if len(collapsed) <= 120 else collapsed[:117] + "..."


def _fetch_script(url):
    """Fetch a SQL script over https, bounded in size. Returns raw bytes."""
    if not url.lower().startswith("https://"):
        raise ValueError("script_url must be an https URL")
    request = urllib.request.Request(url, headers={"Accept": "text/plain"})
    with urllib.request.urlopen(  # noqa: S310 - scheme checked above
        request, timeout=_SCRIPT_FETCH_TIMEOUT_SECONDS
    ) as response:
        # urllib follows redirects; a redirect off https would still be caught
        # by the sha256 gate, but refuse it here so the transport stays stated.
        if not response.url.lower().startswith("https://"):
            raise ValueError(f"script_url redirected off https to {response.url}")
        buffer = io.BytesIO()
        while True:
            chunk = response.read(64 * 1024)
            if not chunk:
                break
            buffer.write(chunk)
            if buffer.tell() > _MAX_SCRIPT_BYTES:
                raise ValueError(
                    f"script at {url} exceeds the {_MAX_SCRIPT_BYTES} byte limit"
                )
        return buffer.getvalue()


def _resolve_script(event):
    """Resolve and verify the script named by the event.

    Returns (sql_text, source_record) or None when the event asks for no
    script. `script_sha256` is mandatory for a fetched script: the URL names
    the bytes, the digest is what proves they are the bytes that were reviewed.
    """
    url = (event.get("script_url") or "").strip()
    inline = event.get("script")
    expected = (event.get("script_sha256") or "").strip().lower()

    if url and inline:
        raise ValueError("provide either script_url or script, not both")
    if not url and not inline:
        return None

    if url:
        if not expected:
            raise ValueError("script_sha256 is required when script_url is set")
        raw = _fetch_script(url)
        source = {"url": url}
    else:
        raw = inline.encode("utf-8") if isinstance(inline, str) else inline
        source = {"url": None, "inline": True}

    actual = hashlib.sha256(raw).hexdigest()
    if expected and actual != expected:
        raise ValueError(
            f"script sha256 mismatch: expected {expected}, fetched {actual}"
        )

    source["bytes"] = len(raw)
    source["sha256"] = actual
    source["sha256_verified"] = bool(expected)
    return raw.decode("utf-8"), source


def _run_script(connection, sql, source):
    """Apply every statement of `sql` inside a single transaction.

    All-or-nothing: the whole file commits or nothing does. pg8000's `run()`
    sends one simple-protocol query per call, so the file has to be split into
    statements first — which also gives a per-statement row count and names the
    failing statement instead of reporting one opaque error for 52 KB of SQL.
    """
    statements = split_sql_statements(sql)
    _assert_no_transaction_control(statements)

    applied = []
    rows_affected = 0
    failing = None
    connection.run("BEGIN")
    try:
        for position, statement in enumerate(statements):
            failing = (position, statement)
            connection.run(statement)
            row_count = connection.row_count
            if row_count is not None and row_count >= 0:
                rows_affected += row_count
            else:
                row_count = None
            applied.append(
                {
                    "index": position,
                    "statement": _summarize(statement),
                    "row_count": row_count,
                }
            )
        failing = None
        connection.run("COMMIT")
    except Exception as error:
        try:
            connection.run("ROLLBACK")
        except Exception:  # noqa: BLE001 - the original failure is what matters
            pass
        where = (
            f"at statement {failing[0]} of {len(statements)} "
            f"('{_summarize(failing[1])}')"
            if failing is not None
            else "while committing"
        )
        raise RuntimeError(
            f"script failed {where}; transaction rolled back, "
            f"nothing applied: {error}"
        ) from error

    return {
        "mode": "script",
        "source": source,
        "committed": True,
        "statement_count": len(statements),
        "rows_affected": rows_affected,
        "statements": applied,
    }


def _connect():
    import boto3
    import pg8000.native

    secret_arn = os.environ["DB_SECRET_ARN"]
    secret = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)
    params = _parse_connection_string(secret["SecretString"])

    # RDS PostgreSQL 15 defaults to rds.force_ssl=1. Verify the RDS server
    # certificate (chain + hostname) against the vendored Amazon RDS global CA
    # bundle so master credentials are never sent over an unverified channel.
    ssl_context = ssl.create_default_context(cafile=_RDS_CA_BUNDLE)
    ssl_context.check_hostname = True
    ssl_context.verify_mode = ssl.CERT_REQUIRED

    return pg8000.native.Connection(
        user=params["Username"],
        password=params["Password"],
        host=params["Host"],
        port=int(params.get("Port", "5432")),
        database=params["Database"],
        ssl_context=ssl_context,
        timeout=30,
    )


def handler(event, context):
    event = event or {}

    # Resolve (fetch + verify) before opening the connection so a bad digest or
    # an unreachable URL costs no database session and applies nothing.
    resolved = _resolve_script(event)

    connection = _connect()
    try:
        if resolved is not None:
            sql, source = resolved
            return _run_script(connection, sql, source)

        # Maintenance escape hatch: a caller may invoke this Lambda with
        # explicit statements (and an optional trailing query) because the RDS
        # instance is reachable only from inside the VPC. Invocation is gated by
        # IAM (lambda:InvokeFunction), the same trust boundary as the default
        # bootstrap behavior.
        statements = event.get("statements")
        query = event.get("query")
        if statements or query:
            results = []
            for statement in statements or []:
                connection.run(statement)
                results.append({"statement": statement[:120], "ok": True})
            payload = {"statements": results}
            if query:
                rows = connection.run(query)
                payload["rows"] = [
                    [None if cell is None else str(cell) for cell in row]
                    for row in rows[:1000]
                ]
            return payload

        for extension in ("postgis", "postgis_raster"):
            connection.run(f"CREATE EXTENSION IF NOT EXISTS {extension}")
        rows = connection.run(
            "SELECT extname, extversion FROM pg_extension WHERE extname LIKE 'postgis%' ORDER BY extname"
        )
    finally:
        connection.close()

    return {"extensions": [{"name": row[0], "version": row[1]} for row in rows]}
