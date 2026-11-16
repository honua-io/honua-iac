import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import gate_tools


class GateToolsTests(unittest.TestCase):
    def test_secure_config_writes_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'terraform.tfvars.json'
            with patch.object(gate_tools.subprocess, 'run') as run:
                run.return_value.stdout = json.dumps({'Parameter': {'Type': 'SecureString', 'Value': '{"private":true}'}})
                gate_tools.load_config('/gate/private', target)
            self.assertEqual(json.loads(target.read_text()), {'private': True})
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertIn('--with-decryption', run.call_args.args[0])
            self.assertIn('us-east-1', run.call_args.args[0])

    def test_plaintext_and_invalid_json_leave_existing_config_intact(self):
        for parameter in ({'Type': 'String', 'Value': '{}'}, {'Type': 'SecureString', 'Value': 'secret'},
                          {'Type': 'SecureString', 'Value': '[]'}):
            with self.subTest(parameter=parameter), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / 'terraform.tfvars.json'
                target.write_text('original')
                with patch.object(gate_tools.subprocess, 'run') as run:
                    run.return_value.stdout = json.dumps({'Parameter': parameter})
                    with self.assertRaises(ValueError):
                        gate_tools.load_config('/gate/private', target)
                self.assertEqual(target.read_text(), 'original')

    def test_template_boundary_injection_preserves_other_resources(self):
        source = {'Resources': {'Role': {'Type': 'AWS::IAM::Role', 'Properties': {'Policies': []}},
                                'Logs': {'Type': 'AWS::Logs::LogGroup'}}}
        result = gate_tools.bound_template(source, 'boundary')
        self.assertEqual(result['Resources']['Role']['Properties']['PermissionsBoundary'], 'boundary')
        self.assertEqual(result['Resources']['Logs'], source['Resources']['Logs'])
        self.assertNotIn('PermissionsBoundary', source['Resources']['Role']['Properties'])

    def test_keys_skip_the_lockout_check_only_with_account_administration(self):
        root = {'Sid': 'EnableAccountIAM', 'Effect': 'Allow', 'Principal': {'AWS': {'Fn::Sub': gate_tools.ACCOUNT_ROOT}},
                'Action': 'kms:*', 'Resource': '*'}
        source = {'Resources': {'Key': {'Type': 'AWS::KMS::Key', 'Properties': {'KeyPolicy': {'Statement': [root]}}}}}
        result = gate_tools.bound_template(source, 'boundary')
        self.assertIs(result['Resources']['Key']['Properties']['BypassPolicyLockoutSafetyCheck'], True)
        self.assertNotIn('BypassPolicyLockoutSafetyCheck', source['Resources']['Key']['Properties'])
        weakened = (dict(root, Action='kms:Decrypt'), dict(root, Condition={'Bool': {'aws:MultiFactorAuthPresent': 'true'}}),
                    dict(root, Effect='Deny'), dict(root, Principal={'AWS': 'arn:aws:iam::000000000002:role/x'}),
                    dict(root, Resource='arn:aws:kms:us-east-1:000000000002:key/other'))
        deny_all = {'Effect': 'Deny', 'Principal': '*', 'Action': 'kms:*', 'Resource': '*'}
        not_principal = {'Effect': 'Allow', 'NotPrincipal': {'AWS': 'x'}, 'Action': 'kms:Decrypt', 'Resource': '*'}
        policies = [{'Statement': [statement]} for statement in weakened] + [
            {'Statement': [root, deny_all]}, {'Statement': [root, not_principal]}, {'Statement': ['text']}, None]
        single = gate_tools.bound_template({'Resources': {'Key': {'Type': 'AWS::KMS::Key', 'Properties': {
            'KeyPolicy': {'Statement': root}}}}}, 'boundary')
        self.assertIs(single['Resources']['Key']['Properties']['BypassPolicyLockoutSafetyCheck'], True)
        for policy in policies:
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                gate_tools.bound_template({'Resources': {'Key': {'Type': 'AWS::KMS::Key', 'Properties': {'KeyPolicy': policy}}}},
                                          'boundary')

    def test_template_rejects_explicit_role_names_outside_namespace(self):
        for name in ('Admin', {'Ref': 'UnconstrainedName'}):
            with self.subTest(name=name), self.assertRaises(ValueError):
                gate_tools.bound_template({'Resources': {'R': {'Type': 'AWS::IAM::Role', 'Properties': {'RoleName': name}}}}, 'boundary')

    def test_inactive_nested_stack_locks_its_selector_to_default(self):
        source = {'Parameters': {'Agents': {'Type': 'String', 'Default': 'Off',
                                           'AllowedValues': ['Off', 'Preview']}},
                  'Conditions': {'Preview': {'Fn::Equals': [{'Ref': 'Agents'}, 'Preview']}},
                  'Resources': {'Child': {'Type': 'AWS::CloudFormation::Stack', 'Condition': 'Preview'},
                                'Role': {'Type': 'AWS::IAM::Role'}}}
        result = gate_tools.bound_template(source, 'boundary')
        self.assertEqual(result['Parameters']['Agents']['AllowedValues'], ['Off'])
        self.assertEqual(result['Resources']['Child'], source['Resources']['Child'])
        self.assertEqual(result['Resources']['Role']['Properties']['PermissionsBoundary'], 'boundary')
        self.assertEqual(source['Parameters']['Agents']['AllowedValues'], ['Off', 'Preview'])

    def test_nested_stack_conditions_fail_closed(self):
        for selector, condition in (
            ({'Type': 'String', 'Default': 'Preview'}, {'Fn::Equals': [{'Ref': 'Agents'}, 'Preview']}),
            ({'Type': 'String'}, {'Fn::Equals': [{'Ref': 'Agents'}, 'Preview']}),
            ({'Type': 'AWS::SSM::Parameter::Value<String>', 'Default': 'Off'},
             {'Fn::Equals': [{'Ref': 'Agents'}, 'Preview']}),
            ({'Type': 'String', 'Default': 'Off'}, {'Fn::Not': [{'Condition': 'Other'}]}),
            ({'Type': 'String', 'Default': 'Off'}, {'Fn::Equals': [{'Ref': 'Missing'}, 'Preview']}),
            ({'Type': 'String', 'Default': 'Off', 'AllowedValues': ['Preview']},
             {'Fn::Equals': [{'Ref': 'Agents'}, 'Preview']}),
            ({'Type': 'String', 'Default': 'Off'}, {'Fn::Equals': [{'Ref': 'Agents'}]}),
            ({'Type': 'String', 'Default': 'Off'}, {'Fn::Equals': [{'Ref': 'Agents'}, {'Ref': 'Other'}]}),
        ):
            source = {'Parameters': {'Agents': selector}, 'Conditions': {'Preview': condition},
                      'Resources': {'Child': {'Type': 'AWS::CloudFormation::Stack', 'Condition': 'Preview'}}}
            with self.subTest(selector=selector, condition=condition), self.assertRaises(ValueError):
                gate_tools.bound_template(source, 'boundary')

    def test_inactive_nested_stack_does_not_bypass_role_validation(self):
        source = {'Parameters': {'Agents': {'Type': 'String', 'Default': 'Off'}},
                  'Conditions': {'Preview': {'Fn::Equals': [{'Ref': 'Agents'}, 'Preview']}},
                  'Resources': {'Child': {'Type': 'AWS::CloudFormation::Stack', 'Condition': 'Preview'},
                                'Role': {'Type': 'AWS::IAM::Role', 'Properties': {'RoleName': 'Admin'}}}}
        with self.assertRaises(ValueError):
            gate_tools.bound_template(source, 'boundary')

    def test_template_rejects_nested_stacks_and_transforms(self):
        for template in ({'Transform': 'AWS::Serverless-2016-10-31'},
                         {'Resources': {'Child': {'Type': 'AWS::CloudFormation::Stack'}}}):
            with self.subTest(template=template), self.assertRaises(ValueError):
                gate_tools.bound_template(template, 'boundary')


if __name__ == '__main__':
    unittest.main()
