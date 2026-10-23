# Disposable release-cell retirement

The Lambda runtime-settings module keeps its `prevent_destroy` guards during
ordinary deployment, including omitted-history updates. Complete retirement of a
disposable release cell uses a separate checked-in release workflow and the
`serverless_cell_retirement.py` helper. The helper is not an operator deployment
toggle and does not authorize deleting a standing environment.

The release workflow must authenticate the original completed run, restore its
encrypted Terraform state using the original key and digest, and check out the
original immutable IaC revision. It supplies the original run, cell, account,
region and Terraform input variables to `retire`. It must prevent concurrent
cleanup of the same state.

Before planning, the helper verifies ownership of every managed resource and all
published Lambda versions in the region. A settings reader outside the complete
owned cell refuses retirement. Only the two runtime-settings lifecycle guards
are overridden in the private workflow checkout. The saved plan must delete
every original resource, with matching identities and no creates, updates,
replacements or partial targeting. The helper rechecks published readers and
applies that exact saved plan. It removes its temporary override on success or
failure; the tracked module never changes.

The private `.release-cell-retirement` directory contains raw diagnostics, state
observations and a saved plan that may contain credentials. Never publish this
directory unencrypted. On failure, the workflow must retain the original state
and reseal the updated state and recovery record before the runner exits. A
partial attempt requires reconciliation before retry; absence of a receipt is
not proof of cleanup.

`terraformRetired` records only successful Terraform deletion and empty managed
state. Independent AWS absence checks, Secrets Manager recovery windows, and the
original run's cost reconciliation remain separate obligations. The helper never
claims zero cost, deletes the state key, or marks a release gate passed. The
release workflow must retain these obligations until its independent checks and
cost accounting finish.

Offline boundary tests run in Terraform CI. The existing mocked omitted-history
test remains mandatory and must continue rejecting ordinary retention loss.
