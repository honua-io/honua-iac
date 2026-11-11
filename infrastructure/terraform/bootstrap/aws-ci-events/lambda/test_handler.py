import hashlib
import hmac
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import handler as h  # noqa: E402

KEY = b"test-secret"
REPO = {"name": "honua-server", "full_name": "honua-io/honua-server", "default_branch": "trunk"}


def call(event_name, payload, key=KEY, sign_with=KEY, b64=False):
    raw = json.dumps(payload).encode()
    sig = "sha256=" + hmac.new(sign_with, raw, hashlib.sha256).hexdigest()
    sent = []
    body = raw.decode()
    if b64:
        import base64
        body = base64.b64encode(raw).decode()
    ev = {"headers": {"X-Hub-Signature-256": sig, "X-GitHub-Event": event_name, "X-GitHub-Delivery": "d-1"},
          "body": body, "isBase64Encoded": b64, "requestContext": {"http": {"method": "POST"}}}
    resp = h.handler(ev, send=sent.append, key=key)
    return resp, [json.loads(s) for s in sent]


def run(conclusion="failure", action="completed", prs=None):
    return {"action": action, "repository": REPO, "sender": {"login": "github-actions[bot]"},
            "workflow_run": {"id": 9, "name": "PR Gate", "workflow_id": 55, "head_branch": "fix/x", "head_sha": "a" * 40,
                             "conclusion": conclusion, "html_url": "u", "updated_at": "2026-11-11T20:00:00Z",
                             "pull_requests": prs if prs is not None else [{"number": 7}]}}


class Signature(unittest.TestCase):
    def test_bad_or_missing_signature_rejected(self):
        resp, sent = call("workflow_run", run(), sign_with=b"wrong")
        self.assertEqual((resp["statusCode"], sent), (401, []))
        self.assertFalse(h.verify(b"x", None, KEY))
        self.assertFalse(h.verify(b"x", "sha1=abc", KEY))
        self.assertFalse(h.verify(b"x", "sha256=" + hmac.new(KEY, b"x", hashlib.sha256).hexdigest(), b""))

    def test_ping_and_base64_body(self):
        self.assertEqual(call("ping", {"zen": "x"})[0]["statusCode"], 200)
        resp, sent = call("workflow_run", run(), b64=True)
        self.assertEqual((resp["statusCode"], len(sent)), (202, 1))

    def test_non_ascii_signature_and_bad_base64(self):
        self.assertFalse(h.verify(b"x", "sha256=\u00e9", KEY))
        ev = {"headers": {}, "body": "!!notb64", "isBase64Encoded": True, "requestContext": {"http": {"method": "POST"}}}
        self.assertEqual(h.handler(ev, key=KEY)["statusCode"], 400)

    def test_get_rejected(self):
        ev = {"headers": {}, "body": "", "requestContext": {"http": {"method": "GET"}}}
        self.assertEqual(h.handler(ev, key=KEY)["statusCode"], 405)


class Filtering(unittest.TestCase):
    def test_workflow_run_red_and_green_kept_others_dropped(self):
        resp, sent = call("workflow_run", run())
        self.assertEqual(resp["body"], "queued")
        m = sent[0]
        self.assertEqual((m["type"], m["repo"], m["pr"], m["check"], m["check_id"], m["run_id"], m["conclusion"],
                          m["default_branch"], m["src"], m["id"]),
                         ("workflow_run", "honua-server", 7, "PR Gate", 55, 9, "failure", "trunk", "webhook", "d-1"))
        self.assertEqual(call("workflow_run", run("success"))[0]["body"], "queued")
        self.assertEqual(call("workflow_run", run("cancelled"))[0]["body"], "dropped")
        self.assertEqual(call("workflow_run", run(action="requested"))[0]["body"], "dropped")
        self.assertNotIn("pr", call("workflow_run", run(prs=[]))[1][0])  # nulls are stripped

    def test_actions_check_runs_dropped_external_kept(self):
        cr = {"action": "completed", "repository": REPO, "check_run": {"name": "ext", "head_sha": "a" * 40,
              "conclusion": "failure", "app": {"slug": "github-actions"}, "pull_requests": [{"number": 7}],
              "check_suite": {"head_branch": "fix/x"}}}
        self.assertEqual(call("check_run", cr)[0]["body"], "dropped")
        cr["check_run"]["app"] = {"slug": "codecov"}
        resp, sent = call("check_run", cr)
        self.assertEqual((sent[0]["check"], sent[0]["branch"]), ("ext", "fix/x"))

    def test_status(self):
        st = {"repository": REPO, "state": "pending", "sha": "a" * 40, "context": "ci/x", "branches": [{"name": "fix/x"}]}
        self.assertEqual(call("status", st)[0]["body"], "dropped")
        st["state"] = "error"
        self.assertEqual(call("status", st)[1][0]["branch"], "fix/x")

    def test_pull_request_fields_and_forks(self):
        pr = {"action": "synchronize", "repository": REPO, "pull_request": {
            "number": 7, "head": {"ref": "fix/x", "sha": "b" * 40, "repo": {"full_name": "honua-io/honua-server"}},
            "base": {"ref": "trunk"}, "mergeable": False, "mergeable_state": "dirty", "merged": False}}
        m = call("pull_request", pr)[1][0]
        self.assertEqual((m["mergeable"], m["merge_state"], m["base"]), ("CONFLICTING", "DIRTY", "trunk"))
        pr["action"] = "labeled"
        self.assertEqual(call("pull_request", pr)[0]["body"], "dropped")
        pr["action"] = "opened"
        pr["pull_request"]["head"]["repo"] = {"full_name": "someone/fork"}
        self.assertEqual(call("pull_request", pr)[0]["body"], "dropped")

    def test_reviews_comments_threads(self):
        pr = {"number": 7, "head": {"ref": "fix/x", "sha": "b" * 40}, "base": {"ref": "trunk"}}
        rv = {"action": "submitted", "repository": REPO, "pull_request": pr,
              "review": {"id": 3, "state": "APPROVED", "user": {"login": "x"}, "author_association": "MEMBER"}}
        self.assertEqual(call("pull_request_review", rv)[0]["body"], "dropped")
        rv["review"]["state"] = "CHANGES_REQUESTED"
        self.assertEqual(call("pull_request_review", rv)[1][0]["type"], "review")
        rc = {"action": "created", "repository": REPO, "pull_request": pr,
              "comment": {"id": 11, "user": {"login": "chatgpt-codex-connector[bot]"}, "author_association": "NONE"}}
        m = call("pull_request_review_comment", rc)[1][0]
        self.assertEqual((m["type"], m["comment_id"], m["actor"]), ("review_comment", 11, "chatgpt-codex-connector[bot]"))
        th = {"action": "resolved", "repository": REPO, "pull_request": pr, "thread": {"comments": [{"id": 1}]}}
        self.assertEqual(call("pull_request_review_thread", th)[0]["body"], "dropped")
        ic = {"action": "created", "repository": REPO, "issue": {"number": 7},
              "comment": {"id": 5, "user": {"login": "b"}, "author_association": "COLLABORATOR"}}
        self.assertEqual(call("issue_comment", ic)[0]["body"], "dropped")  # an issue, not a PR
        ic["issue"]["pull_request"] = {"url": "x"}
        self.assertEqual(call("issue_comment", ic)[1][0]["pr"], 7)

    def test_allowed_repos_and_ignored_senders(self):
        os.environ["ALLOWED_REPOS"] = "honua-console"
        try:
            self.assertEqual(call("workflow_run", run())[0]["body"], "dropped")
        finally:
            del os.environ["ALLOWED_REPOS"]
        os.environ["IGNORE_SENDERS"] = "lane-account"
        try:
            ic = {"action": "created", "repository": REPO, "sender": {"login": "lane-account"},
                  "issue": {"number": 7, "pull_request": {}},
                  "comment": {"id": 5, "user": {"login": "lane-account"}, "author_association": "OWNER"}}
            self.assertEqual(call("issue_comment", ic)[0]["body"], "dropped")
            self.assertEqual(call("workflow_run", dict(run(), sender={"login": "lane-account"}))[0]["body"], "queued")
        finally:
            del os.environ["IGNORE_SENDERS"]

    def test_untrusted_authors_and_fork_prs_dropped(self):
        pr = {"number": 7, "head": {"ref": "x", "sha": "b" * 40, "repo": {"full_name": "honua-io/honua-server"}}}
        ic = {"action": "created", "repository": REPO, "issue": {"number": 7, "pull_request": {}},
              "comment": {"id": 5, "user": {"login": "stranger"}, "author_association": "NONE"}}
        self.assertEqual(call("issue_comment", ic)[0]["body"], "dropped")
        rc = {"action": "created", "repository": REPO, "pull_request": pr,
              "comment": {"id": 6, "user": {"login": "stranger"}, "author_association": "CONTRIBUTOR"}}
        self.assertEqual(call("pull_request_review_comment", rc)[0]["body"], "dropped")
        rc["comment"]["author_association"] = "MEMBER"
        self.assertEqual(call("pull_request_review_comment", rc)[0]["body"], "queued")
        pr["head"]["repo"] = {"full_name": "someone/fork"}
        self.assertEqual(call("pull_request_review_comment", rc)[0]["body"], "dropped")

    def test_unknown_event_dropped(self):
        self.assertEqual(call("push", {"repository": REPO})[0]["body"], "dropped")


if __name__ == "__main__":
    unittest.main()
