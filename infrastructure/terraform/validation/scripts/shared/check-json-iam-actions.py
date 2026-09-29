#!/usr/bin/env python3
"""Reject wildcard JSON IAM grants; explicit Deny and condition values aren't grants."""
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
failed = []
for path in root.rglob('*'):
    if not path.is_file() or '.terraform' in path.parts:
        continue
    if path.name.endswith(('.json', '.json.tftpl')):
        try:
            document = json.loads(path.read_text())
        except (ValueError, UnicodeDecodeError):
            # A malformed policy template must not evade the check.
            if '"Statement"' in path.read_text(errors='replace'):
                failed.append(str(path))
            continue
        def check(value):
            if isinstance(value, dict):
                if 'Statement' in value:
                    statements = value['Statement']
                    for statement in statements if isinstance(statements, list) else [statements]:
                        if not isinstance(statement, dict) or statement.get('Effect') == 'Deny':
                            continue
                        actions = statement.get('Action', [])
                        if actions == '*' or isinstance(actions, list) and '*' in actions:
                            failed.append(str(path))
                for item in value.values():
                    check(item)
            elif isinstance(value, list):
                for item in value:
                    check(item)
        check(document)
    elif path.suffix == '.tf':
        # Retain the legacy embedded-JSON guard, including incomplete snippets.
        if re.search(r'"Action"\s*:\s*"\*"', path.read_text()):
            failed.append(str(path))
if failed:
    print('[ERROR] Policy check failed (least-privilege-actions-json): disallowed pattern found', file=sys.stderr)
    print('\n'.join(sorted(set(failed))), file=sys.stderr)
    sys.exit(1)
