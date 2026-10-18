#!/usr/bin/env python3
"""Hermetic CLI controls: real maintained wrappers, synthetic Git/AWS/Terraform.

The fake tools journal every call; no network, cloud credentials or Terraform
installation is used. Synthetic STS/token output is never live AWS evidence.
"""
import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import standing_cert_plan as producer

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
SENTINEL = "SECRET_SENTINEL_MUST_REMAIN_PRIVATE"
ACCOUNT = "123456789012"
BACKEND = f"arn:aws:iam::{ACCOUNT}:role/honua-terraform-backend"
DEPLOY = f"arn:aws:iam::{ACCOUNT}:role/honua-cert-deploy"


def sha(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def save(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


class StandingCertPlan(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repository = self.base / "source"
        self.repository.mkdir()
        self.root = self.repository / producer.ROOT_REL
        (self.root / ".terraform").mkdir(parents=True)
        (self.root / "main.tf").write_text("locals { fixture = true }\n")
        (self.root / ".terraform.lock.hcl").write_text("# authored provider lock fixture\n")
        (self.repository / ".gitignore").write_text(".terraform/\nbackend.tf\nignored*.tf\n__pycache__/\n")
        for relative in ("scripts/lib/tf-exec-contract.sh", "scripts/terraform-exact-plan.sh",
                         "scripts/terraform-backend-identity.sh"):
            destination = self.repository / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, destination)
        destination = self.repository / HERE.relative_to(REPO) / "standing_cert_plan.py"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / "standing_cert_plan.py", destination)
        self.entrypoint = destination
        self.private = self.base / "private"
        self.private.mkdir(mode=0o700)
        self.tokens = self.private / "oidc-token"
        future = datetime.now(timezone.utc) + timedelta(hours=1)
        claims = {"iss": producer.ISSUER, "aud": producer.AUDIENCE,
                  "sub": producer.SUBJECT, "exp": int(future.timestamp())}
        self.tokens.write_text("header." + base64.urlsafe_b64encode(canonical(claims)).decode().rstrip("=") + ".signature")
        self.tokens.chmod(0o600)
        self.backend_config = {"bucket": "honua-existing-state", "key": "standing/cert/terraform.tfstate",
                               "region": "us-east-1", "encrypt": True, "use_lockfile": True,
                               "assume_role_with_web_identity": {
                                   "role_arn": BACKEND, "web_identity_token_file": str(self.tokens)}}
        self.write_backend()
        backend_doc = {
            "schema_version": "v1", "kind": "honua.iac.backend-identity", "backend_kind": "s3",
            "is_remote": True, "workspace": "existing-cert",
            "location": {"region": "us-east-1", "bucket_id": "honua-existing-state",
                         "bucket_arn": "arn:aws:s3:::honua-existing-state", "object_key": "standing/cert/terraform.tfstate",
                         "workspace_key_prefix": None, "container_name": None, "storage_account_name": None},
            "locking": {"kind": "s3-native-lockfile", "detail": "standing/cert/terraform.tfstate.tflock"},
            "encryption": {"enabled": True, "kms_key_reference": None}, "backend_access_role_arn": BACKEND,
            "non_secret_config": {**{k: v for k, v in self.backend_config.items() if k != "assume_role_with_web_identity"},
                                  "assume_role_with_web_identity": {"role_arn": BACKEND}},
            "redacted_config_keys": ["assume_role_with_web_identity.web_identity_token_file"],
            "resolved_config_digest": sha(canonical(self.backend_config)), "evidence_scope": "non-secret-backend-configuration"}
        work = {"schema_version": "v1", "kind": "aws-sts-web-identity", "role_name": "honua-terraform-backend",
                "role_arn": BACKEND, "issuer": producer.ISSUER, "subject": producer.SUBJECT,
                "audience": producer.AUDIENCE, "max_session_duration": 3600,
                "backend": {"state_bucket_arn": "arn:aws:s3:::honua-existing-state", "lock_table_arn": ""},
                "permissions_purpose": "terraform-state-and-lock-only", "credentials": "short-lived-sts-only"}
        execute = {"schema_version": "v1", "kind": "honua.iac.execution-identity",
                   "account": {"account_id": ACCOUNT, "partition": "aws", "region": "us-east-1"},
                   "federation": {"mode": "oidc", "issuer": producer.ISSUER, "audience": producer.AUDIENCE,
                                  "subjects": [producer.SUBJECT], "trusted_principals": [],
                                  "max_session_duration": 3600, "credential_kind": "short-lived-sts-only"},
                   "roles": {"backend_access": {"role_arn": BACKEND}, "infra_deployment": {"role_arn": DEPLOY}},
                   "separation": {"backend_access_denied_to_deployment": True, "long_lived_credentials_denied": True,
                                  "deployment_role_not_passable": True, "iam_user_created": False, "access_key_created": False}}
        image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua@sha256:" + "a" * 64
        self.variables = {"licensing_mode": "Disabled", "enable_pro_license": False,
                          "honua_image": image, "gp_batch_image": image,
                          "audit_chain_key_secret_arn": f"arn:aws:secretsmanager:us-east-1:{ACCOUNT}:secret:audit-ABC123",
                          "operation_key_ring_certificate_secret_arn": f"arn:aws:secretsmanager:us-east-1:{ACCOUNT}:secret:keyring-DEF456",
                          "honua_admin_password": SENTINEL}
        self.var_file = self.private / "approved.tfvars.json"
        save(self.var_file, self.variables)
        self.request = {"schema": "honua.aws-cert-plan-request/v1", "targetId": "aws-cert", "actorId": "fixture-operator",
                        "iacRevision": "", "candidateDigest": "b" * 64, "accountId": ACCOUNT, "region": "us-east-1",
                        "terraformVersion": "1.10.5", "providerLockSha256": sha((self.root / ".terraform.lock.hcl").read_bytes()),
                        "backend": {"bucket_id": "honua-existing-state", "object_key": "standing/cert/terraform.tfstate",
                                    "workspace": "existing-cert", "configDigest": sha(canonical(backend_doc))},
                        "stateBefore": {"lineage": "authored-existing-lineage", "serial": 42},
                        "workloadIdentityContract": work, "workloadIdentityContractDigest": sha(canonical(work)),
                        "executionIdentityContract": execute, "executionIdentityContractDigest": sha(canonical(execute)),
                        "sessionExpiresAtUtc": future.isoformat(), "expiresInSeconds": 300, "planTimeoutSeconds": 300,
                        "backendTokenFile": str(self.tokens), "varFile": str(self.var_file),
                        "varFileSha256": sha(self.var_file.read_bytes()),
                        "imagePins": {"honua_image": image, "gp_batch_image": image},
                        "secretReferences": {k: v for k, v in self.variables.items() if k.endswith("_secret_arn")},
                        "privateRetention": {"directory": str(self.private), "owner": "fixture custodian",
                                             "accessReference": "fixture independent reviewer ACL",
                                             "retainUntilUtc": future.isoformat()}}
        self.case = {"account": ACCOUNT, "role": DEPLOY, "workspace": "existing-cert", "serial": 42,
                     "lineage": "authored-existing-lineage", "version": "1.10.5", "sentinel": SENTINEL}
        self.case_file = self.base / "case.json"
        self.journal = self.base / "journal.jsonl"
        tools = self.base / "tools"
        tools.mkdir()
        fake = '''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
c=json.loads(Path(os.environ['TEST_CERT_CASE']).read_text())
a=sys.argv[1:]; name=Path(sys.argv[0]).name
with open(os.environ['TEST_CERT_JOURNAL'],'a') as f: f.write(json.dumps([name,*a])+'\\n')
if name=='aws':
 if a[:2]==['sts','get-caller-identity']:
  print(json.dumps({'Account':c['account'],'Arn':c.get('callerArn','arn:aws:sts::'+c['account']+':assumed-role/'+c['role'].split('/')[-1]+'/fixture'),'UserId':'fixture-role:session'}))
 elif a[:2]==['iam','get-role']:
  role=a[a.index('--role-name')+1]
  statement={'Effect':'Allow','Action':'sts:AssumeRoleWithWebIdentity','Principal':{'Federated':'arn:aws:iam::'+c['account']+':oidc-provider/token.actions.githubusercontent.com'},'Condition':{'StringEquals':{'token.actions.githubusercontent.com:aud':'sts.amazonaws.com','token.actions.githubusercontent.com:sub':c.get('subject','repo:honua-io/honua-server:environment:cert')}}}
  if role=='honua-cert-deploy': statement['Condition']['StringLike']={'token.actions.githubusercontent.com:sub':statement['Condition']['StringEquals'].pop('token.actions.githubusercontent.com:sub')}
  print(json.dumps({'Role':{'Arn':'arn:aws:iam::'+c['account']+':role/'+role,'MaxSessionDuration':3600,'AssumeRolePolicyDocument':{'Statement':[statement]}}}))
 else: sys.exit(89)
else:
 a=[x for x in a if not x.startswith('-chdir=')]
 cmd=a[0]
 if cmd=='version': print(json.dumps({'terraform_version':c['version']}))
 elif a==['workspace','show']:
  seen=Path(os.environ['TEST_CERT_JOURNAL']).read_text()
  print(c.get('workspaceAfter',c['workspace']) if '"plan"' in seen else c['workspace'])
 elif a==['state','pull']:
  seen=Path(os.environ['TEST_CERT_JOURNAL']).read_text()
  print(json.dumps({'lineage':c['lineage'],'serial':c.get('serialAfter',c['serial']) if '"plan"' in seen else c['serial'],'rawStateSecret':'MUST_NOT_BE_RETAINED'}))
 elif cmd=='plan':
  out=next(x[5:] for x in a if x.startswith('-out='))
  Path(out).write_text('authored binary plan '+c['sentinel'])
  print(c['sentinel']);sys.exit(c.get('planExit',0))
 elif cmd=='show': print('private resource review '+c['sentinel'])
 else: sys.exit(88)
'''
        for name in ("aws", "terraform"):
            path = tools / name
            path.write_text(fake)
            path.chmod(0o700)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("TF_", "GIT_", "HONUA_IAC_", "AWS_", "LD_", "PYTHON"))}
        self.env.update(PATH=str(tools) + ":" + os.environ["PATH"], TEST_CERT_CASE=str(self.case_file),
                        TEST_CERT_JOURNAL=str(self.journal), AWS_ACCESS_KEY_ID="synthetic",
                        AWS_SECRET_ACCESS_KEY="synthetic", AWS_SESSION_TOKEN="synthetic", RUNNER_ENVIRONMENT="self-hosted")
        for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "authored fixture"]):
            subprocess.run(["git", *args], cwd=self.repository, check=True, capture_output=True)
        self.request["iacRevision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repository, text=True).strip()
        self.request_file = self.private / "request.json"

    def write_backend(self):
        save(self.root / ".terraform/terraform.tfstate", {"backend": {"type": "s3", "config": self.backend_config}})
        # Independently authored backend-only fixture (not the production renderer).
        config = self.backend_config
        web = config.get("assume_role_with_web_identity", {})
        (self.root / "backend.tf").write_text('''# existing operator configuration
terraform {
  backend "s3" {
    bucket = ''' + json.dumps(config["bucket"]) + '''
    key = ''' + json.dumps(config["key"]) + '''
    region = ''' + json.dumps(config["region"]) + '''
    encrypt = true
    use_lockfile = true
    assume_role_with_web_identity = {
      role_arn = ''' + json.dumps(web.get("role_arn", "")) + '''
      web_identity_token_file = ''' + json.dumps(str(self.tokens)) + '''
    }
  }
}
''')

    def invoke(self):
        save(self.request_file, self.request)
        save(self.case_file, self.case)
        result = subprocess.run(["python3", str(self.entrypoint), "--request", str(self.request_file)],
                                env=self.env, cwd=self.repository, capture_output=True, text=True, timeout=60, check=False)
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)
        self.assertNotIn("arn:aws", result.stdout + result.stderr)
        self.assertNotIn(str(self.private), result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        calls = [json.loads(l) for l in self.journal.read_text().splitlines()] if self.journal.exists() else []
        for call in calls:
            self.assertFalse(any(x in call for x in ("apply", "destroy", "init", "new", "select")), call)
        return result, json.loads(result.stdout), calls

    def refused(self, expected=None, plan_started=False):
        result, receipt, calls = self.invoke()
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(receipt["status"], "refused")
        if expected:
            self.assertEqual(receipt["reason"], expected)
        self.assertEqual(any("plan" in c for c in calls), plan_started)
        self.assertFalse(list(self.private.glob("aws-cert-plan-*/packet.json")))

    def test_real_wrapper_private_packet_and_exact_invocation(self):
        result, receipt, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(receipt["status"], "planned-unapproved")
        self.assertEqual(receipt["approvalStatus"], "not-approved")
        self.assertEqual(receipt["qualificationStatus"], "not-evaluated")
        packets = list(self.private.glob("aws-cert-plan-*"))
        self.assertEqual(len(packets), 1)
        packet = packets[0]
        descriptor = json.loads((packet / "packet.json").read_text())
        self.assertEqual(receipt["packetSha256"], sha((packet / "packet.json").read_bytes()))
        self.assertEqual(len(descriptor["files"]), 8)
        for name, expected in descriptor["files"].items():
            self.assertEqual(sha((packet / name).read_bytes()), expected)
            self.assertEqual(stat.S_IMODE((packet / name).stat().st_mode), 0o600)
        self.assertIn(SENTINEL, (packet / "diagnostic.log").read_text())
        self.assertIn(SENTINEL, (packet / "review.txt").read_text())
        self.assertFalse(any("MUST_NOT_BE_RETAINED" in p.read_text() for p in packet.iterdir()))
        plan = [c for c in calls if "plan" in c]
        self.assertEqual(len(plan), 1)
        self.assertIn("-input=false", plan[0])
        self.assertIn("-lock-timeout=120s", plan[0])
        self.assertNotIn("-destroy", plan[0])
        # Each file's changed bytes must fail actual packet verification against
        # the original public receipt; no Terraform/AWS call is involved.
        self.assertEqual(producer.verify_packet(packet, receipt["packetSha256"])["status"], "verified-unapproved")
        for name in (*descriptor["files"], "packet.json"):
            with self.subTest(tampered=name):
                original = (packet / name).read_bytes()
                (packet / name).write_bytes(original + b" ")
                with self.assertRaises(producer.Refused):
                    producer.verify_packet(packet, receipt["packetSha256"])
                (packet / name).write_bytes(original)

    def test_environment_injections_start_no_plan(self):
        for name in ("TF_CLI_ARGS_plan", "TF_VAR_honua_image", "TF_WORKSPACE", "TF_LOG", "TF_LOG_PATH", "GIT_WORK_TREE", "GIT_DIR", "GIT_INDEX_FILE", "HONUA_IAC_OFFLINE", "HONUA_IAC_TERRAFORM_BIN", "AWS_PROFILE", "AWS_ENDPOINT_URL_IAM", "AWS_CONFIG_FILE", "BASH_ENV", "LD_PRELOAD"):
            with self.subTest(name=name):
                self.env[name] = "refuse"
                # LD_PRELOAD itself generates loader stderr before Python starts;
                # call the function in-process for that one environment control.
                if name == "LD_PRELOAD":
                    with mock.patch.dict(os.environ, self.env, clear=True), self.assertRaises(producer.Refused):
                        producer.environment(self.request, self.root)
                else:
                    self.refused("environment-override-refused")
                del self.env[name]

    def test_current_iam_user_is_refused(self):
        self.case["callerArn"] = f"arn:aws:iam::{ACCOUNT}:user/operator"
        self.refused("subprocess-failed")

    def test_wrong_deployment_role_is_refused(self):
        self.case["role"] = BACKEND
        self.refused("subprocess-failed")

    def test_wrong_oidc_trust_is_refused(self):
        self.case["subject"] = "repo:honua-io/honua-release:environment:cert"
        self.refused("live-role-trust-mismatch")

    def test_wildcard_stringlike_trust_is_refused(self):
        self.case["subject"] = "repo:honua-io/honua-server:*"
        self.refused("live-role-trust-mismatch")

    def test_roleless_existing_backend_is_refused(self):
        del self.backend_config["assume_role_with_web_identity"]
        self.write_backend()
        self.refused("backend-web-identity-required")

    def test_backend_substitution_is_refused(self):
        self.backend_config["key"] = "other/state"
        self.write_backend()
        self.refused("backend-mismatch")

    def test_workspace_substitution_is_refused(self):
        self.case["workspace"] = "new-or-empty"
        self.refused("backend-mismatch")

    def test_missing_or_wrong_prior_state_is_refused(self):
        for lineage in (None, "another-existing-lineage"):
            with self.subTest(lineage=lineage):
                self.case["lineage"] = lineage
                self.refused("state-mismatch")

    def test_stale_identity_contract_is_refused(self):
        self.request["workloadIdentityContractDigest"] = "0" * 64
        self.refused("identity-contract-digest-mismatch")

    def test_long_plan_uses_post_plan_creation_and_real_session_deadlines(self):
        now = datetime.now(timezone.utc)
        created = now - timedelta(seconds=1)
        metadata = {"created_at_utc": created.isoformat(),
                    "expires_at_utc": (created + timedelta(seconds=300)).isoformat()}
        claims = {"exp": (now + timedelta(hours=1)).timestamp()}
        # A five-minute refresh must not invalidate a full five-minute review TTL.
        producer.validate_expiry(metadata, self.request, claims, now - timedelta(minutes=5))
        claims["exp"] = (now + timedelta(seconds=120)).timestamp()
        with self.assertRaisesRegex(producer.Refused, "session-expiring"):
            producer.validate_expiry(metadata, self.request, claims, now - timedelta(minutes=5))

    def test_plan_timeout_is_separate_from_review_lifetime(self):
        self.request["expiresInSeconds"] = 60
        self.request["planTimeoutSeconds"] = 120
        claims = {"exp": (datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp()}
        self.assertEqual(producer.planning_seconds(self.request, claims), 120)

    def test_ignored_backend_cannot_hide_resources(self):
        with (self.root / "backend.tf").open("a") as output:
            output.write('\nresource "aws_s3_bucket" "unreviewed" { bucket = "outside-reviewed-source" }\n')
        self.refused("backend-source-invalid")

    def test_ignored_terraform_file_is_refused(self):
        (self.root / "ignored-resources.tf").write_text('resource "null_resource" "unreviewed" {}')
        self.refused("ignored-terraform-source-refused")

    def test_skip_worktree_flag_cannot_hide_source_changes(self):
        subprocess.run(["git", "update-index", "--skip-worktree", str(self.root / "main.tf")],
                       cwd=self.repository, capture_output=True, check=True)
        (self.root / "main.tf").write_text("# hidden source modification\n")
        self.refused("terraform-source-modified")

    def test_expiring_session_is_refused(self):
        self.request["sessionExpiresAtUtc"] = datetime.now(timezone.utc).isoformat()
        self.refused("session-expiring")

    def test_source_pin_or_toolchain_mismatch_is_refused(self):
        for key, value, reason in (("iacRevision", "0" * 40, "source-mismatch"),
                                   ("terraformVersion", "1.11.0", "toolchain-mismatch"),
                                   ("providerLockSha256", "0" * 64, "provider-lock-mismatch")):
            with self.subTest(key=key):
                original = self.request[key]
                self.request[key] = value
                self.refused(reason)
                self.request[key] = original

    def test_git_config_cannot_redirect_source_to_clean_mirror(self):
        mirror = self.base / "clean-mirror"
        shutil.copytree(self.repository, mirror, ignore=shutil.ignore_patterns(".git"))
        subprocess.run(["git", "config", "core.worktree", str(mirror)], cwd=self.repository,
                       capture_output=True, check=True)
        (self.root / "main.tf").write_text("# unapproved changed Terraform\n")
        self.refused("source-dirty")

    def test_input_replacement_and_mutable_image_are_refused(self):
        self.var_file.write_text('{}')
        self.refused("input-file-mismatch")

    def test_mutable_or_rebound_images_are_refused(self):
        self.request["imagePins"]["gp_batch_image"] = "unapproved:latest"
        self.refused("image-input-invalid")

    def test_wrong_account_or_region_secret_reference_is_refused(self):
        self.variables["audit_chain_key_secret_arn"] = "arn:aws:secretsmanager:us-west-2:999999999999:secret:other-ABC123"
        self.request["secretReferences"]["audit_chain_key_secret_arn"] = self.variables["audit_chain_key_secret_arn"]
        save(self.var_file, self.variables)
        self.request["varFileSha256"] = sha(self.var_file.read_bytes())
        self.refused("secret-reference-invalid")

    def test_pro_license_inputs_are_refused(self):
        self.variables["enable_pro_license"] = True
        save(self.var_file, self.variables)
        self.request["varFileSha256"] = sha(self.var_file.read_bytes())
        self.refused("licensing-input-invalid")

    def test_missing_custom_code_pin_is_refused(self):
        self.variables["enable_customcode_batch"] = True
        save(self.var_file, self.variables)
        self.request["varFileSha256"] = sha(self.var_file.read_bytes())
        self.refused("image-input-invalid")

    def test_partial_plan_never_completes_packet(self):
        self.case["planExit"] = 1
        self.refused("subprocess-failed", plan_started=True)
        self.assertTrue(list(self.private.glob("aws-cert-plan-*/plan.bin")))

    def test_state_drift_after_plan_never_completes_packet(self):
        self.case["serialAfter"] = 43
        self.refused("state-mismatch", plan_started=True)

    def test_workspace_drift_after_plan_never_completes_packet(self):
        self.case["workspaceAfter"] = "substituted"
        self.refused("backend-mismatch", plan_started=True)

    def test_hosted_temp_runtime_is_not_durable_retention(self):
        self.env["RUNNER_ENVIRONMENT"] = "github-hosted"
        self.refused("durable-private-runtime-required")

    def test_private_directory_permissions_are_required(self):
        self.private.chmod(0o755)
        self.refused("private-path-permissions")

    def test_private_file_in_replaceable_directory_is_refused(self):
        shared = self.base / "replaceable"
        shared.mkdir(mode=0o777)
        shared.chmod(0o777)
        var_file = shared / "approved.tfvars.json"
        shutil.copyfile(self.var_file, var_file)
        var_file.chmod(0o600)
        self.request["varFile"] = str(var_file)
        self.refused("private-path-parent-permissions")

    def test_symlinked_backend_token_is_refused(self):
        link = self.private / "token-link"
        link.symlink_to(self.tokens)
        self.request["backendTokenFile"] = str(link)
        self.refused("private-path-symlink")

    def test_implicit_tfvars_are_refused(self):
        (self.root / "surprise.auto.tfvars").write_text('honua_image = "unapproved"')
        self.refused("implicit-input-refused")


if __name__ == "__main__":
    unittest.main()
