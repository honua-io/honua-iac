"""Reviewed gaps cannot silently absorb new denials or coverage failures."""
import unittest
from gaps import unresolved


class GapTests(unittest.TestCase):
    def test_grouping_preserves_action_handler_and_count(self):
        row = {"type": "AWS::Example::Thing", "action": "example:Call", "handler": "create", "decision": "Deny"}
        self.assertEqual([{**row, "count": 2}], unresolved([row, row]))
        self.assertEqual([], unresolved([{**row, "decision": "Allow"}]))
        self.assertNotEqual(unresolved([row]), unresolved([{**row, "handler": "delete"}]))
        self.assertNotEqual(unresolved([row]), unresolved([{**row, "decision": "UnknownAction"}]))
