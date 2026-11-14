#!/usr/bin/env python3
"""Exercise SDK recovery without downloading or executing .NET."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ensure-dotnet-sdk.sh'


class SdkInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / 'target'
        self.payload = self.root / 'payload'
        (self.payload / 'sdk/11.0.100').mkdir(parents=True)
        (self.payload / 'dotnet').write_text('muxer')
        (self.payload / 'sdk/11.0.100/dotnet.dll').write_text('sdk')
        manifests = self.payload / 'sdk-manifests/11.0.100'
        (manifests / 'workloadsets/11.0.100').mkdir(parents=True)
        (manifests / 'workloadsets/11.0.100/microsoft.net.workloads.workloadset.json').write_text(
            json.dumps({'Example.Manifest': '11.0.1/11.0.100'}))
        (manifests / 'example.manifest/11.0.1').mkdir(parents=True)
        (manifests / 'example.manifest/11.0.1/WorkloadManifest.json').write_text('{}')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        curl = self.bin / 'curl'
        curl.write_text('''#!/bin/bash
set -eu
printf 'download\\n' >> "$SDK_TEST_LOG"
while [ "$1" != -o ]; do shift; done
cp "$SDK_TEST_INSTALLER" "$2"
''')
        curl.chmod(0o755)
        installer = self.root / 'installer'
        installer.write_text('''#!/bin/bash
set -eu
while [ "$1" != --install-dir ]; do shift; done
mkdir -p "$2"
cp -a "$SDK_TEST_PAYLOAD/." "$2/"
''')
        self.log = self.root / 'downloads'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        SDK_TEST_LOG=str(self.log), SDK_TEST_INSTALLER=str(installer),
                        SDK_TEST_PAYLOAD=str(self.payload))

    def launch(self, version='11.0.100'):
        return subprocess.Popen(['bash', str(SCRIPT), version, str(self.target)], env=self.env)

    def test_fresh_install_and_repeated_admission(self):
        self.assertEqual(0, self.launch().wait())
        self.assertEqual(0, self.launch().wait())
        self.assertEqual(['download'], self.log.read_text().splitlines())

    def test_partial_workload_set_repaired_preserving_sdk(self):
        subprocess.run(['cp', '-a', str(self.payload), str(self.target)], check=True)
        missing = self.target / 'sdk-manifests/11.0.100/example.manifest/11.0.1/WorkloadManifest.json'
        missing.unlink()
        sdk = self.target / 'sdk/11.0.100/dotnet.dll'
        sdk.write_text('in-use-sdk')
        self.assertEqual(0, self.launch().wait())
        self.assertTrue(missing.is_file())
        self.assertEqual('in-use-sdk', sdk.read_text())

    def test_concurrent_installs_download_once(self):
        first, second = self.launch(), self.launch()
        self.assertEqual((0, 0), (first.wait(), second.wait()))
        self.assertEqual(['download'], self.log.read_text().splitlines())

    def test_truncated_manifest_is_rejected_without_overwriting(self):
        subprocess.run(['cp', '-a', str(self.payload), str(self.target)], check=True)
        manifest = self.target / 'sdk-manifests/11.0.100/example.manifest/11.0.1/WorkloadManifest.json'
        manifest.write_text('{')
        self.assertNotEqual(0, self.launch().wait())
        self.assertEqual('{', manifest.read_text())

    def test_stock_archive_without_workload_set(self):
        import shutil
        shutil.rmtree(self.payload / 'sdk-manifests/11.0.100/workloadsets')
        self.assertEqual(0, self.launch().wait())
        missing = self.target / 'sdk-manifests/11.0.100/example.manifest/11.0.1/WorkloadManifest.json'
        missing.unlink()
        self.assertEqual(0, self.launch().wait())
        self.assertTrue(missing.is_file())

    def test_stock_net10_archive_uses_initial_manifest_band(self):
        import shutil
        (self.payload / 'sdk/11.0.100').rename(self.payload / 'sdk/10.0.404')
        manifests = self.payload / 'sdk-manifests/11.0.100'
        shutil.rmtree(manifests / 'workloadsets')
        manifests.rename(self.payload / 'sdk-manifests/10.0.100')
        self.assertEqual(0, self.launch('10.0.404').wait())
        self.assertEqual(0, self.launch('10.0.404').wait())
        self.assertEqual(['download'], self.log.read_text().splitlines())

    def test_incomplete_download_fails(self):
        (self.payload / 'sdk-manifests/11.0.100/example.manifest/11.0.1/WorkloadManifest.json').unlink()
        self.assertNotEqual(0, self.launch().wait())


if __name__ == '__main__':
    unittest.main()
