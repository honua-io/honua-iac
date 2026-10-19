#!/usr/bin/env python3
"""Hermetic CLI controls: real maintained wrappers, synthetic Git/AWS/Terraform.

The fake tools journal every call; no network, cloud credentials or Terraform
installation is used. Synthetic STS/token output is never live AWS evidence.
"""
import base64
import hashlib
import json
import os
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
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
        provider_dir = self.root / ".terraform/providers/registry.terraform.io/hashicorp/aws/6.0.0/linux_amd64"
        provider_dir.mkdir(parents=True)
        self.provider = provider_dir / "terraform-provider-aws_v6.0.0"
        self.provider.write_bytes(b"authored synthetic provider executable\n")
        self.provider.chmod(0o755)
        # Independent GNU sha256sum/OpenSSL vector for this exact file, following
        # Go dirhash.Hash1's two-space records (golang.org/x/mod/sumdb/dirhash).
        package_hash = "h1:W+wOXIl+pNU0L7dzJujxeJ52xJWJUZxLjx8DYGvbd8I="
        (self.root / ".terraform.lock.hcl").write_text(
            'provider "registry.terraform.io/hashicorp/aws" {\n'
            '  version = "6.0.0"\n  hashes = ["' + package_hash + '"]\n}\n')
        modules = self.root / ".terraform/modules"
        (modules / "vpc").mkdir(parents=True)
        (modules / "vpc/main.tf").write_text("locals { downloaded_module = true }\n")
        local_module = self.repository / "infrastructure/terraform/modules/fixture"
        local_module.mkdir(parents=True)
        (local_module / "main.tf").write_text("locals { local_module = true }\n")
        (modules / "honua").symlink_to(local_module, target_is_directory=True)
        (modules / "modules.json").write_text(json.dumps({"Modules": [
            {"Key": "", "Source": "", "Dir": "."},
            {"Key": "honua", "Source": "../../modules/fixture", "Dir": ".terraform/modules/honua"},
            {"Key": "honua.vpc", "Source": "registry.terraform.io/terraform-aws-modules/vpc/aws",
             "Version": "5.21.0", "Dir": ".terraform/modules/vpc"}]}))
        self.bootstrap = self.root / "postgis-bootstrap"
        (self.bootstrap / "build").mkdir(parents=True)
        (self.bootstrap / "handler.py").write_text("def handler(event, context): return {'ok': True}\n")
        shutil.copyfile(self.bootstrap / "handler.py", self.bootstrap / "build/handler.py")
        (self.bootstrap / "build/dependency.py").write_text("AUTHORED_DEPENDENCY_VERSION = 1\n")
        self.write_bootstrap_zip()

        bootstrap_relative = producer.ROOT_REL + "/postgis-bootstrap"
        (self.repository / ".gitignore").write_text(
            ".terraform/\nbackend.tf\nignored*.tf\n__pycache__/\n"
            + bootstrap_relative + "/build/\n"
            + bootstrap_relative + "/bootstrap.zip\n")
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
                     "lineage": "authored-existing-lineage", "version": "1.10.5", "sentinel": SENTINEL, "root": str(self.root)}
        self.case_file = self.base / "case.json"
        self.journal = self.base / "journal.jsonl"
        tools = self.base / "tools"
        tools.mkdir()
        fake = '''#!/usr/bin/python3
import base64,hashlib,json,os,sys
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
 assert Path(os.environ['TF_CLI_CONFIG_FILE']).read_bytes()==b''
 assert 'TF_REATTACH_PROVIDERS' not in os.environ
 if 'home' in c: assert os.environ['HOME']==c['home']
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
  if c.get('mutateBuild'): (Path(c['root'])/'postgis-bootstrap/build/dependency.py').write_text('CHANGED_DURING_PLAN = True')
  if c.get('mutateModule'): (Path(c['root'])/'.terraform/modules/vpc/main.tf').write_text('CHANGED_DURING_PLAN = True')
  if c.get('mutateProvider'): (Path(c['root'])/'.terraform/providers/registry.terraform.io/hashicorp/aws/6.0.0/linux_amd64/terraform-provider-aws_v6.0.0').write_text('CHANGED DURING PLAN')
  print(c['sentinel']);sys.exit(c.get('planExit',0))
 elif cmd=='show':
  if '-json' in a:
   archive=str(Path(c['root'])/'postgis-bootstrap/bootstrap.zip')
   digest=base64.b64encode(hashlib.sha256(Path(archive).read_bytes()).digest()).decode()
   function={'filename':c.get('bootstrapFilename',archive),'source_code_hash':c.get('bootstrapHash',digest)}
   print(json.dumps({'resource_changes':[
    {'address':'terraform_data.postgis_bootstrap_build','change':{'actions':c.get('buildActions',['no-op'])}},
    {'address':'data.archive_file.postgis_bootstrap','change':{'actions':c.get('archiveActions',['no-op'])}},
    {'address':'aws_lambda_function.postgis_bootstrap','change':{'actions':['no-op'],'after':function,'after_unknown':{'source_code_hash':c.get('unknownHash',False)}}}],
    'planned_values':{'root_module':{'resources':[
    {'address':'data.archive_file.postgis_bootstrap','values':{'output_base64sha256':digest,'output_path':archive}},
    {'address':'aws_lambda_function.postgis_bootstrap','values':function}]}}}))
  else: print('private resource review '+c['sentinel'])
 else: sys.exit(88)
'''
        fake = fake.replace("os.environ['TEST_CERT_CASE']", repr(str(self.case_file)))
        fake = fake.replace("os.environ['TEST_CERT_JOURNAL']", repr(str(self.journal)))
        for name in ("aws", "terraform"):
            path = tools / name
            path.write_text(fake)
            path.chmod(0o700)
        refused_ambient = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "REQUESTS_CA_BUNDLE",
                           "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "BASHOPTS", "SHELLOPTS",
                           "BASH_COMPAT", "BASH_LOADABLES_PATH", "CDPATH", "GLOBIGNORE",
                           "POSIXLY_CORRECT", "PS4", "IFS"}
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("TF_", "GIT_", "HONUA_IAC_", "AWS_", "LD_", "PYTHON", "BASH_FUNC_"))
                    and k.upper() not in refused_ambient}
        self.env.update(PATH=str(tools) + ":" + os.environ["PATH"], AWS_ACCESS_KEY_ID="synthetic",
                        AWS_SECRET_ACCESS_KEY="synthetic", AWS_SESSION_TOKEN="synthetic", RUNNER_ENVIRONMENT="self-hosted")
        for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "authored fixture"]):
            subprocess.run(["git", *args], cwd=self.repository, check=True, capture_output=True)
        for relative in (bootstrap_relative + "/build/handler.py", bootstrap_relative + "/bootstrap.zip"):
            self.assertEqual(subprocess.run(["git", "check-ignore", "-q", relative], cwd=self.repository,
                                            capture_output=True, check=False).returncode, 0)
            self.assertEqual(subprocess.run(["git", "ls-files", "--error-unmatch", relative], cwd=self.repository,
                                            capture_output=True, check=False).returncode, 1)
        self.request["iacRevision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repository, text=True).strip()
        self.request_file = self.private / "request.json"

    def write_bootstrap_zip(self):
        with zipfile.ZipFile(self.bootstrap / "bootstrap.zip", "w") as archive:
            for path in sorted((self.bootstrap / "build").rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(self.bootstrap / "build").as_posix())

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
        result = subprocess.run(["python3", "-I", str(self.entrypoint), "--request", str(self.request_file)],
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
        self.assertEqual(len(descriptor["files"]), 11)
        for name, expected in descriptor["files"].items():
            self.assertEqual(sha((packet / name).read_bytes()), expected)
            self.assertEqual(stat.S_IMODE((packet / name).stat().st_mode), 0o600)
        self.assertIn(SENTINEL, (packet / "diagnostic.log").read_text())
        self.assertIn(SENTINEL, (packet / "review.txt").read_text())
        self.assertFalse(any(b"MUST_NOT_BE_RETAINED" in p.read_bytes() for p in packet.iterdir()))
        self.assertEqual((packet / "bootstrap.zip").read_bytes(), (self.bootstrap / "bootstrap.zip").read_bytes())
        self.assertEqual(set(json.loads((packet / "bootstrap-inputs.json").read_text())["files"]),
                         {"handler.py", "dependency.py"})
        modules = json.loads((packet / "module-inputs.json").read_text())
        self.assertEqual(modules["schema"], "honua.aws-cert-module-inputs/v2")
        self.assertEqual(modules["modules"][-1]["version"], "5.21.0")
        self.assertIn("vpc/main.tf", modules["files"])
        self.assertEqual(modules["links"]["honua"], "infrastructure/terraform/modules/fixture")
        self.assertEqual(modules["providers"][0]["address"], "registry.terraform.io/hashicorp/aws")
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
        for name in ("TF_CLI_ARGS_plan", "TF_VAR_honua_image", "TF_WORKSPACE", "TF_LOG", "TF_LOG_PATH", "TF_CLI_CONFIG_FILE", "TERRAFORM_CONFIG", "TF_REATTACH_PROVIDERS", "TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE", "GIT_WORK_TREE", "GIT_DIR", "GIT_INDEX_FILE", "HONUA_IAC_OFFLINE", "HONUA_IAC_TERRAFORM_BIN", "AWS_PROFILE", "AWS_ENDPOINT_URL_IAM", "AWS_STS_ENDPOINT", "AWS_S3_ENDPOINT", "AWS_IAM_ENDPOINT", "AWS_DYNAMODB_ENDPOINT", "AWS_CA_BUNDLE", "SSL_CERT_DIR", "https_proxy", "REQUESTS_CA_BUNDLE", "AWS_CONFIG_FILE", "BASH_ENV", "BASH_FUNC_terraform%%", "BASHOPTS", "SHELLOPTS", "CDPATH", "GLOBIGNORE", "POSIXLY_CORRECT", "PS4", "LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH", "PYTHONUSERBASE", "PYTHONWARNINGS", "PYTHONINSPECT"):
            with self.subTest(name=name):
                self.env[name] = "refuse"
                # Loader variables act before Python starts; exercise the
                # refusal in-process, then rely on the supported launcher to
                # sanitize them before it obtains credentials.
                if name.startswith("LD_"):
                    with mock.patch.dict(os.environ, self.env, clear=True), self.assertRaises(producer.Refused):
                        producer.environment(self.request, self.root)
                else:
                    self.refused("environment-override-refused")
                del self.env[name]

    def test_empty_loader_variables_match_hosted_launcher(self):
        self.env.update(LD_PRELOAD="", LD_AUDIT="", LD_LIBRARY_PATH="")
        self.env["UNREVIEWED_CHILD_ENV"] = "do-not-forward"
        with mock.patch.dict(os.environ, self.env, clear=True):
            admitted = producer.environment(self.request, self.root)
        self.assertFalse(any(name in admitted for name in ("LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
                                                       "UNREVIEWED_CHILD_ENV")))
        self.assertEqual(admitted["HOME"], self.env["HOME"])
        self.assertEqual(admitted["PATH"], self.env["PATH"])
        self.assertEqual(admitted["TMPDIR"], str(self.private))

    def test_isolated_interpreter_blocks_import_override_before_refusal(self):
        hostile = self.base / "hostile-python"
        hostile.mkdir()
        marker = self.base / "sitecustomize-ran"
        (hostile / "sitecustomize.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('ran')\n")
        self.env["PYTHONPATH"] = str(hostile)
        self.refused("environment-override-refused")
        self.assertFalse(marker.exists())
        del self.env["PYTHONPATH"]
        save(self.request_file, self.request)
        result = subprocess.run(["python3", str(self.entrypoint), "--request", str(self.request_file)],
                                env=self.env, cwd=self.repository, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["reason"], "isolated-python-required")

    def test_default_cli_dev_overrides_are_not_loaded_and_home_is_preserved(self):
        home = self.private / "home"
        home.mkdir(mode=0o700)
        ambient = home / ".terraformrc"
        ambient.write_text('provider_installation { dev_overrides { "hashicorp/aws" = "/unapproved" } }')
        self.env["HOME"] = str(home)
        self.case["home"] = str(home)
        result, receipt, _ = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(receipt["status"], "planned-unapproved")
        self.assertIn("dev_overrides", ambient.read_text())
        self.assertFalse(list(self.private.glob(".cert-cli-*")))

    def test_python_children_ignore_user_site_hooks_with_home_preserved(self):
        home = self.private / "home"
        site = home / f".local/lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages"
        site.mkdir(parents=True)
        customize_marker = self.base / "usercustomize-ran"
        pth_marker = self.base / "user-pth-ran"
        (site / "usercustomize.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(customize_marker)) + ").write_text('ran')\n")
        (site / "hostile.pth").write_text(
            "import pathlib; pathlib.Path(" + repr(str(pth_marker)) + ").write_text('ran')\n")
        self.env["HOME"] = str(home)
        self.case["home"] = str(home)
        subprocess.run(["python3", "-c", "pass"], env=self.env, cwd=self.repository,
                       check=True, capture_output=True)
        self.assertTrue(customize_marker.exists())
        self.assertTrue(pth_marker.exists())
        customize_marker.unlink()
        pth_marker.unlink()
        result, receipt, _ = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(receipt["status"], "planned-unapproved")
        self.assertFalse(customize_marker.exists())
        self.assertFalse(pth_marker.exists())

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

    def test_initialized_backend_transport_overrides_are_refused_before_commands(self):
        # Terraform serializes unused S3 backend fields as null; those remain
        # compatible, while any active unreviewed field is refused.
        producer.validate_backend_transport({**self.backend_config,
                                             "access_key": None, "secret_key": None,
                                             "sts_endpoint": None, "profile": None})
        overrides = (("sts_endpoint", "https://sts.attacker.invalid"),
                     ("endpoints", {"sts": "https://sts.attacker.invalid"}),
                     ("endpoints", {"s3": "https://s3.attacker.invalid"}),
                     ("custom_ca_bundle", "/unapproved/ca.pem"),
                     ("shared_config_files", ["/unapproved/config"]),
                     ("insecure", True),
                     ("access_key", "unapproved-key"),
                     ("secret_key", "unapproved-secret"),
                     ("token", "unapproved-token"),
                     ("sse_customer_key", "unapproved-key"),
                     ("profile", "unapproved-profile"))
        for key, value in overrides:
            with self.subTest(key=key, value=value):
                config = {**self.backend_config, key: value}
                save(self.root / ".terraform/terraform.tfstate",
                     {"backend": {"type": "s3", "config": config}})
                self.refused("backend-transport-override-refused")
                self.assertFalse(self.journal.exists())
        config = {**self.backend_config, "assume_role_with_web_identity": {
            **self.backend_config["assume_role_with_web_identity"], "web_identity_token": "unapproved-token"}}
        save(self.root / ".terraform/terraform.tfstate", {"backend": {"type": "s3", "config": config}})
        self.refused("backend-transport-override-refused")
        self.assertFalse(self.journal.exists())

    def test_writable_backend_descriptor_is_refused_before_commands(self):
        descriptor = self.root / ".terraform/terraform.tfstate"
        descriptor.chmod(0o660)
        self.refused("backend-path-permissions")
        self.assertFalse(self.journal.exists())

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
        self.refused("hidden-index-flags-refused")

    def test_replacement_commit_cannot_hide_source_changes(self):
        (self.root / "main.tf").write_text("# substituted Terraform source\n")
        subprocess.run(["git", "add", str(self.root / "main.tf")], cwd=self.repository,
                       capture_output=True, check=True)
        tree = subprocess.check_output(["git", "write-tree"], cwd=self.repository, text=True).strip()
        original = self.request["iacRevision"]
        alternate = subprocess.check_output(
            ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "commit-tree", tree, "-p", original, "-m", "synthetic replacement"],
            cwd=self.repository, text=True).strip()
        subprocess.run(["git", "replace", original, alternate], cwd=self.repository,
                       capture_output=True, check=True)
        self.assertFalse(subprocess.check_output(["git", "status", "--porcelain"],
                                                 cwd=self.repository).strip())
        self.refused("source-dirty")

    def test_each_maintained_helper_hidden_change_is_refused_before_execution(self):
        for relative in ("scripts/lib/tf-exec-contract.sh", "scripts/terraform-exact-plan.sh"):
            for flag in ("skip-worktree", "assume-unchanged"):
                with self.subTest(helper=relative, flag=flag):
                    path = self.repository / relative
                    original = path.read_bytes()
                    marker = self.private / "unexpected-helper-execution"
                    subprocess.run(["git", "update-index", "--" + flag, relative], cwd=self.repository,
                                   capture_output=True, check=True)
                    path.write_bytes(original + ("\nprintf injected > " + shlex.quote(str(marker)) + "\n").encode())
                    self.refused("hidden-index-flags-refused")
                    self.assertFalse(marker.exists())
                    self.assertFalse(self.journal.exists())
                    path.write_bytes(original)
                    subprocess.run(["git", "update-index", "--no-" + flag, relative], cwd=self.repository,
                                   capture_output=True, check=True)

    def test_writable_helper_or_parent_is_refused_before_execution(self):
        helper = self.repository / "scripts/terraform-exact-plan.sh"
        for path in (helper, helper.parent):
            with self.subTest(path=path):
                original_mode = path.stat().st_mode & 0o777
                path.chmod(original_mode | 0o020)
                try:
                    self.refused("helper-path-permissions")
                    self.assertFalse(self.journal.exists())
                finally:
                    path.chmod(original_mode)

    def test_writable_terraform_source_or_parent_is_refused_before_plan(self):
        paths = (self.root / "main.tf", self.bootstrap,
                 self.repository / "infrastructure/terraform/modules/fixture")
        for path in paths:
            with self.subTest(path=path):
                original_mode = path.stat().st_mode & 0o777
                path.chmod(original_mode | 0o020)
                try:
                    self.refused("terraform-source-path-permissions")
                    self.assertFalse(self.journal.exists())
                finally:
                    path.chmod(original_mode)

    def test_timed_out_child_gets_interrupt_before_forced_kill(self):
        graceful = self.base / "graceful.py"
        marker = self.base / "lock-released"
        graceful.write_text("import signal, sys, time\nfrom pathlib import Path\n"
                            + "def release(signum, frame):\n    Path(" + repr(str(marker))
                            + ").write_text('released')\n    sys.exit(0)\n"
                            + "signal.signal(signal.SIGINT, release)\n"
                            + "while True: time.sleep(0.05)\n")
        commands = producer.Commands(self.repository, self.private, self.env)
        with mock.patch.object(producer.os, "killpg", wraps=os.killpg) as kill, \
             self.assertRaises(subprocess.TimeoutExpired):
            commands.run(["python3", "-I", str(graceful)], seconds=1)
        self.assertEqual(marker.read_text(), "released")
        self.assertEqual([call.args[1] for call in kill.call_args_list], [signal.SIGINT])

        stubborn = self.base / "stubborn.py"
        stubborn.write_text("import signal, time\nsignal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                            "while True: time.sleep(0.05)\n")
        with mock.patch.object(producer, "INTERRUPT_GRACE_SECONDS", 0.2), \
             mock.patch.object(producer.os, "killpg", wraps=os.killpg) as kill, \
             self.assertRaises(subprocess.TimeoutExpired):
            commands.run(["python3", "-I", str(stubborn)], seconds=1)
        self.assertEqual([call.args[1] for call in kill.call_args_list],
                         [signal.SIGINT, signal.SIGKILL])

    def test_fsmonitor_cannot_hide_modified_helper(self):
        monitor = self.private / "untrusted-fsmonitor"
        monitor.write_text("#!/bin/sh\nprintf '\\0'\n")
        monitor.chmod(0o700)
        subprocess.run(["git", "config", "core.fsmonitor", str(monitor)], cwd=self.repository,
                       capture_output=True, check=True)
        helper = self.repository / "scripts/lib/tf-exec-contract.sh"
        helper.write_bytes(helper.read_bytes() + b"\n# substituted helper\n")
        with mock.patch.dict(os.environ, self.env, clear=True):
            env = producer.environment(self.request, self.root)
        commands = producer.Commands(self.repository, self.private, env)
        self.assertEqual(commands.run(["git", "config", "--get", "core.fsmonitor"]).strip(), b"false")
        self.assertEqual(commands.run(["git", "config", "--get", "core.untrackedCache"]).strip(), b"false")
        with self.assertRaisesRegex(producer.Refused, "helper-source-modified"):
            producer.validate_runtime_source(commands, self.root, self.repository, self.backend_config)

    def test_bootstrap_handler_must_match_committed_source(self):
        (self.bootstrap / "build/handler.py").write_text("def handler(event, context): return 'substitution'")
        self.write_bootstrap_zip()
        self.refused("bootstrap-handler-source-mismatch")

    def test_bootstrap_dependency_drift_during_plan_is_refused(self):
        self.case["mutateBuild"] = True
        self.refused("bootstrap-build-drift", plan_started=True)

    def test_missing_initialized_module_index_is_refused(self):
        (self.root / ".terraform/modules/modules.json").unlink()
        self.refused("module-cache-required")

    def test_empty_resolved_module_is_refused(self):
        (self.root / ".terraform/modules/vpc/main.tf").unlink()
        self.refused("module-cache-incomplete")

    def test_module_cache_drift_during_plan_is_refused(self):
        self.case["mutateModule"] = True
        self.refused("module-cache-drift", plan_started=True)

    def test_module_cache_external_symlink_is_refused(self):
        (self.root / ".terraform/modules/external").symlink_to(self.private, target_is_directory=True)
        self.refused("module-cache-symlink-refused")

    def test_substituted_provider_is_refused_before_terraform_or_aws(self):
        self.provider.write_bytes(b"substituted executable\n")
        self.refused("provider-checksum-mismatch")
        self.assertFalse(self.journal.exists())

    def test_one_space_provider_checksum_is_refused(self):
        # This was the previous, incorrect fixture checksum. Go Hash1 uses two spaces.
        lock = self.root / ".terraform.lock.hcl"
        lock.write_text(lock.read_text().replace(
            "h1:W+wOXIl+pNU0L7dzJujxeJ52xJWJUZxLjx8DYGvbd8I=",
            "h1:jBoEoxML/rBC44Aq+jgFI+BnQMpmiRQsKkz/cxzdIEw="))
        subprocess.run(["git", "add", str(lock.relative_to(self.repository))],
                       cwd=self.repository, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "one-space lock checksum"],
                       cwd=self.repository, check=True, capture_output=True)
        self.request["iacRevision"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.repository, text=True).strip()
        self.request["providerLockSha256"] = sha(lock.read_bytes())
        self.refused("provider-checksum-mismatch")
        self.assertFalse(self.journal.exists())

    def test_provider_cache_drift_during_plan_is_refused(self):
        self.case["mutateProvider"] = True
        self.refused("provider-checksum-mismatch", plan_started=True)

    def test_locked_provider_in_private_plugin_cache_is_accepted(self):
        package = self.provider.parent
        cached = self.base / "provider-cache"
        package.rename(cached)
        package.symlink_to(cached, target_is_directory=True)
        result, receipt, _ = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(receipt["status"], "planned-unapproved")

    def test_missing_provider_cache_is_refused(self):
        self.provider.unlink()
        self.refused("provider-cache-incomplete")

    def test_bootstrap_zip_must_contain_exact_build_bytes(self):
        with zipfile.ZipFile(self.bootstrap / "bootstrap.zip", "w") as archive:
            archive.writestr("handler.py", "substituted ZIP payload")
        self.refused("bootstrap-archive-input-mismatch", plan_started=True)

    def test_bootstrap_deferred_rebuild_or_archive_is_refused(self):
        for key, value, reason in (("buildActions", ["delete", "create"], "bootstrap-deferred-build-refused"),
                                   ("archiveActions", ["read"], "bootstrap-deferred-archive-refused")):
            with self.subTest(key=key):
                self.case[key] = value
                self.refused(reason, plan_started=True)
                del self.case[key]

    def test_bootstrap_plan_accepts_root_module_relative_path(self):
        self.case["bootstrapFilename"] = "./postgis-bootstrap/bootstrap.zip"
        result, _, _ = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_bootstrap_saved_plan_hash_path_or_unknown_value_is_refused(self):
        for key, value in (("bootstrapHash", "different-payload"), ("bootstrapFilename", "/other/payload.zip"),
                           ("unknownHash", True)):
            with self.subTest(key=key):
                self.case[key] = value
                self.refused("bootstrap-plan-hash-mismatch", plan_started=True)
                del self.case[key]

    def test_bootstrap_zip_links_and_traversal_are_refused(self):
        for name, mode in (("../handler.py", stat.S_IFREG), ("handler.py", stat.S_IFLNK)):
            with self.subTest(name=name):
                with zipfile.ZipFile(self.bootstrap / "bootstrap.zip", "w") as archive:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = (mode | 0o644) << 16
                    archive.writestr(info, "untrusted")
                self.refused("bootstrap-entry-invalid", plan_started=True)

    def test_bootstrap_build_symlink_is_refused_before_plan(self):
        (self.bootstrap / "build/dependency.py").unlink()
        (self.bootstrap / "build/dependency.py").symlink_to(self.bootstrap / "handler.py")
        self.refused("bootstrap-input-type-or-permissions")

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


class HostedSessionBounds(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.request = {"schema": "honua.aws-cert-plan-request/v2", "expiresInSeconds": 900,
                        "planTimeoutSeconds": 1800,
                        "sessionExpiresAtUtc": (self.now + timedelta(hours=1)).isoformat()}

    def test_actual_backend_descriptor_requires_one_hour(self):
        for web in ({}, {"duration": "45m"}, {"duration": "2h"}):
            with self.subTest(web=web), self.assertRaisesRegex(producer.Refused, "backend-session-duration-required"):
                producer.backend_session_deadline(self.request, {"assume_role_with_web_identity": web}, self.now)
        deadline = producer.backend_session_deadline(
            self.request, {"assume_role_with_web_identity": {"duration": "1h"}}, self.now)
        self.assertEqual(deadline, self.now + timedelta(minutes=55))

    def test_token_must_still_be_valid_at_exact_plan_start(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "token"
            for offset, refused in ((50, True), (120, False)):
                claims = {"iss": producer.ISSUER, "sub": producer.SUBJECT,
                          "aud": producer.AUDIENCE,
                          "exp": int((datetime.now(timezone.utc) + timedelta(seconds=offset)).timestamp())}
                payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
                path.write_text("header." + payload + ".signature")
                if refused:
                    with self.assertRaisesRegex(producer.Refused, "backend-token-expiring-before-plan"):
                        producer.token_at_plan_start(path, claims)
                else:
                    producer.token_at_plan_start(path, claims)
            renewed = dict(claims, exp=int((datetime.now(timezone.utc)
                                            + timedelta(minutes=5)).timestamp()))
            payload = base64.urlsafe_b64encode(json.dumps(renewed).encode()).decode().rstrip("=")
            path.write_text("header." + payload + ".signature")
            producer.token_at_plan_start(path, claims)

    def test_post_plan_facts_require_fresh_bound_backend_token(self):
        claims = {"iss": producer.ISSUER, "sub": producer.SUBJECT,
                  "aud": producer.AUDIENCE, "exp": 0}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "token"

            def token(**changes):
                current = dict(claims, exp=int((datetime.now(timezone.utc)
                                                + timedelta(minutes=5)).timestamp()))
                current.update(changes)
                payload = base64.urlsafe_b64encode(json.dumps(current).encode()).decode().rstrip("=")
                path.write_text("header." + payload + ".signature")

            token()
            producer.token_for_post_plan_facts(path, claims)
            token(exp=int((datetime.now(timezone.utc) + timedelta(seconds=170)).timestamp()))
            with self.assertRaisesRegex(producer.Refused, "backend-token-expiring-before-post-plan-facts"):
                producer.token_for_post_plan_facts(path, claims)
            token(sub="repo:untrusted/other")
            with self.assertRaisesRegex(producer.Refused, "backend-token-expiring-before-post-plan-facts"):
                producer.token_for_post_plan_facts(path, claims)
            path.write_text("not-a-jwt")
            with self.assertRaisesRegex(producer.Refused, "backend-token-invalid"):
                producer.token_for_post_plan_facts(path, claims)

    def test_planning_timeout_and_packet_expiry_share_backend_bound(self):
        deadline = self.now + timedelta(minutes=55)
        self.assertLessEqual(producer.planning_seconds(self.request, {"exp": 0}, deadline)
                             + producer.INTERRUPT_GRACE_SECONDS
                             + self.request["expiresInSeconds"], 55 * 60)
        self.request["expiresInSeconds"] = 1800
        self.request["sessionExpiresAtUtc"] = (self.now + timedelta(minutes=30)).isoformat()
        with self.assertRaisesRegex(producer.Refused, "session-expiring"):
            producer.planning_seconds(self.request, {"exp": 0}, self.now + timedelta(minutes=20))


if __name__ == "__main__":
    unittest.main()
