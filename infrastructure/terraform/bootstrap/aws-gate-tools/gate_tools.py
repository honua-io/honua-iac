"""Private gate configuration loading and CloudFormation boundary preparation."""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile


def private_json(target, value):
    target = Path(target)
    descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix='.gate-')
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_config(parameter_name, target):
    response = subprocess.run(
        ['aws', 'ssm', 'get-parameter', '--region', 'us-east-1', '--name', parameter_name,
         '--with-decryption', '--output', 'json'],
        check=True, capture_output=True, text=True)
    parameter = json.loads(response.stdout)['Parameter']
    if parameter['Type'] != 'SecureString':
        raise ValueError('Configuration must come from an SSM SecureString')
    try:
        value = json.loads(parameter['Value'])
    except json.JSONDecodeError:
        raise ValueError('Configuration must contain valid JSON') from None
    if not isinstance(value, dict):
        raise ValueError('Configuration must be a JSON object')
    private_json(target, value)


def lock_inactive_nested_stack(template, resource):
    condition = template.get('Conditions', {}).get(resource.get('Condition'), {})
    operands = condition.get('Fn::Equals') if isinstance(condition, dict) else None
    if not isinstance(operands, list) or len(operands) != 2 or len(condition) != 1:
        raise ValueError('Nested stacks require a simple inactive parameter equality condition')
    reference, enabled_value = operands
    if not isinstance(reference, dict) or set(reference) != {'Ref'} or not isinstance(enabled_value, str):
        raise ValueError('Nested stack conditions must compare a String parameter to a literal')
    parameter_name = reference['Ref']
    parameter = template.get('Parameters', {}).get(parameter_name, {}) if isinstance(parameter_name, str) else {}
    default = parameter.get('Default')
    if parameter.get('Type') != 'String' or not isinstance(default, str) or default == enabled_value:
        raise ValueError('Nested stack selectors require an inactive String default')
    if 'AllowedValues' in parameter and default not in parameter['AllowedValues']:
        raise ValueError('Nested stack selector default must be an allowed value')
    parameter['AllowedValues'] = [default]


def bound_template(source, boundary):
    if 'Transform' in source:
        raise ValueError('Transforms are unsupported in gate templates')
    result = copy.deepcopy(source)
    for resource in result.get('Resources', {}).values():
        if resource['Type'] == 'AWS::CloudFormation::Stack':
            lock_inactive_nested_stack(result, resource)
        if resource['Type'] == 'AWS::IAM::Role':
            properties = resource.setdefault('Properties', {})
            name = properties.get('RoleName', 'honua-gate-generated')
            if not isinstance(name, str) or not name.startswith('honua-gate-'):
                raise ValueError('Explicit role names must start with honua-gate-')
            properties['PermissionsBoundary'] = boundary
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    config = commands.add_parser('load-config')
    config.add_argument('parameter_name')
    config.add_argument('output', type=Path)
    template = commands.add_parser('bind-template')
    template.add_argument('source', type=Path)
    template.add_argument('--boundary-arn', required=True)
    template.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.command == 'load-config':
        load_config(args.parameter_name, args.output)
    else:
        private_json(args.output, bound_template(json.loads(args.source.read_text()), args.boundary_arn))


if __name__ == '__main__':
    main()
