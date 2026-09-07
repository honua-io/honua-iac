#!/usr/bin/env python3
# Copyright (c) Honua. All rights reserved.
# Licensed under the Elastic License 2.0. See LICENSE in the project root.
#
# Unit tests for the postgis-bootstrap Lambda's pure-Python helpers: the SQL
# statement splitter and the script resolution/verification path used by
# `script` mode (see handler.py and postgis-bootstrap.tf).
#
# Deliberately stdlib-only and dependency-free: handler.py imports boto3 and
# pg8000 lazily inside _connect(), so these run on any host with python3 and
# need neither the vendored deployment zip nor a database.
#
#   python3 infrastructure/terraform/examples/aws-cert/postgis-bootstrap/test_handler.py
#
# HONUA_CERT_SEED_SQL may point at honua-server's tests/seed/client-compat-v1.sql
# to additionally split the real certification fixture; the test skips without it.

import hashlib
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import handler  # noqa: E402

split = handler.split_sql_statements


# A miniature of honua-server's tests/seed/client-compat-v1.sql: the same
# constructs (two dollar-quoted bodies, semicolons inside literals, line and
# block comments, a quoted identifier) that make a naive `split(";")` wrong.
FIXTURE = r"""
-- Client compatibility certification seed snapshot; do not split on this ;
CREATE EXTENSION IF NOT EXISTS postgis;

/* Block comment with a semicolon; and a /* nested */ one */
CREATE TABLE honua."odd;name" (
    id SERIAL PRIMARY KEY,
    label TEXT NOT NULL DEFAULT 'a;b',
    note TEXT NOT NULL DEFAULT 'it''s; fine',
    tags TEXT[] NOT NULL DEFAULT '{JSON,GeoJSON}'
);

DO $$
BEGIN
    IF to_regclass('honua.feature_changes') IS NOT NULL THEN
        CREATE UNIQUE INDEX IF NOT EXISTS ux_fc ON honua.feature_changes(event_id);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION honua.seed_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    doc jsonb;
BEGIN
    -- inner comment; with a semicolon
    doc := '{"a": 1}'::jsonb;
    RAISE NOTICE 'nested $$ delimiter; not a terminator';
END;
$body$;

INSERT INTO honua.services (service_name, extent)
VALUES ('test_service', ST_MakeEnvelope(-122.5, 37.7, -122.35, 37.84, 4326));
-- trailing comment, no statement
"""


class SplitterTests(unittest.TestCase):
    def test_splits_on_top_level_semicolons(self):
        self.assertEqual(
            ["SELECT 1", "SELECT 2"], split("SELECT 1; SELECT 2;")
        )

    def test_final_statement_without_trailing_semicolon(self):
        self.assertEqual(["SELECT 1", "SELECT 2"], split("SELECT 1;\nSELECT 2\n"))

    def test_drops_blank_and_comment_only_fragments(self):
        self.assertEqual(
            ["SELECT 1"],
            split(";;\n-- lead\nSELECT 1;\n;\n-- trail\n/* tail */\n"),
        )

    def test_semicolon_inside_string_literal(self):
        self.assertEqual(["SELECT 'a;b'"], split("SELECT 'a;b';"))

    def test_doubled_quote_escape_inside_string(self):
        self.assertEqual(["SELECT 'it''s; fine'"], split("SELECT 'it''s; fine';"))

    def test_backslash_escape_only_applies_to_e_strings(self):
        # In an E'' string `\'` is an escaped quote, so the literal runs on and
        # swallows both semicolons: one statement.
        self.assertEqual(
            [r"SELECT E'a;\'; SELECT 2'"], split(r"SELECT E'a;\'; SELECT 2';")
        )
        # Under the standard_conforming_strings default the same bytes without
        # the E prefix close the literal at that quote, so it is two statements.
        self.assertEqual(
            [r"SELECT 'a;\'", "SELECT 2"], split(r"SELECT 'a;\'; SELECT 2;")
        )

    def test_e_prefix_must_not_be_the_tail_of_an_identifier(self):
        # `value'...'` is an identifier followed by a plain literal, not an
        # escape string, so the backslash is not an escape character.
        self.assertEqual(
            [r"SELECT value'a;\'", "SELECT 2"],
            split(r"SELECT value'a;\'; SELECT 2;"),
        )

    def test_semicolon_inside_line_comment(self):
        self.assertEqual(
            ["SELECT 1", "SELECT 2"], split("SELECT 1; -- trailing; comment\nSELECT 2;")
        )

    def test_semicolon_inside_nested_block_comment(self):
        self.assertEqual(
            ["SELECT 1"], split("/* outer; /* inner; */ still outer; */ SELECT 1;")
        )

    def test_semicolon_inside_quoted_identifier(self):
        self.assertEqual(
            ['SELECT * FROM "odd;name"'], split('SELECT * FROM "odd;name";')
        )

    def test_doubled_double_quote_inside_identifier(self):
        self.assertEqual(['SELECT "a""b;c"'], split('SELECT "a""b;c";'))

    def test_untagged_dollar_quoted_body(self):
        statements = split("DO $$ BEGIN PERFORM 1; PERFORM 2; END $$;\nSELECT 3;")
        self.assertEqual(
            ["DO $$ BEGIN PERFORM 1; PERFORM 2; END $$", "SELECT 3"], statements
        )

    def test_tagged_dollar_quote_ignores_inner_untagged_delimiter(self):
        script = "CREATE FUNCTION f() RETURNS void AS $body$ SELECT '$$'; $body$;\nSELECT 1;"
        self.assertEqual(
            [
                "CREATE FUNCTION f() RETURNS void AS $body$ SELECT '$$'; $body$",
                "SELECT 1",
            ],
            split(script),
        )

    def test_positional_parameter_is_not_a_dollar_quote(self):
        self.assertEqual(
            ["SELECT $1", "SELECT $2"], split("SELECT $1; SELECT $2;")
        )

    def test_dollar_after_identifier_character_is_not_a_delimiter(self):
        # PostgreSQL's longest-match rule lexes `a$$b` as one identifier.
        self.assertEqual(["SELECT a$$b", "SELECT 1"], split("SELECT a$$b; SELECT 1;"))

    def test_crlf_line_comment_terminates_at_the_newline(self):
        self.assertEqual(
            ["SELECT 1", "SELECT 2"], split("SELECT 1; -- note;\r\nSELECT 2;")
        )

    def test_unterminated_string_is_refused(self):
        with self.assertRaisesRegex(ValueError, "unterminated string literal"):
            split("SELECT 'oops")

    def test_unterminated_identifier_is_refused(self):
        with self.assertRaisesRegex(ValueError, "unterminated quoted identifier"):
            split('SELECT "oops')

    def test_unterminated_dollar_quote_is_refused(self):
        with self.assertRaisesRegex(ValueError, r"unterminated dollar-quoted"):
            split("DO $$ BEGIN PERFORM 1; END")

    def test_unterminated_block_comment_is_refused(self):
        with self.assertRaisesRegex(ValueError, "unterminated block comment"):
            split("SELECT 1; /* never closed")


class FixtureTests(unittest.TestCase):
    def test_fixture_splits_into_its_five_statements(self):
        statements = split(FIXTURE)
        self.assertEqual(5, len(statements))
        self.assertTrue(statements[0].startswith("CREATE EXTENSION"))
        self.assertTrue(statements[1].startswith("CREATE TABLE"))
        self.assertTrue(statements[2].startswith("DO $$"))
        self.assertTrue(statements[2].endswith("END $$"))
        self.assertTrue(statements[3].startswith("CREATE OR REPLACE FUNCTION"))
        self.assertTrue(statements[3].endswith("$body$"))
        self.assertTrue(statements[4].startswith("INSERT INTO honua.services"))

    def test_no_fragment_swallows_a_later_statement(self):
        # The plpgsql body's own `END;` and the literal `$$` inside it must not
        # leak out of statement 3, and no statement may contain a bare
        # top-level semicolon followed by more SQL.
        for statement in split(FIXTURE):
            self.assertEqual([statement], split(statement + ";"))

    def test_splitting_is_idempotent(self):
        statements = split(FIXTURE)
        self.assertEqual(statements, split(";\n".join(statements) + ";"))

    @unittest.skipUnless(
        os.environ.get("HONUA_CERT_SEED_SQL"),
        "set HONUA_CERT_SEED_SQL to honua-server tests/seed/client-compat-v1.sql",
    )
    def test_real_certification_seed(self):
        with open(os.environ["HONUA_CERT_SEED_SQL"], encoding="utf-8") as stream:
            sql = stream.read()
        statements = split(sql)
        self.assertGreater(len(statements), 10)
        handler._assert_no_transaction_control(statements)
        self.assertEqual(statements, split(";\n".join(statements) + ";"))
        self.assertTrue(any("test_service" in s for s in statements))


class TransactionControlTests(unittest.TestCase):
    def test_rejects_explicit_transaction_control(self):
        for sql in ("BEGIN;", "COMMIT;", "ROLLBACK;", "END;", "START TRANSACTION;",
                    "SAVEPOINT s;", "RELEASE SAVEPOINT s;", "ABORT;",
                    "PREPARE TRANSACTION 'x';"):
            with self.subTest(sql=sql):
                with self.assertRaisesRegex(ValueError, "manages transactions itself"):
                    handler._assert_no_transaction_control(split("SELECT 1;" + sql))

    def test_allows_plpgsql_begin_end_and_plain_prepare(self):
        handler._assert_no_transaction_control(split(FIXTURE))
        handler._assert_no_transaction_control(split("PREPARE p AS SELECT 1;"))

    def test_leading_comments_do_not_hide_transaction_control(self):
        with self.assertRaisesRegex(ValueError, "manages transactions itself"):
            handler._assert_no_transaction_control(split("-- setup\n/* x */ COMMIT;"))


class ResolveScriptTests(unittest.TestCase):
    SQL = "SELECT 1;\n"
    DIGEST = hashlib.sha256(SQL.encode("utf-8")).hexdigest()

    def test_no_script_keys_returns_none(self):
        self.assertIsNone(handler._resolve_script({}))
        self.assertIsNone(handler._resolve_script({"statements": ["SELECT 1"]}))

    def test_inline_script_without_digest(self):
        sql, source = handler._resolve_script({"script": self.SQL})
        self.assertEqual(self.SQL, sql)
        self.assertEqual(self.DIGEST, source["sha256"])
        self.assertFalse(source["sha256_verified"])
        self.assertEqual(len(self.SQL), source["bytes"])

    def test_inline_script_with_matching_digest(self):
        _, source = handler._resolve_script(
            {"script": self.SQL, "script_sha256": self.DIGEST.upper()}
        )
        self.assertTrue(source["sha256_verified"])

    def test_inline_script_with_wrong_digest_is_refused(self):
        with self.assertRaisesRegex(ValueError, "sha256 mismatch"):
            handler._resolve_script({"script": self.SQL, "script_sha256": "00" * 32})

    def test_url_requires_a_digest(self):
        with self.assertRaisesRegex(ValueError, "script_sha256 is required"):
            handler._resolve_script({"script_url": "https://example.invalid/s.sql"})

    def test_url_and_inline_are_mutually_exclusive(self):
        with self.assertRaisesRegex(ValueError, "not both"):
            handler._resolve_script(
                {"script_url": "https://example.invalid/s.sql", "script": self.SQL}
            )

    def test_non_https_url_is_refused(self):
        with self.assertRaisesRegex(ValueError, "must be an https URL"):
            handler._resolve_script(
                {"script_url": "http://example.invalid/s.sql",
                 "script_sha256": self.DIGEST}
            )

    def _fake_response(self, payload, url="https://example.invalid/s.sql"):
        response = mock.MagicMock()
        response.url = url
        response.read.side_effect = [payload, b""]
        response.__enter__.return_value = response
        response.__exit__.return_value = False
        return response

    def test_fetched_script_is_verified_against_the_digest(self):
        with mock.patch.object(
            handler.urllib.request, "urlopen",
            return_value=self._fake_response(self.SQL.encode("utf-8")),
        ):
            sql, source = handler._resolve_script(
                {"script_url": "https://example.invalid/s.sql",
                 "script_sha256": self.DIGEST}
            )
        self.assertEqual(self.SQL, sql)
        self.assertEqual("https://example.invalid/s.sql", source["url"])
        self.assertTrue(source["sha256_verified"])

    def test_fetched_script_with_wrong_digest_is_refused(self):
        with mock.patch.object(
            handler.urllib.request, "urlopen",
            return_value=self._fake_response(b"DROP SCHEMA honua CASCADE;\n"),
        ):
            with self.assertRaisesRegex(ValueError, "sha256 mismatch"):
                handler._resolve_script(
                    {"script_url": "https://example.invalid/s.sql",
                     "script_sha256": self.DIGEST}
                )

    def test_redirect_off_https_is_refused(self):
        with mock.patch.object(
            handler.urllib.request, "urlopen",
            return_value=self._fake_response(
                self.SQL.encode("utf-8"), url="http://example.invalid/s.sql"
            ),
        ):
            with self.assertRaisesRegex(ValueError, "redirected off https"):
                handler._resolve_script(
                    {"script_url": "https://example.invalid/s.sql",
                     "script_sha256": self.DIGEST}
                )

    def test_oversized_script_is_refused(self):
        oversized = b"-- x\n" * (handler._MAX_SCRIPT_BYTES // 5 + 1)
        with mock.patch.object(
            handler.urllib.request, "urlopen",
            return_value=self._fake_response(oversized),
        ):
            with self.assertRaisesRegex(ValueError, "exceeds the .* byte limit"):
                handler._resolve_script(
                    {"script_url": "https://example.invalid/s.sql",
                     "script_sha256": self.DIGEST}
                )


class FakeConnection:
    """Minimal pg8000.native.Connection stand-in recording what it was asked."""

    def __init__(self, row_counts=None, fail_on=None):
        self.executed = []
        self._row_counts = dict(row_counts or {})
        self._fail_on = fail_on
        self.row_count = -1

    def run(self, sql):
        self.executed.append(sql)
        if self._fail_on is not None and self._fail_on in sql:
            raise RuntimeError("relation does not exist")
        self.row_count = self._row_counts.get(sql, -1)
        return None


class RunScriptTests(unittest.TestCase):
    def test_wraps_every_statement_in_one_transaction(self):
        connection = FakeConnection(row_counts={"INSERT INTO t VALUES (1)": 1})
        result = handler._run_script(
            connection,
            "CREATE TABLE t (id int);\nINSERT INTO t VALUES (1);\n",
            {"url": "https://example.invalid/s.sql"},
        )
        self.assertEqual(
            ["BEGIN", "CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)", "COMMIT"],
            connection.executed,
        )
        self.assertTrue(result["committed"])
        self.assertEqual(2, result["statement_count"])
        self.assertEqual(1, result["rows_affected"])
        self.assertEqual([0, 1], [s["index"] for s in result["statements"]])
        self.assertIsNone(result["statements"][0]["row_count"])
        self.assertEqual(1, result["statements"][1]["row_count"])

    def test_failure_rolls_back_and_names_the_statement(self):
        connection = FakeConnection(fail_on="INSERT INTO missing")
        with self.assertRaises(RuntimeError) as caught:
            handler._run_script(
                connection,
                "CREATE TABLE t (id int);\nINSERT INTO missing VALUES (1);\nSELECT 1;\n",
                {"url": "https://example.invalid/s.sql"},
            )
        self.assertIn("at statement 1 of 3", str(caught.exception))
        self.assertIn("INSERT INTO missing VALUES (1)", str(caught.exception))
        self.assertIn("nothing applied", str(caught.exception))
        self.assertEqual("ROLLBACK", connection.executed[-1])
        self.assertNotIn("COMMIT", connection.executed)
        self.assertNotIn("SELECT 1", connection.executed)

    def test_commit_failure_is_reported_as_such(self):
        connection = FakeConnection(fail_on="COMMIT")
        with self.assertRaisesRegex(RuntimeError, "while committing"):
            handler._run_script(
                connection, "SELECT 1;", {"url": "https://example.invalid/s.sql"}
            )
        self.assertEqual("ROLLBACK", connection.executed[-1])

    def test_statement_summary_is_bounded(self):
        long_statement = "SELECT " + ", ".join(f"col_{i}" for i in range(200))
        connection = FakeConnection()
        result = handler._run_script(
            connection, long_statement + ";", {"url": None, "inline": True}
        )
        self.assertLessEqual(len(result["statements"][0]["statement"]), 120)
        self.assertTrue(result["statements"][0]["statement"].endswith("..."))

    def test_script_that_manages_transactions_applies_nothing(self):
        connection = FakeConnection()
        with self.assertRaisesRegex(ValueError, "manages transactions itself"):
            handler._run_script(
                connection, "SELECT 1;\nCOMMIT;\n", {"url": None, "inline": True}
            )
        self.assertEqual([], connection.executed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
