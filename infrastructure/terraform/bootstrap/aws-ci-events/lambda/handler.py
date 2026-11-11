"""GitHub org webhook receiver: verify X-Hub-Signature-256, drop events the dispatcher does not need, and send a
compact JSON message to SQS. Standard library plus the boto3 that the Lambda runtime provides; no model calls.

Message shape (also produced by the lane host's polling shim):
  {"v": 1, "src": "webhook", "id": <delivery>, "type": ..., "action": ..., "repo": ..., "default_branch": ...,
   "pr": n|null, "branch": ..., "sha": ..., "base": ..., "check": ..., "check_id": ..., "run_id": ...,
   "conclusion": ..., "url": ..., "at": ..., "actor": ..., "comment_id": ..., "review_state": ...,
   "mergeable": "MERGEABLE|CONFLICTING|UNKNOWN", "merge_state": "CLEAN|DIRTY|BEHIND|...", "merged": bool}
"""
import base64
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


def _workflow_run(base, p):
    r = p["workflow_run"]
    if base["action"] != "completed" or r.get("conclusion") not in KEEP_CONCLUSIONS:
        return None
    return dict(base, pr=_pr_number(r.get("pull_requests")), branch=r.get("head_branch"), sha=r.get("head_sha"),
                check=r.get("name"), check_id=r.get("workflow_id"), run_id=r.get("id"),
                conclusion=r.get("conclusion"), url=r.get("html_url"), at=r.get("updated_at"))


def _external_check(base, p):
    """check_run / check_suite from apps other than GitHub Actions (Actions checks arrive as workflow_run)."""
    r = p[base["type"]]
    app = r.get("app") or {}
    if base["action"] != "completed" or app.get("slug") == "github-actions" or r.get("conclusion") not in KEEP_CONCLUSIONS:
        return None
    branch = r.get("head_branch") or (r.get("check_suite") or {}).get("head_branch")
    return dict(base, pr=_pr_number(r.get("pull_requests")), branch=branch, sha=r.get("head_sha"),
                check=r.get("name") or app.get("name"), check_id=None, run_id=None, conclusion=r.get("conclusion"),
                url=r.get("html_url") or r.get("details_url"), at=r.get("completed_at") or r.get("updated_at"))


def _status(base, p):
    state = p.get("state")
    if state not in ("failure", "error", "success"):
        return None
    branches = [b["name"] for b in p.get("branches") or []]
    return dict(base, pr=None, branch=branches[0] if len(branches) == 1 else None, sha=p.get("sha"),
                check=p.get("context"), check_id=None, run_id=None, conclusion=state, url=p.get("target_url"),
                at=p.get("updated_at"))


def _same_repo_head(p):
    head = (p.get("pull_request") or {}).get("head") or {}
    return (head.get("repo") or {}).get("full_name") == p["repository"].get("full_name")


def _pr_fields(p):
    pr = p.get("pull_request") or {}
    head = pr.get("head") or {}
    return {"pr": pr.get("number"), "branch": head.get("ref"), "sha": head.get("sha"),
            "base": (pr.get("base") or {}).get("ref")}


def _pull_request(base, p):
    pr = p.get("pull_request") or {}
    if base["action"] not in PR_ACTIONS or not _same_repo_head(p):
        return None
    mergeable = {True: "MERGEABLE", False: "CONFLICTING"}.get(pr.get("mergeable"), "UNKNOWN")
    return dict(base, **_pr_fields(p), mergeable=mergeable, merge_state=(pr.get("mergeable_state") or "").upper() or None,
                merged=bool(pr.get("merged")), at=pr.get("updated_at"))


def _trusted_author(p):
    """A stranger's text must never reach a fixer: trusted authors or GitHub Apps only. Returns the association."""
    item = p.get("review") or p.get("comment") or ((p.get("thread") or {}).get("comments") or [{}])[-1]
    login = ((item.get("user") or {}).get("login")) or ""
    association = item.get("author_association")
    return association if association in TRUSTED or login.endswith("[bot]") else None


def _review(base, p):
    review = p.get("review") or {}
    state = (review.get("state") or "").lower()
    if base["action"] != "submitted" or state not in ("changes_requested", "commented"):
        return None
    return dict(base, **_pr_fields(p), type="review", review_state=state, comment_id=review.get("id"),
                actor=(review.get("user") or {}).get("login"), url=review.get("html_url"), at=review.get("submitted_at"))


def _review_comment(base, p):
    cm = p.get("comment") or {}
    if base["action"] != "created":
        return None
    return dict(base, **_pr_fields(p), type="review_comment", comment_id=cm.get("id"),
                actor=(cm.get("user") or {}).get("login"), url=cm.get("html_url"), at=cm.get("created_at"))


def _review_thread(base, p):
    if base["action"] != "unresolved":
        return None
    last = ((p.get("thread") or {}).get("comments") or [{}])[-1]
    return dict(base, **_pr_fields(p), type="review_comment", comment_id=last.get("id"), url=last.get("html_url"),
                at=last.get("updated_at"))


def _issue_comment(base, p):
    """Issue comments carry no head repo: ci-dispatch checks isCrossRepository before acting."""
    issue, cm = p.get("issue") or {}, p.get("comment") or {}
    if base["action"] != "created" or not issue.get("pull_request"):
        return None
    return dict(base, pr=issue.get("number"), branch=None, sha=None, comment_id=cm.get("id"),
                actor=(cm.get("user") or {}).get("login"), url=cm.get("html_url"), at=cm.get("created_at"))


CI_EVENTS = {"workflow_run": _workflow_run, "check_run": _external_check, "check_suite": _external_check,
             "status": _status, "pull_request": _pull_request}
TEXT_EVENTS = {"pull_request_review": _review, "pull_request_review_comment": _review_comment,
               "pull_request_review_thread": _review_thread, "issue_comment": _issue_comment}


def _listed(variable):
    return [x for x in os.environ.get(variable, "").split(",") if x]


def normalize(event, p, delivery=None):
    """Return the compact message for a GitHub event payload, or None when the dispatcher has no use for it."""
    repo = (p.get("repository") or {}).get("name")
    if not repo or (_listed("ALLOWED_REPOS") and repo not in _listed("ALLOWED_REPOS")):
        return None
    base = {"v": 1, "src": "webhook", "id": delivery, "type": event, "action": p.get("action"), "repo": repo,
            "default_branch": p["repository"].get("default_branch"), "actor": (p.get("sender") or {}).get("login")}
    if event in CI_EVENTS:
        return CI_EVENTS[event](base, p)
    if event not in TEXT_EVENTS or base["actor"] in _listed("IGNORE_SENDERS"):
        return None
    association = _trusted_author(p)
    if association is None or (event != "issue_comment" and not _same_repo_head(p)):
        return None  # untrusted author, fork PR, or deleted fork (head.repo null): fail closed
    return TEXT_EVENTS[event](dict(base, association=association), p)


def _response(code, text):
    return {"statusCode": code, "headers": {"content-type": "text/plain"}, "body": text}


def handler(event, context=None, send=None, key=None):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body") or ""
    if (event.get("requestContext") or {}).get("http", {}).get("method", "POST") != "POST":
        return _response(405, "POST only")
    try:
        raw = base64.b64decode(body, validate=True) if event.get("isBase64Encoded") else body.encode()
    except (binascii.Error, ValueError):
        return _response(400, "bad body")
    sig = headers.get("x-hub-signature-256")
    ok = verify(raw, sig, key if key is not None else secret())
    if not ok and key is None:
        ok = verify(raw, sig, rotated_secret())
    if not ok:
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
    (send or _send)(json.dumps(msg, separators=(",", ":")))
    return _response(202, "queued")


def _send(body):
    client("sqs").send_message(QueueUrl=os.environ["QUEUE_URL"], MessageBody=body)
