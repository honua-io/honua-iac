using System.Text.RegularExpressions;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static readonly string[] AzureAdapterEnvironmentVariables =
    [
        "HONUA_USE_AOT",
        "HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_ENABLED",
        "HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_NAME",
        "HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_IMAGE",
        "HONUA_AZURE_DATA_CACHE_FILE",
        "HONUA_AZURE_EXISTING_DB_FQDN",
        "HONUA_AZURE_EXISTING_DB_CONNECTION_STRING",
        "HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING",
        "HONUA_AZURE_DESTROY_DATA",
        "HONUA_PLATFORM_VALIDATION_SCRIPT",
        "HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX",
    ];

    private static readonly string[] AwsAdapterEnvironmentVariables =
    [
        "HONUA_USE_AOT",
        "HONUA_AWS_DATA_CACHE_FILE",
        "HONUA_AWS_EXISTING_DB_ENDPOINT",
        "HONUA_AWS_EXISTING_DB_CONNECTION_STRING",
        "HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING",
        "HONUA_AWS_EXISTING_VPC_ID",
        "HONUA_AWS_EXISTING_VPC_CIDR",
        "HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS",
        "HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS",
        "HONUA_AWS_KEEP_DATA",
        "HONUA_AWS_DESTROY_DATA",
        "HONUA_PLATFORM_VALIDATION_SCRIPT",
        "HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX",
    ];

    private static readonly string[] ManagedKubernetesAdapterEnvironmentVariables =
    [
        "HONUA_USE_AOT",
        "HONUA_PLATFORM_VALIDATION_SCRIPT",
    ];

    public static Task RunAsync(ParsedCommand command, RunnerContext context)
    {
        var manifest = ScenarioManifestLoader.Load(context, command.Scenario);

        return command.Scenario switch
        {
            ScenarioName.StaticValidate => RunStaticValidateAsync(context, manifest),
            ScenarioName.PolicyGates => RunPolicyGatesAsync(command, context, manifest),
            ScenarioName.AzureLive => RunAzureLiveAsync(command, context, manifest),
            ScenarioName.AwsLive => RunAwsLiveAsync(command, context, manifest),
            ScenarioName.K8sLive => RunK8sLiveAsync(command, context, manifest),
            ScenarioName.AksLive => RunAksLiveAsync(command, context, manifest),
            ScenarioName.EksLive => RunEksLiveAsync(command, context, manifest),
            ScenarioName.Drift => RunDriftAsync(command, context, manifest),
            _ => throw new ValidationException($"Unsupported scenario: {command.Scenario}"),
        };
    }

    private static async Task RunStaticValidateAsync(RunnerContext context, ScenarioManifest manifest)
    {
        foreach (var formatPath in manifest.FormatPaths ?? [])
        {
            await context.ProcessRunner.RunAsync(
                "terraform",
                ["fmt", "-check", "-recursive", ResolveRepoRelativePath(context, formatPath)],
                context.RepoRoot);
        }

        foreach (var terraformRoot in manifest.TerraformRoots ?? [])
        {
            var resolvedRoot = ResolveRepoRelativePath(context, terraformRoot);
            await context.ProcessRunner.RunAsync(
                "terraform",
                [$"-chdir={resolvedRoot}", "init", "-backend=false", "-input=false", "-no-color"],
                context.RepoRoot);
            await context.ProcessRunner.RunAsync(
                "terraform",
                [$"-chdir={resolvedRoot}", "validate", "-no-color"],
                context.RepoRoot);
        }
    }

    private static async Task RunPolicyGatesAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var strictMode = command.HasOption("strict")
            ? command.GetBoolean("strict", defaultValue: true)
            : context.Environment.GetBoolean("HONUA_TERRAFORM_POLICY_STRICT", defaultValue: false);
        var rootPath = ResolveRepoRelativePath(
            context,
            command.GetString("root", RequiredManifestValue(manifest.RootPath, manifest, "rootPath")));

        RequireDirectory(rootPath, "policy root");
        RequireDirectory(Path.Combine(rootPath, "modules"), "policy modules root");
        RequireDirectory(Path.Combine(rootPath, "examples"), "policy examples root");

        if (strictMode)
        {
            Console.WriteLine("[runner] Policy scanner strict mode enabled");
        }
        else
        {
            Console.WriteLine("[runner] Policy scanner strict mode disabled; findings are reported but do not fail the run");
        }

        await RunTflintAsync(context, manifest, rootPath, strictMode);
        await RunCheckovAsync(context, manifest, rootPath, strictMode);
        await RunTfsecAsync(context, manifest, rootPath, strictMode);
        RunCustomPolicyChecks(rootPath);

        Console.WriteLine("[runner] Terraform policy gate checks completed successfully");
    }

    private static async Task RunAzureLiveAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        EnsurePersistentApproval(deploymentProfile, command.GetRequiredString("apply-confirmation"));

        var env = context.Environment;
        var rootCredentials = new Dictionary<string, string?>
        {
            ["ARM_CLIENT_ID"] = env.GetRequired("BOOTSTRAP_ARM_CLIENT_ID"),
            ["ARM_CLIENT_SECRET"] = env.GetRequired("BOOTSTRAP_ARM_CLIENT_SECRET"),
            ["ARM_TENANT_ID"] = env.GetRequired("BOOTSTRAP_ARM_TENANT_ID"),
            ["ARM_SUBSCRIPTION_ID"] = env.GetRequired("BOOTSTRAP_ARM_SUBSCRIPTION_ID"),
        };

        env.GetRequired("HONUA_ADMIN_PASSWORD");
        env.GetRequired("HONUA_DB_PASSWORD");

        var requestedStack = ParseAzureStack(env.GetOrDefaultAny(["AZURE_VALIDATION_STACK", "HONUA_AZURE_VALIDATION_STACK"], "both"));
        var runUpgradeRollback = env.GetBoolean("HONUA_RUN_UPGRADE_ROLLBACK");
        ValidateAzureImages(env, requestedStack, runUpgradeRollback);

        var bootstrapRoot = context.ResolveTempRelativePath(RequiredManifestValue(manifest.BootstrapRoot, manifest, "bootstrapRoot"));
        var planRoot = context.ResolveTempRelativePath(RequiredManifestValue(manifest.PlanArtifactRoot, manifest, "planArtifactRoot"));
        Directory.CreateDirectory(bootstrapRoot);
        Directory.CreateDirectory(planRoot);

        var leases = new List<BootstrapLease<AzureBootstrapCredentials>>();
        Exception? bodyFailure = null;

        try
        {
            foreach (var stack in Expand(requestedStack))
            {
                var lease = await BootstrapAzureAsync(context, manifest, stack, bootstrapRoot, rootCredentials);
                leases.Add(lease);
                await RunAzureValidationAsync(command, context, manifest, stack, lease.Credentials, rootCredentials, planRoot);
            }
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        var cleanupFailures = await CleanupAsync(leases, lease => DestroyAzureBootstrapAsync(context, lease, rootCredentials));
        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task RunAwsLiveAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        EnsurePersistentApproval(deploymentProfile, command.GetRequiredString("apply-confirmation"));

        var env = context.Environment;
        var rootCredentials = new Dictionary<string, string?>
        {
            ["AWS_ACCESS_KEY_ID"] = env.GetRequired("BOOTSTRAP_AWS_ACCESS_KEY_ID"),
            ["AWS_SECRET_ACCESS_KEY"] = env.GetRequired("BOOTSTRAP_AWS_SECRET_ACCESS_KEY"),
            ["AWS_SESSION_TOKEN"] = env.GetOptional("BOOTSTRAP_AWS_SESSION_TOKEN"),
        };

        env.GetRequired("HONUA_ADMIN_PASSWORD");
        env.GetRequired("HONUA_DB_PASSWORD");

        var requestedStack = ParseAwsStack(env.GetOrDefaultAny(["AWS_VALIDATION_STACK", "HONUA_AWS_VALIDATION_STACK"], "both"));
        var runUpgradeRollback = env.GetBoolean("HONUA_RUN_UPGRADE_ROLLBACK");
        ValidateAwsImages(env, requestedStack, runUpgradeRollback);

        var bootstrapRoot = context.ResolveTempRelativePath(RequiredManifestValue(manifest.BootstrapRoot, manifest, "bootstrapRoot"));
        var planRoot = context.ResolveTempRelativePath(RequiredManifestValue(manifest.PlanArtifactRoot, manifest, "planArtifactRoot"));
        Directory.CreateDirectory(bootstrapRoot);
        Directory.CreateDirectory(planRoot);

        var leases = new List<BootstrapLease<AwsBootstrapCredentials>>();
        Exception? bodyFailure = null;

        try
        {
            foreach (var stack in Expand(requestedStack))
            {
                var lease = await BootstrapAwsAsync(context, manifest, stack, bootstrapRoot, rootCredentials);
                leases.Add(lease);
                await RunAwsValidationAsync(command, context, manifest, stack, lease.Credentials, planRoot);
            }
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        var cleanupFailures = await CleanupAsync(leases, lease => DestroyAwsBootstrapAsync(context, lease, rootCredentials));
        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task RunK8sLiveAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        EnsurePersistentApproval(deploymentProfile, command.GetRequiredString("apply-confirmation"));
        await RunNativeK8sValidationAsync(command, context, manifest);
    }

    private static async Task RunAksLiveAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        EnsurePersistentApproval(deploymentProfile, command.GetRequiredString("apply-confirmation"));

        var env = context.Environment;
        var rootCredentials = new Dictionary<string, string?>
        {
            ["ARM_CLIENT_ID"] = env.GetRequired("BOOTSTRAP_ARM_CLIENT_ID"),
            ["ARM_CLIENT_SECRET"] = env.GetRequired("BOOTSTRAP_ARM_CLIENT_SECRET"),
            ["ARM_TENANT_ID"] = env.GetRequired("BOOTSTRAP_ARM_TENANT_ID"),
            ["ARM_SUBSCRIPTION_ID"] = env.GetRequired("BOOTSTRAP_ARM_SUBSCRIPTION_ID"),
        };

        env.GetRequired("HONUA_ADMIN_PASSWORD");
        env.GetRequired("HONUA_K8S_IMAGE");
        if (env.GetBoolean("HONUA_RUN_UPGRADE_ROLLBACK"))
        {
            env.GetRequired("HONUA_K8S_PREVIOUS_IMAGE");
        }

        var bootstrapDir = context.ResolveTempRelativePath(RequiredManifestValue(manifest.BootstrapRoot, manifest, "bootstrapRoot"));
        var planDir = context.ResolveTempRelativePath(RequiredManifestValue(manifest.PlanArtifactRoot, manifest, "planArtifactRoot"));
        Directory.CreateDirectory(bootstrapDir);
        Directory.CreateDirectory(planDir);

        BootstrapLease<AzureBootstrapCredentials>? lease = null;
        Exception? bodyFailure = null;

        try
        {
            lease = await BootstrapManagedAzureAsync(context, manifest, bootstrapDir, rootCredentials);
            await RunAksValidationAsync(command, context, manifest, lease.Credentials, rootCredentials, planDir);
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        var cleanupFailures = new List<Exception>();
        if (lease is not null)
        {
            cleanupFailures = await CleanupAsync([lease], currentLease => DestroyAzureBootstrapAsync(context, currentLease, rootCredentials));
        }

        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task RunEksLiveAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        EnsurePersistentApproval(deploymentProfile, command.GetRequiredString("apply-confirmation"));

        var env = context.Environment;
        var rootCredentials = new Dictionary<string, string?>
        {
            ["AWS_ACCESS_KEY_ID"] = env.GetRequired("BOOTSTRAP_AWS_ACCESS_KEY_ID"),
            ["AWS_SECRET_ACCESS_KEY"] = env.GetRequired("BOOTSTRAP_AWS_SECRET_ACCESS_KEY"),
            ["AWS_SESSION_TOKEN"] = env.GetOptional("BOOTSTRAP_AWS_SESSION_TOKEN"),
        };

        env.GetRequired("HONUA_ADMIN_PASSWORD");
        env.GetRequired("HONUA_K8S_IMAGE");
        if (env.GetBoolean("HONUA_RUN_UPGRADE_ROLLBACK"))
        {
            env.GetRequired("HONUA_K8S_PREVIOUS_IMAGE");
        }

        var bootstrapDir = context.ResolveTempRelativePath(RequiredManifestValue(manifest.BootstrapRoot, manifest, "bootstrapRoot"));
        var planDir = context.ResolveTempRelativePath(RequiredManifestValue(manifest.PlanArtifactRoot, manifest, "planArtifactRoot"));
        Directory.CreateDirectory(bootstrapDir);
        Directory.CreateDirectory(planDir);

        BootstrapLease<AwsBootstrapCredentials>? lease = null;
        Exception? bodyFailure = null;

        try
        {
            lease = await BootstrapManagedAwsAsync(context, manifest, bootstrapDir, rootCredentials);
            await RunEksValidationAsync(command, context, manifest, lease.Credentials, planDir);
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        var cleanupFailures = new List<Exception>();
        if (lease is not null)
        {
            cleanupFailures = await CleanupAsync([lease], currentLease => DestroyAwsBootstrapAsync(context, currentLease, rootCredentials));
        }

        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task RunDriftAsync(ParsedCommand command, RunnerContext context, ScenarioManifest manifest)
    {
        var cloud = ParseCloud(command.GetString("cloud", "both"));
        var roots = command.GetStrings("root");
        if (roots.Count == 0)
        {
            roots = context.Environment.GetCsv("HONUA_DRIFT_ROOTS");
        }

        if (roots.Count == 0)
        {
            roots = BuildDefaultDriftRoots(manifest, cloud, command.GetBoolean("run-aks", false), command.GetBoolean("run-eks", false));
        }

        if (roots.Count == 0)
        {
            throw new ValidationException("No Terraform roots selected for drift detection");
        }

        var varFiles = command.GetStrings("var-file");
        if (varFiles.Count == 0)
        {
            varFiles = context.Environment.GetCsv("HONUA_DRIFT_VAR_FILES");
        }

        var driftDir = command.HasOption("plan-artifact-dir")
            ? ResolveRepoRelativePath(context, command.GetRequiredString("plan-artifact-dir"))
            : context.ResolveTempPath("drift");
        Directory.CreateDirectory(driftDir);
        var resolvedVarFiles = varFiles
            .Select(varFile => ResolveRepoRelativePath(context, varFile))
            .ToArray();
        var backendEnabled = !command.GetBoolean("backend-false", defaultValue: false);

        foreach (var root in roots)
        {
            await RunDriftCheckForRootAsync(
                context,
                ResolveRepoRelativePath(context, root),
                resolvedVarFiles,
                driftDir,
                backendEnabled);
        }

        Console.WriteLine("[runner] Terraform drift detection completed successfully");
    }

    private static async Task<BootstrapLease<AzureBootstrapCredentials>> BootstrapAzureAsync(
        RunnerContext context,
        ScenarioManifest manifest,
        AzureStack stack,
        string bootstrapRoot,
        IReadOnlyDictionary<string, string?> rootCredentials)
    {
        var bootstrapName = stack switch
        {
            AzureStack.Aca => "aca",
            AzureStack.Functions => "functions",
            _ => throw new ValidationException($"Unsupported Azure stack bootstrap: {stack}"),
        };

        var bootstrapDir = Path.Combine(bootstrapRoot, bootstrapName);
        Directory.CreateDirectory(bootstrapDir);

        var bootstrapModule = GetRequiredBootstrapModule(manifest, bootstrapName);
        var sourceDirectory = context.ResolveRepoRelativePath(bootstrapModule.SourcePath);

        CopyTerraformFiles(sourceDirectory, bootstrapDir);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + bootstrapDir, "init", "-input=false", "-no-color"], context.RepoRoot, rootCredentials);

        var appName = bootstrapModule.ExpandAppName(context);
        var roleName = bootstrapModule.ExpandRoleName(context);

        await context.ProcessRunner.RunAsync(
            "terraform",
            ["-chdir=" + bootstrapDir, "apply", "-input=false", "-auto-approve", "-no-color", "-var", $"app_name={appName}", "-var", $"role_name={roleName}"],
            context.RepoRoot,
            rootCredentials);

        var credentials = new AzureBootstrapCredentials(
            ClientId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "client_id"], context.RepoRoot, rootCredentials, redactOutput: true),
            ClientSecret: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "client_secret"], context.RepoRoot, rootCredentials, redactOutput: true),
            TenantId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "tenant_id"], context.RepoRoot, rootCredentials, redactOutput: true),
            SubscriptionId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "subscription_id"], context.RepoRoot, rootCredentials, redactOutput: true));

        return new BootstrapLease<AzureBootstrapCredentials>(bootstrapDir, bootstrapName, credentials);
    }

    private static async Task<BootstrapLease<AwsBootstrapCredentials>> BootstrapAwsAsync(
        RunnerContext context,
        ScenarioManifest manifest,
        AwsStack stack,
        string bootstrapRoot,
        IReadOnlyDictionary<string, string?> rootCredentials)
    {
        var bootstrapName = stack switch
        {
            AwsStack.Ecs => "ecs",
            AwsStack.Serverless => "serverless",
            _ => throw new ValidationException($"Unsupported AWS stack bootstrap: {stack}"),
        };

        var bootstrapDir = Path.Combine(bootstrapRoot, bootstrapName);
        Directory.CreateDirectory(bootstrapDir);

        var bootstrapModule = GetRequiredBootstrapModule(manifest, bootstrapName);
        var sourceDirectory = context.ResolveRepoRelativePath(bootstrapModule.SourcePath);

        CopyTerraformFiles(sourceDirectory, bootstrapDir);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + bootstrapDir, "init", "-input=false", "-no-color"], context.RepoRoot, rootCredentials);

        var userName = bootstrapModule.ExpandUserName(context);

        await context.ProcessRunner.RunAsync(
            "terraform",
            [
                "-chdir=" + bootstrapDir,
                "apply",
                "-input=false",
                "-auto-approve",
                "-no-color",
                "-var", $"aws_region={context.Environment.GetOrDefaultAny(["AWS_VALIDATION_REGION", "HONUA_AWS_VALIDATION_REGION"], "us-east-1")}",
                "-var", "create_access_key=true",
                "-var", $"user_name={userName}",
            ],
            context.RepoRoot,
            rootCredentials);

        var credentials = new AwsBootstrapCredentials(
            AccessKeyId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "access_key_id"], context.RepoRoot, rootCredentials, redactOutput: true),
            SecretAccessKey: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "secret_access_key"], context.RepoRoot, rootCredentials, redactOutput: true));

        return new BootstrapLease<AwsBootstrapCredentials>(bootstrapDir, bootstrapName, credentials);
    }

    private static async Task<BootstrapLease<AzureBootstrapCredentials>> BootstrapManagedAzureAsync(
        RunnerContext context,
        ScenarioManifest manifest,
        string bootstrapDir,
        IReadOnlyDictionary<string, string?> rootCredentials)
    {
        var bootstrapModule = GetRequiredBootstrapModule(manifest, "aks");
        CopyTerraformFiles(context.ResolveRepoRelativePath(bootstrapModule.SourcePath), bootstrapDir);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + bootstrapDir, "init", "-input=false", "-no-color"], context.RepoRoot, rootCredentials);
        await context.ProcessRunner.RunAsync(
            "terraform",
            [
                "-chdir=" + bootstrapDir,
                "apply",
                "-input=false",
                "-auto-approve",
                "-no-color",
                "-var", $"app_name={bootstrapModule.ExpandAppName(context)}",
                "-var", $"role_name={bootstrapModule.ExpandRoleName(context)}",
            ],
            context.RepoRoot,
            rootCredentials);

        var credentials = new AzureBootstrapCredentials(
            ClientId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "client_id"], context.RepoRoot, rootCredentials, redactOutput: true),
            ClientSecret: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "client_secret"], context.RepoRoot, rootCredentials, redactOutput: true),
            TenantId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "tenant_id"], context.RepoRoot, rootCredentials, redactOutput: true),
            SubscriptionId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "subscription_id"], context.RepoRoot, rootCredentials, redactOutput: true));

        return new BootstrapLease<AzureBootstrapCredentials>(bootstrapDir, "aks", credentials);
    }

    private static async Task<BootstrapLease<AwsBootstrapCredentials>> BootstrapManagedAwsAsync(
        RunnerContext context,
        ScenarioManifest manifest,
        string bootstrapDir,
        IReadOnlyDictionary<string, string?> rootCredentials)
    {
        var bootstrapModule = GetRequiredBootstrapModule(manifest, "eks");
        CopyTerraformFiles(context.ResolveRepoRelativePath(bootstrapModule.SourcePath), bootstrapDir);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + bootstrapDir, "init", "-input=false", "-no-color"], context.RepoRoot, rootCredentials);
        await context.ProcessRunner.RunAsync(
            "terraform",
            [
                "-chdir=" + bootstrapDir,
                "apply",
                "-input=false",
                "-auto-approve",
                "-no-color",
                "-var", $"aws_region={context.Environment.GetOrDefaultAny(["AWS_VALIDATION_REGION", "HONUA_AWS_VALIDATION_REGION"], "us-east-1")}",
                "-var", "create_access_key=true",
                "-var", $"user_name={bootstrapModule.ExpandUserName(context)}",
            ],
            context.RepoRoot,
            rootCredentials);

        var credentials = new AwsBootstrapCredentials(
            AccessKeyId: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "access_key_id"], context.RepoRoot, rootCredentials, redactOutput: true),
            SecretAccessKey: await context.ProcessRunner.CaptureAsync("terraform", ["-chdir=" + bootstrapDir, "output", "-raw", "secret_access_key"], context.RepoRoot, rootCredentials, redactOutput: true));

        return new BootstrapLease<AwsBootstrapCredentials>(bootstrapDir, "eks", credentials);
    }

    private static async Task RunAzureValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        ScenarioManifest manifest,
        AzureStack stack,
        AzureBootstrapCredentials credentials,
        IReadOnlyDictionary<string, string?> rootCredentials,
        string planRoot)
    {
        _ = manifest;
        await ExecuteNativeAzureValidationAsync(command, context, stack, credentials, rootCredentials, planRoot);
    }

    private static async Task RunAwsValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        ScenarioManifest manifest,
        AwsStack stack,
        AwsBootstrapCredentials credentials,
        string planRoot)
    {
        _ = manifest;
        await RunNativeAwsValidationAsync(command, context, stack, credentials, planRoot);
    }

    private static async Task RunAksValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        ScenarioManifest manifest,
        AzureBootstrapCredentials credentials,
        IReadOnlyDictionary<string, string?> rootCredentials,
        string planDir)
    {
        await RunNativeAksValidationAsync(command, context, manifest, credentials, rootCredentials, planDir);
    }

    private static async Task RunEksValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        ScenarioManifest manifest,
        AwsBootstrapCredentials credentials,
        string planDir)
    {
        await RunNativeEksValidationAsync(command, context, manifest, credentials, planDir);
    }

    private static async Task DestroyAzureBootstrapAsync(
        RunnerContext context,
        BootstrapLease<AzureBootstrapCredentials> lease,
        IReadOnlyDictionary<string, string?> rootCredentials)
    {
        if (!context.DryRun && !File.Exists(Path.Combine(lease.Directory, "terraform.tfstate")))
        {
            return;
        }

        Console.WriteLine($"[runner] Destroying Azure bootstrap identity for '{lease.Name}'");
        await context.ProcessRunner.RunAsync(
            "terraform",
            ["-chdir=" + lease.Directory, "destroy", "-input=false", "-auto-approve", "-no-color"],
            context.RepoRoot,
            rootCredentials);
    }

    private static async Task DestroyAwsBootstrapAsync(
        RunnerContext context,
        BootstrapLease<AwsBootstrapCredentials> lease,
        IReadOnlyDictionary<string, string?> rootCredentials)
    {
        if (!context.DryRun && !File.Exists(Path.Combine(lease.Directory, "terraform.tfstate")))
        {
            return;
        }

        Console.WriteLine($"[runner] Destroying AWS bootstrap identity for '{lease.Name}'");
        await context.ProcessRunner.RunAsync(
            "terraform",
            ["-chdir=" + lease.Directory, "destroy", "-input=false", "-auto-approve", "-no-color"],
            context.RepoRoot,
            rootCredentials);
    }

    private static void ValidateAzureImages(EnvironmentReader env, AzureStackSelection stackSelection, bool runUpgradeRollback)
    {
        if (stackSelection is AzureStackSelection.Aca or AzureStackSelection.Both)
        {
            env.GetRequired("HONUA_ACA_IMAGE");
            if (runUpgradeRollback)
            {
                env.GetRequired("HONUA_ACA_PREVIOUS_IMAGE");
            }
        }

        if (stackSelection is AzureStackSelection.Functions or AzureStackSelection.Both)
        {
            env.GetRequired("HONUA_FUNCTIONS_IMAGE");
            if (runUpgradeRollback)
            {
                env.GetRequired("HONUA_FUNCTIONS_PREVIOUS_IMAGE");
            }
        }
    }

    private static void ValidateAwsImages(EnvironmentReader env, AwsStackSelection stackSelection, bool runUpgradeRollback)
    {
        if (stackSelection is AwsStackSelection.Ecs or AwsStackSelection.Both)
        {
            env.GetRequired("HONUA_AWS_ECS_IMAGE");
            if (runUpgradeRollback)
            {
                env.GetRequired("HONUA_AWS_ECS_PREVIOUS_IMAGE");
            }
        }

        if (stackSelection is AwsStackSelection.Serverless or AwsStackSelection.Both)
        {
            env.GetRequired("HONUA_AWS_SERVERLESS_IMAGE");
            if (runUpgradeRollback)
            {
                env.GetRequired("HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE");
            }
        }
    }

    private static async Task RunTflintAsync(RunnerContext context, ScenarioManifest manifest, string rootPath, bool strictMode)
    {
        if (!CommandExists("tflint"))
        {
            Console.WriteLine("[runner] tflint is not installed; skipping tflint checks");
            return;
        }

        foreach (var configuredRoot in manifest.TflintRoots ?? [])
        {
            var resolvedRoot = ResolvePathUnderRoot(rootPath, configuredRoot);
            if (!Directory.Exists(resolvedRoot))
            {
                continue;
            }

            Console.WriteLine($"[runner] tflint: {resolvedRoot}");
            await RunPolicyCommandAsync(
                $"tflint ({resolvedRoot})",
                strictMode,
                async () =>
                {
                    await context.ProcessRunner.RunAsync("tflint", ["--init"], resolvedRoot);
                    await context.ProcessRunner.RunAsync("tflint", Array.Empty<string>(), resolvedRoot);
                });
        }
    }

    private static async Task RunCheckovAsync(RunnerContext context, ScenarioManifest manifest, string rootPath, bool strictMode)
    {
        var checkovAvailable = CommandExists("checkov");
        var dockerAvailable = CommandExists("docker");
        if (!checkovAvailable && !dockerAvailable)
        {
            Console.WriteLine("[runner] checkov unavailable (no binary, no docker); skipping");
            return;
        }

        var checkovImage = GetScenarioSetting(context.Environment, manifest, "HONUA_CHECKOV_IMAGE", "bridgecrew/checkov:3.2.497");
        var checkovSkipChecks = GetScenarioSetting(context.Environment, manifest, "HONUA_CHECKOV_SKIP_CHECKS", "CKV_TF_1,CKV_AWS_149,CKV_AWS_191");

        foreach (var configuredTarget in manifest.CheckovTargets ?? [])
        {
            var resolvedTarget = ResolvePathUnderRoot(rootPath, configuredTarget);
            if (!Directory.Exists(resolvedTarget))
            {
                continue;
            }

            var label = $"checkov {configuredTarget}";
            if (checkovAvailable)
            {
                var arguments = BuildCheckovArguments(resolvedTarget, checkovSkipChecks, strictMode);
                await RunPolicyCommandAsync(
                    label,
                    strictMode,
                    () => context.ProcessRunner.RunAsync("checkov", arguments, context.RepoRoot));
                continue;
            }

            var dockerArguments = new List<string>
            {
                "run",
                "--rm",
                "-v", $"{context.RepoRoot}:/workspace",
                "-w", "/workspace",
                checkovImage,
            };
            dockerArguments.AddRange(BuildCheckovArguments(GetContainerPath(context, resolvedTarget, "/workspace"), checkovSkipChecks, strictMode));

            await RunPolicyCommandAsync(
                $"{label} (docker)",
                strictMode,
                () => context.ProcessRunner.RunAsync("docker", dockerArguments, context.RepoRoot));
        }
    }

    private static async Task RunTfsecAsync(RunnerContext context, ScenarioManifest manifest, string rootPath, bool strictMode)
    {
        var tfsecEnabled = GetScenarioBoolean(context.Environment, manifest, "HONUA_TERRAFORM_ENABLE_TFSEC", defaultValue: false);
        if (!tfsecEnabled)
        {
            Console.WriteLine("[runner] tfsec is disabled by default because it cannot parse Terraform check blocks in this repository; enable with HONUA_TERRAFORM_ENABLE_TFSEC=true");
            return;
        }

        var tfsecAvailable = CommandExists("tfsec");
        var dockerAvailable = CommandExists("docker");
        if (!tfsecAvailable && !dockerAvailable)
        {
            Console.WriteLine("[runner] tfsec unavailable (no binary, no docker); skipping");
            return;
        }

        var tfsecImage = GetScenarioSetting(context.Environment, manifest, "HONUA_TFSEC_IMAGE", "aquasec/tfsec:v1.28");

        foreach (var configuredTarget in manifest.TfsecTargets ?? [])
        {
            var resolvedTarget = ResolvePathUnderRoot(rootPath, configuredTarget);
            if (!Directory.Exists(resolvedTarget))
            {
                continue;
            }

            var label = $"tfsec {configuredTarget}";
            if (tfsecAvailable)
            {
                var arguments = BuildTfsecArguments(resolvedTarget, strictMode);
                await RunPolicyCommandAsync(
                    label,
                    strictMode,
                    () => context.ProcessRunner.RunAsync("tfsec", arguments, context.RepoRoot));
                continue;
            }

            var dockerArguments = new List<string>
            {
                "run",
                "--rm",
                "-v", $"{context.RepoRoot}:/src",
                tfsecImage,
            };
            dockerArguments.AddRange(BuildTfsecArguments(GetContainerPath(context, resolvedTarget, "/src"), strictMode));

            await RunPolicyCommandAsync(
                $"{label} (docker)",
                strictMode,
                () => context.ProcessRunner.RunAsync("docker", dockerArguments, context.RepoRoot));
        }
    }

    private static void RunCustomPolicyChecks(string rootPath)
    {
        Console.WriteLine("[runner] Running custom policy checks");

        AssertRegexAbsent(@"actions\s*=\s*\[\s*""\*""\s*\]", rootPath, "least-privilege-actions");
        AssertRegexAbsent(@"Action""\s*:\s*""\*""", rootPath, "least-privilege-actions-json");

        foreach (var relativePath in new[]
                 {
                     "modules/aws-ecs/variables.tf",
                     "modules/aws-serverless/variables.tf",
                     "modules/aws-eks/variables.tf",
                     "modules/azure-aca/variables.tf",
                     "modules/azure-data/variables.tf",
                     "modules/azure-functions/variables.tf",
                     "modules/azure-aks/variables.tf",
                     "examples/aws/variables.tf",
                     "examples/aws-serverless/variables.tf",
                     "examples/aws-eks/variables.tf",
                     "examples/azure/variables.tf",
                     "examples/azure-data/variables.tf",
                     "examples/azure-functions/variables.tf",
                     "examples/azure-aks/variables.tf",
                 })
        {
            var filePath = ResolvePathUnderRoot(rootPath, relativePath);
            if (File.Exists(filePath))
            {
                AssertRegexPresent(@"variable ""tags""", filePath, "mandatory-tags-variable");
            }
        }

        AssertRegexPresent(@"storage_encrypted\s*=\s*true", ResolvePathUnderRoot(rootPath, "modules/aws-ecs/main.tf"), "aws-ecs-rds-encryption");
        AssertRegexPresent(@"storage_encrypted\s*=\s*true", ResolvePathUnderRoot(rootPath, "modules/aws-serverless/main.tf"), "aws-serverless-rds-encryption");
        AssertRegexPresent(@"transit_encryption_enabled\s*=\s*true", ResolvePathUnderRoot(rootPath, "modules/aws-ecs/main.tf"), "aws-ecs-redis-transit-encryption");
        AssertRegexPresent(@"transit_encryption_enabled\s*=\s*true", ResolvePathUnderRoot(rootPath, "modules/aws-serverless/main.tf"), "aws-serverless-redis-transit-encryption");
        AssertRegexPresent(@"minimum_tls_version\s*=\s*""1\.2""", ResolvePathUnderRoot(rootPath, "modules/azure-aca/main.tf"), "azure-aca-redis-tls12");
        AssertRegexPresent(@"minimum_tls_version\s*=\s*""1\.2""", ResolvePathUnderRoot(rootPath, "modules/azure-data/main.tf"), "azure-data-redis-tls12");
        AssertRegexPresent(@"minimum_tls_version\s*=\s*""1\.2""", ResolvePathUnderRoot(rootPath, "modules/azure-functions/main.tf"), "azure-functions-redis-tls12");

        AssertRegexAbsent(@"^\s*source\s+""\$DATA_CACHE_FILE""", ResolvePathUnderRoot(rootPath, "validation/scripts/aws/run-aws-terraform-integration.sh"), "aws-cache-source-execution");
        AssertRegexAbsent(@"^\s*source\s+""\$DATA_CACHE_FILE""", ResolvePathUnderRoot(rootPath, "validation/scripts/azure/run-azure-terraform-integration.sh"), "azure-cache-source-execution");
        AssertRegexPresent(@"DATA_CACHE_FORMAT=""v2-base64""", ResolvePathUnderRoot(rootPath, "validation/scripts/aws/run-aws-terraform-integration.sh"), "aws-cache-format-marker");
        AssertRegexPresent(@"DATA_CACHE_FORMAT=""v2-base64""", ResolvePathUnderRoot(rootPath, "validation/scripts/azure/run-azure-terraform-integration.sh"), "azure-cache-format-marker");

        AssertRegexAbsent(@"ConnectionStrings__redis\s*=\s*local\.redis_connection", ResolvePathUnderRoot(rootPath, "modules/aws-serverless/main.tf"), "aws-serverless-redis-plaintext-env");
        AssertRegexPresent(@"HONUA_SECRET_REDIS_CONNECTION_ARN", ResolvePathUnderRoot(rootPath, "modules/aws-serverless/main.tf"), "aws-serverless-redis-secret-env");

        AssertRegexAbsent(@"ConnectionStrings__redis\s*=\s*local\.redis_connection", ResolvePathUnderRoot(rootPath, "modules/azure-functions/main.tf"), "azure-functions-redis-plaintext-env");
        AssertRegexPresent(@"azurerm_key_vault_secret"" ""redis_connection""", ResolvePathUnderRoot(rootPath, "modules/azure-functions/main.tf"), "azure-functions-redis-secret-resource");
        AssertRegexPresent(@"ConnectionStrings__redis\s*=\s*""@Microsoft\.KeyVault\(SecretUri=\$\{azurerm_key_vault_secret\.redis_connection\[0\]\.versionless_id\}\)""", ResolvePathUnderRoot(rootPath, "modules/azure-functions/main.tf"), "azure-functions-redis-keyvault-reference");

        AssertRegexAbsent(@"kubernetes\s*=\s*\{", ResolvePathUnderRoot(rootPath, "examples/observability/main.tf"), "helm-provider-kubernetes-attribute");
        AssertRegexPresent(@"^\s*kubernetes\s*\{", ResolvePathUnderRoot(rootPath, "examples/observability/main.tf"), "helm-provider-kubernetes-block");
    }

    private static void AssertRegexAbsent(string pattern, string scopePath, string label)
    {
        var regex = new Regex(pattern, RegexOptions.Multiline | RegexOptions.CultureInvariant);
        foreach (var filePath in EnumeratePolicyFiles(scopePath))
        {
            if (regex.IsMatch(File.ReadAllText(filePath)))
            {
                throw new ValidationException($"Policy check failed ({label}): disallowed pattern found in {filePath}");
            }
        }
    }

    private static void AssertRegexPresent(string pattern, string filePath, string label)
    {
        if (!File.Exists(filePath))
        {
            throw new ValidationException($"Policy check failed ({label}): file not found: {filePath}");
        }

        var regex = new Regex(pattern, RegexOptions.Multiline | RegexOptions.CultureInvariant);
        if (!regex.IsMatch(File.ReadAllText(filePath)))
        {
            throw new ValidationException($"Policy check failed ({label}): expected pattern not found in {filePath}");
        }
    }

    private static IEnumerable<string> EnumeratePolicyFiles(string scopePath)
    {
        if (File.Exists(scopePath))
        {
            yield return scopePath;
            yield break;
        }

        if (!Directory.Exists(scopePath))
        {
            yield break;
        }

        var pending = new Stack<string>();
        pending.Push(scopePath);

        while (pending.Count > 0)
        {
            var current = pending.Pop();

            foreach (var subdirectory in Directory.EnumerateDirectories(current))
            {
                var name = Path.GetFileName(subdirectory);
                if (name is ".terraform" or "bin" or "obj")
                {
                    continue;
                }

                pending.Push(subdirectory);
            }

            foreach (var filePath in Directory.EnumerateFiles(current))
            {
                yield return filePath;
            }
        }
    }

    private static async Task RunPolicyCommandAsync(string label, bool strictMode, Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (CommandExecutionException exception)
        {
            if (strictMode)
            {
                throw new ValidationException($"{label} failed with exit code {exception.ExitCode}");
            }

            Console.WriteLine($"[runner] {label} failed with exit code {exception.ExitCode}; continuing because strict mode is disabled");
        }
    }

    private static List<string> BuildCheckovArguments(string targetPath, string skipChecks, bool strictMode)
    {
        var arguments = new List<string>
        {
            "-d", targetPath,
            "--download-external-modules", "false",
            "--compact",
        };

        if (!string.IsNullOrWhiteSpace(skipChecks))
        {
            arguments.Add("--skip-check");
            arguments.Add(skipChecks);
        }

        if (!strictMode)
        {
            arguments.Add("--soft-fail");
        }

        return arguments;
    }

    private static List<string> BuildTfsecArguments(string targetPath, bool strictMode)
    {
        var arguments = new List<string>();
        if (!strictMode)
        {
            arguments.Add("--soft-fail");
        }

        arguments.Add(targetPath);
        return arguments;
    }

    private static async Task RunDriftCheckForRootAsync(
        RunnerContext context,
        string rootPath,
        IReadOnlyList<string> varFiles,
        string planArtifactDir,
        bool backendEnabled)
    {
        if (!Directory.Exists(rootPath))
        {
            throw new ValidationException($"Terraform root does not exist: {rootPath}");
        }

        var logFile = Path.Combine(planArtifactDir, $"{SanitizeArtifactName(rootPath)}.drift-plan.txt");
        Directory.CreateDirectory(planArtifactDir);

        var initArguments = new List<string>
        {
            $"-chdir={rootPath}",
            "init",
            "-input=false",
            "-no-color",
        };
        if (!backendEnabled)
        {
            initArguments.Add("-backend=false");
        }

        Console.WriteLine($"[runner] terraform init ({rootPath})");
        await context.ProcessRunner.RunAsync("terraform", initArguments, context.RepoRoot);

        var planArguments = new List<string>
        {
            $"-chdir={rootPath}",
            "plan",
            "-input=false",
            "-no-color",
            "-detailed-exitcode",
        };
        foreach (var varFile in varFiles)
        {
            planArguments.Add($"-var-file={varFile}");
        }

        Console.WriteLine($"[runner] terraform plan -detailed-exitcode ({rootPath})");
        try
        {
            var output = await context.ProcessRunner.CaptureAsync("terraform", planArguments, context.RepoRoot);
            if (!context.DryRun)
            {
                await File.WriteAllTextAsync(logFile, output);
            }
        }
        catch (CommandExecutionException exception) when (exception.ExitCode == 2)
        {
            if (!context.DryRun)
            {
                await File.WriteAllTextAsync(logFile, exception.Output ?? string.Empty);
            }

            throw new ValidationException($"Drift detected for {rootPath}. See {logFile}");
        }
        catch (CommandExecutionException exception)
        {
            if (!context.DryRun)
            {
                await File.WriteAllTextAsync(logFile, exception.Output ?? string.Empty);
            }

            throw new ValidationException($"Drift check errored for {rootPath}. See {logFile}");
        }
    }

    private static string SanitizeArtifactName(string value)
    {
        return value
            .Replace(Path.DirectorySeparatorChar, '_')
            .Replace(Path.AltDirectorySeparatorChar, '_')
            .Replace(':', '_');
    }

    private static string ResolvePathUnderRoot(string rootPath, string path)
    {
        return Path.IsPathRooted(path) ? path : Path.GetFullPath(Path.Combine(rootPath, path));
    }

    private static string GetScenarioSetting(EnvironmentReader environment, ScenarioManifest manifest, string name, string defaultValue)
    {
        var configuredValue = environment.GetOptional(name);
        if (!string.IsNullOrWhiteSpace(configuredValue))
        {
            return configuredValue;
        }

        if (manifest.Defaults is not null &&
            manifest.Defaults.TryGetValue(name, out var manifestValue) &&
            !string.IsNullOrWhiteSpace(manifestValue))
        {
            return manifestValue;
        }

        return defaultValue;
    }

    private static bool GetScenarioBoolean(EnvironmentReader environment, ScenarioManifest manifest, string name, bool defaultValue)
    {
        var configuredValue = environment.GetOptional(name);
        if (!string.IsNullOrWhiteSpace(configuredValue))
        {
            return ParsedCommand.ParseBoolean(configuredValue, name);
        }

        if (manifest.Defaults is not null &&
            manifest.Defaults.TryGetValue(name, out var manifestValue) &&
            !string.IsNullOrWhiteSpace(manifestValue))
        {
            return ParsedCommand.ParseBoolean(manifestValue, name);
        }

        return defaultValue;
    }

    private static bool CommandExists(string commandName)
    {
        var pathValue = System.Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(pathValue))
        {
            return false;
        }

        var executableExtensions = OperatingSystem.IsWindows()
            ? (System.Environment.GetEnvironmentVariable("PATHEXT") ?? ".EXE;.BAT;.CMD")
                .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            : [string.Empty];

        foreach (var directory in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            foreach (var extension in executableExtensions)
            {
                var candidate = Path.Combine(directory, commandName + extension);
                if (File.Exists(candidate))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static string GetContainerPath(RunnerContext context, string hostPath, string containerRoot)
    {
        var relativePath = Path.GetRelativePath(context.RepoRoot, hostPath);
        if (relativePath.StartsWith("..", StringComparison.Ordinal))
        {
            throw new ValidationException($"Path is outside the repository root and cannot be mounted into the container: {hostPath}");
        }

        return $"{containerRoot}/{relativePath.Replace('\\', '/')}";
    }

    private static void RequireDirectory(string path, string label)
    {
        if (!Directory.Exists(path))
        {
            throw new ValidationException($"Directory not found for {label}: {path}");
        }
    }

    private static IReadOnlyList<string> BuildDefaultDriftRoots(ScenarioManifest manifest, CloudTarget cloud, bool runAks, bool runEks)
    {
        var defaults = manifest.DriftDefaults ?? throw new ValidationException($"Scenario manifest '{manifest.Name}' is missing driftDefaults.");
        var roots = new List<string>();

        if (cloud is CloudTarget.Both or CloudTarget.Azure)
        {
            roots.AddRange(defaults.AzureBaseRoots);
            if (runAks && !string.IsNullOrWhiteSpace(defaults.AzureManagedRoot))
            {
                roots.Add(defaults.AzureManagedRoot);
            }
        }

        if (cloud is CloudTarget.Both or CloudTarget.Aws)
        {
            roots.AddRange(defaults.AwsBaseRoots);
            if (runEks && !string.IsNullOrWhiteSpace(defaults.AwsManagedRoot))
            {
                roots.Add(defaults.AwsManagedRoot);
            }
        }

        roots.AddRange(defaults.AlwaysRoots);
        return roots;
    }

    private static async Task<List<Exception>> CleanupAsync<TLease>(
        IReadOnlyList<TLease> leases,
        Func<TLease, Task> cleanup)
    {
        var failures = new List<Exception>();
        for (var index = leases.Count - 1; index >= 0; index--)
        {
            try
            {
                await cleanup(leases[index]);
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }
        }

        return failures;
    }

    private static void RethrowIfNeeded(Exception? bodyFailure, IReadOnlyList<Exception> cleanupFailures)
    {
        if (bodyFailure is null && cleanupFailures.Count == 0)
        {
            return;
        }

        if (bodyFailure is not null && cleanupFailures.Count == 0)
        {
            throw bodyFailure;
        }

        if (bodyFailure is null && cleanupFailures.Count == 1)
        {
            throw cleanupFailures[0];
        }

        var failures = new List<Exception>();
        if (bodyFailure is not null)
        {
            failures.Add(bodyFailure);
        }

        failures.AddRange(cleanupFailures);
        throw new AggregateException(failures);
    }

    private static string ResolveRepoRelativePath(RunnerContext context, string path)
    {
        return Path.IsPathRooted(path) ? path : context.ResolveRepoRelativePath(path);
    }

    private static BootstrapModuleManifest GetRequiredBootstrapModule(ScenarioManifest manifest, string key)
    {
        if (manifest.BootstrapModules is null || !manifest.BootstrapModules.TryGetValue(key, out var bootstrapModule))
        {
            throw new ValidationException($"Scenario manifest '{manifest.Name}' is missing bootstrap module '{key}'.");
        }

        return bootstrapModule;
    }

    private static string RequiredManifestValue(string? value, ScenarioManifest manifest, string propertyName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ValidationException($"Scenario manifest '{manifest.Name}' is missing {propertyName}.");
        }

        return value;
    }

    private static void AppendOption(List<string> arguments, string optionName, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        arguments.Add(optionName);
        arguments.Add(value);
    }

    private static void AppendFlag(List<string> arguments, string optionName, bool enabled)
    {
        if (enabled)
        {
            arguments.Add(optionName);
        }
    }

    private static void AddConfigEnvironmentVariables(EnvironmentReader environment, IDictionary<string, string?> target, IEnumerable<string> names)
    {
        foreach (var name in names)
        {
            var value = environment.GetOptional(name);
            if (!string.IsNullOrWhiteSpace(value))
            {
                target[name] = value;
            }
        }
    }

    private static void SetDefaultEnvironmentVariable(IDictionary<string, string?> target, string name, string? value)
    {
        if (target.ContainsKey(name) || string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        target[name] = value;
    }

    private static string GetWorkflowCachePath(RunnerContext context, string fileName)
    {
        var cacheDirectory = context.ResolveRepoPath(".gha-cache");
        Directory.CreateDirectory(cacheDirectory);
        return Path.Combine(cacheDirectory, fileName);
    }

    private static string? TryGetDefaultPlatformValidationScript(RunnerContext context)
    {
        var scriptPath = context.ResolveRepoPath("honua-server", "scripts", "run-cloud-post-apply-validation.sh");
        return File.Exists(scriptPath) ? scriptPath : null;
    }

    private static string? BuildImportTablePrefix(RunnerContext context, ParsedCommand command)
    {
        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        if (deploymentProfile != DeploymentProfile.Ephemeral || command.GetBoolean("no-destroy", defaultValue: false))
        {
            return null;
        }

        return $"cloud{context.GitHubRunId}{context.GitHubRunAttempt}";
    }

    private static void EnsurePersistentApproval(DeploymentProfile deploymentProfile, string applyConfirmation)
    {
        if (deploymentProfile == DeploymentProfile.Persistent &&
            !string.Equals(applyConfirmation, "APPROVED", StringComparison.Ordinal))
        {
            throw new ValidationException("Persistent profile requires --apply-confirmation APPROVED");
        }
    }

    private static DeploymentProfile ParseDeploymentProfile(string value)
    {
        return value switch
        {
            "ephemeral" => DeploymentProfile.Ephemeral,
            "persistent" => DeploymentProfile.Persistent,
            _ => throw new ValidationException($"Unsupported deployment profile: {value}"),
        };
    }

    private static AzureStackSelection ParseAzureStack(string value)
    {
        return value switch
        {
            "aca" => AzureStackSelection.Aca,
            "functions" => AzureStackSelection.Functions,
            "both" => AzureStackSelection.Both,
            _ => throw new ValidationException($"Unsupported AZURE_VALIDATION_STACK: {value}"),
        };
    }

    private static AwsStackSelection ParseAwsStack(string value)
    {
        return value switch
        {
            "ecs" => AwsStackSelection.Ecs,
            "serverless" => AwsStackSelection.Serverless,
            "both" => AwsStackSelection.Both,
            _ => throw new ValidationException($"Unsupported AWS_VALIDATION_STACK: {value}"),
        };
    }

    private static CloudTarget ParseCloud(string value)
    {
        return value switch
        {
            "both" => CloudTarget.Both,
            "azure" => CloudTarget.Azure,
            "aws" => CloudTarget.Aws,
            _ => throw new ValidationException($"Unsupported cloud selection: {value}"),
        };
    }

    private static IReadOnlyList<AzureStack> Expand(AzureStackSelection selection)
    {
        return selection switch
        {
            AzureStackSelection.Aca => [AzureStack.Aca],
            AzureStackSelection.Functions => [AzureStack.Functions],
            AzureStackSelection.Both => [AzureStack.Aca, AzureStack.Functions],
            _ => throw new ValidationException($"Unsupported Azure validation stack: {selection}"),
        };
    }

    private static IReadOnlyList<AwsStack> Expand(AwsStackSelection selection)
    {
        return selection switch
        {
            AwsStackSelection.Ecs => [AwsStack.Ecs],
            AwsStackSelection.Serverless => [AwsStack.Serverless],
            AwsStackSelection.Both => [AwsStack.Ecs, AwsStack.Serverless],
            _ => throw new ValidationException($"Unsupported AWS validation stack: {selection}"),
        };
    }

    private static void CopyTerraformFiles(string sourceDirectory, string targetDirectory)
    {
        if (!Directory.Exists(sourceDirectory))
        {
            throw new ValidationException($"Terraform bootstrap source directory does not exist: {sourceDirectory}");
        }

        var terraformFiles = Directory.GetFiles(sourceDirectory, "*.tf", SearchOption.TopDirectoryOnly);
        if (terraformFiles.Length == 0)
        {
            throw new ValidationException($"No Terraform files found in bootstrap source directory: {sourceDirectory}");
        }

        foreach (var file in terraformFiles)
        {
            var destination = Path.Combine(targetDirectory, Path.GetFileName(file));
            File.Copy(file, destination, overwrite: true);
        }
    }
}

internal enum DeploymentProfile
{
    Ephemeral,
    Persistent,
}

internal enum AzureStackSelection
{
    Aca,
    Functions,
    Both,
}

internal enum AzureStack
{
    Aca,
    Functions,
}

internal enum AwsStackSelection
{
    Ecs,
    Serverless,
    Both,
}

internal enum AwsStack
{
    Ecs,
    Serverless,
}

internal enum CloudTarget
{
    Both,
    Azure,
    Aws,
}

internal sealed record BootstrapLease<TCredentials>(string Directory, string Name, TCredentials Credentials);

internal sealed record AzureBootstrapCredentials(string ClientId, string ClientSecret, string TenantId, string SubscriptionId);

internal sealed record AwsBootstrapCredentials(string AccessKeyId, string SecretAccessKey);
