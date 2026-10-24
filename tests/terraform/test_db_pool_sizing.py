#!/usr/bin/env python3
"""Keep the shared database pool sizing block identical across modules.

Each deployment module carries the same db-pool-sizing block (a nested local
module would be refused by the aws-cert reviewed-module admission gate), with
only local.db_pool_inputs differing. This check fails when a copy drifts,
when a module's inputs miss a key, or when the max_connections tables stop
being a lower bound of the values seen on real instances.
"""
import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / "infrastructure" / "terraform" / "modules"
SIZED_MODULES = ["aws-serverless", "aws-ecs", "aws-eks", "azure-aca", "azure-functions"]
BEGIN = "# ---- BEGIN shared db-pool-sizing ----"
END = "# ---- END shared db-pool-sizing ----"
INPUT_KEYS = {
    "engine", "instance", "external_database", "max_connections_override",
    "max_processes", "pools_per_process", "other_connections", "safety_fraction",
    "pool_size_override", "fallback_pool_size", "pooler_enabled",
    "emit_min_pool_size", "serverless",
}
SIZING_VARIABLES = {"db_max_connections_override", "db_pools_per_process", "db_connection_safety_fraction"}


def sizing_file(module):
    return (MODULES / module / "db-pool-sizing.tf").read_text()


def shared_block(text):
    start = text.index(BEGIN)
    end = text.index(END) + len(END)
    return text[start:end]


class SharedBlockTest(unittest.TestCase):
    def test_every_copy_is_identical(self):
        reference = shared_block(sizing_file(SIZED_MODULES[0]))
        for module in SIZED_MODULES[1:]:
            with self.subTest(module=module):
                self.assertEqual(
                    shared_block(sizing_file(module)), reference,
                    f"{module}/db-pool-sizing.tf drifted; copy the block from {SIZED_MODULES[0]}/db-pool-sizing.tf")

    def test_inputs_define_every_key_once(self):
        for module in SIZED_MODULES:
            text = sizing_file(module)
            inputs = text[text.index("db_pool_inputs = {"):text.index(BEGIN)]
            keys = re.findall(r"^\s{4}([a-z_]+)\s+=", inputs, re.MULTILINE)
            with self.subTest(module=module):
                self.assertEqual(sorted(keys), sorted(INPUT_KEYS))

    def test_modules_declare_the_override_variables(self):
        for module in SIZED_MODULES:
            text = (MODULES / module / "variables.tf").read_text()
            declared = set(re.findall(r'^variable "([a-z_]+)"', text, re.MULTILINE))
            with self.subTest(module=module):
                self.assertTrue(SIZING_VARIABLES <= declared, SIZING_VARIABLES - declared)


class TablesTest(unittest.TestCase):
    block = shared_block(sizing_file(SIZED_MODULES[0]))

    def rds(self, gib):
        match = re.search(r"min\(floor\(local\.db_pool_rds_memory_gib \* 1073741824 \* ([0-9.]+) / 9531392\), 5000\)", self.block)
        self.assertIsNotNone(match, "the RDS formula changed shape")
        return min(math.floor(gib * 1073741824 * float(match.group(1)) / 9531392), 5000)

    def test_rds_table_is_a_lower_bound_of_observed_values(self):
        # db.t3.micro reported about 87 (honua-release e2e-cloud-aws run
        # 38107383082); the demo db.t4g.small peaked at 175 connections in use.
        self.assertLessEqual(self.rds(1), 87)
        self.assertLessEqual(self.rds(2), 175)
        self.assertEqual(self.rds(64), 5000)

    def test_azure_table_matches_the_documented_limits(self):
        documented = {"B1ms": 50, "B2s": 429, "B2ms": 859, "B4ms": 1718, "B8ms": 3437}
        for name, value in documented.items():
            with self.subTest(sku=name):
                self.assertRegex(self.block, rf'"{name}" = {value}\b')


if __name__ == "__main__":
    unittest.main()
