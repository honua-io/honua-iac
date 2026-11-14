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

    def test_template_rejects_explicit_role_names_outside_namespace(self):
        for name in ('Admin', {'Ref': 'UnconstrainedName'}):
            with self.subTest(name=name), self.assertRaises(ValueError):
                gate_tools.bound_template({'Resources': {'R': {'Type': 'AWS::IAM::Role', 'Properties': {'RoleName': name}}}}, 'boundary')

    def test_template_rejects_nested_stacks_and_transforms(self):
        for template in ({'Transform': 'AWS::Serverless-2016-10-31'},
                         {'Resources': {'Child': {'Type': 'AWS::CloudFormation::Stack'}}}):
            with self.subTest(template=template), self.assertRaises(ValueError):
                gate_tools.bound_template(template, 'boundary')


if __name__ == '__main__':
    unittest.main()
