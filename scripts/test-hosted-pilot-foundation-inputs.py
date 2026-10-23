#!/usr/bin/env python3
"""Refuse changed pilot identity, raw values, funding reset or workload authority."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('pilot_input_check',HERE/'check-hosted-pilot-foundation-inputs.py')
check=importlib.util.module_from_spec(spec);spec.loader.exec_module(check)

class NonsecretPilotInputs(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.path=self.root/check.RELATIVE;self.path.parent.mkdir(parents=True)
        self.original=json.loads((check.ROOT/check.RELATIVE).read_text())
        self.value=copy.deepcopy(self.original)
    def validate(self):
        self.path.write_text(json.dumps(self.value));return check.check(self.root)
    def test_reviewed_nonzero_source_configuration_passes_without_aws_calls(self):
        self.assertEqual(len(self.validate()),64)
    def test_changed_account_region_owner_or_prefix_refuse(self):
        for key,value in (('account_id','123456789012'),('region','us-west-2'),('owner','unknown'),('name_prefix','honua-pilot-other')):
            self.value=copy.deepcopy(self.original);self.value[key]=value
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'pilot identity'):self.validate()
    def test_raw_credential_or_unknown_fields_refuse(self):
        self.value['client_secret']='private-sentinel'
        with self.assertRaisesRegex(ValueError,'pilot identity'):self.validate()
    def test_independent_secret_and_oidc_references_cannot_change(self):
        self.value['runtime_secret_arns'][0]=self.value['runtime_secret_arns'][1]
        with self.assertRaisesRegex(ValueError,'secret/OIDC'):self.validate()
    def test_model_invocation_cannot_be_enabled_by_foundation_configuration(self):
        self.value['controller_model_resource_arns']=['unreviewed-model']
        with self.assertRaisesRegex(ValueError,'cannot enable inference'):self.validate()
    def test_broadened_provision_actions_and_resources_refuse(self):
        for key,value in (('Action',['iam:PutRolePolicy']),('Resource',['*'])):
            self.value=copy.deepcopy(self.original);policy=json.loads(self.value['provision_policy_document']);policy['Statement'][0][key]=value
            self.value['provision_policy_document']=json.dumps(policy)
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'only reviewed registry'):self.validate()
    def test_zero_hold_expanded_allowance_and_changed_original_allocation_refuse(self):
        for key,value in (('reserved_usd',0),('deployment_reservation_usd',100),('reservation_id','new-unfunded-allocation'),('source_sha','a'*40)):
            self.value=copy.deepcopy(self.original);self.value['budget_ledger'][key]=value
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'original nonzero funding'):self.validate()
    def test_symlink_configuration_refuses_before_inspection(self):
        original=self.root/'original.json';original.write_text(json.dumps(self.value));self.path.symlink_to(original)
        with self.assertRaisesRegex(ValueError,'configuration missing'):check.check(self.root)

    def test_both_original_expiration_deadlines_are_pinned(self):
        for scope in ('infrastructure','funding'):
            self.value=copy.deepcopy(self.original)
            target=self.value if scope=='infrastructure' else self.value['budget_ledger']
            target['expires_at']='2026-11-30T00:00:00Z'
            self.path.write_text(json.dumps(self.value))
            with self.subTest(scope=scope),self.assertRaisesRegex(ValueError,'deadline differs'):
                check.check(self.root)

    def test_equivalent_or_parent_path_spellings_refuse_before_profile_selection(self):
        for selected in ('./'+check.RELATIVE,check.RELATIVE.replace('deployments/','deployments/../deployments/'),
                         check.RELATIVE.replace('deployments/','deployments//'),'/'+check.RELATIVE,check.RELATIVE.replace('/',chr(92))):
            with self.subTest(selected=selected),self.assertRaisesRegex(ValueError,'canonical reviewed'):
                check.canonical_path(selected)
    def compiled(self,value):
        result=copy.deepcopy(value);result.pop('image_preparation_funding')
        result['budget_ledger'].update(source_sha='a'*40,config_sha256=check.hashlib.sha256(b'actual-funding-source').hexdigest())
        return result
    def test_complete_compiled_output_allows_only_two_derived_hash_fields(self):
        before=copy.deepcopy(self.original)
        def resolve(value,root,sha,**kwargs):
            self.assertEqual(kwargs,{'config_path':check.RELATIVE})
            return self.compiled(value)
        self.assertEqual(check.check_compiled(self.original,self.root,'a'*40,resolve,b'actual-funding-source'),self.compiled(self.original))
        self.assertEqual(self.original,before)
    def test_any_compiled_ledger_field_or_added_authority_change_refuses(self):
        for field in self.original['budget_ledger']:
            def resolve(value,root,sha,**kwargs):
                result=self.compiled(value);old=result['budget_ledger'][field]
                result['budget_ledger'][field]=old+1 if isinstance(old,(int,float)) else old+'-changed'
                return result
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'compiler changed reviewed'):
                check.check_compiled(self.original,self.root,'a'*40,resolve,b'actual-funding-source')
        def added(value,root,sha,**kwargs):return self.compiled(value)|{'unreviewed_authority':True}
        with self.assertRaisesRegex(ValueError,'compiler changed reviewed'):
            check.check_compiled(self.original,self.root,'a'*40,added,b'actual-funding-source')
    def test_compiler_cannot_modify_the_input_to_change_its_expected_output(self):
        before=copy.deepcopy(self.original)
        def mutation(value,root,sha,**kwargs):
            value['budget_ledger']['reserved_usd']=0
            return self.compiled(value)
        with self.assertRaisesRegex(ValueError,'compiler changed reviewed'):
            check.check_compiled(self.original,self.root,'a'*40,mutation,b'actual-funding-source')
        self.assertEqual(self.original,before)
    def test_other_canonical_explicit_budget_path_remains_available(self):
        relative='certification/hosted-pilot/bootstrap/deployments/other-reviewed.tfvars.json'
        path=self.root/relative;path.write_text('{"budget_ledger":{"source_sha":"reviewed-explicit-source"}}')
        self.assertEqual(len(check.check(self.root,configuration_path=relative)),64)
        path.write_text(json.dumps(self.original))
        with self.assertRaisesRegex(ValueError,'exact reviewed configuration path'):
            check.check(self.root,configuration_path=relative)

if __name__=='__main__':unittest.main()
