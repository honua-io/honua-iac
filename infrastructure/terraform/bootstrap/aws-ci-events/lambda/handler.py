"""GitHub org webhook receiver: verify X-Hub-Signature-256, drop events the dispatcher does not need, and send a
compact JSON message to SQS. Standard library plus the boto3 that the Lambda runtime provides; no model calls.

Message shape (also produced by the lane host's polling shim):
  {"v": 1, "src": "webhook", "id": <delivery>, "type": ..., "action": ..., "repo": ..., "default_branch": ...,
   "pr": n|null, "branch": ..., "sha": ..., "base": ..., "check": ..., "check_id": ..., "run_id": ...,
   "conclusion": ..., "url": ..., "at": ..., "actor": ..., "comment_id": ..., "review_state": ...,
   "mergeable": "MERGEABLE|CONFLICTING|UNKNOWN", "merge_state": "CLEAN|DIRTY|BEHIND|...", "merged": bool,
   "run_status": ..., "run_attempt": ..., "run_event": ..., "workflow_path": ..., "created_at": ..., "started_at": ...}
"""
import base64
import collections
import binascii
import hashlib
import hmac
import json
import os
import time

RED = {"failure", "timed_out", "startup_failure", "action_required"}
KEEP_CONCLUSIONS = RED | {"success"}
PR_ACTIONS = {"opened", "reopened", "synchronize", "closed", "ready_for_review"}
SECRET_TTL = 300
REFETCH_AFTER_MISMATCH = 60
TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}

_secret = {"value": None, "at": 0.0}
_clients = {}


def client(name):
    if name not in _clients:
        import boto3  # provided by the Lambda runtime
        _clients[name] = boto3.client(name)
    return _clients[name]


def _load_secret():
    resp = client("ssm").get_parameter(Name=os.environ["WEBHOOK_SECRET_PARAM"], WithDecryption=True)
    _secret.update(value=resp["Parameter"]["Value"].strip().encode(), at=time.time())
    return _secret["value"]


def secret():
    """The webhook secret, cached for SECRET_TTL."""
    if _secret["value"] is None or time.time() - _secret["at"] > SECRET_TTL:
        return _load_secret()
    return _secret["value"]


def rotated_secret():
    """Re-read the secret after a signature mismatch (it may just have been rotated), at most once a minute."""
    if time.time() - _secret["at"] > REFETCH_AFTER_MISMATCH:
        return _load_secret()
    return _secret["value"]


def verify(body, signature, key):
    if not signature or not signature.startswith("sha256=") or not key:
        return False
    expected = ("sha256=" + hmac.new(key, body, hashlib.sha256).hexdigest()).encode()
    return hmac.compare_digest(expected, signature.encode("utf-8", "replace"))


def _pr_number(prs):
    return prs[0]["number"] if prs else None


def _workflow_run(base, payload):
    run = payload["workflow_run"]
    if base["action"] not in {"requested", "in_progress", "completed"}:
        return None
    if (run.get("head_repository") or {}).get("full_name") != payload["repository"].get("full_name"):
        return None  # fork run: its head_branch may be named like ours (even 'trunk'); fail closed
    return dict(base, pr=_pr_number(run.get("pull_requests")), branch=run.get("head_branch"), sha=run.get("head_sha"),
                check=run.get("name"), check_id=run.get("workflow_id"), run_id=run.get("id"),
                conclusion=run.get("conclusion") if base["action"] == "completed" else None,
                url=run.get("html_url"), at=run.get("updated_at"),
                run_status=run.get("status"), run_attempt=run.get("run_attempt"), run_event=run.get("event"),
                workflow_path=run.get("path"), created_at=run.get("created_at"), started_at=run.get("run_started_at"))


def _external_check(base, payload):
    """check_run / check_suite from apps other than GitHub Actions (Actions checks arrive as workflow_run)."""
    item = payload[base["type"]]
    app = item.get("app") or {}
    if (base["action"] != "completed" or app.get("slug") == "github-actions"
            or item.get("conclusion") not in KEEP_CONCLUSIONS):
        return None
    branch = item.get("head_branch") or (item.get("check_suite") or {}).get("head_branch")
    if not item.get("pull_requests") and branch != base["default_branch"]:
        return None  # fork PR checks carry no PR and a fork branch name; ci-dispatch checks default-branch SHAs
    return dict(base, pr=_pr_number(item.get("pull_requests")), branch=branch, sha=item.get("head_sha"),
                check=item.get("name") or app.get("name"), check_id=None, run_id=None,
                conclusion=item.get("conclusion"), url=item.get("html_url") or item.get("details_url"),
                at=item.get("completed_at") or item.get("updated_at"))


def _status(base, payload):
    state = payload.get("state")
    if state not in ("failure", "error", "success"):
        return None
    branches = [b["name"] for b in payload.get("branches") or []]
    return dict(base, pr=None, branch=branches[0] if len(branches) == 1 else None, sha=payload.get("sha"),
                check=payload.get("context"), check_id=None, run_id=None, conclusion=state,
                url=payload.get("target_url"),
                at=payload.get("updated_at"))


def _same_repo_head(payload):
    head = (payload.get("pull_request") or {}).get("head") or {}
    return (head.get("repo") or {}).get("full_name") == payload["repository"].get("full_name")


def _pr_fields(payload):
    pr = payload.get("pull_request") or {}
    head = pr.get("head") or {}
    return {"pr": pr.get("number"), "branch": head.get("ref"), "sha": head.get("sha"),
            "base": (pr.get("base") or {}).get("ref")}


def _pull_request(base, payload):
    pr = payload.get("pull_request") or {}
    if base["action"] not in PR_ACTIONS or not _same_repo_head(payload):
        return None
    mergeable = {True: "MERGEABLE", False: "CONFLICTING"}.get(pr.get("mergeable"), "UNKNOWN")
    merge_state = (pr.get("mergeable_state") or "").upper() or None
    return dict(base, **_pr_fields(payload), mergeable=mergeable, merge_state=merge_state,
                merged=bool(pr.get("merged")), at=pr.get("updated_at"))


def _last_thread_comment(payload):
    return ((payload.get("thread") or {}).get("comments") or [{}])[-1]


def _trusted_author(payload):
    """A stranger's text must never reach a fixer: trusted authors or GitHub Apps only. Returns the association."""
    item = payload.get("review") or payload.get("comment") or _last_thread_comment(payload)
    login = ((item.get("user") or {}).get("login")) or ""
    association = item.get("author_association")
    return association if association in TRUSTED or login.endswith("[bot]") else None


def _review(base, payload):
    review = payload.get("review") or {}
    state = (review.get("state") or "").lower()
    if base["action"] != "submitted" or state not in ("changes_requested", "commented"):
        return None
    return dict(base, **_pr_fields(payload), type="review", review_state=state, comment_id=review.get("id"),
                actor=(review.get("user") or {}).get("login"), url=review.get("html_url"),
                at=review.get("submitted_at"))


def _review_comment(base, payload):
    comment = payload.get("comment") or {}
    if base["action"] != "created":
        return None
    return dict(base, **_pr_fields(payload), type="review_comment", comment_id=comment.get("id"),
                actor=(comment.get("user") or {}).get("login"), url=comment.get("html_url"),
                at=comment.get("created_at"))


def _review_thread(base, payload):
    if base["action"] != "unresolved":
        return None
    last = _last_thread_comment(payload)
    return dict(base, **_pr_fields(payload), type="review_comment", comment_id=last.get("id"), url=last.get("html_url"),
                at=last.get("updated_at"))


def _issue_comment(base, payload):
    """Issue comments carry no head repo: ci-dispatch checks isCrossRepository before acting."""
    issue, comment = payload.get("issue") or {}, payload.get("comment") or {}
    if base["action"] != "created" or not issue.get("pull_request"):
        return None
    return dict(base, pr=issue.get("number"), branch=None, sha=None, comment_id=comment.get("id"),
                actor=(comment.get("user") or {}).get("login"), url=comment.get("html_url"),
                at=comment.get("created_at"))


CI_EVENTS = {"workflow_run": _workflow_run, "check_run": _external_check, "check_suite": _external_check,
             "status": _status, "pull_request": _pull_request}
TEXT_EVENTS = {"pull_request_review": _review, "pull_request_review_comment": _review_comment,
               "pull_request_review_thread": _review_thread, "issue_comment": _issue_comment}


def _listed(variable):
    return [x for x in os.environ.get(variable, "").split(",") if x]


def normalize(event, payload, delivery=None):
    """Return the compact message for a GitHub event payload, or None when the dispatcher has no use for it."""
    repo = (payload.get("repository") or {}).get("name")
    if not repo or (_listed("ALLOWED_REPOS") and repo not in _listed("ALLOWED_REPOS")):
        return None
    base = {"v": 1, "src": "webhook", "id": delivery, "type": event, "action": payload.get("action"), "repo": repo,
            "default_branch": payload["repository"].get("default_branch"),
            "actor": (payload.get("sender") or {}).get("login")}
    if event in CI_EVENTS:
        return CI_EVENTS[event](base, payload)
    if event not in TEXT_EVENTS or base["actor"] in _listed("IGNORE_SENDERS"):
        return None
    association = _trusted_author(payload)
    if association is None or (event != "issue_comment" and not _same_repo_head(payload)):
        return None  # untrusted author, fork PR, or deleted fork (head.repo null): fail closed
    return TEXT_EVENTS[event](dict(base, association=association), payload)


def _response(code, text):
    return {"statusCode": code, "headers": {"content-type": "text/plain"}, "body": text}


Dependencies = collections.namedtuple("Dependencies", "current rotated send")  # secret readers and the SQS sender


def handler(event, context=None):
    """Lambda function URL entry point."""
    return process(event, Dependencies(secret, rotated_secret, _send))


def _verified(raw, sig, deps):
    return verify(raw, sig, deps.current()) or verify(raw, sig, deps.rotated())


def process(event, deps):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body") or ""
    if (event.get("requestContext") or {}).get("http", {}).get("method", "POST") != "POST":
        return _response(405, "POST only")
    try:
        raw = base64.b64decode(body, validate=True) if event.get("isBase64Encoded") else body.encode()
    except (binascii.Error, ValueError):
        return _response(400, "bad body")
    sig = headers.get("x-hub-signature-256")
    if not _verified(raw, sig, deps):
        return _response(401, "bad signature")
    name = headers.get("x-github-event", "")
    if name == "ping":
        return _response(200, "pong")
    try:
        payload = json.loads(raw)
    except ValueError:
        return _response(400, "bad json")
    msg = normalize(name, payload, headers.get("x-github-delivery"))
    if msg is None:
        return _response(202, "dropped")
    msg = {k: v for k, v in msg.items() if v is not None}
    deps.send(json.dumps(msg, separators=(",", ":")))
    return _response(202, "queued")


def _send(body):
    client("sqs").send_message(QueueUrl=os.environ["QUEUE_URL"], MessageBody=body)
