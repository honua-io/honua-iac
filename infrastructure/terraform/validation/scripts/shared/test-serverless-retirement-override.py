"""Exercise the temporary override with Terraform's mocked provider, never AWS."""
import importlib.util
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
MODULE = ROOT / "infrastructure/terraform/modules/aws-serverless"
HELPER = Path(__file__).resolve().parent.parent / "aws/serverless_cell_retirement.py"


def main():
    spec = importlib.util.spec_from_file_location("retirement", HELPER)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    with tempfile.TemporaryDirectory(prefix="honua-retirement-mock-") as temporary:
        module = Path(temporary) / "aws-serverless"
        shutil.copytree(MODULE, module, symlinks=True, ignore=shutil.ignore_patterns(".terraform", "*.tfstate*"))
        helper.prepare_override(module, {}, {"foreignReaders": 0})
        subprocess.run(["terraform", f"-chdir={module}", "init", "-backend=false", "-input=false", "-no-color"], check=True)
        # The same mocked shared-state change is rejected by the ordinary
        # module's separate negative test. Here it proves that Terraform reads
        # the generated override. Production retire() permits delete-only plans.
        subprocess.run(["terraform", f"-chdir={module}", "test", "-no-color",
                        "-test-directory=tests-retention-negative",
                        "-filter=tests-retention-negative/omitted_history.tftest.hcl"], check=True)
    assert not (MODULE / helper.OVERRIDE_NAME).exists()


if __name__ == "__main__":
    main()
