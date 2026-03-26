using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static async Task ExecuteNativeK8sValidationAsync(
        RunnerContext context,
        K8sScenarioSettings settings)
    {
        ValidateK8sSettings(settings);

        var workspace = PrepareTerraformWorkspace(context, "k8s");
        var state = new K8sRuntimeState(workspace.Root, workspace.TerraformRoot);
        var kubectlEnvironment = BuildKubeEnvironment(settings);
        Exception? bodyFailure = null;
        var cleanupFailures = new List<Exception>();

        try
        {
            await RunHelmStaticValidationAsync(context, settings, kubectlEnvironment);
            await EnsureClusterReadyAsync(context, settings, state, kubectlEnvironment);
            await RunK8sDeploymentFlowAsync(context, settings, state, kubectlEnvironment);

            if (!settings.SkipObservability)
            {
                await ApplyObservabilityStackAsync(context, settings, state, kubectlEnvironment);
            }
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        if (settings.AutoDestroy)
        {
            await StopPortForwardAsync(state);

            try
            {
                await DestroyObservabilityStackAsync(context, settings, state, kubectlEnvironment);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }

            try
            {
                await DestroyHonuaStackAsync(context, settings, state, kubectlEnvironment);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }

            try
            {
                await DestroyClusterAsync(context, settings, state, kubectlEnvironment);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }

            try
            {
                if (Directory.Exists(workspace.Root))
                {
                    Directory.Delete(workspace.Root, recursive: true);
                }
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }
        }
        else
        {
            Console.WriteLine($"[runner] Auto-destroy disabled; retained Kubernetes validation workspace at {workspace.Root}");
        }

        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static K8sScenarioSettings BuildK8sSettings(
        ParsedCommand command,
        RunnerContext context,
        K8sScenarioOverrides? overrides = null)
    {
        var env = context.Environment;
        var useAot = overrides?.UseAot ?? GetBooleanOption(command, env, "aot", "HONUA_USE_AOT");
        var adminPassword = overrides?.AdminPassword ?? env.GetRequired("HONUA_ADMIN_PASSWORD");
        var masterKey = overrides?.MasterKey ?? env.GetOptional("SECURITY_MASTER_KEY") ?? adminPassword;
        var currentImage = overrides?.Image ?? ResolveManagedImage(
            GetOptionOrEnvironment(command, env, "image", "HONUA_K8S_IMAGE", string.Empty),
            useAot);

        return new K8sScenarioSettings(
            ClusterName: overrides?.ClusterName ?? GetOptionOrEnvironment(command, env, "cluster-name", "K8S_TF_CLUSTER_NAME", $"honua-it-{DateTime.UtcNow:MMddHHmm}"),
            ClusterMode: overrides?.ClusterMode ?? GetOptionOrEnvironment(command, env, "cluster-mode", "K8S_TF_CLUSTER_MODE", "k3d"),
            AccessMode: overrides?.AccessMode ?? GetOptionOrEnvironment(command, env, "access-mode", "K8S_TF_ACCESS_MODE", "ingress"),
            KubeconfigPath: overrides?.KubeconfigPath ?? GetOptionOrEnvironment(command, env, "kubeconfig", "KUBECONFIG", GetDefaultKubeconfigPath()),
            EnvironmentOverrides: overrides?.EnvironmentOverrides ?? new Dictionary<string, string?>(StringComparer.Ordinal),
            KubeContext: overrides?.KubeContext ?? GetOptionOrEnvironment(command, env, "kube-context", "K8S_TF_KUBE_CONTEXT", string.Empty),
            HttpPort: GetIntOption(command, env, "http-port", "K8S_TF_HTTP_PORT", 8080),
            HttpsPort: GetIntOption(command, env, "https-port", "K8S_TF_HTTPS_PORT", 8443),
            ApiPort: GetIntOption(command, env, "api-port", "K8S_TF_API_PORT", 6550),
            ForwardPort: GetIntOption(command, env, "forward-port", "K8S_TF_FORWARD_PORT", 18080),
            Namespace: overrides?.Namespace ?? GetOptionOrEnvironment(command, env, "namespace", "K8S_TF_NAMESPACE", "honua"),
            ObservabilityNamespace: overrides?.ObservabilityNamespace ?? GetOptionOrEnvironment(command, env, "observability-namespace", "K8S_TF_OBS_NAMESPACE", "honua-observability"),
            ReleaseName: overrides?.ReleaseName ?? GetOptionOrEnvironment(command, env, "release-name", "K8S_TF_RELEASE_NAME", "honua"),
            IngressHostname: overrides?.IngressHostname ?? GetOptionOrEnvironment(command, env, "ingress-host", "K8S_TF_INGRESS_HOSTNAME", "honua.local"),
            UseAot: useAot,
            CurrentImage: currentImage,
            PreviousImage: overrides?.PreviousImage ?? GetOptionOrEnvironment(command, env, "previous-image", "HONUA_K8S_PREVIOUS_IMAGE", string.Empty),
            RunUpgradeRollback: overrides?.RunUpgradeRollback ?? GetBooleanOption(command, env, "upgrade-rollback", "HONUA_RUN_UPGRADE_ROLLBACK"),
            TimeoutSeconds: GetIntOption(command, env, "timeout-seconds", "HONUA_K8S_TEST_TIMEOUT_SECONDS", 900),
            LoadRequests: GetIntOption(command, env, "load-requests", "HONUA_K8S_LOAD_REQUESTS", 80),
            LoadConcurrency: GetIntOption(command, env, "load-concurrency", "HONUA_K8S_LOAD_CONCURRENCY", 20),
            ScaleTargetReplicas: GetIntOption(command, env, "scale-target-replicas", "HONUA_K8S_SCALE_TARGET_REPLICAS", 2),
            ReadySloSeconds: GetIntOption(command, env, "max-ready-seconds", "HONUA_READY_SLO_SECONDS", 600),
            MaxLoadErrorRatePercent: GetDecimalOption(command, env, "max-load-error-rate", "HONUA_MAX_LOAD_ERROR_RATE_PERCENT", 0m),
            SkipIdempotency: overrides?.SkipIdempotency ?? GetBooleanOption(command, env, "skip-idempotency", "HONUA_SKIP_IDEMPOTENCY"),
            SkipProtocolChecks: overrides?.SkipProtocolChecks ?? GetBooleanOption(command, env, "skip-protocol-checks", "HONUA_SKIP_PROTOCOL_CHECKS"),
            SkipObservability: overrides?.SkipObservability ?? GetBooleanOption(command, env, "skip-observability", "HONUA_SKIP_OBSERVABILITY"),
            SkipDbResilience: overrides?.SkipDbResilience ?? GetBooleanOption(command, env, "skip-db-resilience", "HONUA_SKIP_DB_RESILIENCE"),
            SkipHelmStaticValidation: overrides?.SkipHelmStaticValidation ?? GetBooleanOption(command, env, "skip-helm-static-validation", "HONUA_SKIP_HELM_STATIC_VALIDATION"),
            SkipScaleCheck: overrides?.SkipScaleCheck ?? GetBooleanOption(command, env, "no-scale-check", "HONUA_SKIP_SCALE_CHECK"),
            AutoDestroy: overrides?.AutoDestroy ?? !command.GetBoolean("no-destroy", false),
            AdminPassword: adminPassword,
            MasterKey: masterKey,
            HelmChartPath: overrides?.HelmChartPath ?? ResolveHelmChartPath(context, env.GetOptional("HONUA_HELM_CHART_PATH")),
            KubeconformImage: env.GetOrDefault("HONUA_KUBECONFORM_IMAGE", "ghcr.io/yannh/kubeconform:v0.7.0"));
    }

    private static async Task RunK8sDeploymentFlowAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        await EnsurePostgisAsync(context, settings, state, kubectlEnvironment);

        if (settings.RunUpgradeRollback)
        {
            await DeployHonuaReleaseAsync(context, settings, state, kubectlEnvironment, settings.PreviousImage, "previous");
            await RunStackChecksAsync(context, settings, state, loadProbe: false, kubectlEnvironment);

            await DeployHonuaReleaseAsync(context, settings, state, kubectlEnvironment, settings.CurrentImage, "upgrade");
            await RunStackChecksAsync(context, settings, state, loadProbe: true, kubectlEnvironment);
            await RunScaleCheckAsync(context, settings, state, kubectlEnvironment);

            await DeployHonuaReleaseAsync(context, settings, state, kubectlEnvironment, settings.PreviousImage, "rollback");
            await RunStackChecksAsync(context, settings, state, loadProbe: false, kubectlEnvironment);

            if (!settings.AutoDestroy)
            {
                await DeployHonuaReleaseAsync(context, settings, state, kubectlEnvironment, settings.CurrentImage, "restore-current");
                await RunStackChecksAsync(context, settings, state, loadProbe: false, kubectlEnvironment);
            }
        }
        else
        {
            await DeployHonuaReleaseAsync(context, settings, state, kubectlEnvironment, settings.CurrentImage, "current");
            await RunStackChecksAsync(context, settings, state, loadProbe: true, kubectlEnvironment);
            await RunScaleCheckAsync(context, settings, state, kubectlEnvironment);
        }
    }

    private static async Task RunHelmStaticValidationAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (settings.SkipHelmStaticValidation)
        {
            return;
        }

        RequireCommand("helm");
        await context.ProcessRunner.RunAsync("helm", ["dependency", "update", settings.HelmChartPath], context.RepoRoot, kubectlEnvironment);

        var ingressClass = settings.ClusterMode == "k3d" ? "traefik" : "nginx";
        var lintArguments = BuildHelmValidationArguments(
            "lint",
            settings.HelmChartPath,
            settings,
            ingressClass);
        await context.ProcessRunner.RunAsync("helm", lintArguments, context.RepoRoot, kubectlEnvironment);

        var templateArguments = BuildHelmValidationArguments(
            "template",
            settings.HelmChartPath,
            settings,
            ingressClass,
            includeNamespace: true);
        var rendered = await context.ProcessRunner.CaptureAsync("helm", templateArguments, context.RepoRoot, kubectlEnvironment);

        if (CommandExists("kubeconform"))
        {
            await context.ProcessRunner.RunWithInputAsync(
                "kubeconform",
                ["-strict", "-summary", "-ignore-missing-schemas"],
                context.RepoRoot,
                rendered,
                kubectlEnvironment);
            return;
        }

        RequireCommand("docker");
        await context.ProcessRunner.RunWithInputAsync(
            "docker",
            ["run", "--rm", "-i", settings.KubeconformImage, "-strict", "-summary", "-ignore-missing-schemas"],
            context.RepoRoot,
            rendered,
            kubectlEnvironment);
    }

    private static async Task EnsureClusterReadyAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        RequireCommand("kubectl");
        RequireCommand("helm");
        RequireCommand("terraform");
        RequireCommand("curl");

        if (settings.ClusterMode == "external")
        {
            if (!string.IsNullOrWhiteSpace(settings.KubeContext))
            {
                await context.ProcessRunner.RunAsync("kubectl", ["config", "use-context", settings.KubeContext], context.RepoRoot, kubectlEnvironment);
            }

            return;
        }

        RequireCommand("k3d");
        RequireCommand("docker");

        var clusterList = await context.ProcessRunner.CaptureAsync("k3d", ["cluster", "list"], context.RepoRoot, kubectlEnvironment);
        var clusterExists = !context.DryRun && clusterList
            .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Skip(1)
            .Any(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() == settings.ClusterName);
        state.ClusterCreated = !clusterExists;

        if (!clusterExists)
        {
            var createArguments = new List<string>
            {
                "cluster", "create", settings.ClusterName,
                "--api-port", settings.ApiPort.ToString(CultureInfo.InvariantCulture),
                "--servers", "1",
                "--agents", "0",
            };

            if (settings.AccessMode == "port-forward")
            {
                createArguments.Add("--no-lb");
            }
            else
            {
                createArguments.Add("-p");
                createArguments.Add($"{settings.HttpPort}:80@loadbalancer");
                createArguments.Add("-p");
                createArguments.Add($"{settings.HttpsPort}:443@loadbalancer");
            }

            await context.ProcessRunner.RunAsync("k3d", createArguments, context.RepoRoot, kubectlEnvironment);
        }

        await context.ProcessRunner.RunAsync("kubectl", ["config", "use-context", $"k3d-{settings.ClusterName}"], context.RepoRoot, kubectlEnvironment);

        if (context.DryRun)
        {
            return;
        }

        try
        {
            await context.ProcessRunner.RunAsync("kubectl", ["-n", "kube-system", "rollout", "status", "deployment/traefik", "--timeout=120s"], context.RepoRoot, kubectlEnvironment);
        }
        catch (CommandExecutionException)
        {
            Console.WriteLine("[runner] traefik deployment not found; install an ingress controller before testing ingress");
        }
    }

    private static async Task EnsurePostgisAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        await EnsureNamespaceAsync(context, settings.Namespace, kubectlEnvironment);
        var manifestPath = context.ResolveRepoPath("infrastructure", "terraform", "validation", "scripts", "k8s", "k8s", "postgis.yaml");
        await context.ProcessRunner.RunAsync("kubectl", ["-n", settings.Namespace, "apply", "--validate=false", "-f", manifestPath], context.RepoRoot, kubectlEnvironment);
        state.PostgisApplied = true;

        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.Namespace, "rollout", "status", "deployment/honua-postgis", "--timeout=120s"],
            context.RepoRoot,
            kubectlEnvironment);

        if (!context.DryRun)
        {
            for (var attempt = 1; attempt <= 60; attempt++)
            {
                try
                {
                    await context.ProcessRunner.RunAsync(
                        "kubectl",
                        [
                            "-n", settings.Namespace,
                            "exec",
                            "deployment/honua-postgis",
                            "--",
                            "sh",
                            "-c",
                            "export PGPASSWORD=honua; psql -h 127.0.0.1 -U honua -d honua -tAc 'SELECT 1'",
                        ],
                        context.RepoRoot,
                        kubectlEnvironment);
                    break;
                }
                catch (CommandExecutionException) when (attempt < 60)
                {
                    await Task.Delay(TimeSpan.FromSeconds(2));
                }
            }
        }

        await context.ProcessRunner.RunAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "exec",
                "deployment/honua-postgis",
                "--",
                "sh",
                "-c",
                "export PGPASSWORD=honua; psql -h 127.0.0.1 -U honua -d honua -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS postgis;'; psql -h 127.0.0.1 -U honua -d honua -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS postgis_raster;'",
            ],
            context.RepoRoot,
            kubectlEnvironment);
    }

    private static async Task DeployHonuaReleaseAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment,
        string image,
        string label)
    {
        await EnsureNamespaceAsync(context, settings.Namespace, kubectlEnvironment);

        var ingressClass = settings.ClusterMode == "k3d" ? "traefik" : "nginx";
        var (imageRepository, imageTag) = ParseImageReference(image);
        var helmArguments = new List<string>
        {
            "upgrade",
            "--install",
            settings.ReleaseName,
            settings.HelmChartPath,
            "--namespace", settings.Namespace,
            "--set", "ingress.enabled=true",
            "--set", $"ingress.className={ingressClass}",
            "--set", $"ingress.hosts[0].host={settings.IngressHostname}",
            "--set", "ingress.hosts[0].paths[0].path=/",
            "--set", "ingress.hosts[0].paths[0].pathType=Prefix",
            "--set", "postgresql.enabled=false",
            "--set-string", "secret.env.ConnectionStrings__DefaultConnection=Host=honua-postgis;Port=5432;Database=honua;Username=honua;Password=honua",
            "--set", $"secret.env.HONUA_ADMIN_PASSWORD={settings.AdminPassword}",
            "--set-string", $"secret.env.Security__ConnectionEncryption__MasterKey={settings.MasterKey}",
            "--set", $"image.repository={imageRepository}",
            "--set", $"image.tag={imageTag}",
            "--set", "config.env.HONUA_ADMIN_UI=true",
            "--set", "config.env.HostValidation__Enabled=false",
            "--set-string", $"config.env.PUBLIC_BASE_URL=http://{settings.IngressHostname}",
        };

        await context.ProcessRunner.RunAsync("helm", ["dependency", "update", settings.HelmChartPath], context.RepoRoot, kubectlEnvironment);
        await context.ProcessRunner.RunAsync("helm", helmArguments, context.RepoRoot, kubectlEnvironment);
        state.HonuaApplied = true;

        state.HonuaDeploymentName = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "get", "deployment",
                "-l", $"app.kubernetes.io/instance={settings.ReleaseName},app.kubernetes.io/name=honua",
                "-o", "jsonpath={.items[0].metadata.name}",
            ],
            context.RepoRoot,
            kubectlEnvironment);

        state.HonuaServiceName = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "get", "service",
                "-l", $"app.kubernetes.io/instance={settings.ReleaseName},app.kubernetes.io/name=honua",
                "-o", "jsonpath={.items[0].metadata.name}",
            ],
            context.RepoRoot,
            kubectlEnvironment);

        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.Namespace, "rollout", "status", $"deployment/{state.HonuaDeploymentName}", $"--timeout={settings.TimeoutSeconds}s"],
            context.RepoRoot,
            kubectlEnvironment);

        await context.ProcessRunner.RunAsync("helm", ["test", settings.ReleaseName, "--namespace", settings.Namespace], context.RepoRoot, kubectlEnvironment);
        await StopPortForwardAsync(state);
        state.PortForwardHandle = await StartPortForwardAsync(context, settings, state.HonuaServiceName, kubectlEnvironment);
        Console.WriteLine($"[runner] Release deployment complete for phase: {label}");
    }

    private static async Task RunStackChecksAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        bool loadProbe,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        await WaitForReadyAsync(context, settings);

        if (!settings.SkipProtocolChecks)
        {
            await VerifyProtocolEndpointsAsync(context, settings);
            await RunAdminApiCrudSmokeAsync(context, settings, kubectlEnvironment);
        }

        await VerifyPostgisExtensionsAsync(context, settings, kubectlEnvironment);
        if (!settings.SkipDbResilience)
        {
            await VerifyDbBackupRestoreAsync(context, settings, kubectlEnvironment);
        }

        if (loadProbe)
        {
            await RunLoadProbeAsync(context, settings);
        }
    }

    private static async Task RunScaleCheckAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (settings.SkipScaleCheck)
        {
            return;
        }

        var baselineReplicasRaw = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            ["-n", settings.Namespace, "get", $"deployment/{state.HonuaDeploymentName}", "-o", "jsonpath={.spec.replicas}"],
            context.RepoRoot,
            kubectlEnvironment);
        var baselineReplicas = int.TryParse(baselineReplicasRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedReplicas)
            ? parsedReplicas
            : 1;

        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.Namespace, "scale", $"deployment/{state.HonuaDeploymentName}", $"--replicas={settings.ScaleTargetReplicas}"],
            context.RepoRoot,
            kubectlEnvironment);
        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.Namespace, "rollout", "status", $"deployment/{state.HonuaDeploymentName}", $"--timeout={settings.TimeoutSeconds}s"],
            context.RepoRoot,
            kubectlEnvironment);

        var availableReplicasRaw = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            ["-n", settings.Namespace, "get", $"deployment/{state.HonuaDeploymentName}", "-o", "jsonpath={.status.availableReplicas}"],
            context.RepoRoot,
            kubectlEnvironment);

        if (!context.DryRun &&
            (!int.TryParse(availableReplicasRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var availableReplicas) ||
             availableReplicas < settings.ScaleTargetReplicas))
        {
            throw new ValidationException($"Expected available replicas >= {settings.ScaleTargetReplicas}, observed: {availableReplicasRaw}");
        }

        if (baselineReplicas != settings.ScaleTargetReplicas)
        {
            await context.ProcessRunner.RunAsync(
                "kubectl",
                ["-n", settings.Namespace, "scale", $"deployment/{state.HonuaDeploymentName}", $"--replicas={baselineReplicas}"],
                context.RepoRoot,
                kubectlEnvironment);
            await context.ProcessRunner.RunAsync(
                "kubectl",
                ["-n", settings.Namespace, "rollout", "status", $"deployment/{state.HonuaDeploymentName}", $"--timeout={settings.TimeoutSeconds}s"],
                context.RepoRoot,
                kubectlEnvironment);
        }
    }

    private static async Task ApplyObservabilityStackAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        var observabilityRoot = Path.Combine(state.TerraformRoot, "examples", "observability");
        var terraformEnvironment = new Dictionary<string, string?>(kubectlEnvironment, StringComparer.Ordinal)
        {
            ["TF_VAR_kubeconfig_path"] = settings.KubeconfigPath,
            ["TF_VAR_namespace"] = settings.ObservabilityNamespace,
            ["TF_VAR_honua_metrics_target"] = $"{state.HonuaServiceName}.{settings.Namespace}.svc.cluster.local:80",
            ["TF_VAR_grafana_ingress_host"] = string.Empty,
            ["TF_VAR_prometheus_persistence_enabled"] = "false",
            ["TF_VAR_grafana_persistence_enabled"] = "false",
            ["TF_VAR_helm_timeout_seconds"] = Math.Max(settings.TimeoutSeconds, 1800).ToString(CultureInfo.InvariantCulture),
            ["TF_IN_AUTOMATION"] = "true",
        };

        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + observabilityRoot, "init", "-input=false", "-no-color"], context.RepoRoot, terraformEnvironment);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + observabilityRoot, "plan", "-input=false", "-no-color", "-out=observability.tfplan"], context.RepoRoot, terraformEnvironment);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + observabilityRoot, "apply", "-input=false", "-auto-approve", "-no-color", "observability.tfplan"], context.RepoRoot, terraformEnvironment);
        state.ObservabilityApplied = true;

        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.ObservabilityNamespace, "wait", "--for=condition=Ready", "pod", "-l", "app.kubernetes.io/instance=honua-prometheus", $"--timeout={settings.TimeoutSeconds}s"],
            context.RepoRoot,
            kubectlEnvironment);
        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.ObservabilityNamespace, "wait", "--for=condition=Ready", "pod", "-l", "app.kubernetes.io/instance=honua-grafana", $"--timeout={settings.TimeoutSeconds}s"],
            context.RepoRoot,
            kubectlEnvironment);
        await context.ProcessRunner.RunAsync(
            "kubectl",
            ["-n", settings.ObservabilityNamespace, "get", "configmap", "honua-overview-dashboard"],
            context.RepoRoot,
            kubectlEnvironment);

        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, observabilityRoot, terraformEnvironment);
        }
    }

    private static async Task DestroyObservabilityStackAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (!state.ObservabilityApplied)
        {
            return;
        }

        var observabilityRoot = Path.Combine(state.TerraformRoot, "examples", "observability");
        var terraformEnvironment = new Dictionary<string, string?>(kubectlEnvironment, StringComparer.Ordinal)
        {
            ["TF_VAR_kubeconfig_path"] = settings.KubeconfigPath,
            ["TF_VAR_namespace"] = settings.ObservabilityNamespace,
            ["TF_VAR_honua_metrics_target"] = $"{state.HonuaServiceName}.{settings.Namespace}.svc.cluster.local:80",
            ["TF_VAR_grafana_ingress_host"] = string.Empty,
            ["TF_VAR_prometheus_persistence_enabled"] = "false",
            ["TF_VAR_grafana_persistence_enabled"] = "false",
            ["TF_VAR_helm_timeout_seconds"] = Math.Max(settings.TimeoutSeconds, 1800).ToString(CultureInfo.InvariantCulture),
            ["TF_IN_AUTOMATION"] = "true",
        };

        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + observabilityRoot, "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, terraformEnvironment);
    }

    private static async Task DestroyHonuaStackAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (state.HonuaApplied)
        {
            await context.ProcessRunner.RunAsync("helm", ["uninstall", settings.ReleaseName, "--namespace", settings.Namespace], context.RepoRoot, kubectlEnvironment);
        }

        if (state.PostgisApplied)
        {
            var manifestPath = context.ResolveRepoPath("infrastructure", "terraform", "validation", "scripts", "k8s", "k8s", "postgis.yaml");
            await context.ProcessRunner.RunAsync("kubectl", ["-n", settings.Namespace, "delete", "-f", manifestPath], context.RepoRoot, kubectlEnvironment);
        }
    }

    private static async Task DestroyClusterAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        K8sRuntimeState state,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (settings.ClusterMode != "k3d" || !state.ClusterCreated)
        {
            return;
        }

        await context.ProcessRunner.RunAsync("k3d", ["cluster", "delete", settings.ClusterName], context.RepoRoot, kubectlEnvironment);
    }

    private static async Task EnsureNamespaceAsync(
        RunnerContext context,
        string namespaceName,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        var yaml = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            ["create", "namespace", namespaceName, "--dry-run=client", "-o", "yaml"],
            context.RepoRoot,
            kubectlEnvironment);
        await context.ProcessRunner.RunWithInputAsync("kubectl", ["apply", "--validate=false", "-f", "-"], context.RepoRoot, yaml, kubectlEnvironment);
    }

    private static async Task WaitForReadyAsync(RunnerContext context, K8sScenarioSettings settings)
    {
        if (context.DryRun)
        {
            Console.WriteLine($"[runner] Dry-run: skipping readiness wait for {BuildHttpBaseUrl(settings)}/healthz/ready");
            return;
        }

        using var client = CreateHttpClient(settings);
        var start = DateTimeOffset.UtcNow;
        while (true)
        {
            if (await IsHttpSuccessAsync(client, settings, "/healthz/ready"))
            {
                var elapsed = DateTimeOffset.UtcNow - start;
                if (elapsed.TotalSeconds > settings.ReadySloSeconds)
                {
                    throw new ValidationException($"Ready SLO failed: {elapsed.TotalSeconds:0}s exceeds {settings.ReadySloSeconds}s");
                }

                return;
            }

            if ((DateTimeOffset.UtcNow - start).TotalSeconds > settings.TimeoutSeconds)
            {
                throw new ValidationException($"Timed out waiting for readiness: {BuildHttpBaseUrl(settings)}/healthz/ready");
            }

            await Task.Delay(TimeSpan.FromSeconds(10));
        }
    }

    private static async Task VerifyProtocolEndpointsAsync(RunnerContext context, K8sScenarioSettings settings)
    {
        if (context.DryRun)
        {
            Console.WriteLine("[runner] Dry-run: skipping protocol/admin smoke checks");
            return;
        }

        using var client = CreateHttpClient(settings);
        await EnsureEndpointAccessibleAsync(client, settings, "/rest/services?f=pjson");
        await EnsureEndpointAccessibleAsync(client, settings, "/ogc/features");
        await EnsureODataEndpointAccessibleAsync(client, settings, "/odata");

        using var adminRequest = CreateRequest(settings, HttpMethod.Get, "/api/v1/admin/config");
        using var adminResponse = await client.SendAsync(adminRequest);
        if (adminResponse.StatusCode is not HttpStatusCode.Unauthorized and not HttpStatusCode.Forbidden)
        {
            throw new ValidationException($"Expected unauthenticated admin endpoint to return 401/403, got {(int)adminResponse.StatusCode}");
        }
    }

    private static async Task RunAdminApiCrudSmokeAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (context.DryRun)
        {
            Console.WriteLine("[runner] Dry-run: skipping admin CRUD smoke");
            return;
        }

        var suffix = $"{DateTime.UtcNow:MMddHHmmss}{Guid.NewGuid():N}".Substring(0, 16);
        var tableName = $"smoke_{suffix}";
        var layerName = $"Smoke Layer {suffix}";
        var serviceName = $"smoke{suffix}";
        var connectionName = $"smoke-conn-{suffix}";
        string? connectionId = null;
        int? layerId = null;

        using var client = CreateHttpClient(settings);

        try
        {
            await ExecutePostgisSqlAsync(
                context,
                settings,
                kubectlEnvironment,
                $"""
                CREATE TABLE public.{tableName} (
                  id SERIAL PRIMARY KEY,
                  name TEXT NOT NULL,
                  population INTEGER,
                  geom geometry(Point, 4326) NOT NULL
                );
                INSERT INTO public.{tableName} (name, population, geom)
                VALUES ('Smoke Feature', 1, ST_SetSRID(ST_Point(1, 1), 4326));
                """);

            var connectionResponse = await SendJsonAsync(
                client,
                settings,
                HttpMethod.Post,
                "/api/v1/admin/connections",
                JsonSerializer.Serialize(new
                {
                    name = connectionName,
                    description = "Terraform smoke test connection",
                    host = "honua-postgis",
                    port = 5432,
                    databaseName = "honua",
                    username = "honua",
                    password = "honua",
                    sslRequired = false,
                    sslMode = "Disable",
                }),
                includeAdminApiKey: true);
            connectionId = GetRequiredJsonString(connectionResponse, "connectionId");

            var publishResponse = await SendJsonAsync(
                client,
                settings,
                HttpMethod.Post,
                $"/api/v1/admin/connections/{connectionId}/layers",
                JsonSerializer.Serialize(new
                {
                    schema = "public",
                    table = tableName,
                    layerName,
                    description = "Terraform smoke test layer",
                    geometryColumn = "geom",
                    geometryType = "Point",
                    srid = 4326,
                    primaryKey = "id",
                    fields = new[] { "id", "name", "population" },
                    serviceName,
                    enabled = true,
                }),
                includeAdminApiKey: true);
            layerId = GetRequiredJsonInt(publishResponse, "layerId");

            await ExecutePostgisSqlAsync(
                context,
                settings,
                kubectlEnvironment,
                $"""
                INSERT INTO features (layer_id, geometry, attributes)
                VALUES (
                  {layerId.Value},
                  ST_SetSRID(ST_Point(1, 1), 4326),
                  jsonb_build_object('id', 1, 'name', 'Smoke Feature', 'population', 1)
                );
                """);

            using var queryRequest = CreateRequest(
                settings,
                HttpMethod.Get,
                $"/rest/services/{serviceName}/FeatureServer/{layerId.Value}/query?where=1%3D1&outFields=id,name,population&f=pjson",
                includeAdminApiKey: true);
            using var queryResponse = await client.SendAsync(queryRequest);
            queryResponse.EnsureSuccessStatusCode();
            var queryBody = await queryResponse.Content.ReadAsStringAsync();
            using var queryJson = JsonDocument.Parse(queryBody);
            var featureCount = queryJson.RootElement.TryGetProperty("features", out var features) && features.ValueKind == JsonValueKind.Array
                ? features.GetArrayLength()
                : 0;

            if (featureCount == 0)
            {
                throw new ValidationException("Admin CRUD smoke failed: query returned no features");
            }
        }
        finally
        {
            var cleanupStatements = new List<string>();
            if (layerId.HasValue)
            {
                cleanupStatements.Add($"""
                DELETE FROM features WHERE layer_id = {layerId.Value};
                DELETE FROM honua.layer_fields WHERE layer_id = {layerId.Value};
                DELETE FROM honua.service_layers WHERE layer_id = {layerId.Value};
                DELETE FROM honua.layers WHERE layer_id = {layerId.Value};
                """);
                cleanupStatements.Add($"DELETE FROM honua.services WHERE service_name = '{serviceName.Replace("'", "''", StringComparison.Ordinal)}';");
            }

            cleanupStatements.Add($"DROP TABLE IF EXISTS public.{tableName};");
            await ExecutePostgisSqlAsync(context, settings, kubectlEnvironment, string.Join(Environment.NewLine, cleanupStatements), ignoreErrors: true);

            if (!string.IsNullOrWhiteSpace(connectionId))
            {
                try
                {
                    using var deleteRequest = CreateRequest(settings, HttpMethod.Delete, $"/api/v1/admin/connections/{connectionId}", includeAdminApiKey: true);
                    using var deleteResponse = await client.SendAsync(deleteRequest);
                    _ = deleteResponse.IsSuccessStatusCode;
                }
                catch
                {
                    // Swallow cleanup failures.
                }
            }
        }
    }

    private static async Task VerifyPostgisExtensionsAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (context.DryRun)
        {
            Console.WriteLine("[runner] Dry-run: skipping PostGIS extension verification");
            return;
        }

        var output = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "exec",
                "deployment/honua-postgis",
                "--",
                "sh",
                "-c",
                "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d honua -tA -c \"SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster') ORDER BY extname;\"",
            ],
            context.RepoRoot,
            kubectlEnvironment);

        if (!output.Contains("postgis", StringComparison.Ordinal) || !output.Contains("postgis_raster", StringComparison.Ordinal))
        {
            throw new ValidationException($"Expected postgis + postgis_raster extensions not both present. Observed: {output}");
        }
    }

    private static async Task VerifyDbBackupRestoreAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (context.DryRun)
        {
            Console.WriteLine("[runner] Dry-run: skipping DB backup/restore drill");
            return;
        }

        await context.ProcessRunner.RunAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "exec",
                "deployment/honua-postgis",
                "--",
                "sh",
                "-c",
                "set -e; export PGPASSWORD=honua; pg_dump -h 127.0.0.1 -U honua -d honua -Fc -f /tmp/honua.dump; psql -h 127.0.0.1 -U honua -d postgres -c 'DROP DATABASE IF EXISTS honua_restore_check'; psql -h 127.0.0.1 -U honua -d postgres -c 'CREATE DATABASE honua_restore_check'; pg_restore -h 127.0.0.1 -U honua -d honua_restore_check /tmp/honua.dump;",
            ],
            context.RepoRoot,
            kubectlEnvironment);

        var extensionsCount = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "exec",
                "deployment/honua-postgis",
                "--",
                "sh",
                "-c",
                "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d honua_restore_check -tA -c \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');\"",
            ],
            context.RepoRoot,
            kubectlEnvironment);

        await context.ProcessRunner.RunAsync(
            "kubectl",
            [
                "-n", settings.Namespace,
                "exec",
                "deployment/honua-postgis",
                "--",
                "sh",
                "-c",
                "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d postgres -c 'DROP DATABASE IF EXISTS honua_restore_check'",
            ],
            context.RepoRoot,
            kubectlEnvironment);

        if (!string.Equals(extensionsCount.Trim(), "2", StringComparison.Ordinal))
        {
            throw new ValidationException($"DB backup/restore drill failed: expected 2 PostGIS extensions in restored DB, got {extensionsCount}");
        }
    }

    private static async Task RunLoadProbeAsync(RunnerContext context, K8sScenarioSettings settings)
    {
        if (context.DryRun)
        {
            Console.WriteLine($"[runner] Dry-run: skipping load probe ({settings.LoadRequests} requests, concurrency {settings.LoadConcurrency})");
            return;
        }

        using var client = CreateHttpClient(settings);
        using var throttler = new SemaphoreSlim(settings.LoadConcurrency);
        var failures = 0;
        var tasks = Enumerable.Range(0, settings.LoadRequests).Select(async _ =>
        {
            await throttler.WaitAsync();
            try
            {
                if (!await IsHttpSuccessAsync(client, settings, "/healthz/ready"))
                {
                    Interlocked.Increment(ref failures);
                }
            }
            finally
            {
                throttler.Release();
            }
        });

        await Task.WhenAll(tasks);
        var errorRate = settings.LoadRequests == 0
            ? 0m
            : (decimal)failures * 100m / settings.LoadRequests;
        if (errorRate > settings.MaxLoadErrorRatePercent)
        {
            throw new ValidationException($"Load probe failed SLO: error rate {errorRate:0.####}% exceeds {settings.MaxLoadErrorRatePercent:0.####}%");
        }
    }

    private static async Task<string> SendJsonAsync(
        HttpClient client,
        K8sScenarioSettings settings,
        HttpMethod method,
        string path,
        string payload,
        bool includeAdminApiKey)
    {
        using var request = CreateRequest(settings, method, path, includeAdminApiKey);
        request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync();
    }

    private static async Task EnsureEndpointAccessibleAsync(HttpClient client, K8sScenarioSettings settings, string path)
    {
        using var request = CreateRequest(settings, HttpMethod.Get, path);
        using var response = await client.SendAsync(request);
        if (response.IsSuccessStatusCode || ((int)response.StatusCode >= 300 && (int)response.StatusCode < 400))
        {
            return;
        }

        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            using var authRequest = CreateRequest(settings, HttpMethod.Get, path, includeAdminApiKey: true);
            using var authResponse = await client.SendAsync(authRequest);
            authResponse.EnsureSuccessStatusCode();
            return;
        }

        throw new ValidationException($"Protocol smoke endpoint failed: {path} returned HTTP {(int)response.StatusCode}");
    }

    private static async Task EnsureODataEndpointAccessibleAsync(HttpClient client, K8sScenarioSettings settings, string path)
    {
        using var request = CreateRequest(settings, HttpMethod.Get, path);
        using var response = await client.SendAsync(request);
        if (response.IsSuccessStatusCode || ((int)response.StatusCode >= 300 && (int)response.StatusCode < 400))
        {
            return;
        }

        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            using var authRequest = CreateRequest(settings, HttpMethod.Get, path, includeAdminApiKey: true);
            using var authResponse = await client.SendAsync(authRequest);
            authResponse.EnsureSuccessStatusCode();
            return;
        }

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            var body = await response.Content.ReadAsStringAsync();
            if (body.Contains("OData is not enabled for any available service.", StringComparison.Ordinal) ||
                body.Contains("No OData-enabled services found", StringComparison.Ordinal))
            {
                return;
            }
        }

        throw new ValidationException($"Protocol smoke endpoint failed: {path} returned HTTP {(int)response.StatusCode}");
    }

    private static async Task<bool> IsHttpSuccessAsync(HttpClient client, K8sScenarioSettings settings, string path)
    {
        try
        {
            using var request = CreateRequest(settings, HttpMethod.Get, path);
            using var response = await client.SendAsync(request);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    private static HttpClient CreateHttpClient(K8sScenarioSettings settings)
    {
        return new HttpClient
        {
            BaseAddress = new Uri(BuildHttpBaseUrl(settings), UriKind.Absolute),
            Timeout = TimeSpan.FromSeconds(20),
        };
    }

    private static HttpRequestMessage CreateRequest(
        K8sScenarioSettings settings,
        HttpMethod method,
        string path,
        bool includeAdminApiKey = false)
    {
        var request = new HttpRequestMessage(method, path);
        if (settings.AccessMode == "ingress")
        {
            request.Headers.Host = settings.IngressHostname;
        }

        if (includeAdminApiKey)
        {
            request.Headers.Add("X-API-Key", settings.AdminPassword);
        }

        return request;
    }

    private static string BuildHttpBaseUrl(K8sScenarioSettings settings)
    {
        return settings.AccessMode == "port-forward"
            ? $"http://localhost:{settings.ForwardPort}"
            : $"http://localhost:{settings.HttpPort}";
    }

    private static async Task ExecutePostgisSqlAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        IReadOnlyDictionary<string, string?> kubectlEnvironment,
        string sql,
        bool ignoreErrors = false)
    {
        try
        {
            await context.ProcessRunner.RunWithInputAsync(
                "kubectl",
                [
                    "-n", settings.Namespace,
                    "exec",
                    "-i",
                    "deployment/honua-postgis",
                    "--",
                    "sh",
                    "-c",
                    "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d honua -v ON_ERROR_STOP=1",
                ],
                context.RepoRoot,
                sql + Environment.NewLine,
                kubectlEnvironment);
        }
        catch when (ignoreErrors)
        {
            // Swallow cleanup errors.
        }
    }

    private static async Task<PortForwardHandle?> StartPortForwardAsync(
        RunnerContext context,
        K8sScenarioSettings settings,
        string serviceName,
        IReadOnlyDictionary<string, string?> kubectlEnvironment)
    {
        if (settings.AccessMode != "port-forward")
        {
            return null;
        }

        if (context.DryRun)
        {
            Console.WriteLine($"[runner] Dry-run: skipping kubectl port-forward for service {serviceName}");
            return null;
        }

        var logPath = context.ResolveTempPath($"k8s-port-forward-{Guid.NewGuid():N}.log");
        var startInfo = new ProcessStartInfo
        {
            FileName = "kubectl",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = context.RepoRoot,
        };
        foreach (var argument in new[]
                 {
                     "-n", settings.Namespace,
                     "port-forward",
                     $"svc/{serviceName}",
                     $"{settings.ForwardPort}:80",
                 })
        {
            startInfo.ArgumentList.Add(argument);
        }

        foreach (var (name, value) in kubectlEnvironment)
        {
            if (value is null)
            {
                startInfo.Environment.Remove(name);
            }
            else
            {
                startInfo.Environment[name] = value;
            }
        }

        var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true,
        };
        process.OutputDataReceived += (_, args) =>
        {
            if (args.Data is not null)
            {
                File.AppendAllText(logPath, args.Data + Environment.NewLine);
            }
        };
        process.ErrorDataReceived += (_, args) =>
        {
            if (args.Data is not null)
            {
                File.AppendAllText(logPath, args.Data + Environment.NewLine);
            }
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        for (var attempt = 0; attempt < 30; attempt++)
        {
            if (process.HasExited)
            {
                var logContents = File.Exists(logPath) ? await File.ReadAllTextAsync(logPath) : string.Empty;
                throw new ValidationException($"Port-forward exited before becoming ready. Log: {logContents}");
            }

            if (File.Exists(logPath))
            {
                var logContents = await File.ReadAllTextAsync(logPath);
                if (logContents.Contains($"Forwarding from 127.0.0.1:{settings.ForwardPort}", StringComparison.Ordinal))
                {
                    return new PortForwardHandle(process, logPath);
                }
            }

            await Task.Delay(TimeSpan.FromSeconds(1));
        }

        throw new ValidationException($"Timed out waiting for port-forward on localhost:{settings.ForwardPort}");
    }

    private static async Task StopPortForwardAsync(K8sRuntimeState state)
    {
        if (state.PortForwardHandle is null)
        {
            return;
        }

        try
        {
            if (!state.PortForwardHandle.Process.HasExited)
            {
                state.PortForwardHandle.Process.Kill(entireProcessTree: true);
                await state.PortForwardHandle.Process.WaitForExitAsync();
            }
        }
        catch
        {
            // Best effort cleanup.
        }
        finally
        {
            state.PortForwardHandle.Process.Dispose();
            if (File.Exists(state.PortForwardHandle.LogPath))
            {
                File.Delete(state.PortForwardHandle.LogPath);
            }

            state.PortForwardHandle = null;
        }
    }

    private static string ResolveHelmChartPath(RunnerContext context, string? configuredPath)
    {
        if (TryResolveHelmChartPath(context, configuredPath, out var resolvedPath))
        {
            return resolvedPath;
        }

        throw new ValidationException("Could not resolve Helm chart path. Set HONUA_HELM_CHART_PATH or check out honua-server.");
    }

    private static bool TryResolveHelmChartPath(RunnerContext context, string? configuredPath, out string resolvedPath)
    {
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            candidates.Add(Path.IsPathRooted(configuredPath) ? configuredPath : context.ResolveRepoRelativePath(configuredPath));
        }

        candidates.Add(context.ResolveRepoPath("infrastructure", "helm", "honua"));
        candidates.Add(context.ResolveRepoPath("honua-server", "infrastructure", "helm", "honua"));
        candidates.Add(Path.GetFullPath(Path.Combine(context.RepoRoot, "..", "honua-server", "infrastructure", "helm", "honua")));
        candidates.Add(context.ResolveRepoPath("honua-server", "tmp", "repo-migrations", "honua-helm", "honua"));
        candidates.Add(Path.GetFullPath(Path.Combine(context.RepoRoot, "..", "honua-server", "tmp", "repo-migrations", "honua-helm", "honua")));

        foreach (var candidate in candidates)
        {
            if (File.Exists(Path.Combine(candidate, "Chart.yaml")))
            {
                resolvedPath = candidate;
                return true;
            }
        }

        resolvedPath = string.Empty;
        return false;
    }

    private static IReadOnlyDictionary<string, string?> BuildKubeEnvironment(K8sScenarioSettings settings)
    {
        var environment = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["KUBECONFIG"] = settings.KubeconfigPath,
        };

        foreach (var pair in settings.EnvironmentOverrides)
        {
            environment[pair.Key] = pair.Value;
        }

        return environment;
    }

    private static void ValidateK8sSettings(K8sScenarioSettings settings)
    {
        if (string.IsNullOrWhiteSpace(settings.CurrentImage))
        {
            throw new ValidationException("Kubernetes image is required. Set HONUA_K8S_IMAGE or pass --image.");
        }

        if (settings.RunUpgradeRollback &&
            (string.IsNullOrWhiteSpace(settings.PreviousImage) || string.Equals(settings.PreviousImage, settings.CurrentImage, StringComparison.Ordinal)))
        {
            throw new ValidationException("Upgrade/rollback requires HONUA_K8S_PREVIOUS_IMAGE or --previous-image, and it must differ from the current image.");
        }

        if (settings.AdminPassword.Length < 12)
        {
            throw new ValidationException("HONUA_ADMIN_PASSWORD must be at least 12 characters.");
        }

        if (settings.MasterKey.Length < 32)
        {
            throw new ValidationException("SECURITY_MASTER_KEY (or HONUA_ADMIN_PASSWORD fallback) must be at least 32 characters.");
        }

        if (settings.ClusterMode is not "k3d" and not "external")
        {
            throw new ValidationException($"Invalid cluster mode: {settings.ClusterMode}");
        }

        if (settings.AccessMode is not "ingress" and not "port-forward")
        {
            throw new ValidationException($"Invalid access mode: {settings.AccessMode}");
        }

        _ = ParseImageReference(settings.CurrentImage);
        if (!string.IsNullOrWhiteSpace(settings.PreviousImage))
        {
            _ = ParseImageReference(settings.PreviousImage);
        }
    }

    private static (string Repository, string Tag) ParseImageReference(string image)
    {
        if (image.Contains('@', StringComparison.Ordinal))
        {
            throw new ValidationException("Image digest format is not supported here. Provide image as repository:tag.");
        }

        var separator = image.LastIndexOf(':');
        if (separator <= 0 || separator == image.Length - 1)
        {
            throw new ValidationException($"Image must include a tag. Example: ghcr.io/honua-io/honua-server:latest. Received: {image}");
        }

        return (image[..separator], image[(separator + 1)..]);
    }

    private static List<string> BuildHelmValidationArguments(
        string mode,
        string chartPath,
        K8sScenarioSettings settings,
        string ingressClass,
        bool includeNamespace = false)
    {
        var arguments = new List<string>();
        if (mode == "lint")
        {
            arguments.Add("lint");
            arguments.Add(chartPath);
        }
        else
        {
            arguments.Add("template");
            arguments.Add(settings.ReleaseName);
            arguments.Add(chartPath);
            if (includeNamespace)
            {
                arguments.Add("--namespace");
                arguments.Add(settings.Namespace);
            }
        }

        arguments.AddRange(
            [
                "--set", "ingress.enabled=true",
                "--set", $"ingress.className={ingressClass}",
                "--set", $"ingress.hosts[0].host={settings.IngressHostname}",
                "--set", "ingress.hosts[0].paths[0].path=/",
                "--set", "ingress.hosts[0].paths[0].pathType=Prefix",
                "--set", "postgresql.enabled=false",
                "--set-string", "secret.env.ConnectionStrings__DefaultConnection=Host=honua-postgis;Port=5432;Database=honua;Username=honua;Password=honua",
                "--set", $"secret.env.HONUA_ADMIN_PASSWORD={settings.AdminPassword}",
                "--set-string", $"secret.env.Security__ConnectionEncryption__MasterKey={settings.MasterKey}",
                "--set", $"image.repository={ParseImageReference(settings.CurrentImage).Repository}",
                "--set", $"image.tag={ParseImageReference(settings.CurrentImage).Tag}",
            ]);

        return arguments;
    }

    private static string GetRequiredJsonString(string payload, string propertyName)
    {
        using var document = JsonDocument.Parse(payload);
        if (!TryGetResponseProperty(document.RootElement, propertyName, out var property) || property.ValueKind != JsonValueKind.String)
        {
            throw new ValidationException(BuildJsonParseFailureMessage(document.RootElement, propertyName));
        }

        return property.GetString() ?? throw new ValidationException($"JSON property {propertyName} was empty");
    }

    private static int GetRequiredJsonInt(string payload, string propertyName)
    {
        using var document = JsonDocument.Parse(payload);
        if (!TryGetResponseProperty(document.RootElement, propertyName, out var property) || !property.TryGetInt32(out var value))
        {
            throw new ValidationException(BuildJsonParseFailureMessage(document.RootElement, propertyName));
        }

        return value;
    }

    private static bool TryGetResponseProperty(JsonElement root, string propertyName, out JsonElement property)
    {
        if (root.TryGetProperty(propertyName, out property))
        {
            return true;
        }

        if (root.TryGetProperty("data", out var data) &&
            data.ValueKind == JsonValueKind.Object &&
            data.TryGetProperty(propertyName, out property))
        {
            return true;
        }

        property = default;
        return false;
    }

    private static string BuildJsonParseFailureMessage(JsonElement root, string propertyName)
    {
        if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
        {
            var messageText = message.GetString();
            if (!string.IsNullOrWhiteSpace(messageText))
            {
                return $"Could not parse {propertyName} from JSON response: {messageText}";
            }
        }

        return $"Could not parse {propertyName} from JSON response";
    }

    private static string GetDefaultKubeconfigPath()
    {
        var configured = EnvironmentReader.GetEnvironmentVariableOrDefault("KUBECONFIG", string.Empty);
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured.Split(':', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).First();
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".kube", "config");
    }

    private sealed record K8sScenarioSettings(
        string ClusterName,
        string ClusterMode,
        string AccessMode,
        string KubeconfigPath,
        IReadOnlyDictionary<string, string?> EnvironmentOverrides,
        string KubeContext,
        int HttpPort,
        int HttpsPort,
        int ApiPort,
        int ForwardPort,
        string Namespace,
        string ObservabilityNamespace,
        string ReleaseName,
        string IngressHostname,
        bool UseAot,
        string CurrentImage,
        string PreviousImage,
        bool RunUpgradeRollback,
        int TimeoutSeconds,
        int LoadRequests,
        int LoadConcurrency,
        int ScaleTargetReplicas,
        int ReadySloSeconds,
        decimal MaxLoadErrorRatePercent,
        bool SkipIdempotency,
        bool SkipProtocolChecks,
        bool SkipObservability,
        bool SkipDbResilience,
        bool SkipHelmStaticValidation,
        bool SkipScaleCheck,
        bool AutoDestroy,
        string AdminPassword,
        string MasterKey,
        string HelmChartPath,
        string KubeconformImage);

    private sealed record K8sScenarioOverrides(
        string? ClusterName = null,
        string? ClusterMode = null,
        string? AccessMode = null,
        string? KubeconfigPath = null,
        IReadOnlyDictionary<string, string?>? EnvironmentOverrides = null,
        string? KubeContext = null,
        string? Namespace = null,
        string? ObservabilityNamespace = null,
        string? ReleaseName = null,
        string? IngressHostname = null,
        bool? UseAot = null,
        string? Image = null,
        string? PreviousImage = null,
        bool? RunUpgradeRollback = null,
        bool? SkipIdempotency = null,
        bool? SkipProtocolChecks = null,
        bool? SkipObservability = null,
        bool? SkipDbResilience = null,
        bool? SkipHelmStaticValidation = null,
        bool? SkipScaleCheck = null,
        bool? AutoDestroy = null,
        string? AdminPassword = null,
        string? MasterKey = null,
        string? HelmChartPath = null);

    private sealed class K8sRuntimeState(string workspaceRoot, string terraformRoot)
    {
        public string WorkspaceRoot { get; } = workspaceRoot;

        public string TerraformRoot { get; } = terraformRoot;

        public bool ClusterCreated { get; set; }

        public bool HonuaApplied { get; set; }

        public bool ObservabilityApplied { get; set; }

        public bool PostgisApplied { get; set; }

        public string HonuaDeploymentName { get; set; } = string.Empty;

        public string HonuaServiceName { get; set; } = string.Empty;

        public PortForwardHandle? PortForwardHandle { get; set; }
    }

    private sealed record PortForwardHandle(Process Process, string LogPath);
}
