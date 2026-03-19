using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private const string DefaultHonuaImage = "ghcr.io/honua-io/honua-server:latest";
    private const string DefaultHonuaAotImage = "ghcr.io/honua-io/honua-server:latest-aot";

    private static async Task RunNativeK8sValidationAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        _ = manifest;
        await ExecuteNativeK8sValidationAsync(context, BuildK8sSettings(command, context));
    }

    private static async Task RunNativeAksValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        ScenarioManifest manifest,
        AzureBootstrapCredentials credentials,
        IReadOnlyDictionary<string, string?> rootCredentialsEnvironment,
        string defaultPlanDir)
    {
        _ = manifest;
        context.Environment.GetRequired("HONUA_ADMIN_PASSWORD");

        var settings = BuildAksSettings(command, context.Environment, defaultPlanDir);
        var workspace = PrepareTerraformWorkspace(context, "aks");
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "azure-aks");
        var kubeconfigPath = Path.Combine(workspace.Root, "kubeconfig", "config");
        Directory.CreateDirectory(Path.GetDirectoryName(kubeconfigPath)!);

        var credentialsEnvironment = new Dictionary<string, string?>
        {
            ["ARM_CLIENT_ID"] = credentials.ClientId,
            ["ARM_CLIENT_SECRET"] = credentials.ClientSecret,
            ["ARM_TENANT_ID"] = credentials.TenantId,
            ["ARM_SUBSCRIPTION_ID"] = credentials.SubscriptionId,
        };

        var validationEnvironment = new Dictionary<string, string?>(credentialsEnvironment, StringComparer.Ordinal)
        {
            ["HONUA_VALIDATION_RUN_ID"] = settings.ValidationRunId,
        };
        AddConfigEnvironmentVariables(context.Environment, validationEnvironment, ManagedKubernetesAdapterEnvironmentVariables);
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_SCRIPT", TryGetDefaultPlatformValidationScript(context));

        var bodyFailure = (Exception?)null;
        var cleanupFailures = new List<Exception>();
        var clusterApplied = false;
        string? resourceGroupName = null;
        string? clusterName = null;

        try
        {
            RequireCommand("terraform");
            RequireCommand("kubectl");
            RequireCommand("helm");
            RequireCommand("az");

            await EnsureAzSessionAsync(context, credentialsEnvironment, credentials.SubscriptionId);

            AssertEstimatedRunCost(
                nodeCount: settings.NodeCount,
                unitCostUsd: 25m,
                maxRunCostUsd: settings.MaxRunCostUsd,
                label: "AKS");

            if (!settings.SkipQuotaPreflight)
            {
                await RunAksQuotaPreflightAsync(context, credentialsEnvironment, settings);
            }

            var terraformEnvironment = BuildAksTerraformEnvironment(settings, validationEnvironment);

            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, terraformEnvironment);
            await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, "aks.tfplan", "aks", settings.AllowDestroyPlan);
            clusterApplied = true;

            resourceGroupName = await CaptureTerraformOutputAsync(context, terraformRoot, "resource_group_name", terraformEnvironment);
            clusterName = await CaptureTerraformOutputAsync(context, terraformRoot, "cluster_name", terraformEnvironment);

            if (!settings.SkipIdempotency)
            {
                await AssertIdempotentPlanAsync(context, terraformRoot, terraformEnvironment);
            }

            await context.ProcessRunner.RunAsync(
                "az",
                [
                    "aks",
                    "get-credentials",
                    "--resource-group", resourceGroupName,
                    "--name", clusterName,
                    "--file", kubeconfigPath,
                    "--overwrite-existing",
                ],
                context.RepoRoot,
                credentialsEnvironment);

            await RunManagedK8sChecksAsync(
                command,
                context,
                clusterName,
                kubeconfigPath,
                validationEnvironment);
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        if (settings.AutoDestroy)
        {
            if (clusterApplied)
            {
                try
                {
                    var terraformEnvironment = BuildAksTerraformEnvironment(settings, validationEnvironment);
                    await context.ProcessRunner.RunAsync(
                        "terraform",
                        ["-chdir=" + terraformRoot, "destroy", "-input=false", "-auto-approve", "-no-color"],
                        context.RepoRoot,
                        terraformEnvironment);
                }
                catch (Exception exception)
                {
                    cleanupFailures.Add(exception);
                }
            }

            try
            {
                await VerifyNoAzureLeaksAsync(context, settings.ValidationRunId, rootCredentialsEnvironment);
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
            Console.WriteLine($"[runner] Auto-destroy disabled; retained AKS Terraform workspace at {workspace.Root}");
        }

        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task RunNativeEksValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        ScenarioManifest manifest,
        AwsBootstrapCredentials credentials,
        string defaultPlanDir)
    {
        _ = manifest;
        context.Environment.GetRequired("HONUA_ADMIN_PASSWORD");

        var settings = BuildEksSettings(command, context.Environment, defaultPlanDir);
        var workspace = PrepareTerraformWorkspace(context, "eks");
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "aws-eks");
        var kubeconfigPath = Path.Combine(workspace.Root, "kubeconfig");

        var credentialsEnvironment = new Dictionary<string, string?>
        {
            ["AWS_ACCESS_KEY_ID"] = credentials.AccessKeyId,
            ["AWS_SECRET_ACCESS_KEY"] = credentials.SecretAccessKey,
            ["AWS_SESSION_TOKEN"] = null,
            ["AWS_REGION"] = settings.Region,
            ["AWS_DEFAULT_REGION"] = settings.Region,
        };

        var validationEnvironment = new Dictionary<string, string?>(credentialsEnvironment, StringComparer.Ordinal)
        {
            ["HONUA_VALIDATION_RUN_ID"] = settings.ValidationRunId,
        };
        AddConfigEnvironmentVariables(context.Environment, validationEnvironment, ManagedKubernetesAdapterEnvironmentVariables);
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_SCRIPT", TryGetDefaultPlatformValidationScript(context));

        var bodyFailure = (Exception?)null;
        var cleanupFailures = new List<Exception>();
        var clusterApplied = false;
        string? clusterName = null;

        try
        {
            RequireCommand("terraform");
            RequireCommand("kubectl");
            RequireCommand("helm");
            RequireCommand("aws");

            await EnsureAwsSessionAsync(context, credentialsEnvironment);
            AssertEstimatedRunCost(
                nodeCount: settings.NodeDesiredSize,
                unitCostUsd: 35m,
                maxRunCostUsd: settings.MaxRunCostUsd,
                label: "EKS");

            if (!settings.SkipQuotaPreflight)
            {
                await RunEksQuotaPreflightAsync(context, credentialsEnvironment, settings);
            }

            settings = settings with
            {
                RunnerAccessCidr = settings.RunnerAccessCidr ?? $"{await DetectPublicIpv4Async(context)}/32"
            };
            var terraformEnvironment = BuildEksTerraformEnvironment(settings, validationEnvironment);

            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, terraformEnvironment);
            await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, "eks.tfplan", "eks", settings.AllowDestroyPlan);
            clusterApplied = true;

            clusterName = await CaptureTerraformOutputAsync(context, terraformRoot, "cluster_name", terraformEnvironment);

            if (!settings.SkipIdempotency)
            {
                await AssertIdempotentPlanAsync(context, terraformRoot, terraformEnvironment);
            }

            await context.ProcessRunner.RunAsync(
                "aws",
                [
                    "eks",
                    "update-kubeconfig",
                    "--name", clusterName,
                    "--region", settings.Region,
                    "--kubeconfig", kubeconfigPath,
                    "--alias", clusterName,
                ],
                context.RepoRoot,
                credentialsEnvironment);
            await MaterializeStaticEksKubeconfigAsync(context, clusterName, kubeconfigPath, credentialsEnvironment);
            await WaitForEksApiAccessAsync(context, clusterName, kubeconfigPath, credentialsEnvironment, timeoutSeconds: 300);

            await RunManagedK8sChecksAsync(
                command,
                context,
                clusterName,
                kubeconfigPath,
                validationEnvironment);
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        if (settings.AutoDestroy)
        {
            if (clusterApplied)
            {
                try
                {
                    var terraformEnvironment = BuildEksTerraformEnvironment(settings, validationEnvironment);
                    await context.ProcessRunner.RunAsync(
                        "terraform",
                        ["-chdir=" + terraformRoot, "destroy", "-input=false", "-auto-approve", "-no-color"],
                        context.RepoRoot,
                        terraformEnvironment);
                }
                catch (Exception exception)
                {
                    cleanupFailures.Add(exception);
                }
            }

            try
            {
                await VerifyNoAwsLeaksAsync(context, settings.ValidationRunId, credentialsEnvironment);
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
            Console.WriteLine($"[runner] Auto-destroy disabled; retained EKS Terraform workspace at {workspace.Root}");
        }

        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task RunManagedK8sChecksAsync(
        ParsedCommand command,
        RunnerContext context,
        string clusterName,
        string kubeconfigPath,
        IReadOnlyDictionary<string, string?> validationEnvironment)
    {
        await ExecuteNativeK8sValidationAsync(
            context,
            BuildK8sSettings(
                command,
                context,
                new K8sScenarioOverrides(
                    ClusterName: clusterName,
                    ClusterMode: "external",
                    AccessMode: "port-forward",
                    KubeconfigPath: kubeconfigPath,
                    EnvironmentOverrides: validationEnvironment,
                    AutoDestroy: !command.GetBoolean("no-destroy", false))));
    }

    private static async Task MaterializeStaticEksKubeconfigAsync(
        RunnerContext context,
        string clusterName,
        string kubeconfigPath,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var tokenResponse = await context.ProcessRunner.CaptureAsync(
            "aws",
            ["eks", "get-token", "--cluster-name", clusterName, "--region", credentialsEnvironment["AWS_REGION"]!],
            context.RepoRoot,
            credentialsEnvironment,
            redactOutput: true);
        using var tokenDocument = JsonDocument.Parse(tokenResponse);
        var token = tokenDocument.RootElement.GetProperty("status").GetProperty("token").GetString();
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new ValidationException($"Failed to capture EKS bearer token for cluster {clusterName}");
        }

        var kubeconfigJson = await context.ProcessRunner.CaptureAsync(
            "kubectl",
            ["config", "view", "--raw", "--kubeconfig", kubeconfigPath, "-o", "json"],
            context.RepoRoot,
            credentialsEnvironment);
        using var kubeconfigDocument = JsonDocument.Parse(kubeconfigJson);
        var root = kubeconfigDocument.RootElement;
        var clusterEntry = root.GetProperty("clusters").EnumerateArray().FirstOrDefault();
        var contextEntry = root.GetProperty("contexts").EnumerateArray().FirstOrDefault();
        if (clusterEntry.ValueKind == JsonValueKind.Undefined || contextEntry.ValueKind == JsonValueKind.Undefined)
        {
            throw new ValidationException($"Could not determine EKS cluster/context from kubeconfig {kubeconfigPath}");
        }

        var clusterRef = clusterEntry.GetProperty("name").GetString();
        var cluster = clusterEntry.GetProperty("cluster");
        var server = cluster.GetProperty("server").GetString();
        var certificateAuthorityData = cluster.GetProperty("certificate-authority-data").GetString();
        if (string.IsNullOrWhiteSpace(clusterRef) || string.IsNullOrWhiteSpace(server) || string.IsNullOrWhiteSpace(certificateAuthorityData))
        {
            throw new ValidationException($"EKS kubeconfig {kubeconfigPath} was missing cluster connection details");
        }

        var contextName = root.TryGetProperty("current-context", out var currentContextElement)
            ? currentContextElement.GetString()
            : contextEntry.GetProperty("name").GetString();
        if (string.IsNullOrWhiteSpace(contextName))
        {
            contextName = clusterName;
        }

        var staticKubeconfig = new Dictionary<string, object?>
        {
            ["apiVersion"] = "v1",
            ["kind"] = "Config",
            ["clusters"] = new object[]
            {
                new Dictionary<string, object?>
                {
                    ["name"] = clusterRef,
                    ["cluster"] = new Dictionary<string, object?>
                    {
                        ["server"] = server,
                        ["certificate-authority-data"] = certificateAuthorityData
                    }
                }
            },
            ["users"] = new object[]
            {
                new Dictionary<string, object?>
                {
                    ["name"] = clusterName,
                    ["user"] = new Dictionary<string, object?>
                    {
                        ["token"] = token
                    }
                }
            },
            ["contexts"] = new object[]
            {
                new Dictionary<string, object?>
                {
                    ["name"] = contextName,
                    ["context"] = new Dictionary<string, object?>
                    {
                        ["cluster"] = clusterRef,
                        ["user"] = clusterName
                    }
                }
            },
            ["current-context"] = contextName
        };

        File.WriteAllText(
            kubeconfigPath,
            JsonSerializer.Serialize(staticKubeconfig, new JsonSerializerOptions
            {
                WriteIndented = true
            }));
    }

    private static async Task WaitForEksApiAccessAsync(
        RunnerContext context,
        string clusterName,
        string kubeconfigPath,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        int timeoutSeconds)
    {
        var startedAt = DateTimeOffset.UtcNow;
        while (true)
        {
            await MaterializeStaticEksKubeconfigAsync(context, clusterName, kubeconfigPath, credentialsEnvironment);

            var (captured, output) = await context.ProcessRunner.TryCaptureAsync(
                "kubectl",
                ["--kubeconfig", kubeconfigPath, "get", "namespace", "default", "--request-timeout=15s", "-o", "name"],
                context.RepoRoot,
                credentialsEnvironment);
            if (captured && string.Equals(output.Trim(), "namespace/default", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            if ((DateTimeOffset.UtcNow - startedAt).TotalSeconds > timeoutSeconds)
            {
                throw new ValidationException($"Timed out waiting for EKS Kubernetes API access on cluster {clusterName}");
            }

            Console.WriteLine($"[runner] EKS API access not ready for cluster {clusterName}; retrying in 10s");
            await Task.Delay(TimeSpan.FromSeconds(10));
        }
    }

    private static ManagedAksSettings BuildAksSettings(ParsedCommand command, EnvironmentReader env, string defaultPlanDir)
    {
        var validationRunId = env.GetOrDefault("HONUA_VALIDATION_RUN_ID", $"aks-{DateTime.UtcNow:yyyyMMddHHmmss}");
        var useAot = GetBooleanOption(command, env, "aot", "HONUA_USE_AOT");
        var image = ResolveManagedImage(GetOptionOrEnvironment(command, env, "image", "HONUA_K8S_IMAGE", string.Empty), useAot);
        if (string.IsNullOrWhiteSpace(image))
        {
            throw new ValidationException("HONUA_K8S_IMAGE or --image is required for AKS validation.");
        }

        var previousImage = GetOptionOrEnvironment(command, env, "previous-image", "HONUA_K8S_PREVIOUS_IMAGE", string.Empty);
        if (GetBooleanOption(command, env, "upgrade-rollback", "HONUA_RUN_UPGRADE_ROLLBACK") &&
            (string.IsNullOrWhiteSpace(previousImage) || string.Equals(previousImage, image, StringComparison.Ordinal)))
        {
            throw new ValidationException("AKS upgrade/rollback requires --previous-image or HONUA_K8S_PREVIOUS_IMAGE and it must differ from the current image.");
        }

        return new ManagedAksSettings(
            Location: GetOptionOrEnvironment(command, env, "location", "HONUA_AZURE_VALIDATION_REGION", env.GetOrDefault("AZURE_VALIDATION_REGION", "westus")),
            Environment: NormalizeTerraformEnvironment(GetOptionOrEnvironment(command, env, "environment", "AKS_TF_ENVIRONMENT", "it")),
            NamePrefix: NormalizeNamePrefix(GetOptionOrEnvironment(command, env, "name-prefix-base", "HONUA_AKS_NAME_PREFIX_BASE", env.GetOrDefault("AKS_TF_NAME_PREFIX_BASE", BuildManagedNamePrefixBase(validationRunId, 10))), maxBaseLength: 10, suffix: "ak", maxTotalLength: 20),
            NodeCount: GetIntOption(command, env, "node-count", "AKS_NODE_COUNT", 2),
            NodeVmSize: GetOptionOrEnvironment(command, env, "node-vm-size", "AKS_NODE_VM_SIZE", "Standard_D2s_v3"),
            PlanArtifactDir: ResolveManagedPlanArtifactDir(command, defaultPlanDir),
            ValidationRunId: validationRunId,
            TtlHours: GetIntOption(command, env, "ttl-hours", "HONUA_TTL_HOURS", 8),
            MaxRunCostUsd: GetDecimalOption(command, env, "max-run-cost-usd", "HONUA_MAX_RUN_COST_USD", 100m),
            AllowDestroyPlan: command.GetBoolean("allow-destroy-plan", false),
            SkipQuotaPreflight: GetBooleanOption(command, env, "skip-quota-preflight", "HONUA_SKIP_QUOTA_PREFLIGHT"),
            SkipIdempotency: GetBooleanOption(command, env, "skip-idempotency", "HONUA_SKIP_IDEMPOTENCY"),
            AutoDestroy: !command.GetBoolean("no-destroy", false));
    }

    private static ManagedEksSettings BuildEksSettings(ParsedCommand command, EnvironmentReader env, string defaultPlanDir)
    {
        var validationRunId = env.GetOrDefault("HONUA_VALIDATION_RUN_ID", $"eks-{DateTime.UtcNow:yyyyMMddHHmmss}");
        var useAot = GetBooleanOption(command, env, "aot", "HONUA_USE_AOT");
        var image = ResolveManagedImage(GetOptionOrEnvironment(command, env, "image", "HONUA_K8S_IMAGE", string.Empty), useAot);
        if (string.IsNullOrWhiteSpace(image))
        {
            throw new ValidationException("HONUA_K8S_IMAGE or --image is required for EKS validation.");
        }

        var previousImage = GetOptionOrEnvironment(command, env, "previous-image", "HONUA_K8S_PREVIOUS_IMAGE", string.Empty);
        if (GetBooleanOption(command, env, "upgrade-rollback", "HONUA_RUN_UPGRADE_ROLLBACK") &&
            (string.IsNullOrWhiteSpace(previousImage) || string.Equals(previousImage, image, StringComparison.Ordinal)))
        {
            throw new ValidationException("EKS upgrade/rollback requires --previous-image or HONUA_K8S_PREVIOUS_IMAGE and it must differ from the current image.");
        }

        return new ManagedEksSettings(
            Region: GetOptionOrEnvironment(command, env, "region", "HONUA_AWS_VALIDATION_REGION", env.GetOrDefault("AWS_VALIDATION_REGION", "us-east-1")),
            Environment: NormalizeTerraformEnvironment(GetOptionOrEnvironment(command, env, "environment", "EKS_TF_ENVIRONMENT", "it")),
            NamePrefix: NormalizeNamePrefix(GetOptionOrEnvironment(command, env, "name-prefix-base", "HONUA_EKS_NAME_PREFIX_BASE", env.GetOrDefault("EKS_TF_NAME_PREFIX_BASE", BuildManagedNamePrefixBase(validationRunId, 8))), maxBaseLength: 8, suffix: "ek", maxTotalLength: 16),
            NodeInstanceType: GetOptionOrEnvironment(command, env, "node-instance-type", "EKS_NODE_INSTANCE_TYPE", "t3.small"),
            NodeMinSize: GetIntOption(command, env, "node-min-size", "EKS_NODE_MIN_SIZE", 1),
            NodeMaxSize: GetIntOption(command, env, "node-max-size", "EKS_NODE_MAX_SIZE", 3),
            NodeDesiredSize: GetIntOption(command, env, "node-desired-size", "EKS_NODE_DESIRED_SIZE", 2),
            PlanArtifactDir: ResolveManagedPlanArtifactDir(command, defaultPlanDir),
            ValidationRunId: validationRunId,
            TtlHours: GetIntOption(command, env, "ttl-hours", "HONUA_TTL_HOURS", 8),
            MaxRunCostUsd: GetDecimalOption(command, env, "max-run-cost-usd", "HONUA_MAX_RUN_COST_USD", 100m),
            ExistingVpcId: env.GetOptional("HONUA_AWS_EXISTING_VPC_ID"),
            ExistingVpcCidr: env.GetOptional("HONUA_AWS_EXISTING_VPC_CIDR"),
            ExistingPublicSubnetIdsJson: env.GetOptional("HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS"),
            ExistingPrivateSubnetIdsJson: env.GetOptional("HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS"),
            RunnerAccessCidr: env.GetOptional("HONUA_EKS_CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDR"),
            AllowDestroyPlan: command.GetBoolean("allow-destroy-plan", false),
            SkipQuotaPreflight: GetBooleanOption(command, env, "skip-quota-preflight", "HONUA_SKIP_QUOTA_PREFLIGHT"),
            SkipIdempotency: GetBooleanOption(command, env, "skip-idempotency", "HONUA_SKIP_IDEMPOTENCY"),
            AutoDestroy: !command.GetBoolean("no-destroy", false));
    }

    private static Dictionary<string, string?> BuildAksTerraformEnvironment(ManagedAksSettings settings, IReadOnlyDictionary<string, string?> baseEnvironment)
    {
        var environment = new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_VAR_location"] = settings.Location,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = settings.NamePrefix,
            ["TF_VAR_node_count"] = settings.NodeCount.ToString(CultureInfo.InvariantCulture),
            ["TF_VAR_node_vm_size"] = settings.NodeVmSize,
            ["TF_VAR_tags"] = BuildValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
            ["TF_IN_AUTOMATION"] = "true",
        };
        return environment;
    }

    private static Dictionary<string, string?> BuildEksTerraformEnvironment(ManagedEksSettings settings, IReadOnlyDictionary<string, string?> baseEnvironment)
    {
        var environment = new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["AWS_REGION"] = settings.Region,
            ["AWS_DEFAULT_REGION"] = settings.Region,
            ["TF_VAR_region"] = settings.Region,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = settings.NamePrefix,
            ["TF_VAR_node_instance_types"] = $"[\"{settings.NodeInstanceType}\"]",
            ["TF_VAR_node_min_size"] = settings.NodeMinSize.ToString(CultureInfo.InvariantCulture),
            ["TF_VAR_node_max_size"] = settings.NodeMaxSize.ToString(CultureInfo.InvariantCulture),
            ["TF_VAR_node_desired_size"] = settings.NodeDesiredSize.ToString(CultureInfo.InvariantCulture),
            ["TF_VAR_cluster_endpoint_public_access"] = "true",
            ["TF_VAR_cluster_endpoint_public_access_cidrs"] = JsonSerializer.Serialize(new[] { settings.RunnerAccessCidr ?? "0.0.0.0/0" }),
            ["TF_VAR_enable_cluster_creator_admin_permissions"] = "true",
            ["TF_VAR_tags"] = BuildValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
            ["TF_IN_AUTOMATION"] = "true",
        };

        if (!string.IsNullOrWhiteSpace(settings.ExistingVpcId))
        {
            environment["TF_VAR_existing_vpc_id"] = settings.ExistingVpcId;
            environment["TF_VAR_existing_vpc_cidr"] = settings.ExistingVpcCidr;
            environment["TF_VAR_existing_public_subnet_ids"] = settings.ExistingPublicSubnetIdsJson ?? "[]";
            environment["TF_VAR_existing_private_subnet_ids"] = settings.ExistingPrivateSubnetIdsJson ?? "[]";
        }

        return environment;
    }

    private static async Task RunTerraformPlanApplyAsync(
        RunnerContext context,
        string terraformRoot,
        IReadOnlyDictionary<string, string?> environment,
        string planArtifactDir,
        string planFileName,
        string label,
        bool allowDestroyPlan)
    {
        Directory.CreateDirectory(planArtifactDir);
        await context.ProcessRunner.RunAsync(
            "terraform",
            ["-chdir=" + terraformRoot, "plan", "-input=false", "-no-color", "-out=" + planFileName],
            context.RepoRoot,
            environment);

        var planText = await context.ProcessRunner.CaptureAsync(
            "terraform",
            ["-chdir=" + terraformRoot, "show", "-no-color", planFileName],
            context.RepoRoot,
            environment);

        if (!context.DryRun)
        {
            await File.WriteAllTextAsync(Path.Combine(planArtifactDir, $"{label}.plan.txt"), planText);

            var planPath = Path.Combine(terraformRoot, planFileName);
            if (File.Exists(planPath))
            {
                File.Copy(planPath, Path.Combine(planArtifactDir, $"{label}.tfplan"), overwrite: true);
            }
        }

        var destroyCount = ParseDestroyCount(planText);
        if (!allowDestroyPlan && destroyCount > 0)
        {
            throw new ValidationException($"Plan '{label}' includes {destroyCount} destroy actions; refusing apply without --allow-destroy-plan");
        }

        await context.ProcessRunner.RunAsync(
            "terraform",
            ["-chdir=" + terraformRoot, "apply", "-input=false", "-auto-approve", "-no-color", planFileName],
            context.RepoRoot,
            environment);
    }

    private static async Task AssertIdempotentPlanAsync(
        RunnerContext context,
        string terraformRoot,
        IReadOnlyDictionary<string, string?> environment)
    {
        try
        {
            await context.ProcessRunner.CaptureAsync(
                "terraform",
                ["-chdir=" + terraformRoot, "plan", "-input=false", "-no-color", "-detailed-exitcode"],
                context.RepoRoot,
                environment);
        }
        catch (CommandExecutionException exception) when (exception.ExitCode == 2)
        {
            throw new ValidationException($"Idempotency check failed for {terraformRoot} (terraform reports pending changes)");
        }
    }

    private static async Task<string> CaptureTerraformOutputAsync(
        RunnerContext context,
        string terraformRoot,
        string outputName,
        IReadOnlyDictionary<string, string?> environment)
    {
        return await context.ProcessRunner.CaptureAsync(
            "terraform",
            ["-chdir=" + terraformRoot, "output", "-raw", outputName],
            context.RepoRoot,
            environment);
    }

    private static async Task RunAksQuotaPreflightAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        ManagedAksSettings settings)
    {
        var vcpuRaw = await context.ProcessRunner.CaptureAsync(
            "az",
            [
                "vm",
                "list-skus",
                "-l", settings.Location,
                "--resource-type", "virtualMachines",
                "--query", $"[?name=='{settings.NodeVmSize}'].capabilities[?name=='vCPUs'].value | [0]",
                "-o", "tsv",
            ],
            context.RepoRoot,
            credentialsEnvironment);
        var vmVcpu = int.TryParse(vcpuRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedVcpu) ? parsedVcpu : 2;

        var usageRaw = await context.ProcessRunner.CaptureAsync(
            "az",
            [
                "vm",
                "list-usage",
                "-l", settings.Location,
                "--query", "[?name.value=='cores'] | [0].[currentValue,limit]",
                "-o", "tsv",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        var usageParts = usageRaw
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (usageParts.Length >= 2 &&
            int.TryParse(usageParts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var current) &&
            int.TryParse(usageParts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var limit))
        {
            var required = settings.NodeCount * vmVcpu;
            if (current + required > limit)
            {
                throw new ValidationException($"AKS quota preflight failed: cores usage {current}/{limit}, estimated required +{required}");
            }
        }
    }

    private static async Task RunEksQuotaPreflightAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        ManagedEksSettings settings)
    {
        var (quotaSuccess, quotaRaw) = await context.ProcessRunner.TryCaptureAsync(
            "aws",
            [
                "service-quotas",
                "get-service-quota",
                "--service-code", "ec2",
                "--quota-code", "L-1216C47A",
                "--query", "Quota.Value",
                "--output", "text",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        if (!quotaSuccess)
        {
            Console.WriteLine("[runner] Warn: unable to query EC2 vCPU quota; skipping EKS vCPU quota preflight.");
        }

        var (vcpuSuccess, vcpuRaw) = await context.ProcessRunner.TryCaptureAsync(
            "aws",
            [
                "ec2",
                "describe-instance-types",
                "--instance-types", settings.NodeInstanceType,
                "--query", "InstanceTypes[0].VCpuInfo.DefaultVCpus",
                "--output", "text",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        var vcpuPerNode = vcpuSuccess &&
                          int.TryParse(vcpuRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedVcpu)
            ? parsedVcpu
            : 2;

        if (quotaSuccess &&
            !string.IsNullOrWhiteSpace(quotaRaw) &&
            decimal.TryParse(quotaRaw, NumberStyles.Number, CultureInfo.InvariantCulture, out var quota))
        {
            var required = settings.NodeDesiredSize * vcpuPerNode;
            if (required > quota)
            {
                throw new ValidationException($"EKS quota preflight failed: required vCPU {required} exceeds EC2 regional quota {quota}");
            }
        }

        if (!string.IsNullOrWhiteSpace(settings.ExistingVpcId))
        {
            Console.WriteLine($"[runner] Reusing existing VPC for EKS validation: {settings.ExistingVpcId}");
            return;
        }

        var (vpcQuotaSuccess, vpcQuotaRaw) = await context.ProcessRunner.TryCaptureAsync(
            "aws",
            [
                "service-quotas",
                "list-service-quotas",
                "--service-code", "vpc",
                "--query", "Quotas[?QuotaName=='VPCs per Region'] | [0].Value",
                "--output", "text",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        if (!vpcQuotaSuccess)
        {
            Console.WriteLine("[runner] Warn: unable to query VPC quota; skipping EKS VPC quota preflight.");
            return;
        }

        var (currentVpcCountSuccess, currentVpcCountRaw) = await context.ProcessRunner.TryCaptureAsync(
            "aws",
            [
                "ec2",
                "describe-vpcs",
                "--query", "length(Vpcs)",
                "--output", "text",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        if (!currentVpcCountSuccess)
        {
            Console.WriteLine("[runner] Warn: unable to query current VPC count; skipping EKS VPC quota preflight.");
            return;
        }

        if (decimal.TryParse(vpcQuotaRaw, NumberStyles.Number, CultureInfo.InvariantCulture, out var vpcQuota) &&
            int.TryParse(currentVpcCountRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var currentVpcCount) &&
            currentVpcCount >= decimal.ToInt32(decimal.Truncate(vpcQuota)))
        {
            throw new ValidationException($"EKS quota preflight failed: VPC usage {currentVpcCount}/{vpcQuota}; no capacity remains for the validation VPC.");
        }
    }

    private static async Task VerifyNoAzureLeaksAsync(
        RunnerContext context,
        string validationRunId,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun)
        {
            Console.WriteLine($"[runner] Dry-run: skipping Azure leak janitor for ValidationRunId={validationRunId}");
            return;
        }

        IReadOnlyList<string> remainingResources = Array.Empty<string>();
        for (var attempt = 1; attempt <= 24; attempt++)
        {
            var resourcesJson = await context.ProcessRunner.CaptureAsync(
                "az",
                [
                    "resource",
                    "list",
                    "--tag", $"ValidationRunId={validationRunId}",
                    "--query", "[].{id:id,type:type,name:name,provisioningState:properties.provisioningState}",
                    "-o", "json",
                ],
                context.RepoRoot,
                credentialsEnvironment);

            remainingResources = ClassifyAzureLeakResources(resourcesJson);
            if (remainingResources.Count == 0)
            {
                return;
            }

            Console.WriteLine($"[runner] Azure leak janitor wait {attempt}/24: {remainingResources.Count} tagged resources still visible for ValidationRunId={validationRunId}");
            if (!context.DryRun)
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(15 * attempt, 60)));
            }
        }

        throw new ValidationException($"Leak janitor check failed: resources tagged ValidationRunId={validationRunId} still exist after extended wait: {string.Join(", ", remainingResources.Take(20))}");
    }

    private static IReadOnlyList<string> ClassifyAzureLeakResources(string resourcesJson)
    {
        if (string.IsNullOrWhiteSpace(resourcesJson))
        {
            return Array.Empty<string>();
        }

        try
        {
            using var document = JsonDocument.Parse(resourcesJson);
            var actionable = new List<string>();
            foreach (var resource in document.RootElement.EnumerateArray())
            {
                var id = resource.TryGetProperty("id", out var idProperty) ? idProperty.GetString() : null;
                var type = resource.TryGetProperty("type", out var typeProperty) ? typeProperty.GetString() : null;
                var name = resource.TryGetProperty("name", out var nameProperty) ? nameProperty.GetString() : null;
                var provisioningState = resource.TryGetProperty("provisioningState", out var stateProperty) ? stateProperty.GetString() : null;

                if (!string.IsNullOrWhiteSpace(provisioningState) &&
                    (provisioningState.Contains("Deleting", StringComparison.OrdinalIgnoreCase) ||
                     provisioningState.Contains("Deleted", StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }

                actionable.Add($"{type ?? "unknown"}:{name ?? id ?? "unknown"}");
            }

            return actionable;
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private static async Task EnsureAzSessionAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string subscriptionId)
    {
        var maxAttemptsRaw = context.Environment.GetOrDefault("HONUA_AZURE_LOGIN_MAX_ATTEMPTS", "12");
        var retrySecondsRaw = context.Environment.GetOrDefault("HONUA_AZURE_LOGIN_RETRY_SECONDS", "10");
        var maxAttempts = int.TryParse(maxAttemptsRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedMaxAttempts)
            ? Math.Max(parsedMaxAttempts, 1)
            : 12;
        var retrySeconds = int.TryParse(retrySecondsRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedRetrySeconds)
            ? Math.Max(parsedRetrySeconds, 1)
            : 10;

        Exception? lastFailure = null;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                await context.ProcessRunner.RunAsync(
                    "az",
                    [
                        "login",
                        "--service-principal",
                        "--allow-no-subscriptions",
                        "-u", credentialsEnvironment["ARM_CLIENT_ID"] ?? string.Empty,
                        "-p", credentialsEnvironment["ARM_CLIENT_SECRET"] ?? string.Empty,
                        "--tenant", credentialsEnvironment["ARM_TENANT_ID"] ?? string.Empty,
                    ],
                    context.RepoRoot,
                    credentialsEnvironment);

                await context.ProcessRunner.RunAsync(
                    "az",
                    ["account", "set", "-s", subscriptionId],
                    context.RepoRoot,
                    credentialsEnvironment);

                return;
            }
            catch (Exception exception) when (attempt < maxAttempts)
            {
                lastFailure = exception;
                Console.WriteLine($"[runner] Azure session attempt {attempt}/{maxAttempts} failed; retrying in {retrySeconds}s");
                if (!context.DryRun)
                {
                    await Task.Delay(TimeSpan.FromSeconds(retrySeconds));
                }
            }
        }

        if (lastFailure is not null)
        {
            throw lastFailure;
        }
    }

    private static async Task VerifyNoAwsLeaksAsync(
        RunnerContext context,
        string validationRunId,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun)
        {
            Console.WriteLine($"[runner] Dry-run: skipping AWS leak janitor for ValidationRunId={validationRunId}");
            return;
        }

        IReadOnlyList<string> remainingResources = Array.Empty<string>();
        for (var attempt = 1; attempt <= 24; attempt++)
        {
            var taggedResources = await ListAwsTaggedResourcesAsync(context, validationRunId, credentialsEnvironment);
            remainingResources = await FilterActionableAwsResourcesAsync(context, taggedResources, credentialsEnvironment);
            if (remainingResources.Count == 0)
            {
                return;
            }

            if (attempt == 1 || attempt % 4 == 0)
            {
                Console.WriteLine($"[runner] AWS leak janitor wait {attempt}/24: {remainingResources.Count} actionable tagged resources still visible for ValidationRunId={validationRunId}");
                foreach (var resource in remainingResources.Take(10))
                {
                    Console.WriteLine($"[runner]   lingering resource: {resource}");
                }

                if (remainingResources.Count > 10)
                {
                    Console.WriteLine($"[runner]   ... and {remainingResources.Count - 10} more");
                }
            }

            if (!context.DryRun)
            {
                var delaySeconds = Math.Min(15 + ((attempt - 1) / 4) * 15, 60);
                await Task.Delay(TimeSpan.FromSeconds(delaySeconds));
            }
        }

        throw new ValidationException($"Leak janitor check failed: resources tagged ValidationRunId={validationRunId} still exist after extended wait: {string.Join(", ", remainingResources.Take(20))}");
    }

    private static async Task<IReadOnlyList<string>> FilterActionableAwsResourcesAsync(
        RunnerContext context,
        IReadOnlyList<string> resources,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (resources.Count == 0)
        {
            return Array.Empty<string>();
        }

        var actionableResources = new List<string>(resources.Count);
        foreach (var resourceArn in resources)
        {
            var ignoreReason = await TryGetIgnorableAwsResourceReasonAsync(context, resourceArn, credentialsEnvironment);
            if (ignoreReason is null)
            {
                actionableResources.Add(resourceArn);
                continue;
            }

            Console.WriteLine($"[runner]   ignoring transient AWS cleanup artifact: {resourceArn} ({ignoreReason})");
        }

        actionableResources.Sort(StringComparer.Ordinal);
        return actionableResources;
    }

    private static async Task<string?> TryGetIgnorableAwsResourceReasonAsync(
        RunnerContext context,
        string resourceArn,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (resourceArn.Contains(":secretsmanager:", StringComparison.Ordinal))
        {
            var deletedDate = await TryCaptureAwsFieldAsync(
                context,
                ["secretsmanager", "describe-secret", "--secret-id", resourceArn, "--query", "DeletedDate", "--output", "text"],
                credentialsEnvironment);
            if (IsMissingAwsField(deletedDate))
            {
                return null;
            }

            return "scheduled for deletion";
        }

        if (resourceArn.Contains(":kms:", StringComparison.Ordinal))
        {
            var keyState = await TryCaptureAwsFieldAsync(
                context,
                ["kms", "describe-key", "--key-id", resourceArn, "--query", "KeyMetadata.KeyState", "--output", "text"],
                credentialsEnvironment);
            if (string.IsNullOrWhiteSpace(keyState))
            {
                return null;
            }

            if (!string.Equals(keyState, "Enabled", StringComparison.OrdinalIgnoreCase))
            {
                return $"kms state {keyState}";
            }

            return null;
        }

        if (!resourceArn.Contains(":ecs:", StringComparison.Ordinal))
        {
            if (resourceArn.Contains(":ec2:", StringComparison.Ordinal))
            {
                return await TryGetIgnorableEc2ResourceReasonAsync(context, resourceArn, credentialsEnvironment);
            }

            return null;
        }

        var resourcePart = GetAwsArnResourcePart(resourceArn);
        if (resourcePart.StartsWith("cluster/", StringComparison.Ordinal))
        {
            return "ECS clusters are non-billable control-plane metadata after service teardown";
        }

        if (resourcePart.StartsWith("service/", StringComparison.Ordinal))
        {
            return "ECS services are non-billable control-plane metadata after task teardown";
        }

        if (resourcePart.StartsWith("task-definition/", StringComparison.Ordinal))
        {
            return "ECS task definitions are non-billable metadata";
        }

        return null;
    }

    private static async Task<string?> TryGetIgnorableEc2ResourceReasonAsync(
        RunnerContext context,
        string resourceArn,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var resourcePart = GetAwsArnResourcePart(resourceArn);
        if (resourcePart.StartsWith("instance/", StringComparison.Ordinal))
        {
            var instanceId = resourcePart["instance/".Length..];
            var state = await TryCaptureAwsFieldAsync(
                context,
                ["ec2", "describe-instances", "--instance-ids", instanceId, "--query", "Reservations[0].Instances[0].State.Name", "--output", "text"],
                credentialsEnvironment);
            if (string.IsNullOrWhiteSpace(state))
            {
                return "instance not found";
            }

            if (state is "shutting-down" or "terminated")
            {
                return $"instance state {state}";
            }

            return null;
        }

        if (resourcePart.StartsWith("network-interface/", StringComparison.Ordinal))
        {
            var networkInterfaceId = resourcePart["network-interface/".Length..];
            var state = await TryCaptureAwsFieldAsync(
                context,
                ["ec2", "describe-network-interfaces", "--network-interface-ids", networkInterfaceId, "--query", "NetworkInterfaces[0].[Status,Attachment.Status]", "--output", "text"],
                credentialsEnvironment);
            if (string.IsNullOrWhiteSpace(state))
            {
                return "network interface not found";
            }

            var parts = state.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var interfaceStatus = parts.Length >= 1 ? parts[0] : string.Empty;
            var attachmentStatus = parts.Length >= 2 ? parts[1] : string.Empty;
            if (string.Equals(interfaceStatus, "available", StringComparison.OrdinalIgnoreCase) &&
                (string.IsNullOrWhiteSpace(attachmentStatus) || string.Equals(attachmentStatus, "detached", StringComparison.OrdinalIgnoreCase)))
            {
                return $"network interface status {interfaceStatus}";
            }

            return null;
        }

        if (resourcePart.StartsWith("volume/", StringComparison.Ordinal))
        {
            var volumeId = resourcePart["volume/".Length..];
            var state = await TryCaptureAwsFieldAsync(
                context,
                ["ec2", "describe-volumes", "--volume-ids", volumeId, "--query", "Volumes[0].State", "--output", "text"],
                credentialsEnvironment);
            if (string.IsNullOrWhiteSpace(state))
            {
                return "volume not found";
            }

            if (state is "deleting" or "deleted")
            {
                return $"volume state {state}";
            }

            return null;
        }

        return null;
    }

    private static async Task<string?> TryCaptureAwsFieldAsync(
        RunnerContext context,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var (success, output) = await context.ProcessRunner.TryCaptureAsync("aws", arguments, context.RepoRoot, credentialsEnvironment);
        if (!success)
        {
            return null;
        }

        var normalized = output?.Trim();
        return IsMissingAwsField(normalized) ? null : normalized;
    }

    private static bool IsMissingAwsField(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ||
               string.Equals(value, "None", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(value, "null", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(value, "[]", StringComparison.Ordinal);
    }

    private static string GetAwsArnResourcePart(string arn)
    {
        var parts = arn.Split(':', 6, StringSplitOptions.None);
        return parts.Length == 6 ? parts[5] : string.Empty;
    }

    private static async Task<IReadOnlyList<string>> ListAwsTaggedResourcesAsync(
        RunnerContext context,
        string validationRunId,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var raw = await context.ProcessRunner.CaptureAsync(
            "aws",
            [
                "resourcegroupstaggingapi",
                "get-resources",
                "--tag-filters", $"Key=ValidationRunId,Values={validationRunId}",
                "--query", "ResourceTagMappingList[].ResourceARN",
                "--output", "json",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        if (string.IsNullOrWhiteSpace(raw))
        {
            return Array.Empty<string>();
        }

        using var document = JsonDocument.Parse(raw);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }

        var results = new List<string>();
        foreach (var element in document.RootElement.EnumerateArray())
        {
            if (element.ValueKind == JsonValueKind.String)
            {
                var value = element.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    results.Add(value);
                }
            }
        }

        results.Sort(StringComparer.Ordinal);
        return results.Distinct(StringComparer.Ordinal).ToArray();
    }

    private static IsolatedTerraformWorkspace PrepareTerraformWorkspace(RunnerContext context, string label)
    {
        var root = context.ResolveTempPath($"managed-k8s-{label}-{Guid.NewGuid():N}");
        var terraformRoot = Path.Combine(root, "terraform");
        Directory.CreateDirectory(root);
        CopyDirectory(context.ResolveRepoPath("infrastructure", "terraform"), terraformRoot);
        return new IsolatedTerraformWorkspace(root, terraformRoot);
    }

    private static void CopyDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);

        foreach (var directory in Directory.GetDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(sourceDirectory, directory);
            if (relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(part => part is ".terraform" or "bin" or "obj"))
            {
                continue;
            }

            Directory.CreateDirectory(Path.Combine(destinationDirectory, relative));
        }

        foreach (var file in Directory.GetFiles(sourceDirectory, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(sourceDirectory, file);
            if (relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(part => part is ".terraform" or "bin" or "obj"))
            {
                continue;
            }

            var destination = Path.Combine(destinationDirectory, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file, destination, overwrite: true);
        }
    }

    private static void AssertEstimatedRunCost(int nodeCount, decimal unitCostUsd, decimal maxRunCostUsd, string label)
    {
        if (maxRunCostUsd <= 0)
        {
            return;
        }

        var estimated = nodeCount * unitCostUsd;
        if (estimated > maxRunCostUsd)
        {
            throw new ValidationException($"Estimated {label} run cost ({estimated:0.##} USD) exceeds cap ({maxRunCostUsd:0.##} USD)");
        }
    }

    private static string ResolveManagedPlanArtifactDir(ParsedCommand command, string defaultPlanDir)
    {
        return command.HasOption("plan-artifact-dir")
            ? Path.GetFullPath(command.GetRequiredString("plan-artifact-dir"))
            : defaultPlanDir;
    }

    private static string ResolveManagedImage(string image, bool useAot)
    {
        if (!useAot)
        {
            return image;
        }

        return string.Equals(image, DefaultHonuaImage, StringComparison.Ordinal)
            ? DefaultHonuaAotImage
            : image;
    }

    private static bool GetBooleanOption(ParsedCommand command, EnvironmentReader environment, string optionName, string envName)
    {
        return command.HasOption(optionName)
            ? command.GetBoolean(optionName, defaultValue: false)
            : environment.GetBoolean(envName, defaultValue: false);
    }

    private static string GetOptionOrEnvironment(ParsedCommand command, EnvironmentReader environment, string optionName, string envName, string defaultValue)
    {
        if (command.HasOption(optionName))
        {
            return command.GetString(optionName, defaultValue);
        }

        return environment.GetOrDefault(envName, defaultValue);
    }

    private static int GetIntOption(ParsedCommand command, EnvironmentReader environment, string optionName, string envName, int defaultValue)
    {
        var raw = GetOptionOrEnvironment(command, environment, optionName, envName, defaultValue.ToString(CultureInfo.InvariantCulture));
        if (!int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
        {
            throw new ValidationException($"Invalid integer value for {optionName}: {raw}");
        }

        return parsed;
    }

    private static decimal GetDecimalOption(ParsedCommand command, EnvironmentReader environment, string optionName, string envName, decimal defaultValue)
    {
        var raw = GetOptionOrEnvironment(command, environment, optionName, envName, defaultValue.ToString(CultureInfo.InvariantCulture));
        if (!decimal.TryParse(raw, NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed))
        {
            throw new ValidationException($"Invalid decimal value for {optionName}: {raw}");
        }

        return parsed;
    }

    private static string NormalizeTerraformEnvironment(string value)
    {
        var normalized = Regex.Replace(value.ToLowerInvariant(), "[^a-z0-9-]", string.Empty);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            throw new ValidationException("Environment value became empty after normalization");
        }

        return normalized;
    }

    private static string NormalizeNamePrefix(string value, int maxBaseLength, string suffix, int maxTotalLength)
    {
        var normalized = Regex.Replace(value.ToLowerInvariant(), "[^a-z0-9]", string.Empty);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            throw new ValidationException("Name prefix became empty after normalization");
        }

        normalized = normalized[..Math.Min(normalized.Length, maxBaseLength)];
        var combined = normalized + suffix;
        return combined[..Math.Min(combined.Length, maxTotalLength)];
    }

    private static int ParseDestroyCount(string planText)
    {
        var match = Regex.Match(planText, @"Plan:\s+\d+\s+to add,\s+\d+\s+to change,\s+(\d+)\s+to destroy\.", RegexOptions.CultureInvariant);
        if (!match.Success || !int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var destroyCount))
        {
            return 0;
        }

        return destroyCount;
    }

    private static string BuildValidationTagsJson(string validationRunId, int ttlHours)
    {
        var expiresAt = DateTime.UtcNow.AddHours(ttlHours).ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
        return $$"""{"ValidationRunId":"{{validationRunId}}","TTLHours":"{{ttlHours.ToString(CultureInfo.InvariantCulture)}}","ExpiresAtUTC":"{{expiresAt}}","Owner":"terraform-validation"}""";
    }

    private static string BuildManagedNamePrefixBase(string validationRunId, int maxBaseLength)
    {
        var normalized = Regex.Replace(validationRunId.ToLowerInvariant(), "[^a-z0-9]", string.Empty);
        var payloadLength = Math.Max(maxBaseLength - 1, 1);
        if (normalized.Length > payloadLength)
        {
            normalized = normalized[^payloadLength..];
        }

        return $"h{normalized.PadLeft(payloadLength, '0')}";
    }

    private static void RequireCommand(string commandName)
    {
        if (!CommandExists(commandName))
        {
            throw new ValidationException($"Required command not found: {commandName}");
        }
    }

    private sealed record ManagedAksSettings(
        string Location,
        string Environment,
        string NamePrefix,
        int NodeCount,
        string NodeVmSize,
        string PlanArtifactDir,
        string ValidationRunId,
        int TtlHours,
        decimal MaxRunCostUsd,
        bool AllowDestroyPlan,
        bool SkipQuotaPreflight,
        bool SkipIdempotency,
        bool AutoDestroy);

    private sealed record ManagedEksSettings(
        string Region,
        string Environment,
        string NamePrefix,
        string NodeInstanceType,
        int NodeMinSize,
        int NodeMaxSize,
        int NodeDesiredSize,
        string PlanArtifactDir,
        string ValidationRunId,
        int TtlHours,
        decimal MaxRunCostUsd,
        string? ExistingVpcId,
        string? ExistingVpcCidr,
        string? ExistingPublicSubnetIdsJson,
        string? ExistingPrivateSubnetIdsJson,
        string? RunnerAccessCidr,
        bool AllowDestroyPlan,
        bool SkipQuotaPreflight,
        bool SkipIdempotency,
        bool AutoDestroy);

    private sealed record IsolatedTerraformWorkspace(string Root, string TerraformRoot);
}
