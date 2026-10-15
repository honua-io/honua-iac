# Agent E2E Fargate attempt

Internal infrastructure for honua-release #619. This root defines one isolated
attempt's FIFO command/reply queues, task identity, pinned non-root Fargate task
and a Step Functions launch lifecycle. It creates no EC2 instance or SSM transport.
Execution input cannot override the task, image, role, network or expiry.

The caller must reserve the full infrastructure liability before apply. Supply
an existing isolated cluster/network and durable controller claim table. Activate
a remote encrypted/locked backend with a unique key per attempt. Retain the exact
plan, IaC revision and state lineage; never share state with a customer deployment.

Start the emitted state machine only through the trusted controller. A conditional
claim prevents a second execution from starting another worker for this attempt.
Never delete that claim, reuse the queues, or grant execution redrive. A failed
worker retains an interrupted attempt; an authorized retry needs a new identity.

The task can only read/delete its command messages and send its own replies. Its
execution role can pull the pinned repository and write its log group. Neither
identity can read controller evidence or approve a goal. Replies are untrusted.
No controller/approval credentials belong in task environment variables.

The image must include the container runtime from honua-release, its pinned SDK
dependencies, bash and a UID 10001-writable /workspace and /journal volume layout.
The entrypoint must load only immutable /app modules, not workspace Python files.

This root is not a complete deployed campaign. The independent expiry reaper,
shared infrastructure, Docker lane, runtime image build and live isolation tests
remain required. Step Functions timeout alone does not prove resource cleanup.
The separate reaper must stop owned tasks even when the worker/controller dies,
then use Terraform to destroy this root after retaining its diagnostic artifacts.
Do not infer qualification from Terraform validation or a successful task exit.
