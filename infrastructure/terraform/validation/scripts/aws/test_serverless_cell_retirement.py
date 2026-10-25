"""Failure controls for the disposable-cell retirement boundary; no AWS writes."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

from serverless_cell_retirement import (
    CELL_TAG, RUN_TAG, OVERRIDE_NAME, RetirementRefused, inventory,
    observe_lambda_readers, prepare_override, validate_plan, retire,
)

ACCOUNT = "123456789012"
REGION = "us-east-1"
RUN = "39911551529"
CELL = "aws-serverless/redis-off"
FUNCTION = f"arn:aws:lambda:{REGION}:{ACCOUNT}:function:owned"
SECRET = f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:owned/runtime-settings-abc-123456"


def row(kind, name, values, tagged=True):
    if tagged:
        values["tags_all"] = {RUN_TAG: RUN, CELL_TAG: CELL}
    return {"mode": "managed", "type": kind, "address": f"module.honua.{kind}.{name}", "values": values}


def fixture():
    return {"values": {"root_module": {"child_modules": [{"resources": [
        row("aws_lambda_function", "this", {"id": "owned", "arn": FUNCTION, "function_name": "owned"}),
        row("aws_secretsmanager_secret", 'runtime_settings["abc"]',
            {"id": SECRET, "arn": SECRET, "name": "owned/runtime-settings-abc"}),
        row("aws_secretsmanager_secret_version", 'runtime_settings["abc"]',
            {"id": SECRET + "|v1", "secret_id": SECRET}, False),
        row("aws_lambda_alias", "live", {"id": FUNCTION + ":live", "function_name": "owned"}, False),
    ]}]}}}


def inspect(state):
    return inventory(state, run_id=RUN, cell=CELL, account_id=ACCOUNT, region=REGION)


def plan_for(state):
    rows = state["values"]["root_module"]["child_modules"][0]["resources"]
    return {"complete": True, "applyable": True, "resource_changes": [
        {"address": r["address"], "type": r["type"], "mode": "managed",
         "change": {"actions": ["delete"], "before": r["values"], "after": None}} for r in rows]}


class Paginator:
    def __init__(self, fn):
        self.fn = fn

    def paginate(self, **kwargs):
        yield from self.fn(**kwargs)


class Lambda:
    def __init__(self, versions):
        self.versions = versions

    def get_paginator(self, name):
        if name == "list_functions":
            return Paginator(lambda: [{"Functions": [{"FunctionArn": arn}]} for arn in self.versions])
        assert name == "list_versions_by_function"
        return Paginator(lambda FunctionName: [{"Versions": [v]} for v in self.versions[FunctionName]])


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.state = fixture()
        self.rows = self.state["values"]["root_module"]["child_modules"][0]["resources"]

    def test_complete_original_cell_can_prepare_delete_only_plan(self):
        record = inspect(self.state)
        observed = observe_lambda_readers(Lambda({FUNCTION: [{"Version": "$LATEST"}, {"Version": "7"}]}), record)
        with tempfile.TemporaryDirectory() as directory:
            module = Path(directory)
            source = 'resource "first" "x" {\n prevent_destroy = true\n}\nresource "second" "y" {\n prevent_destroy = true\n}\n'
            (module / "runtime-settings.tf").write_text(source)
            receipt = prepare_override(module, record, observed)
            self.assertEqual(source, (module / "runtime-settings.tf").read_text())
            self.assertEqual(2, len(json.loads((module / OVERRIDE_NAME).read_text())["resource"]))
            self.assertEqual(4, validate_plan(plan_for(self.state), receipt)["destroyCount"])

    def test_mixed_run_or_cell_tags_refused(self):
        for tag in (RUN_TAG, CELL_TAG):
            state = copy.deepcopy(self.state)
            state["values"]["root_module"]["child_modules"][0]["resources"][0]["values"]["tags_all"][tag] = "foreign"
            with self.subTest(tag=tag), self.assertRaises(RetirementRefused):
                inspect(state)

    def test_foreign_parent_child_refused(self):
        self.rows[-1]["values"]["function_name"] = "standing-production"
        with self.assertRaises(RetirementRefused):
            inspect(self.state)

    def test_unknown_untagged_resource_refused(self):
        self.rows.append(row("aws_unknown_resource", "x", {"id": "x"}, False))
        with self.assertRaises(RetirementRefused):
            inspect(self.state)

    def test_foreign_account_and_region_refused(self):
        for replacement in (FUNCTION.replace(ACCOUNT, "999999999999"), FUNCTION.replace(REGION, "us-west-2")):
            self.rows[0]["values"]["arn"] = replacement
            with self.subTest(arn=replacement), self.assertRaises(RetirementRefused):
                inspect(self.state)

    def test_missing_secret_version_refused(self):
        self.rows.pop(2)
        with self.assertRaises(RetirementRefused):
            inspect(self.state)

    def add_custom_domain(self):
        domain = 'honuarawsse399115-aws-serverless-redis-off.cert.demo.honua.io'
        certificate = f'arn:aws:acm:{REGION}:{ACCOUNT}:certificate/owned'
        self.rows.extend([
            row('aws_acm_certificate','api[0]',{'id':certificate,'arn':certificate,'domain_name':domain,
                'domain_validation_options':[{'domain_name':domain,'resource_record_name':'_challenge.'+domain+'.',
                    'resource_record_type':'CNAME','resource_record_value':'_validation.acm-validations.aws.'}]}),
            row('aws_apigatewayv2_domain_name','this[0]',{'id':domain,'domain_name':domain,
                'domain_name_configuration':[{'target_domain_name':'owned.execute-api.us-east-1.amazonaws.com',
                    'hosted_zone_id':'ZAPI'}]}),
            row('aws_route53_record','api_alias[0]',{'id':'ZSHARED_'+domain+'_A','name':domain,'type':'A',
                'zone_id':'ZSHARED','alias':[{'name':'owned.execute-api.us-east-1.amazonaws.com.','zone_id':'ZAPI'}]},False),
            row('aws_route53_record','api_cert_validation["'+domain+'"]',{'id':'ZSHARED_validation_CNAME',
                'name':'_challenge.'+domain,'zone_id':'ZSHARED','type':'CNAME',
                'records':['_validation.acm-validations.aws']},False)])

    def test_actual_custom_domain_records_use_owned_parents_not_guessed_run_label(self):
        self.add_custom_domain()
        record = inspect(self.state)
        self.assertEqual(validate_plan(plan_for(self.state), record)['destroyCount'],8)

    def test_lookalike_or_foreign_dns_record_is_refused(self):
        self.add_custom_domain()
        for index, patch in ((-2,{'name':RUN+'-aws-serverless-redis-off.cert.foreign.example'}),
                             (-2,{'alias':[{'name':'foreign.example','zone_id':'ZAPI'}]}),
                             (-2,{'alias':[{'name':'owned.execute-api.us-east-1.amazonaws.com','zone_id':'ZFOREIGN'}]}),
                             (-1,{'records':['foreign.acm-validations.aws']})):
            state = copy.deepcopy(self.state)
            state['values']['root_module']['child_modules'][0]['resources'][index]['values'].update(patch)
            with self.subTest(patch=patch), self.assertRaises(RetirementRefused):
                inspect(state)

    def test_refreshed_dns_must_still_bind_original_owned_parent(self):
        self.add_custom_domain()
        record = inspect(self.state)
        plan = copy.deepcopy(plan_for(self.state))
        plan['resource_changes'][-2]['change']['before']['alias'][0]['name'] = 'foreign.example'
        with self.assertRaises(RetirementRefused):
            validate_plan(plan,record)

    def test_old_unaliased_foreign_function_version_refused(self):
        versions = {FUNCTION: [{"Version": "1"}], FUNCTION + "foreign": [
            {"Version": "$LATEST"}, {"Version": "3", "Environment": {"Variables": {
                "Settings__Document": "aws:secretsmanager:owned/runtime-settings-abc?versionId=v1"}}}]}
        with self.assertRaises(RetirementRefused):
            observe_lambda_readers(Lambda(versions), inspect(self.state))

    def test_foreign_reader_using_partial_secret_arn_is_refused(self):
        versions = {FUNCTION: [{"Version":"1"}], FUNCTION + "foreign": [{"Version":"7", "Environment":{
            "Variables":{"Settings__Document":"aws:secretsmanager:" + SECRET[:-7] + "?versionId=v1"}}}]}
        with self.assertRaises(RetirementRefused):
            observe_lambda_readers(Lambda(versions), inspect(self.state))

    def test_guardrail_protected_standing_functions_are_recorded_not_listed(self):
        standing = f"arn:aws:lambda:{REGION}:{ACCOUNT}:function:honua-cert-cert-honua"
        demo = f"arn:aws:lambda:{REGION}:{ACCOUNT}:function:honua-demo-tiles"
        lookalike = FUNCTION + "-honua-cert-lookalike"
        client = Lambda({FUNCTION: [{"Version": "1"}], lookalike: [{"Version": "2"}]})
        listed = client.get_paginator
        def guarded(name):
            if name == "list_functions":
                return Paginator(lambda: [{"Functions": [{"FunctionArn": arn}
                                                          for arn in (FUNCTION, standing, demo, lookalike)]}])
            def versions(FunctionName):
                self.assertNotIn(FunctionName, (standing, demo), "guardrail-protected function must not be listed")
                return listed(name).paginate(FunctionName=FunctionName)
            return Paginator(versions)
        client.get_paginator = guarded
        observed = observe_lambda_readers(client, inspect(self.state))
        self.assertEqual(observed["standingExcluded"], sorted([standing, demo]))
        self.assertEqual((observed["functionCount"], observed["versionCount"], observed["foreignReaders"]), (4, 2, 0))
        record = dict(inspect(self.state), functions=[standing])
        with self.assertRaises(RetirementRefused):
            observe_lambda_readers(client, record)

    def test_unreadable_or_missing_function_refused(self):
        for versions in ({}, {FUNCTION: [{"Environment": {"Error": {"ErrorCode": "AccessDenied"}}}]}):
            with self.subTest(versions=versions), self.assertRaises(RetirementRefused):
                observe_lambda_readers(Lambda(versions), inspect(self.state))

    def test_foreign_reader_provider_is_case_insensitive_but_identifier_is_not(self):
        for provider in ("aws", "AWS", "Aws", "aWs"):
            for identifier in (SECRET, SECRET[:-7], "owned/runtime-settings-abc"):
                versions = {FUNCTION: [{"Version": "1"}], FUNCTION + "foreign": [
                    {"Version": "7", "Environment": {"Variables": {
                        "Settings__Document": provider + ":secretsmanager:" + identifier + "?versionId=v1"}}}]}
                with self.subTest(provider=provider, identifier=identifier), self.assertRaises(RetirementRefused):
                    observe_lambda_readers(Lambda(versions), inspect(self.state))
        versions[FUNCTION + "foreign"][0]["Environment"]["Variables"]["Settings__Document"] = (
            "AWS:secretsmanager:Owned/runtime-settings-abc?versionId=v1")
        self.assertEqual(observe_lambda_readers(Lambda(versions), inspect(self.state))["foreignReaders"], 0)

    def test_partial_destroy_and_resource_substitution_refused(self):
        record = inspect(self.state)
        for mutate in (lambda p: p["resource_changes"].pop(),
                       lambda p: p["resource_changes"][0]["change"]["before"].update(id="foreign")):
            plan = copy.deepcopy(plan_for(self.state))
            mutate(plan)
            with self.assertRaises(RetirementRefused):
                validate_plan(plan, record)

    def test_create_update_replace_or_noop_refused(self):
        record = inspect(self.state)
        for actions in (["create"], ["update"], ["delete", "create"], ["no-op"]):
            plan = plan_for(self.state)
            plan["resource_changes"][0]["change"]["actions"] = actions
            with self.subTest(actions=actions), self.assertRaises(RetirementRefused):
                validate_plan(plan, record)

    def test_incomplete_plan_refused(self):
        plan = plan_for(self.state)
        plan["complete"] = False
        with self.assertRaises(RetirementRefused):
            validate_plan(plan, inspect(self.state))

    def test_refreshed_foreign_ownership_or_parent_cannot_use_stale_owned_state(self):
        for mutate in (lambda p: p['resource_changes'][0]['change']['before']['tags_all'].update({RUN_TAG:'foreign'}),
                       lambda p: p['resource_changes'][0]['change']['before'].update(tags_all={}),
                       lambda p: p['resource_changes'][-1]['change']['before'].update(function_name='foreign')):
            plan = copy.deepcopy(plan_for(self.state))
            mutate(plan)
            with self.assertRaises(RetirementRefused):
                validate_plan(plan, inspect(self.state))

    def test_deposed_and_duplicate_changes_are_not_hidden_by_address(self):
        for deposed in (False, True):
            plan = copy.deepcopy(plan_for(self.state))
            duplicate = copy.deepcopy(plan['resource_changes'][0])
            if deposed:
                duplicate['deposed'] = 'deadbeef'
                duplicate['change']['before']['id'] = 'never-inventoried'
            plan['resource_changes'].insert(0, duplicate)
            with self.subTest(deposed=deposed), self.assertRaises(RetirementRefused):
                validate_plan(plan, inspect(self.state))

    def test_existing_override_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            module = Path(directory)
            (module / "runtime-settings.tf").write_text("prevent_destroy = true\n" * 2)
            (module / OVERRIDE_NAME).write_text("{}")
            with self.assertRaises(RetirementRefused):
                prepare_override(module, inspect(self.state), {"foreignReaders": 0})


class RetirementExecutionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        base = Path(self.directory.name)
        self.root = base / "examples/aws-serverless"
        self.module = base / "modules/aws-serverless"
        self.root.mkdir(parents=True)
        self.module.mkdir(parents=True)
        self.source = 'prevent_destroy = true\n' * 2
        (self.module / 'runtime-settings.tf').write_text(self.source)
        self.state = fixture()
        self.plan = plan_for(self.state)
        self.calls = []
        self.fail = None
        self.remaining = {"values": {"root_module": {}}}
        self.client = Lambda({FUNCTION: [{"Version": "1"}]})
        self.client.meta = SimpleNamespace(region_name=REGION)

    def terraform(self, command, **kwargs):
        self.calls.append(command)
        verb = command[2]
        if verb == self.fail:
            return SimpleNamespace(returncode=1, stdout='', stderr='private fixture credential')
        if verb == 'plan':
            Path(next(v[5:] for v in command if v.startswith('-out='))).write_bytes(b'original saved plan')
            value = ''
        elif verb == 'show' and len(command) == 5:
            value = json.dumps(self.plan)
        elif verb == 'show':
            value = json.dumps(self.remaining if any(c[2]=='apply' for c in self.calls) else self.state)
        else:
            value = ''
        return SimpleNamespace(returncode=0, stdout=value, stderr='')

    def execute(self, **overrides):
        args = dict(run_id=RUN, cell=CELL, account_id=ACCOUNT, region=REGION,
                    variables=['-input=false', '-no-color', '-var=environment=it'],
                    lambda_client=self.client, sts_client=Mock(get_caller_identity=lambda: {'Account': ACCOUNT}),
                    run=self.terraform)
        args.update(overrides)
        return retire(self.root, self.module, **args)

    def assert_retention_restored(self):
        self.assertFalse((self.module / OVERRIDE_NAME).exists())
        self.assertEqual((self.module / 'runtime-settings.tf').read_text(), self.source)

    def test_only_inspected_saved_delete_plan_is_applied(self):
        receipt = self.execute()
        self.assertTrue(receipt['terraformRetired'])
        self.assertFalse(receipt['independentAbsenceVerified'])
        self.assertFalse(receipt['costReconciled'])
        applied = [c for c in self.calls if c[2]=='apply']
        self.assertEqual(len(applied), 1)
        self.assertEqual(applied[0][3:], ['-input=false', '-no-color',
                                         str(self.root / '.release-cell-retirement/destroy.tfplan')])
        self.assertTrue(any(c[2:4]==['plan','-destroy'] for c in self.calls))
        self.assert_retention_restored()

    def test_partial_plan_cannot_reach_apply(self):
        self.plan['resource_changes'].pop()
        with self.assertRaises(RetirementRefused):
            self.execute()
        self.assertFalse(any(c[2]=='apply' for c in self.calls))
        self.assert_retention_restored()

    def test_failed_apply_retains_private_recovery_and_original_guard(self):
        self.fail = 'apply'
        with self.assertRaises(RetirementRefused) as error:
            self.execute()
        self.assertNotIn('private fixture credential', str(error.exception))
        directory = self.root / '.release-cell-retirement'
        self.assertEqual(json.loads((directory/'receipt.json').read_text())['status'], 'incomplete')
        self.assertTrue((directory/'destroy.tfplan').exists())
        self.assertEqual((directory/'apply-delete-plan.private.json').stat().st_mode & 0o777, 0o600)
        self.assert_retention_restored()

    def test_remaining_resource_prevents_completion(self):
        self.remaining = self.state
        with self.assertRaises(RetirementRefused):
            self.execute()
        self.assert_retention_restored()

    def test_wrong_caller_or_targeting_options_refuse_before_terraform(self):
        for overrides in ({'sts_client': Mock(get_caller_identity=lambda:{'Account':'999999999999'})},
                          {'variables':['-target=module.honua.aws_lambda_function.this']},
                          {'variables':['-refresh=false']}):
            with self.subTest(overrides=overrides), self.assertRaises(RetirementRefused):
                self.execute(**overrides)
            self.assertEqual(self.calls, [])

    def test_foreign_published_reader_prevents_override_and_plan(self):
        self.client.versions[FUNCTION+'foreign'] = [{'Version':'2', 'Environment':{'Variables':{
            'Settings__Document':'aws:secretsmanager:'+SECRET+'?versionId=v1'}}}]
        with self.assertRaises(RetirementRefused):
            self.execute()
        self.assertEqual([c[2] for c in self.calls], ['show'])
        self.assert_retention_restored()

    def test_repeated_attempt_requires_original_state_reconciliation(self):
        self.execute()
        count = len(self.calls)
        with self.assertRaises(RetirementRefused):
            self.execute()
        self.assertEqual(len(self.calls), count)


if __name__ == "__main__":
    unittest.main()
