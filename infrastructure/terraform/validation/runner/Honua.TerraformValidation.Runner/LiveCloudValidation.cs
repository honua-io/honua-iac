using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private const string AzureDataCacheFormat = "v2-base64";
    private const string AwsDataCacheFormat = "v2-base64";
    private const string DefaultFunctionsAotImage = "ghcr.io/honua-io/honua-server:latest-aot";

    private static async Task ExecuteNativeAzureValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        AzureStack stack,
        AzureBootstrapCredentials credentials,
        IReadOnlyDictionary<string, string?> rootCredentialsEnvironment,
        string defaultPlanDir)
    {
        var settings = BuildAzureLiveSettings(command, context, stack, defaultPlanDir);
        var workspace = PrepareTerraformWorkspace(context, $"azure-{stack.ToString().ToLowerInvariant()}");
        var credentialsEnvironment = new Dictionary<string, string?>(StringComparer.Ordinal)
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
        AddConfigEnvironmentVariables(context.Environment, validationEnvironment, AzureAdapterEnvironmentVariables);
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_SCRIPT", TryGetDefaultPlatformValidationScript(context));
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX", BuildImportTablePrefix(context, command));

        var state = new AzureLiveState();
        Exception? bodyFailure = null;
        var cleanupFailures = new List<Exception>();

        try
        {
            RequireCommand("terraform");
            RequireCommand("az");
            ValidateCloudAdminPassword(settings.AdminPassword);

            await EnsureAzSessionAsync(context, credentialsEnvironment, credentials.SubscriptionId);
            await ResolveAzureRegistryCredentialsAsync(context, settings, credentialsEnvironment);
            AssertAzureCostGuardrail(settings);
            if (!settings.SkipQuotaPreflight)
            {
                await RunAzureQuotaPreflightAsync(context, credentialsEnvironment, settings);
            }

            await PrepareAzureInputsAsync(context, settings, state);
            if (state.HasReusableDataInputs)
            {
                await ValidateAzureReusableDataInputsAsync(context, settings, state, credentialsEnvironment);
            }

            if (state.HasReusableDataInputs)
            {
                await EnsureExistingAzureDbFirewallAccessAsync(context, settings, state, credentialsEnvironment);
            }
            else
            {
                await ApplyAzureDataStackAsync(context, settings, state, validationEnvironment, workspace);
            }

            if (stack == AzureStack.Aca)
            {
                await ApplyAzureAcaStackAsync(command, context, settings, state, validationEnvironment, workspace, credentialsEnvironment);
            }
            else
            {
                await ApplyAzureFunctionsStackAsync(context, settings, state, validationEnvironment, workspace);
            }
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        try
        {
            await ClearAzureFirewallRulesAsync(context, state, credentialsEnvironment);
        }
        catch (Exception exception)
        {
            cleanupFailures.Add(exception);
        }

        if (settings.AutoDestroy)
        {
            try
            {
                await DestroyAzureStacksAsync(context, settings, state, validationEnvironment, workspace);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }

            try
            {
                await VerifyNoAzureLeaksAsync(context, settings.ValidationRunId, rootCredentialsEnvironment);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }
        }
        else
        {
            Console.WriteLine($"[runner] Auto-destroy disabled; retained Azure validation workspace at {workspace.Root}");
        }

        TryDeleteWorkspace(workspace.Root, cleanupFailures);
        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static async Task ExecuteNativeAwsValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        AwsStack stack,
        AwsBootstrapCredentials credentials,
        string defaultPlanDir)
    {
        var settings = BuildAwsLiveSettings(command, context, stack, defaultPlanDir);
        var workspace = PrepareTerraformWorkspace(context, $"aws-{stack.ToString().ToLowerInvariant()}");
        var credentialsEnvironment = new Dictionary<string, string?>(StringComparer.Ordinal)
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
        AddConfigEnvironmentVariables(context.Environment, validationEnvironment, AwsAdapterEnvironmentVariables);
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_SCRIPT", TryGetDefaultPlatformValidationScript(context));
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX", BuildImportTablePrefix(context, command));

        var state = new AwsLiveState();
        Exception? bodyFailure = null;
        var cleanupFailures = new List<Exception>();

        try
        {
            RequireCommand("terraform");
            RequireCommand("aws");
            ValidateCloudAdminPassword(settings.AdminPassword);

            await EnsureAwsSessionAsync(context, credentialsEnvironment);
            AssertAwsCostGuardrail(settings);
            if (!settings.SkipQuotaPreflight)
            {
                await RunAwsQuotaPreflightAsync(context, credentialsEnvironment, settings);
            }

            await PrepareAwsInputsAsync(context, settings, state);
            if (state.HasReusableDataInputs)
            {
                await EnsureExistingVpcPrivateEgressAsync(context, settings, state, credentialsEnvironment);
                await AuthorizeExistingAwsDbIngressAsync(context, settings, state, credentialsEnvironment);
            }
            else
            {
                await ApplyAwsDataStackAsync(context, settings, state, validationEnvironment, workspace, credentialsEnvironment);
            }

            if (stack == AwsStack.Ecs)
            {
                await ApplyAwsEcsStackAsync(context, settings, state, validationEnvironment, workspace, credentialsEnvironment);
            }
            else
            {
                await ApplyAwsServerlessStackAsync(context, settings, state, validationEnvironment, workspace);
            }
        }
        catch (Exception exception)
        {
            bodyFailure = exception;
        }

        try
        {
            await RevokeExistingAwsDbIngressAsync(context, settings, state, credentialsEnvironment);
        }
        catch (Exception exception)
        {
            cleanupFailures.Add(exception);
        }

        if (settings.AutoDestroy)
        {
            try
            {
                await DestroyAwsStacksAsync(context, settings, state, validationEnvironment, workspace);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }

            try
            {
                await VerifyNoAwsLeaksAsync(context, settings.ValidationRunId, credentialsEnvironment);
            }
            catch (Exception exception)
            {
                cleanupFailures.Add(exception);
            }
        }
        else
        {
            Console.WriteLine($"[runner] Auto-destroy disabled; retained AWS validation workspace at {workspace.Root}");
        }

        TryDeleteWorkspace(workspace.Root, cleanupFailures);
        RethrowIfNeeded(bodyFailure, cleanupFailures);
    }

    private static void TryDeleteWorkspace(string workspaceRoot, ICollection<Exception> cleanupFailures)
    {
        try
        {
            if (Directory.Exists(workspaceRoot))
            {
                Directory.Delete(workspaceRoot, recursive: true);
            }
        }
        catch (Exception exception)
        {
            cleanupFailures.Add(exception);
        }
    }

    private static void ValidateCloudAdminPassword(string adminPassword)
    {
        if (adminPassword.Length < 32)
        {
            throw new ValidationException("HONUA_ADMIN_PASSWORD must be at least 32 characters.");
        }
    }

    private static async Task<string> CaptureTerraformOutputsJsonAsync(
        RunnerContext context,
        string terraformRoot,
        IReadOnlyDictionary<string, string?> environment)
    {
        return await context.ProcessRunner.CaptureAsync(
            "terraform",
            ["-chdir=" + terraformRoot, "output", "-json"],
            context.RepoRoot,
            environment,
            redactOutput: true);
    }

    private static async Task<string> CaptureOrSynthesizeTerraformOutputsAsync(
        RunnerContext context,
        string terraformRoot,
        IReadOnlyDictionary<string, string?> environment,
        string syntheticJson)
    {
        return context.DryRun ? syntheticJson : await CaptureTerraformOutputsJsonAsync(context, terraformRoot, environment);
    }

    private static string NormalizeBaseUrl(string baseUrl)
    {
        var trimmed = baseUrl.TrimEnd('/');
        return trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            ? trimmed
            : $"https://{trimmed}";
    }

    private static string BuildAzureValidationTagsJson(string validationRunId, int ttlHours)
    {
        var expiresAt = DateTime.UtcNow.AddHours(ttlHours).ToString("MM/dd/yyyy HH:mm:ss", CultureInfo.InvariantCulture);
        return $$"""{"ValidationRunId":"{{validationRunId}}","TTLHours":"{{ttlHours.ToString(CultureInfo.InvariantCulture)}}","ExpiresAtUTC":"{{expiresAt}}","Owner":"terraform-validation"}""";
    }

    private static AzureLiveSettings BuildAzureLiveSettings(ParsedCommand command, RunnerContext context, AzureStack stack, string defaultPlanDir)
    {
        var env = context.Environment;
        var rawPrefix = Regex.Replace(
            GetOptionOrEnvironment(command, env, "name-prefix-base", "HONUA_AZURE_NAME_PREFIX_BASE", $"h{DateTime.UtcNow:MMddHHmm}{Random.Shared.Next(0, 10)}").ToLowerInvariant(),
            "[^a-z0-9]",
            string.Empty);
        var normalizedPrefix = rawPrefix[..Math.Min(rawPrefix.Length, 10)];
        if (string.IsNullOrWhiteSpace(normalizedPrefix))
        {
            throw new ValidationException("Azure name prefix became empty after normalization");
        }

        var useAot = env.GetBoolean("HONUA_USE_AOT");
        var acaImage = stack is AzureStack.Aca
            ? ResolveManagedImage(env.GetRequired("HONUA_ACA_IMAGE"), useAot)
            : string.Empty;
        var functionsImage = stack is AzureStack.Functions
            ? env.GetRequired("HONUA_FUNCTIONS_IMAGE")
            : string.Empty;
        if (stack is AzureStack.Functions &&
            useAot &&
            string.Equals(functionsImage, DefaultHonuaImage, StringComparison.Ordinal))
        {
            functionsImage = DefaultFunctionsAotImage;
        }

        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        var reuseDataStack = command.GetBoolean("reuse-data-stack", false);

        return new AzureLiveSettings
        {
            Stack = stack,
            Location = env.GetOrDefaultAny(["AZURE_VALIDATION_REGION", "HONUA_AZURE_VALIDATION_REGION"], "westus"),
            Environment = NormalizeTerraformEnvironment(env.GetOrDefault("AZURE_TF_ENVIRONMENT", "it")),
            DataNamePrefix = normalizedPrefix,
            AcaNamePrefix = $"{normalizedPrefix}aca"[..Math.Min($"{normalizedPrefix}aca".Length, 20)],
            FunctionsNamePrefix = $"{normalizedPrefix}fn"[..Math.Min($"{normalizedPrefix}fn".Length, 20)],
            PlanArtifactDir = ResolveManagedPlanArtifactDir(command, Path.Combine(defaultPlanDir, stack == AzureStack.Aca ? "aca" : "functions")),
            ValidationRunId = env.GetOrDefault("HONUA_VALIDATION_RUN_ID", $"gha-{context.GitHubRunId}-azure-{stack.ToString().ToLowerInvariant()}"),
            AdminPassword = env.GetRequired("HONUA_ADMIN_PASSWORD"),
            DbAdminPassword = env.GetRequired("HONUA_DB_PASSWORD"),
            MaxRunCostUsd = decimal.Parse(env.GetOrDefault("HONUA_MAX_RUN_COST_USD", "50"), CultureInfo.InvariantCulture),
            TimeoutSeconds = int.Parse(env.GetOrDefault("HONUA_AZURE_TEST_TIMEOUT_SECONDS", "900"), CultureInfo.InvariantCulture),
            ReadySloSeconds = int.Parse(env.GetOrDefault("HONUA_READY_SLO_SECONDS", "600"), CultureInfo.InvariantCulture),
            MaxLoadErrorRatePercent = decimal.Parse(env.GetOrDefault("HONUA_MAX_LOAD_ERROR_RATE_PERCENT", "0"), CultureInfo.InvariantCulture),
            LoadRequests = int.Parse(env.GetOrDefault("HONUA_AZURE_LOAD_REQUESTS", "120"), CultureInfo.InvariantCulture),
            LoadConcurrency = int.Parse(env.GetOrDefault("HONUA_AZURE_LOAD_CONCURRENCY", "20"), CultureInfo.InvariantCulture),
            TtlHours = int.Parse(env.GetOrDefault("HONUA_TTL_HOURS", "8"), CultureInfo.InvariantCulture),
            AllowDestroyPlan = command.GetBoolean("allow-destroy-plan", false),
            AutoDestroy = !command.GetBoolean("no-destroy", false),
            DestroyData = !command.GetBoolean("no-destroy", false) && deploymentProfile == DeploymentProfile.Ephemeral && !reuseDataStack,
            SkipQuotaPreflight = env.GetBoolean("HONUA_SKIP_QUOTA_PREFLIGHT"),
            SkipIdempotency = env.GetBoolean("HONUA_SKIP_IDEMPOTENCY"),
            SkipProtocolChecks = env.GetBoolean("HONUA_SKIP_PROTOCOL_CHECKS"),
            SkipScaleCheck = env.GetBoolean("HONUA_SKIP_SCALE_CHECK"),
            RunUpgradeRollback = env.GetBoolean("HONUA_RUN_UPGRADE_ROLLBACK"),
            AcaImage = acaImage,
            AcaPreviousImage = stack is AzureStack.Aca ? env.GetOptional("HONUA_ACA_PREVIOUS_IMAGE") : null,
            FunctionsImage = functionsImage,
            FunctionsPreviousImage = stack is AzureStack.Functions ? env.GetOptional("HONUA_FUNCTIONS_PREVIOUS_IMAGE") : null,
            FunctionsPlanSku = env.GetOrDefault("HONUA_FUNCTIONS_PLAN_SKU", "EP1"),
            FunctionsSkipMigrations = env.GetBoolean("HONUA_AZURE_FUNCTIONS_SKIP_MIGRATIONS"),
            FunctionsDeploymentSlotEnabled = env.GetBoolean("HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_ENABLED"),
            FunctionsDeploymentSlotName = env.GetOrDefault("HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_NAME", "staging"),
            FunctionsDeploymentSlotImage = stack is AzureStack.Functions ? env.GetOptional("HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_IMAGE") : null,
            AcaMinReplicas = int.Parse(env.GetOrDefault("HONUA_AZURE_ACA_MIN_REPLICAS", "1"), CultureInfo.InvariantCulture),
            AcaMaxReplicas = int.Parse(env.GetOrDefault("HONUA_AZURE_ACA_MAX_REPLICAS", "3"), CultureInfo.InvariantCulture),
            AcaScaleTargetMinReplicas = int.Parse(env.GetOrDefault("HONUA_AZURE_ACA_SCALE_TARGET_MIN_REPLICAS", "2"), CultureInfo.InvariantCulture),
            RegistryResourceId = env.GetOptional("HONUA_AZURE_REGISTRY_RESOURCE_ID"),
            RegistryServer = env.GetOptional("HONUA_AZURE_REGISTRY_SERVER"),
            RegistryUsername = env.GetOptional("HONUA_AZURE_REGISTRY_USERNAME"),
            RegistryPassword = env.GetOptional("HONUA_AZURE_REGISTRY_PASSWORD"),
            DataCacheFile = env.GetOrDefault("HONUA_AZURE_DATA_CACHE_FILE", GetWorkflowCachePath(context, "azure-data-reuse.env")),
            ForceNewDataInfra = env.GetBooleanAny(["HONUA_AZURE_FORCE_NEW_DATA_INFRA", "HONUA_AZURE_FORCE_NEW_DATA"], defaultValue: false),
            ExistingDbFqdn = env.GetOptional("HONUA_AZURE_EXISTING_DB_FQDN"),
            ExistingDbResourceGroup = env.GetOptional("HONUA_AZURE_EXISTING_DB_RESOURCE_GROUP"),
            ExistingDbConnectionString = env.GetOptional("HONUA_AZURE_EXISTING_DB_CONNECTION_STRING"),
            ExistingRedisConnectionString = env.GetOptional("HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING"),
            DbFirewallStartIp = env.GetOptional("HONUA_AZURE_DB_FIREWALL_START_IP"),
            DbFirewallEndIp = env.GetOptional("HONUA_AZURE_DB_FIREWALL_END_IP"),
        };
    }

    private static AwsLiveSettings BuildAwsLiveSettings(ParsedCommand command, RunnerContext context, AwsStack stack, string defaultPlanDir)
    {
        var env = context.Environment;
        var rawPrefix = Regex.Replace(env.GetOrDefault("HONUA_AWS_NAME_PREFIX_BASE", $"h{DateTime.UtcNow:MMddHHmm}{Random.Shared.Next(0, 10)}").ToLowerInvariant(), "[^a-z0-9]", string.Empty);
        var normalizedPrefix = rawPrefix[..Math.Min(rawPrefix.Length, 10)];
        if (string.IsNullOrWhiteSpace(normalizedPrefix))
        {
            throw new ValidationException("AWS name prefix became empty after normalization");
        }

        var deploymentProfile = ParseDeploymentProfile(command.GetRequiredString("deployment-profile"));
        var reuseDataStack = command.GetBoolean("reuse-data-stack", false);

        var ecsImage = stack is AwsStack.Ecs
            ? ApplyAwsAotImage(env.GetRequired("HONUA_AWS_ECS_IMAGE"), env.GetBoolean("HONUA_USE_AOT"), "-ecs")
            : string.Empty;
        var serverlessImage = stack is AwsStack.Serverless
            ? ApplyAwsAotImage(env.GetRequired("HONUA_AWS_SERVERLESS_IMAGE"), env.GetBoolean("HONUA_USE_AOT"), "-lambda")
            : string.Empty;

        return new AwsLiveSettings
        {
            Stack = stack,
            Region = env.GetOrDefaultAny(["AWS_VALIDATION_REGION", "HONUA_AWS_VALIDATION_REGION"], "us-east-1"),
            Environment = NormalizeTerraformEnvironment(env.GetOrDefault("AWS_TF_ENVIRONMENT", "it")),
            DataNamePrefix = $"{normalizedPrefix}data",
            EcsNamePrefix = $"{normalizedPrefix}ecs",
            ServerlessNamePrefix = $"{normalizedPrefix}sl",
            PlanArtifactDir = ResolveManagedPlanArtifactDir(command, Path.Combine(defaultPlanDir, stack == AwsStack.Ecs ? "ecs" : "serverless")),
            ValidationRunId = env.GetOrDefault("HONUA_VALIDATION_RUN_ID", $"gha-{context.GitHubRunId}-aws-{stack.ToString().ToLowerInvariant()}"),
            AdminPassword = env.GetRequired("HONUA_ADMIN_PASSWORD"),
            DbAdminPassword = env.GetRequired("HONUA_DB_PASSWORD"),
            MaxRunCostUsd = decimal.Parse(env.GetOrDefault("HONUA_MAX_RUN_COST_USD", "50"), CultureInfo.InvariantCulture),
            TimeoutSeconds = int.Parse(env.GetOrDefault("HONUA_AWS_TEST_TIMEOUT_SECONDS", "900"), CultureInfo.InvariantCulture),
            ReadySloSeconds = int.Parse(env.GetOrDefault("HONUA_READY_SLO_SECONDS", "600"), CultureInfo.InvariantCulture),
            MaxLoadErrorRatePercent = decimal.Parse(env.GetOrDefault("HONUA_MAX_LOAD_ERROR_RATE_PERCENT", "0"), CultureInfo.InvariantCulture),
            LoadRequests = int.Parse(env.GetOrDefault("HONUA_AWS_LOAD_REQUESTS", "120"), CultureInfo.InvariantCulture),
            LoadConcurrency = int.Parse(env.GetOrDefault("HONUA_AWS_LOAD_CONCURRENCY", "20"), CultureInfo.InvariantCulture),
            TtlHours = int.Parse(env.GetOrDefault("HONUA_TTL_HOURS", "8"), CultureInfo.InvariantCulture),
            AllowDestroyPlan = command.GetBoolean("allow-destroy-plan", false),
            AutoDestroy = !command.GetBoolean("no-destroy", false),
            DestroyData = !command.GetBoolean("no-destroy", false) && deploymentProfile == DeploymentProfile.Ephemeral && !reuseDataStack,
            SkipQuotaPreflight = env.GetBoolean("HONUA_SKIP_QUOTA_PREFLIGHT"),
            SkipIdempotency = env.GetBoolean("HONUA_SKIP_IDEMPOTENCY"),
            SkipProtocolChecks = env.GetBoolean("HONUA_SKIP_PROTOCOL_CHECKS"),
            SkipScaleCheck = env.GetBoolean("HONUA_SKIP_SCALE_CHECK"),
            RunUpgradeRollback = env.GetBoolean("HONUA_RUN_UPGRADE_ROLLBACK"),
            EcsImage = ecsImage,
            EcsPreviousImage = stack is AwsStack.Ecs ? env.GetOptional("HONUA_AWS_ECS_PREVIOUS_IMAGE") : null,
            EcsCanaryEnabled = env.GetBoolean("HONUA_AWS_ECS_CANARY_ENABLED"),
            EcsCanaryImage = env.GetOptional("HONUA_AWS_ECS_CANARY_IMAGE"),
            EcsCanaryDesiredCount = int.Parse(env.GetOrDefault("HONUA_AWS_ECS_CANARY_DESIRED_COUNT", "1"), CultureInfo.InvariantCulture),
            EcsCanaryWeightPercentage = int.Parse(env.GetOrDefault("HONUA_AWS_ECS_CANARY_WEIGHT_PERCENTAGE", "0"), CultureInfo.InvariantCulture),
            EcsCanaryHeaderName = env.GetOrDefault("HONUA_AWS_ECS_CANARY_HEADER_NAME", "X-Honua-Canary"),
            EcsCanaryHeaderValue = env.GetOrDefault("HONUA_AWS_ECS_CANARY_HEADER_VALUE", "always"),
            EcsDesiredCount = 1,
            EcsScaleTargetDesiredCount = 2,
            ServerlessImage = serverlessImage,
            ServerlessPreviousImage = stack is AwsStack.Serverless ? env.GetOptional("HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE") : null,
            DataCacheFile = env.GetOrDefault("HONUA_AWS_DATA_CACHE_FILE", GetWorkflowCachePath(context, "aws-data-reuse.env")),
            ForceNewDataInfra = env.GetBooleanAny(["HONUA_AWS_FORCE_NEW_DATA_INFRA", "HONUA_AWS_FORCE_NEW_DATA"], defaultValue: false),
            AutoRepairVpcEgress = env.GetBoolean("HONUA_AWS_AUTO_REPAIR_VPC_EGRESS", defaultValue: true),
            ExistingDbEndpoint = env.GetOptional("HONUA_AWS_EXISTING_DB_ENDPOINT"),
            ExistingDbConnectionString = env.GetOptional("HONUA_AWS_EXISTING_DB_CONNECTION_STRING"),
            ExistingRedisConnectionString = env.GetOptional("HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING"),
            ExistingVpcId = env.GetOptional("HONUA_AWS_EXISTING_VPC_ID"),
            ExistingVpcCidr = env.GetOptional("HONUA_AWS_EXISTING_VPC_CIDR"),
            ExistingPublicSubnetIdsJson = env.GetOptional("HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS"),
            ExistingPrivateSubnetIdsJson = env.GetOptional("HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS"),
            DbIngressCidr = env.GetOptional("HONUA_AWS_DB_INGRESS_CIDR"),
            HttpIngressCidr = env.GetOptional("HONUA_AWS_HTTP_INGRESS_CIDR"),
        };
    }

    private static async Task PrepareAzureInputsAsync(RunnerContext context, AzureLiveSettings settings, AzureLiveState state)
    {
        state.ExistingDbFqdn = settings.ExistingDbFqdn;
        state.DataResourceGroup = settings.ExistingDbResourceGroup;
        state.ExistingDbConnectionString = settings.ExistingDbConnectionString;
        state.ExistingRedisConnectionString = settings.ExistingRedisConnectionString;

        if (!settings.ForceNewDataInfra &&
            string.IsNullOrWhiteSpace(state.ExistingDbConnectionString) &&
            string.IsNullOrWhiteSpace(state.ExistingRedisConnectionString))
        {
            LoadKeyValueCache(settings.DataCacheFile, AzureDataCacheFormat, values =>
            {
                state.DataResourceGroup ??= values.GetValueOrDefault("EXISTING_DB_RESOURCE_GROUP");
                state.ExistingDbFqdn = values.GetValueOrDefault("EXISTING_DB_FQDN");
                state.ExistingDbConnectionString = values.GetValueOrDefault("EXISTING_DB_CONNECTION_STRING");
                state.ExistingRedisConnectionString = values.GetValueOrDefault("EXISTING_REDIS_CONNECTION_STRING");
            });
        }

        state.HasReusableDataInputs =
            !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString) &&
            !string.IsNullOrWhiteSpace(state.ExistingRedisConnectionString);

        if (!string.IsNullOrWhiteSpace(settings.DbFirewallStartIp) ^ !string.IsNullOrWhiteSpace(settings.DbFirewallEndIp))
        {
            throw new ValidationException("HONUA_AZURE_DB_FIREWALL_START_IP and HONUA_AZURE_DB_FIREWALL_END_IP must be set together.");
        }

        if (string.IsNullOrWhiteSpace(settings.DbFirewallStartIp))
        {
            var detectedIp = await DetectPublicIpv4Async(context);
            settings.DbFirewallStartIp = detectedIp;
            settings.DbFirewallEndIp = detectedIp;
        }
    }

    private static async Task PrepareAwsInputsAsync(RunnerContext context, AwsLiveSettings settings, AwsLiveState state)
    {
        state.ExistingDbEndpoint = settings.ExistingDbEndpoint;
        state.ExistingDbConnectionString = settings.ExistingDbConnectionString;
        state.ExistingRedisConnectionString = settings.ExistingRedisConnectionString;
        state.ExistingVpcId = settings.ExistingVpcId;
        state.ExistingVpcCidr = settings.ExistingVpcCidr;
        state.ExistingPublicSubnetIdsJson = settings.ExistingPublicSubnetIdsJson;
        state.ExistingPrivateSubnetIdsJson = settings.ExistingPrivateSubnetIdsJson;

        if (!settings.ForceNewDataInfra && !HasCompleteAwsExistingData(state))
        {
            LoadKeyValueCache(settings.DataCacheFile, AwsDataCacheFormat, values =>
            {
                state.ExistingDbEndpoint = values.GetValueOrDefault("EXISTING_DB_ENDPOINT");
                state.ExistingDbConnectionString = values.GetValueOrDefault("EXISTING_DB_CONNECTION_STRING");
                state.ExistingRedisConnectionString = values.GetValueOrDefault("EXISTING_REDIS_CONNECTION_STRING");
                state.ExistingVpcId = values.GetValueOrDefault("EXISTING_VPC_ID");
                state.ExistingVpcCidr = values.GetValueOrDefault("EXISTING_VPC_CIDR");
                state.ExistingPublicSubnetIdsJson = values.GetValueOrDefault("EXISTING_PUBLIC_SUBNET_IDS");
                state.ExistingPrivateSubnetIdsJson = values.GetValueOrDefault("EXISTING_PRIVATE_SUBNET_IDS");
            });
        }

        state.HasReusableDataInputs = HasCompleteAwsExistingData(state);

        var detectedIp = await DetectPublicIpv4Async(context);
        settings.DbIngressCidr ??= $"{detectedIp}/32";
        settings.HttpIngressCidr ??= settings.DbIngressCidr;
    }

    private static async Task<string> DetectPublicIpv4Async(RunnerContext context)
    {
        if (context.DryRun)
        {
            return "203.0.113.10";
        }

        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        foreach (var endpoint in new[] { "https://api.ipify.org", "https://ifconfig.me/ip", "https://checkip.amazonaws.com" })
        {
            try
            {
                var candidate = (await client.GetStringAsync(endpoint)).Trim();
                if (Regex.IsMatch(candidate, @"^([0-9]{1,3}\.){3}[0-9]{1,3}$", RegexOptions.CultureInvariant))
                {
                    return candidate;
                }
            }
            catch
            {
                // Try the next endpoint.
            }
        }

        throw new ValidationException("Failed to detect public IPv4 address for validation.");
    }

    private static void AssertAzureCostGuardrail(AzureLiveSettings settings)
    {
        if (settings.MaxRunCostUsd <= 0)
        {
            return;
        }

        var estimated = settings.Stack == AzureStack.Aca ? 45m : 30m;
        if (estimated > settings.MaxRunCostUsd)
        {
            throw new ValidationException($"Estimated run cost ({estimated:0.##} USD) exceeds cap ({settings.MaxRunCostUsd:0.##} USD)");
        }
    }

    private static void AssertAwsCostGuardrail(AwsLiveSettings settings)
    {
        if (settings.MaxRunCostUsd <= 0)
        {
            return;
        }

        var estimated = settings.Stack == AwsStack.Ecs ? 50m : 25m;
        if (!HasCompleteAwsExistingData(settings))
        {
            estimated += 25m;
        }

        if (estimated > settings.MaxRunCostUsd)
        {
            throw new ValidationException($"Estimated run cost ({estimated:0.##} USD) exceeds cap ({settings.MaxRunCostUsd:0.##} USD)");
        }
    }

    private static async Task RunAzureQuotaPreflightAsync(RunnerContext context, IReadOnlyDictionary<string, string?> credentialsEnvironment, AzureLiveSettings settings)
    {
        var usageRaw = await context.ProcessRunner.CaptureAsync(
            "az",
            ["vm", "list-usage", "-l", settings.Location, "--query", "[?name.value=='cores'] | [0].[currentValue,limit]", "-o", "tsv"],
            context.RepoRoot,
            credentialsEnvironment);
        if (context.DryRun)
        {
            return;
        }

        var usageParts = usageRaw
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (usageParts.Length >= 2 &&
            int.TryParse(usageParts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var current) &&
            int.TryParse(usageParts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var limit))
        {
            var required = settings.Stack == AzureStack.Aca ? 4 : 2;
            if (current + required > limit)
            {
                throw new ValidationException($"Azure quota preflight failed: cores usage {current}/{limit}, estimated required +{required}");
            }
        }
    }

    private static async Task EnsureAwsSessionAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun)
        {
            return;
        }

        var maxAttemptsRaw = context.Environment.GetOrDefault("HONUA_AWS_LOGIN_MAX_ATTEMPTS", "12");
        var retrySecondsRaw = context.Environment.GetOrDefault("HONUA_AWS_LOGIN_RETRY_SECONDS", "10");
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
                    "aws",
                    ["sts", "get-caller-identity", "--output", "json"],
                    context.RepoRoot,
                    credentialsEnvironment);
                return;
            }
            catch (Exception exception) when (attempt < maxAttempts)
            {
                lastFailure = exception;
                Console.WriteLine($"[runner] AWS session attempt {attempt}/{maxAttempts} failed; retrying in {retrySeconds}s");
                await Task.Delay(TimeSpan.FromSeconds(retrySeconds));
            }
        }

        if (lastFailure is not null)
        {
            throw lastFailure;
        }
    }

    private static async Task RunAwsQuotaPreflightAsync(RunnerContext context, IReadOnlyDictionary<string, string?> credentialsEnvironment, AwsLiveSettings settings)
    {
        var (quotaSuccess, quotaRaw) = await context.ProcessRunner.TryCaptureAsync("aws", ["service-quotas", "get-service-quota", "--service-code", "ec2", "--quota-code", "L-1216C47A", "--query", "Quota.Value", "--output", "text"], context.RepoRoot, credentialsEnvironment);
        if (context.DryRun)
        {
            return;
        }

        if (!quotaSuccess)
        {
            Console.WriteLine("[runner] Warn: unable to query EC2 vCPU quota; skipping AWS quota preflight.");
            return;
        }

        if (string.IsNullOrWhiteSpace(quotaRaw) || !decimal.TryParse(quotaRaw, NumberStyles.Number, CultureInfo.InvariantCulture, out var quota))
        {
            return;
        }

        var required = settings.Stack == AwsStack.Ecs ? 4 : 2;
        if (!HasCompleteAwsExistingData(settings))
        {
            required += 2;
        }

        if (required > quota)
        {
            throw new ValidationException($"AWS quota preflight failed: estimated required vCPU {required} exceeds EC2 regional quota {quota}");
        }
    }

    private static async Task EnsureExistingAzureDbFirewallAccessAsync(
        RunnerContext context,
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun || string.IsNullOrWhiteSpace(state.ExistingDbFqdn) || !state.ExistingDbFqdn.EndsWith(".postgres.database.azure.com", StringComparison.Ordinal))
        {
            return;
        }

        var serverName = state.ExistingDbFqdn[..state.ExistingDbFqdn.IndexOf('.', StringComparison.Ordinal)];
        var resourceGroup = await ResolveAzurePostgresResourceGroupAsync(context, credentialsEnvironment, serverName, state.DataResourceGroup);
        if (string.IsNullOrWhiteSpace(resourceGroup) || string.Equals(resourceGroup, "None", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (!await AzurePostgresSupportsFirewallRulesAsync(context, credentialsEnvironment, resourceGroup, serverName))
        {
            Console.WriteLine($"[runner] Existing Azure DB firewall helper skipped: PostgreSQL server {serverName} does not have public network access enabled.");
            return;
        }

        var runId = Regex.Replace(settings.ValidationRunId.ToLowerInvariant(), "[^a-z0-9-]", string.Empty);
        var ruleName = $"runner-{runId[..Math.Min(runId.Length, 52)]}";
        await context.ProcessRunner.RunAsync("az", ["postgres", "flexible-server", "firewall-rule", "create", "--resource-group", resourceGroup, "--name", serverName, "--rule-name", ruleName, "--start-ip-address", settings.DbFirewallStartIp!, "--end-ip-address", settings.DbFirewallEndIp!], context.RepoRoot, credentialsEnvironment);
        state.DataResourceGroup = resourceGroup;
        state.RunnerFirewallRules.Add((resourceGroup, serverName, ruleName));
    }

    private static async Task ValidateAzureReusableDataInputsAsync(
        RunnerContext context,
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (!state.HasReusableDataInputs)
        {
            return;
        }

        var dbHost = state.ExistingDbFqdn;
        if (string.IsNullOrWhiteSpace(dbHost))
        {
            dbHost = TryGetConnectionStringHost(state.ExistingDbConnectionString);
            state.ExistingDbFqdn = dbHost;
        }

        if (string.IsNullOrWhiteSpace(dbHost) ||
            !dbHost.EndsWith(".postgres.database.azure.com", StringComparison.Ordinal))
        {
            Console.WriteLine("[runner] Existing Azure data reuse disabled: reusable DB host was unavailable or not an Azure PostgreSQL Flexible Server endpoint; provisioning fresh data infra.");
            ClearAzureReusableDataInputs(state);
            return;
        }

        var serverName = dbHost[..dbHost.IndexOf('.', StringComparison.Ordinal)];
        var resourceGroup = await ResolveAzurePostgresResourceGroupAsync(context, credentialsEnvironment, serverName, state.DataResourceGroup);
        if (string.IsNullOrWhiteSpace(resourceGroup) || string.Equals(resourceGroup, "None", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"[runner] Existing Azure data reuse disabled: could not resolve resource group for PostgreSQL server {serverName}; provisioning fresh data infra.");
            ClearAzureReusableDataInputs(state);
            return;
        }

        state.DataResourceGroup = resourceGroup;
        PersistAzureDataReuseCache(settings, state);
    }

    private static void ClearAzureReusableDataInputs(AzureLiveState state)
    {
        state.HasReusableDataInputs = false;
        state.DataResourceGroup = null;
        state.ExistingDbFqdn = null;
        state.ExistingDbConnectionString = null;
        state.ExistingRedisConnectionString = null;
    }

    private static async Task ApplyAzureDataStackAsync(
        RunnerContext context,
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace)
    {
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "azure-data");
        var terraformEnvironment = BuildAzureDataEnvironment(settings, validationEnvironment);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, terraformEnvironment);
        state.DataApplied = true;
        await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, "data.tfplan", "azure-data", settings.AllowDestroyPlan);

        if (context.DryRun)
        {
            state.DataCreated = true;
            state.DataResourceGroup = $"{settings.DataNamePrefix}-{settings.Environment}-data-rg";
            state.ExistingDbFqdn = $"{settings.DataNamePrefix}-{settings.Environment}.postgres.database.azure.com";
            state.ExistingDbConnectionString = BuildDryRunConnectionString(state.ExistingDbFqdn);
            state.ExistingRedisConnectionString = $"rediss://:{settings.AdminPassword}@{settings.DataNamePrefix}.redis.cache.windows.net:6380";
            state.HasReusableDataInputs = true;
            PersistAzureDataReuseCache(settings, state);
            return;
        }

        var outputs = await CaptureTerraformOutputsJsonAsync(context, terraformRoot, terraformEnvironment);
        state.DataCreated = true;
        state.DataResourceGroup = GetTerraformResourceGroup(outputs);
        state.ExistingDbFqdn = GetTerraformDatabaseHost(outputs);
        state.ExistingDbConnectionString = await ReadAzureSecretAsync(context, GetTerraformDatabaseSecretRef(outputs), validationEnvironment);
        state.ExistingRedisConnectionString = await ReadAzureSecretAsync(context, GetTerraformCacheSecretRef(outputs), validationEnvironment);
        state.HasReusableDataInputs = true;
        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, terraformRoot, terraformEnvironment);
        }

        PersistAzureDataReuseCache(settings, state);
    }

    private static async Task ApplyAzureAcaStackAsync(
        ParsedCommand command,
        RunnerContext context,
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "azure");
        state.AcaApplied = true;
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, BuildAzureAcaEnvironment(settings, state, validationEnvironment, settings.AcaImage, settings.AcaMinReplicas));

        async Task ApplyRevisionAsync(string image, int minReplicas, string label, bool runPlatformValidation)
        {
            var terraformEnvironment = BuildAzureAcaEnvironment(settings, state, validationEnvironment, image, minReplicas);
            await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, $"{label}.tfplan", label, settings.AllowDestroyPlan);
            var outputs = await CaptureOrSynthesizeTerraformOutputsAsync(context, terraformRoot, terraformEnvironment, BuildSyntheticAzureAcaOutputs(settings));
            state.BaseUrl = NormalizeBaseUrl(GetTerraformBaseUrl(outputs) ?? $"https://{settings.AcaNamePrefix}.example.test");
            state.DbHost = GetTerraformDatabaseHost(outputs) ?? state.ExistingDbFqdn;
            state.ResourceGroupName = GetTerraformResourceGroup(outputs) ?? $"{settings.AcaNamePrefix}-{settings.Environment}-rg";
            state.WorkloadName = GetTerraformWorkloadName(outputs) ?? settings.AcaNamePrefix;
            await EnsureAcaDbFirewallAccessAsync(context, state, credentialsEnvironment);
            await WaitForAzureAcaReplicasAsync(context, credentialsEnvironment, state.ResourceGroupName!, state.WorkloadName!, minReplicas, settings.TimeoutSeconds);
            state.ActiveBaseUrl = await ResolveAzureAcaProbeBaseUrlAsync(context, credentialsEnvironment, state.ResourceGroupName!, state.WorkloadName!, state.BaseUrl);
            await RunCloudHttpChecksAsync(context, settings.AdminPassword, state.ActiveBaseUrl ?? state.BaseUrl, settings.TimeoutSeconds, settings.ReadySloSeconds, settings.LoadRequests, settings.LoadConcurrency, settings.MaxLoadErrorRatePercent, settings.SkipProtocolChecks);
            if (runPlatformValidation)
            {
                await RunCloudPlatformValidationAsync(context, validationEnvironment, state.ActiveBaseUrl ?? state.BaseUrl, "azure-container-apps", outputs, state.DbHost!, settings.AdminPassword, settings.DbAdminPassword);
            }
        }

        if (settings.RunUpgradeRollback)
        {
            if (string.IsNullOrWhiteSpace(settings.AcaPreviousImage) || string.Equals(settings.AcaPreviousImage, settings.AcaImage, StringComparison.Ordinal))
            {
                throw new ValidationException("ACA upgrade/rollback requires HONUA_ACA_PREVIOUS_IMAGE different from HONUA_ACA_IMAGE.");
            }

            await ApplyRevisionAsync(settings.AcaPreviousImage!, settings.AcaMinReplicas, "aca-previous", true);
            await ApplyRevisionAsync(settings.AcaImage, settings.AcaMinReplicas, "aca-upgrade", true);

            if (!settings.SkipScaleCheck)
            {
                await ApplyRevisionAsync(settings.AcaImage, settings.AcaScaleTargetMinReplicas, "aca-scale", false);
                await WaitForAzureAcaReplicasAsync(context, credentialsEnvironment, state.ResourceGroupName!, state.WorkloadName!, settings.AcaScaleTargetMinReplicas, settings.TimeoutSeconds);
                await ApplyRevisionAsync(settings.AcaImage, settings.AcaMinReplicas, "aca-scale-reset", false);
            }

            await ApplyRevisionAsync(settings.AcaPreviousImage!, settings.AcaMinReplicas, "aca-rollback", true);
            if (!settings.AutoDestroy)
            {
                await ApplyRevisionAsync(settings.AcaImage, settings.AcaMinReplicas, "aca-restore-current", true);
            }
        }
        else
        {
            await ApplyRevisionAsync(settings.AcaImage, settings.AcaMinReplicas, "aca", true);
            if (!settings.SkipScaleCheck)
            {
                await ApplyRevisionAsync(settings.AcaImage, settings.AcaScaleTargetMinReplicas, "aca-scale", false);
                await WaitForAzureAcaReplicasAsync(context, credentialsEnvironment, state.ResourceGroupName!, state.WorkloadName!, settings.AcaScaleTargetMinReplicas, settings.TimeoutSeconds);
                await ApplyRevisionAsync(settings.AcaImage, settings.AcaMinReplicas, "aca-scale-reset", false);
            }
        }

        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, terraformRoot, BuildAzureAcaEnvironment(settings, state, validationEnvironment, settings.AcaImage, settings.AcaMinReplicas));
        }
    }

    private static async Task ApplyAzureFunctionsStackAsync(
        RunnerContext context,
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace)
    {
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "azure-functions");
        state.FunctionsApplied = true;
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, BuildAzureFunctionsEnvironment(settings, state, validationEnvironment, settings.FunctionsImage, settings.FunctionsDeploymentSlotImage, settings.FunctionsDeploymentSlotEnabled || settings.RunUpgradeRollback));

        string? currentRevision = null;
        string? desiredRevision = null;

        async Task ApplyRevisionAsync(string image, string? slotImage, string label, bool runPlatformValidation)
        {
            var terraformEnvironment = BuildAzureFunctionsEnvironment(settings, state, validationEnvironment, image, slotImage, settings.FunctionsDeploymentSlotEnabled || settings.RunUpgradeRollback);
            await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, $"{label}.tfplan", label, settings.AllowDestroyPlan);
            var outputs = await CaptureOrSynthesizeTerraformOutputsAsync(context, terraformRoot, terraformEnvironment, BuildSyntheticAzureFunctionsOutputs(settings));
            state.BaseUrl = NormalizeBaseUrl(GetTerraformBaseUrl(outputs) ?? $"https://{settings.FunctionsNamePrefix}.example.test");
            state.DbHost = GetTerraformDatabaseHost(outputs) ?? state.ExistingDbFqdn;
            state.ResourceGroupName = GetTerraformResourceGroup(outputs) ?? $"{settings.FunctionsNamePrefix}-{settings.Environment}-rg";
            state.WorkloadName = GetTerraformWorkloadName(outputs) ?? settings.FunctionsNamePrefix;
            state.CurrentRevision = GetTerraformCurrentRevision(outputs) ?? "dry-run-current";
            state.DesiredRevision = GetTerraformDesiredRevision(outputs) ?? "dry-run-desired";
            await RunCloudHttpChecksAsync(context, settings.AdminPassword, state.BaseUrl, settings.TimeoutSeconds, settings.ReadySloSeconds, settings.LoadRequests, settings.LoadConcurrency, settings.MaxLoadErrorRatePercent, settings.SkipProtocolChecks);
            if (runPlatformValidation)
            {
                await RunCloudPlatformValidationAsync(context, validationEnvironment, state.BaseUrl, "azure-functions", outputs, state.DbHost!, settings.AdminPassword, settings.DbAdminPassword, currentRevision, desiredRevision, settings.RunUpgradeRollback);
            }
        }

        if (settings.RunUpgradeRollback)
        {
            if (string.IsNullOrWhiteSpace(settings.FunctionsPreviousImage) || string.Equals(settings.FunctionsPreviousImage, settings.FunctionsImage, StringComparison.Ordinal))
            {
                throw new ValidationException("Functions upgrade/rollback requires HONUA_FUNCTIONS_PREVIOUS_IMAGE different from HONUA_FUNCTIONS_IMAGE.");
            }

            await ApplyRevisionAsync(settings.FunctionsPreviousImage!, settings.FunctionsPreviousImage, "functions-previous", false);
            currentRevision = state.CurrentRevision;
            await ApplyRevisionAsync(settings.FunctionsPreviousImage!, settings.FunctionsImage, "functions-stage-current", true);
            desiredRevision = state.DesiredRevision;
            if (!settings.AutoDestroy)
            {
                await ApplyRevisionAsync(settings.FunctionsImage, settings.FunctionsImage, "functions-reconcile-current", false);
            }
        }
        else
        {
            await ApplyRevisionAsync(settings.FunctionsImage, settings.FunctionsDeploymentSlotImage, "functions", true);
        }

        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, terraformRoot, BuildAzureFunctionsEnvironment(settings, state, validationEnvironment, settings.FunctionsImage, settings.FunctionsDeploymentSlotImage, settings.FunctionsDeploymentSlotEnabled || settings.RunUpgradeRollback));
        }
    }

    private static async Task ClearAzureFirewallRulesAsync(RunnerContext context, AzureLiveState state, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        foreach (var (resourceGroup, serverName, ruleName) in state.AcaFirewallRules.Concat(state.RunnerFirewallRules))
        {
            await context.ProcessRunner.RunAsync("az", ["postgres", "flexible-server", "firewall-rule", "delete", "--resource-group", resourceGroup, "--name", serverName, "--rule-name", ruleName, "--yes"], context.RepoRoot, credentialsEnvironment);
        }
    }

    private static async Task DestroyAzureStacksAsync(
        RunnerContext context,
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace)
    {
        if (state.AcaApplied)
        {
            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + Path.Combine(workspace.TerraformRoot, "examples", "azure"), "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, BuildAzureAcaEnvironment(settings, state, validationEnvironment, settings.AcaImage, settings.AcaMinReplicas));
        }

        if (state.FunctionsApplied)
        {
            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + Path.Combine(workspace.TerraformRoot, "examples", "azure-functions"), "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, BuildAzureFunctionsEnvironment(settings, state, validationEnvironment, settings.FunctionsImage, settings.FunctionsDeploymentSlotImage, settings.FunctionsDeploymentSlotEnabled || settings.RunUpgradeRollback));
        }

        if (state.DataApplied && state.DataCreated && settings.DestroyData)
        {
            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + Path.Combine(workspace.TerraformRoot, "examples", "azure-data"), "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, BuildAzureDataEnvironment(settings, validationEnvironment));
            ClearDataReuseCache(settings.DataCacheFile);
        }
    }

    private static Dictionary<string, string?> BuildAzureDataEnvironment(AzureLiveSettings settings, IReadOnlyDictionary<string, string?> baseEnvironment)
    {
        return new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_IN_AUTOMATION"] = "true",
            ["TF_VAR_location"] = settings.Location,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = settings.DataNamePrefix,
            ["TF_VAR_honua_admin_password"] = settings.AdminPassword,
            ["TF_VAR_db_admin_password"] = settings.DbAdminPassword,
            ["TF_VAR_enable_postgis"] = "false",
            ["TF_VAR_redis_enabled"] = "true",
            ["TF_VAR_existing_db_fqdn"] = string.Empty,
            ["TF_VAR_existing_db_connection_string"] = string.Empty,
            ["TF_VAR_redis_connection_string"] = string.Empty,
            ["TF_VAR_db_firewall_start_ip"] = settings.DbFirewallStartIp,
            ["TF_VAR_db_firewall_end_ip"] = settings.DbFirewallEndIp,
            ["TF_VAR_key_vault_default_action"] = "Allow",
            ["TF_VAR_tags"] = BuildAzureValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
        };
    }

    private static Dictionary<string, string?> BuildAzureAcaEnvironment(AzureLiveSettings settings, AzureLiveState state, IReadOnlyDictionary<string, string?> baseEnvironment, string image, int minReplicas)
    {
        var reusingExistingData = !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString);
        return new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_IN_AUTOMATION"] = "true",
            ["TF_VAR_location"] = settings.Location,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = settings.AcaNamePrefix,
            ["TF_VAR_honua_admin_password"] = settings.AdminPassword,
            ["TF_VAR_db_admin_password"] = settings.DbAdminPassword,
            ["TF_VAR_enable_postgis"] = (!reusingExistingData).ToString().ToLowerInvariant(),
            // Azure live validation exercises a single-instance ACA path. Reused Redis has
            // introduced readiness flakiness without adding signal for the current checks.
            ["TF_VAR_redis_enabled"] = "false",
            ["TF_VAR_existing_db_fqdn"] = state.ExistingDbFqdn,
            ["TF_VAR_existing_db_connection_string"] = state.ExistingDbConnectionString,
            ["TF_VAR_redis_connection_string"] = string.Empty,
            ["TF_VAR_db_firewall_start_ip"] = settings.DbFirewallStartIp,
            ["TF_VAR_db_firewall_end_ip"] = settings.DbFirewallEndIp,
            ["TF_VAR_honua_image"] = image,
            ["TF_VAR_registry_server"] = settings.RegistryServer,
            ["TF_VAR_registry_username"] = settings.RegistryUsername,
            ["TF_VAR_registry_password"] = settings.RegistryPassword,
            ["TF_VAR_min_replicas"] = minReplicas.ToString(CultureInfo.InvariantCulture),
            ["TF_VAR_max_replicas"] = settings.AcaMaxReplicas.ToString(CultureInfo.InvariantCulture),
            ["TF_VAR_key_vault_default_action"] = "Allow",
            ["TF_VAR_tags"] = BuildAzureValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
        };
    }

    private static Dictionary<string, string?> BuildAzureFunctionsEnvironment(AzureLiveSettings settings, AzureLiveState state, IReadOnlyDictionary<string, string?> baseEnvironment, string image, string? slotImage, bool deploymentSlotEnabled)
    {
        var reusingExistingData = !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString);
        return new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_IN_AUTOMATION"] = "true",
            ["TF_VAR_location"] = settings.Location,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = settings.FunctionsNamePrefix,
            ["TF_VAR_honua_admin_password"] = settings.AdminPassword,
            ["TF_VAR_db_admin_password"] = settings.DbAdminPassword,
            ["TF_VAR_enable_postgis"] = (!reusingExistingData).ToString().ToLowerInvariant(),
            ["TF_VAR_redis_enabled"] = "false",
            ["TF_VAR_existing_db_fqdn"] = state.ExistingDbFqdn,
            ["TF_VAR_existing_db_connection_string"] = state.ExistingDbConnectionString,
            ["TF_VAR_redis_connection_string"] = string.Empty,
            ["TF_VAR_db_firewall_start_ip"] = settings.DbFirewallStartIp,
            ["TF_VAR_db_firewall_end_ip"] = settings.DbFirewallEndIp,
            ["TF_VAR_honua_image"] = image,
            ["TF_VAR_registry_server"] = settings.RegistryServer,
            ["TF_VAR_registry_username"] = settings.RegistryUsername,
            ["TF_VAR_registry_password"] = settings.RegistryPassword,
            ["TF_VAR_deployment_slot_enabled"] = deploymentSlotEnabled.ToString().ToLowerInvariant(),
            ["TF_VAR_deployment_slot_name"] = settings.FunctionsDeploymentSlotName,
            ["TF_VAR_deployment_slot_image"] = slotImage ?? settings.FunctionsDeploymentSlotImage ?? image,
            ["TF_VAR_plan_sku_name"] = settings.FunctionsPlanSku,
            ["TF_VAR_skip_migrations"] = settings.FunctionsSkipMigrations.ToString().ToLowerInvariant(),
            ["TF_VAR_tags"] = BuildAzureValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
        };
    }

    private static async Task ResolveAzureRegistryCredentialsAsync(
        RunnerContext context,
        AzureLiveSettings settings,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (!NeedsAzureRegistryCredentials(settings))
        {
            return;
        }

        if (!string.IsNullOrWhiteSpace(settings.RegistryServer) &&
            !string.IsNullOrWhiteSpace(settings.RegistryUsername) &&
            !string.IsNullOrWhiteSpace(settings.RegistryPassword))
        {
            return;
        }

        if (context.DryRun)
        {
            settings.RegistryServer ??= GetAzureRegistryServerFromImages(settings) ?? "example.azurecr.io";
            settings.RegistryUsername ??= "<dry-run>";
            settings.RegistryPassword ??= "<dry-run>";
            return;
        }

        if (string.IsNullOrWhiteSpace(settings.RegistryResourceId))
        {
            throw new ValidationException("HONUA_AZURE_REGISTRY_RESOURCE_ID is required when Azure live validation uses private registry images without explicit registry credentials.");
        }

        var registryName = GetAzureResourceName(settings.RegistryResourceId);
        if (string.IsNullOrWhiteSpace(settings.RegistryServer))
        {
            settings.RegistryServer = await context.ProcessRunner.CaptureAsync(
                "az",
                ["acr", "show", "--name", registryName, "--query", "loginServer", "-o", "tsv"],
                context.RepoRoot,
                credentialsEnvironment);
        }

        if (!string.IsNullOrWhiteSpace(settings.RegistryUsername) &&
            !string.IsNullOrWhiteSpace(settings.RegistryPassword))
        {
            return;
        }

        var credentialsJson = await context.ProcessRunner.CaptureAsync(
            "az",
            ["acr", "credential", "show", "--name", registryName, "--query", "{username:username,password:passwords[0].value}", "-o", "json"],
            context.RepoRoot,
            credentialsEnvironment,
            redactOutput: true);

        using var document = JsonDocument.Parse(credentialsJson);
        settings.RegistryUsername = document.RootElement.TryGetProperty("username", out var usernameValue)
            ? usernameValue.GetString()
            : settings.RegistryUsername;
        settings.RegistryPassword = document.RootElement.TryGetProperty("password", out var passwordValue)
            ? passwordValue.GetString()
            : settings.RegistryPassword;

        if (string.IsNullOrWhiteSpace(settings.RegistryServer) ||
            string.IsNullOrWhiteSpace(settings.RegistryUsername) ||
            string.IsNullOrWhiteSpace(settings.RegistryPassword))
        {
            throw new ValidationException("Failed to resolve Azure Container Registry credentials for azure-live validation.");
        }
    }

    private static bool NeedsAzureRegistryCredentials(AzureLiveSettings settings)
    {
        return UsesAzureContainerRegistry(settings.AcaImage) ||
               UsesAzureContainerRegistry(settings.FunctionsImage) ||
               UsesAzureContainerRegistry(settings.FunctionsDeploymentSlotImage);
    }

    private static bool UsesAzureContainerRegistry(string? image)
    {
        if (string.IsNullOrWhiteSpace(image))
        {
            return false;
        }

        var imageParts = image.Split('/', 2, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return imageParts.Length > 1 && imageParts[0].EndsWith(".azurecr.io", StringComparison.OrdinalIgnoreCase);
    }

    private static string? GetAzureRegistryServerFromImages(AzureLiveSettings settings)
    {
        return GetAzureRegistryServer(settings.AcaImage) ??
               GetAzureRegistryServer(settings.FunctionsImage) ??
               GetAzureRegistryServer(settings.FunctionsDeploymentSlotImage);
    }

    private static string? GetAzureRegistryServer(string? image)
    {
        if (!UsesAzureContainerRegistry(image))
        {
            return null;
        }

        var imageParts = image!.Split('/', 2, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return imageParts[0];
    }

    private static string GetAzureResourceName(string resourceId)
    {
        var segments = resourceId
            .Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (segments.Length == 0)
        {
            throw new ValidationException($"Invalid Azure resource ID: {resourceId}");
        }

        return segments[^1];
    }

    private static async Task EnsureAcaDbFirewallAccessAsync(RunnerContext context, AzureLiveState state, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun)
        {
            return;
        }

        var dbHost = state.DbHost;
        if (string.IsNullOrWhiteSpace(dbHost))
        {
            dbHost = TryGetConnectionStringHost(state.ExistingDbConnectionString);
            if (!string.IsNullOrWhiteSpace(dbHost))
            {
                state.DbHost = dbHost;
            }
        }

        if (string.IsNullOrWhiteSpace(dbHost))
        {
            Console.WriteLine("[runner] ACA DB firewall helper skipped: database host was not available from outputs or connection string.");
            return;
        }

        if (!dbHost.EndsWith(".postgres.database.azure.com", StringComparison.Ordinal))
        {
            Console.WriteLine($"[runner] ACA DB firewall helper skipped: database host is not an Azure PostgreSQL Flexible Server endpoint ({dbHost}).");
            return;
        }

        if (string.IsNullOrWhiteSpace(state.ResourceGroupName) || string.IsNullOrWhiteSpace(state.WorkloadName))
        {
            Console.WriteLine("[runner] ACA DB firewall helper skipped: resource group or workload name was empty.");
            return;
        }

        var serverName = dbHost[..dbHost.IndexOf('.', StringComparison.Ordinal)];
        var resourceGroup = await ResolveAzurePostgresResourceGroupAsync(context, credentialsEnvironment, serverName, state.DataResourceGroup);
        if (string.IsNullOrWhiteSpace(resourceGroup) || string.Equals(resourceGroup, "None", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"[runner] ACA DB firewall helper skipped: could not resolve resource group for PostgreSQL server {serverName}.");
            return;
        }

        if (!await AzurePostgresSupportsFirewallRulesAsync(context, credentialsEnvironment, resourceGroup, serverName))
        {
            Console.WriteLine($"[runner] ACA DB firewall helper skipped: PostgreSQL server {serverName} does not have public network access enabled.");
            return;
        }

        var outboundIps = await context.ProcessRunner.CaptureAsync("az", ["containerapp", "show", "--resource-group", state.ResourceGroupName, "--name", state.WorkloadName, "--query", "properties.outboundIpAddresses[]", "-o", "tsv"], context.RepoRoot, credentialsEnvironment);
        var ips = outboundIps.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (ips.Length == 0)
        {
            Console.WriteLine($"[runner] ACA DB firewall helper skipped: no outbound IPs were reported for container app {state.WorkloadName}.");
            return;
        }

        for (var index = 0; index < ips.Length; index++)
        {
            var ruleName = $"aca-validation-egress-{index}";
            await context.ProcessRunner.RunAsync("az", ["postgres", "flexible-server", "firewall-rule", "create", "--resource-group", resourceGroup, "--name", serverName, "--rule-name", ruleName, "--start-ip-address", ips[index], "--end-ip-address", ips[index]], context.RepoRoot, credentialsEnvironment);
            state.AcaFirewallRules.Add((resourceGroup, serverName, ruleName));
        }

        state.DataResourceGroup = resourceGroup;
    }

    private static async Task<string?> ResolveAzurePostgresResourceGroupAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string serverName,
        string? preferredResourceGroup)
    {
        if (!string.IsNullOrWhiteSpace(preferredResourceGroup))
        {
            var (resourceGroupExists, resourceGroup) = await context.ProcessRunner.TryCaptureAsync(
                "az",
                ["resource", "show", "--resource-group", preferredResourceGroup, "--resource-type", "Microsoft.DBforPostgreSQL/flexibleServers", "--name", serverName, "--query", "resourceGroup", "-o", "tsv"],
                context.RepoRoot,
                credentialsEnvironment);
            if (resourceGroupExists &&
                !string.IsNullOrWhiteSpace(resourceGroup) &&
                !string.Equals(resourceGroup, "None", StringComparison.OrdinalIgnoreCase))
            {
                return resourceGroup;
            }

            Console.WriteLine($"[runner] Azure PostgreSQL server {serverName} was not found in configured resource group {preferredResourceGroup}; attempting subscription-wide discovery.");
        }

        var (serverListed, discoveredResourceGroup) = await context.ProcessRunner.TryCaptureAsync(
            "az",
            ["postgres", "flexible-server", "list", "--query", $"[?name=='{serverName}'].resourceGroup | [0]", "-o", "tsv"],
            context.RepoRoot,
            credentialsEnvironment);
        if (serverListed &&
            !string.IsNullOrWhiteSpace(discoveredResourceGroup) &&
            !string.Equals(discoveredResourceGroup, "None", StringComparison.OrdinalIgnoreCase))
        {
            return discoveredResourceGroup;
        }

        var (resourceListed, listedResourceGroup) = await context.ProcessRunner.TryCaptureAsync(
            "az",
            ["resource", "list", "--name", serverName, "--resource-type", "Microsoft.DBforPostgreSQL/flexibleServers", "--query", "[0].resourceGroup", "-o", "tsv"],
            context.RepoRoot,
            credentialsEnvironment);
        if (resourceListed &&
            !string.IsNullOrWhiteSpace(listedResourceGroup) &&
            !string.Equals(listedResourceGroup, "None", StringComparison.OrdinalIgnoreCase))
        {
            return listedResourceGroup;
        }

        return null;
    }

    private static async Task<bool> AzurePostgresSupportsFirewallRulesAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string resourceGroup,
        string serverName)
    {
        var (captured, publicNetworkAccess) = await context.ProcessRunner.TryCaptureAsync(
            "az",
            ["postgres", "flexible-server", "show", "--resource-group", resourceGroup, "--name", serverName, "--query", "network.publicNetworkAccess", "-o", "tsv"],
            context.RepoRoot,
            credentialsEnvironment);
        if (!captured)
        {
            return false;
        }

        return string.Equals(publicNetworkAccess?.Trim(), "Enabled", StringComparison.OrdinalIgnoreCase);
    }

    private static string? TryGetConnectionStringHost(string? connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            return null;
        }

        foreach (var segment in connectionString.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = segment.Split('=', 2, StringSplitOptions.TrimEntries);
            if (parts.Length != 2)
            {
                continue;
            }

            if (parts[0] is "Host" or "Server")
            {
                return parts[1];
            }
        }

        return null;
    }

    private static async Task WaitForAzureAcaReplicasAsync(RunnerContext context, IReadOnlyDictionary<string, string?> credentialsEnvironment, string resourceGroup, string appName, int expectedMinReplicas, int timeoutSeconds)
    {
        if (context.DryRun)
        {
            return;
        }

        var startedAt = DateTimeOffset.UtcNow;
        while (true)
        {
            var countRaw = await context.ProcessRunner.CaptureAsync("az", ["containerapp", "replica", "list", "-g", resourceGroup, "-n", appName, "--query", "length(@)", "-o", "tsv"], context.RepoRoot, credentialsEnvironment);
            if (int.TryParse(countRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) && count >= expectedMinReplicas)
            {
                return;
            }

            if ((DateTimeOffset.UtcNow - startedAt).TotalSeconds > timeoutSeconds)
            {
                throw new ValidationException($"Timed out waiting for ACA replicas >= {expectedMinReplicas}");
            }

            await Task.Delay(TimeSpan.FromSeconds(15));
        }
    }

    private static async Task<string?> ResolveAzureAcaProbeBaseUrlAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string resourceGroup,
        string appName,
        string? fallbackBaseUrl)
    {
        if (context.DryRun)
        {
            return fallbackBaseUrl;
        }

        var appUrl = string.IsNullOrWhiteSpace(fallbackBaseUrl) ? null : NormalizeBaseUrl(fallbackBaseUrl);
        var revisionUrl = await TryGetAzureAcaLatestRevisionUrlAsync(context, credentialsEnvironment, resourceGroup, appName);
        if (string.IsNullOrWhiteSpace(revisionUrl))
        {
            return appUrl;
        }

        if (string.Equals(appUrl, revisionUrl, StringComparison.OrdinalIgnoreCase))
        {
            return appUrl;
        }

        Console.WriteLine($"[runner] ACA readiness will probe latest revision endpoint first: {revisionUrl}");
        return revisionUrl;
    }

    private static async Task<string?> TryGetAzureAcaLatestRevisionUrlAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string resourceGroup,
        string appName)
    {
        var (success, raw) = await context.ProcessRunner.TryCaptureAsync(
            "az",
            [
                "containerapp",
                "show",
                "--resource-group", resourceGroup,
                "--name", appName,
                "--query", "properties.latestRevisionFqdn",
                "-o", "tsv",
            ],
            context.RepoRoot,
            credentialsEnvironment);

        if (!success)
        {
            Console.WriteLine("[runner] Warn: unable to query ACA latest revision FQDN; using app ingress FQDN.");
            return null;
        }

        if (string.IsNullOrWhiteSpace(raw) || string.Equals(raw.Trim(), "None", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return NormalizeBaseUrl(raw.Trim());
    }

    private static async Task RunCloudHttpChecksAsync(RunnerContext context, string adminApiKey, string baseUrl, int timeoutSeconds, int readySloSeconds, int loadRequests, int loadConcurrency, decimal maxLoadErrorRatePercent, bool skipProtocolChecks)
    {
        await WaitForCloudReadyAsync(context, baseUrl, timeoutSeconds, readySloSeconds);
        if (!skipProtocolChecks)
        {
            await VerifyProtocolEndpointsAsync(context, baseUrl, adminApiKey);
        }

        await RunLoadProbeAsync(context, baseUrl, loadRequests, loadConcurrency, maxLoadErrorRatePercent);
    }

    private static async Task WaitForCloudReadyAsync(RunnerContext context, string baseUrl, int timeoutSeconds, int readySloSeconds)
    {
        if (context.DryRun)
        {
            return;
        }

        using var client = new HttpClient { BaseAddress = new Uri(NormalizeBaseUrl(baseUrl), UriKind.Absolute), Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("HonuaTerraformValidation", "1.0"));
        var startedAt = DateTimeOffset.UtcNow;
        var readySloSatisfied = false;
        var consecutiveReadyChecks = 0;
        while (true)
        {
            try
            {
                using var response = await client.GetAsync("/healthz/ready");
                if (response.IsSuccessStatusCode)
                {
                    if (!readySloSatisfied)
                    {
                        var elapsed = (DateTimeOffset.UtcNow - startedAt).TotalSeconds;
                        if (elapsed > readySloSeconds)
                        {
                            throw new ValidationException($"Ready SLO failed: {elapsed:0}s exceeds {readySloSeconds}s");
                        }

                        readySloSatisfied = true;
                    }

                    consecutiveReadyChecks++;
                    if (consecutiveReadyChecks >= 3)
                    {
                        return;
                    }

                    await Task.Delay(TimeSpan.FromSeconds(5));
                    continue;
                }
            }
            catch
            {
                // retry
            }

            consecutiveReadyChecks = 0;

            if ((DateTimeOffset.UtcNow - startedAt).TotalSeconds > timeoutSeconds)
            {
                throw new ValidationException($"Timed out waiting for readiness: {NormalizeBaseUrl(baseUrl)}/healthz/ready");
            }

            await Task.Delay(TimeSpan.FromSeconds(10));
        }
    }

    private static async Task VerifyProtocolEndpointsAsync(RunnerContext context, string baseUrl, string adminApiKey)
    {
        if (context.DryRun)
        {
            return;
        }

        using var client = new HttpClient { BaseAddress = new Uri(NormalizeBaseUrl(baseUrl), UriKind.Absolute), Timeout = TimeSpan.FromSeconds(20) };
        await EnsureEndpointAsync(client, "/rest/services?f=pjson", adminApiKey, allowODataEmptyCatalog: false);
        await EnsureEndpointAsync(client, "/ogc/features", adminApiKey, allowODataEmptyCatalog: false);
        await EnsureEndpointAsync(client, "/odata", adminApiKey, allowODataEmptyCatalog: true);

        using var adminRequest = new HttpRequestMessage(HttpMethod.Get, "/api/v1/admin/config");
        using var adminResponse = await client.SendAsync(adminRequest);
        if (adminResponse.StatusCode is not HttpStatusCode.Unauthorized and not HttpStatusCode.Forbidden)
        {
            throw new ValidationException($"Expected unauthenticated admin endpoint to return 401/403, got {(int)adminResponse.StatusCode}");
        }
    }

    private static async Task EnsureEndpointAsync(HttpClient client, string path, string adminApiKey, bool allowODataEmptyCatalog)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        using var response = await client.SendAsync(request);
        if (response.IsSuccessStatusCode || ((int)response.StatusCode >= 300 && (int)response.StatusCode < 400))
        {
            return;
        }

        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            using var authenticated = new HttpRequestMessage(HttpMethod.Get, path);
            authenticated.Headers.Add("X-API-Key", adminApiKey);
            using var authenticatedResponse = await client.SendAsync(authenticated);
            authenticatedResponse.EnsureSuccessStatusCode();
            return;
        }

        if (allowODataEmptyCatalog && response.StatusCode == HttpStatusCode.NotFound)
        {
            var body = await response.Content.ReadAsStringAsync();
            if (body.Contains("No OData-enabled services found", StringComparison.OrdinalIgnoreCase) ||
                body.Contains("OData is not enabled for any available service", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
        }

        throw new ValidationException($"Protocol smoke endpoint failed: {path} returned HTTP {(int)response.StatusCode}");
    }

    private static async Task RunLoadProbeAsync(RunnerContext context, string baseUrl, int requests, int concurrency, decimal maxLoadErrorRatePercent)
    {
        if (context.DryRun)
        {
            return;
        }

        using var client = new HttpClient { BaseAddress = new Uri(NormalizeBaseUrl(baseUrl), UriKind.Absolute), Timeout = TimeSpan.FromSeconds(20) };
        using var throttler = new SemaphoreSlim(concurrency);
        var failures = 0;
        var tasks = Enumerable.Range(0, requests).Select(async _ =>
        {
            await throttler.WaitAsync();
            try
            {
                using var response = await client.GetAsync("/healthz/ready");
                if (!response.IsSuccessStatusCode)
                {
                    Interlocked.Increment(ref failures);
                }
            }
            catch
            {
                Interlocked.Increment(ref failures);
            }
            finally
            {
                throttler.Release();
            }
        });

        await Task.WhenAll(tasks);
        var errorRate = requests == 0 ? 0m : failures * 100m / requests;
        if (errorRate > maxLoadErrorRatePercent)
        {
            throw new ValidationException($"Load probe failed SLO: error rate {errorRate:0.####}% exceeds {maxLoadErrorRatePercent:0.####}%");
        }
    }

    private static async Task RunCloudPlatformValidationAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        string baseUrl,
        string defaultPlatform,
        string rawTerraformOutputs,
        string dbHost,
        string adminApiKey,
        string dbPassword,
        string? currentRevision = null,
        string? desiredRevision = null,
        bool executeDeployOperation = false)
    {
        if (!validationEnvironment.TryGetValue("HONUA_PLATFORM_VALIDATION_SCRIPT", out var scriptPath) || string.IsNullOrWhiteSpace(scriptPath))
        {
            return;
        }

        // This is an optional cross-repo handoff into honua-server's platform suite,
        // not the deprecated internal Terraform shell orchestration path.
        var processEnvironment = new Dictionary<string, string?>(validationEnvironment, StringComparer.Ordinal)
        {
            ["HONUA_PLATFORM_VALIDATION_PLATFORM"] = defaultPlatform,
            ["HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON"] = rawTerraformOutputs,
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST"] = dbHost,
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT"] = "5432",
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME"] = "honua",
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME"] = "honua",
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD"] = dbPassword,
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE"] = "Require",
            ["HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED"] = "true",
            ["HONUA_CLOUD_TEST_BASE_URL"] = baseUrl,
            ["HONUA_CLOUD_TEST_ADMIN_API_KEY"] = adminApiKey,
        };
        var deployPlanSupport = GetTerraformValidationCapability(rawTerraformOutputs, "deploy_plan");
        if (!string.IsNullOrWhiteSpace(deployPlanSupport))
        {
            processEnvironment["HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT"] = deployPlanSupport;
        }

        var mutationSupport = GetTerraformValidationCapability(rawTerraformOutputs, "mutation");
        if (!string.IsNullOrWhiteSpace(mutationSupport))
        {
            processEnvironment["HONUA_CLOUD_TEST_EXPECT_MUTATION_SUPPORT"] = mutationSupport;
        }

        if (!string.IsNullOrWhiteSpace(currentRevision))
        {
            processEnvironment["HONUA_PLATFORM_VALIDATION_DEPLOY_CURRENT_REVISION"] = currentRevision;
        }

        if (!string.IsNullOrWhiteSpace(desiredRevision))
        {
            processEnvironment["HONUA_PLATFORM_VALIDATION_DEPLOY_DESIRED_REVISION"] = desiredRevision;
        }

        if (executeDeployOperation)
        {
            processEnvironment["HONUA_PLATFORM_VALIDATION_EXECUTE_DEPLOY_OPERATION"] = "true";
            processEnvironment["HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK"] = "true";
            processEnvironment["HONUA_PLATFORM_VALIDATION_DEPLOY_TIMEOUT_SECONDS"] = "240";
        }

        var scriptDirectory = Path.GetDirectoryName(scriptPath) ?? context.RepoRoot;
        var scriptWorkingDirectory = Directory.GetParent(scriptDirectory)?.FullName ?? context.RepoRoot;
        await context.ProcessRunner.RunAsync("bash", [scriptPath], scriptWorkingDirectory, processEnvironment);
    }

    private static async Task<string> ReadAzureSecretAsync(RunnerContext context, string? secretId, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (string.IsNullOrWhiteSpace(secretId))
        {
            throw new ValidationException("Azure secret reference was empty");
        }

        return await context.ProcessRunner.CaptureAsync("az", ["keyvault", "secret", "show", "--id", secretId, "--query", "value", "-o", "tsv"], context.RepoRoot, credentialsEnvironment, redactOutput: true);
    }

    private static string BuildDryRunConnectionString(string dbHost)
    {
        return $"Host={dbHost};Port=5432;Database=honua;Username=honua;Password=DryRunPassword12345678901234567890;SslMode=Require";
    }

    private static void LoadKeyValueCache(string path, string expectedFormat, Action<Dictionary<string, string>> applyValues)
    {
        if (!File.Exists(path) || new FileInfo(path).LinkTarget is not null)
        {
            return;
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var formatSeen = false;
        foreach (var rawLine in File.ReadLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
            {
                continue;
            }

            var separatorIndex = line.IndexOf('=');
            if (separatorIndex <= 0)
            {
                return;
            }

            var key = line[..separatorIndex];
            var value = line[(separatorIndex + 1)..];
            if (key == "HONUA_CACHE_FORMAT")
            {
                if (!string.Equals(value, expectedFormat, StringComparison.Ordinal))
                {
                    return;
                }

                formatSeen = true;
                continue;
            }

            try
            {
                values[key] = Encoding.UTF8.GetString(Convert.FromBase64String(value));
            }
            catch
            {
                return;
            }
        }

        if (formatSeen)
        {
            applyValues(values);
        }
    }

    private static void PersistAzureDataReuseCache(AzureLiveSettings settings, AzureLiveState state)
    {
        WriteKeyValueCache(settings.DataCacheFile, AzureDataCacheFormat, new Dictionary<string, string?>
        {
            ["EXISTING_DB_RESOURCE_GROUP"] = state.DataResourceGroup,
            ["EXISTING_DB_FQDN"] = state.ExistingDbFqdn,
            ["EXISTING_DB_CONNECTION_STRING"] = state.ExistingDbConnectionString,
            ["EXISTING_REDIS_CONNECTION_STRING"] = state.ExistingRedisConnectionString,
        });
    }

    private static void WriteKeyValueCache(string path, string format, IReadOnlyDictionary<string, string?> values)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        var tempFile = Path.Combine(Path.GetDirectoryName(path) ?? ".", $"honua-cache-{Guid.NewGuid():N}.tmp");
        using (var writer = new StreamWriter(tempFile, append: false, Encoding.UTF8))
        {
            writer.WriteLine($"HONUA_CACHE_FORMAT={format}");
            foreach (var (key, value) in values)
            {
                writer.WriteLine($"{key}={Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? string.Empty))}");
            }
        }

        File.Move(tempFile, path, overwrite: true);
    }

    private static void ClearDataReuseCache(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    private static bool HasCompleteAwsExistingData(AwsLiveSettings settings) =>
        !string.IsNullOrWhiteSpace(settings.ExistingDbEndpoint) &&
        !string.IsNullOrWhiteSpace(settings.ExistingDbConnectionString) &&
        !string.IsNullOrWhiteSpace(settings.ExistingRedisConnectionString) &&
        !string.IsNullOrWhiteSpace(settings.ExistingVpcId) &&
        !string.IsNullOrWhiteSpace(settings.ExistingVpcCidr) &&
        !string.IsNullOrWhiteSpace(settings.ExistingPublicSubnetIdsJson) &&
        !string.IsNullOrWhiteSpace(settings.ExistingPrivateSubnetIdsJson);

    private static bool HasCompleteAwsExistingData(AwsLiveState state) =>
        !string.IsNullOrWhiteSpace(state.ExistingDbEndpoint) &&
        !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString) &&
        !string.IsNullOrWhiteSpace(state.ExistingRedisConnectionString) &&
        !string.IsNullOrWhiteSpace(state.ExistingVpcId) &&
        !string.IsNullOrWhiteSpace(state.ExistingVpcCidr) &&
        !string.IsNullOrWhiteSpace(state.ExistingPublicSubnetIdsJson) &&
        !string.IsNullOrWhiteSpace(state.ExistingPrivateSubnetIdsJson);

    private static string ApplyAwsAotImage(string image, bool useAot, string suffix)
    {
        if (!useAot)
        {
            return image;
        }

        if (image.Contains(':', StringComparison.Ordinal))
        {
            var repository = image[..image.LastIndexOf(':')];
            var tag = image[(image.LastIndexOf(':') + 1)..];
            if (tag.EndsWith(suffix, StringComparison.Ordinal) && !tag.EndsWith($"{suffix}-aot", StringComparison.Ordinal))
            {
                return $"{repository}:{tag}-aot";
            }
        }

        return ResolveManagedImage(image, useAot);
    }

    private static Task RunNativeAwsValidationAsync(
        ParsedCommand command,
        RunnerContext context,
        AwsStack stack,
        AwsBootstrapCredentials credentials,
        string defaultPlanDir)
    {
        return ExecuteNativeAwsValidationAsync(command, context, stack, credentials, defaultPlanDir);
    }

    private static string? GetTerraformBaseUrl(string rawJson) => GetTerraformOutputString(rawJson,
        ["validation_contract", "value", "tests", "base_url"],
        ["deployment_contract", "value", "endpoints", "public_base_url"],
        ["honua_url", "value"]);

    private static string? GetTerraformDatabaseHost(string rawJson) => GetTerraformOutputString(rawJson,
        ["deployment_contract", "value", "dependencies", "database", "host"],
        ["db_endpoint", "value"],
        ["database_fqdn", "value"],
        ["db_fqdn", "value"]);

    private static string? GetTerraformDatabaseSecretRef(string rawJson) => GetTerraformOutputString(rawJson,
        ["deployment_contract", "value", "dependencies", "database", "secret_ref"],
        ["operations_contract", "value", "secrets", "db_connection_secret"],
        ["db_connection_secret_arn", "value"],
        ["db_connection_secret_id", "value"]);

    private static string? GetTerraformCacheSecretRef(string rawJson) => GetTerraformOutputString(rawJson,
        ["deployment_contract", "value", "dependencies", "cache", "secret_ref"],
        ["operations_contract", "value", "secrets", "redis_connection_secret"],
        ["redis_connection_secret_arn", "value"],
        ["redis_connection_secret_id", "value"]);

    private static string? GetTerraformResourceGroup(string rawJson) => GetTerraformOutputString(rawJson,
        ["validation_contract", "value", "artifacts", "resource_group"],
        ["operations_contract", "value", "grouping", "resource_group"],
        ["resource_group_name", "value"]);

    private static string? GetTerraformWorkloadName(string rawJson) => GetTerraformOutputString(rawJson,
        ["validation_contract", "value", "artifacts", "workload_name"],
        ["deployment_contract", "value", "workload", "name"],
        ["container_app_name", "value"],
        ["function_app_name", "value"],
        ["ecs_service_name", "value"],
        ["lambda_function_name", "value"]);

    private static string? GetTerraformCurrentRevision(string rawJson) => GetTerraformOutputString(rawJson,
        ["deployment_contract", "value", "rollout", "current_revision"],
        ["control_plane_current_revision", "value"]);

    private static string? GetTerraformDesiredRevision(string rawJson) => GetTerraformOutputString(rawJson,
        ["deployment_contract", "value", "rollout", "desired_revision"],
        ["control_plane_desired_revision", "value"]);

    private static string? GetTerraformValidationCapability(string rawJson, string capability) => GetTerraformOutputString(rawJson,
        ["validation_contract", "value", "platform", "capabilities", capability]);

    private static string? GetTerraformOutputString(string rawJson, params string[][] candidatePaths)
    {
        using var document = JsonDocument.Parse(rawJson);
        foreach (var path in candidatePaths)
        {
            if (!TryGetJsonPath(document.RootElement, path, out var value))
            {
                continue;
            }

            if (value.ValueKind == JsonValueKind.String)
            {
                var text = value.GetString();
                if (!string.IsNullOrWhiteSpace(text))
                {
                    return text;
                }
            }
            else if (value.ValueKind is JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False)
            {
                return value.ToString();
            }
        }

        return null;
    }

    private static bool TryGetJsonPath(JsonElement element, IReadOnlyList<string> path, out JsonElement value)
    {
        value = element;
        foreach (var segment in path)
        {
            if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(segment, out value))
            {
                value = default;
                return false;
            }
        }

        return true;
    }

    private static string BuildSyntheticAzureAcaOutputs(AzureLiveSettings settings)
    {
        return JsonSerializer.Serialize(new
        {
            validation_contract = new { value = new { tests = new { base_url = NormalizeBaseUrl($"https://{settings.AcaNamePrefix}.example.test") }, artifacts = new { resource_group = $"{settings.AcaNamePrefix}-{settings.Environment}-rg", workload_name = settings.AcaNamePrefix } } },
            deployment_contract = new { value = new { endpoints = new { public_base_url = NormalizeBaseUrl($"https://{settings.AcaNamePrefix}.example.test") }, dependencies = new { database = new { host = settings.ExistingDbFqdn ?? "dry-run-db" } } } },
        });
    }

    private static string BuildSyntheticAzureFunctionsOutputs(AzureLiveSettings settings)
    {
        return JsonSerializer.Serialize(new
        {
            validation_contract = new { value = new { tests = new { base_url = NormalizeBaseUrl($"https://{settings.FunctionsNamePrefix}.example.test") }, artifacts = new { resource_group = $"{settings.FunctionsNamePrefix}-{settings.Environment}-rg", workload_name = settings.FunctionsNamePrefix } } },
            deployment_contract = new { value = new { endpoints = new { public_base_url = NormalizeBaseUrl($"https://{settings.FunctionsNamePrefix}.example.test") }, dependencies = new { database = new { host = settings.ExistingDbFqdn ?? "dry-run-db" } }, rollout = new { current_revision = "dry-run-current", desired_revision = "dry-run-desired" } } },
        });
    }

    private static async Task EnsureExistingVpcPrivateEgressAsync(RunnerContext context, AwsLiveSettings settings, AwsLiveState state, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun || !settings.AutoRepairVpcEgress || !state.HasReusableDataInputs)
        {
            return;
        }

        Console.WriteLine("[runner] Reused AWS VPC egress repair is enabled; assuming existing private subnets already have outbound routing");
    }

    private static async Task AuthorizeExistingAwsDbIngressAsync(RunnerContext context, AwsLiveSettings settings, AwsLiveState state, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (context.DryRun || string.IsNullOrWhiteSpace(state.ExistingDbEndpoint) || string.IsNullOrWhiteSpace(settings.DbIngressCidr))
        {
            return;
        }

        var groupsRaw = await context.ProcessRunner.CaptureAsync("aws", ["rds", "describe-db-instances", "--query", $"DBInstances[?Endpoint.Address=='{state.ExistingDbEndpoint}'].VpcSecurityGroups[].VpcSecurityGroupId", "--output", "text"], context.RepoRoot, credentialsEnvironment);
        foreach (var groupId in groupsRaw.Split(['\t', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            try
            {
                var permissions = $"[{{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"IpRanges\":[{{\"CidrIp\":\"{settings.DbIngressCidr}\",\"Description\":\"Honua validation runner {settings.ValidationRunId}\"}}]}}]";
                await context.ProcessRunner.RunAsync("aws", ["ec2", "authorize-security-group-ingress", "--group-id", groupId, "--ip-permissions", permissions], context.RepoRoot, credentialsEnvironment);
                state.DbIngressSecurityGroupIds.Add(groupId);
            }
            catch
            {
                // Security group may already allow the ingress.
            }
        }
    }

    private static async Task RevokeExistingAwsDbIngressAsync(RunnerContext context, AwsLiveSettings settings, AwsLiveState state, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        foreach (var groupId in state.DbIngressSecurityGroupIds)
        {
            var permissions = $"[{{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"IpRanges\":[{{\"CidrIp\":\"{settings.DbIngressCidr}\"}}]}}]";
            await context.ProcessRunner.RunAsync("aws", ["ec2", "revoke-security-group-ingress", "--group-id", groupId, "--ip-permissions", permissions], context.RepoRoot, credentialsEnvironment);
        }
    }

    private static async Task ApplyAwsDataStackAsync(
        RunnerContext context,
        AwsLiveSettings settings,
        AwsLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "aws-data");
        var terraformEnvironment = BuildAwsDataEnvironment(settings, validationEnvironment);
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, terraformEnvironment);
        state.DataApplied = true;
        await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, "data.tfplan", "aws-data", settings.AllowDestroyPlan);

        if (context.DryRun)
        {
            state.DataCreated = true;
            state.ExistingDbEndpoint = $"{settings.DataNamePrefix}.{settings.Region}.rds.amazonaws.com";
            state.ExistingDbConnectionString = BuildDryRunConnectionString(state.ExistingDbEndpoint);
            state.ExistingRedisConnectionString = $"redis://:{settings.AdminPassword}@{settings.DataNamePrefix}.cache.amazonaws.com:6379";
            state.ExistingVpcId = "vpc-dryrun";
            state.ExistingVpcCidr = "10.42.0.0/16";
            state.ExistingPublicSubnetIdsJson = """["subnet-public-a","subnet-public-b"]""";
            state.ExistingPrivateSubnetIdsJson = """["subnet-private-a","subnet-private-b"]""";
            state.HasReusableDataInputs = true;
            PersistAwsDataReuseCache(settings, state);
            return;
        }

        var outputs = await CaptureTerraformOutputsJsonAsync(context, terraformRoot, terraformEnvironment);
        state.DataCreated = true;
        state.ExistingDbEndpoint = GetTerraformDatabaseHost(outputs);
        state.ExistingDbConnectionString = await ReadAwsSecretAsync(context, GetTerraformDatabaseSecretRef(outputs), credentialsEnvironment);
        state.ExistingRedisConnectionString = await ReadAwsSecretAsync(context, GetTerraformCacheSecretRef(outputs), credentialsEnvironment);
        state.ExistingVpcId = GetTerraformNetworkId(outputs);
        state.ExistingVpcCidr = GetTerraformNetworkCidr(outputs);
        state.ExistingPublicSubnetIdsJson = GetTerraformPublicSubnetIdsJson(outputs);
        state.ExistingPrivateSubnetIdsJson = GetTerraformPrivateSubnetIdsJson(outputs);
        state.HasReusableDataInputs = true;
        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, terraformRoot, terraformEnvironment);
        }

        PersistAwsDataReuseCache(settings, state);
    }

    private static async Task ApplyAwsEcsStackAsync(
        RunnerContext context,
        AwsLiveSettings settings,
        AwsLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace,
        IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "aws");
        state.EcsApplied = true;
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, BuildAwsEcsEnvironment(settings, state, validationEnvironment, settings.EcsImage, settings.EcsDesiredCount));

        async Task ApplyRevisionAsync(string image, int desiredCount, string label)
        {
            var terraformEnvironment = BuildAwsEcsEnvironment(settings, state, validationEnvironment, image, desiredCount);
            await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, $"{label}.tfplan", label, settings.AllowDestroyPlan);
            var outputs = await CaptureOrSynthesizeTerraformOutputsAsync(context, terraformRoot, terraformEnvironment, BuildSyntheticAwsEcsOutputs(settings));
            state.BaseUrl = NormalizeBaseUrl(GetTerraformBaseUrl(outputs) ?? $"https://{settings.EcsNamePrefix}.example.test");
            state.DbHost = GetTerraformDatabaseHost(outputs) ?? state.ExistingDbEndpoint;
            state.ClusterName = GetTerraformClusterName(outputs) ?? $"{settings.EcsNamePrefix}-cluster";
            state.WorkloadName = GetTerraformWorkloadName(outputs) ?? $"{settings.EcsNamePrefix}-service";
            state.CanaryEnabled = settings.EcsCanaryEnabled;
            state.CanaryServiceName = $"{settings.EcsNamePrefix}-canary";
            state.CanaryHeaderName = settings.EcsCanaryHeaderName;
            state.CanaryHeaderValue = settings.EcsCanaryHeaderValue;
            await RunCloudHttpChecksAsync(context, settings.AdminPassword, state.BaseUrl, settings.TimeoutSeconds, settings.ReadySloSeconds, settings.LoadRequests, settings.LoadConcurrency, settings.MaxLoadErrorRatePercent, settings.SkipProtocolChecks);
            if (state.CanaryEnabled && !context.DryRun)
            {
                await WaitForEcsRunningCountAsync(context, credentialsEnvironment, state.ClusterName!, state.CanaryServiceName!, settings.EcsCanaryDesiredCount, settings.TimeoutSeconds);
            }
            await RunCloudPlatformValidationAsync(context, validationEnvironment, state.BaseUrl, "aws-ecs", outputs, state.DbHost!, settings.AdminPassword, settings.DbAdminPassword);
        }

        if (settings.RunUpgradeRollback)
        {
            if (string.IsNullOrWhiteSpace(settings.EcsPreviousImage) || string.Equals(settings.EcsPreviousImage, settings.EcsImage, StringComparison.Ordinal))
            {
                throw new ValidationException("ECS upgrade/rollback requires HONUA_AWS_ECS_PREVIOUS_IMAGE different from HONUA_AWS_ECS_IMAGE.");
            }

            await ApplyRevisionAsync(settings.EcsPreviousImage!, settings.EcsDesiredCount, "ecs-previous");
            await ApplyRevisionAsync(settings.EcsImage, settings.EcsDesiredCount, "ecs-upgrade");
            if (!settings.SkipScaleCheck)
            {
                await ApplyRevisionAsync(settings.EcsImage, settings.EcsScaleTargetDesiredCount, "ecs-scale");
                await ApplyRevisionAsync(settings.EcsImage, settings.EcsDesiredCount, "ecs-scale-reset");
            }
            await ApplyRevisionAsync(settings.EcsPreviousImage!, settings.EcsDesiredCount, "ecs-rollback");
        }
        else
        {
            await ApplyRevisionAsync(settings.EcsImage, settings.EcsDesiredCount, "ecs");
        }

        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, terraformRoot, BuildAwsEcsEnvironment(settings, state, validationEnvironment, settings.EcsImage, settings.EcsDesiredCount));
        }
    }

    private static async Task ApplyAwsServerlessStackAsync(
        RunnerContext context,
        AwsLiveSettings settings,
        AwsLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace)
    {
        var terraformRoot = Path.Combine(workspace.TerraformRoot, "examples", "aws-serverless");
        await EnsureLambdaCanPullEcrImageAsync(context, settings.ServerlessImage, validationEnvironment, settings.Region);
        state.ServerlessApplied = true;
        await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + terraformRoot, "init", "-input=false", "-no-color"], context.RepoRoot, BuildAwsServerlessEnvironment(settings, state, validationEnvironment, settings.ServerlessImage, null));

        string? currentRevision = null;
        string? desiredRevision = null;

        async Task ApplyRevisionAsync(string image, string? aliasVersion, string label, bool runPlatformValidation)
        {
            var terraformEnvironment = BuildAwsServerlessEnvironment(settings, state, validationEnvironment, image, aliasVersion);
            await RunTerraformPlanApplyAsync(context, terraformRoot, terraformEnvironment, settings.PlanArtifactDir, $"{label}.tfplan", label, settings.AllowDestroyPlan);
            var outputs = await CaptureOrSynthesizeTerraformOutputsAsync(context, terraformRoot, terraformEnvironment, BuildSyntheticAwsServerlessOutputs(settings));
            state.BaseUrl = NormalizeBaseUrl(GetTerraformBaseUrl(outputs) ?? $"https://{settings.ServerlessNamePrefix}.example.test");
            state.DbHost = GetTerraformDatabaseHost(outputs) ?? state.ExistingDbEndpoint;
            state.WorkloadName = GetTerraformWorkloadName(outputs) ?? $"{settings.ServerlessNamePrefix}-lambda";
            state.CurrentRevision = GetTerraformCurrentRevision(outputs) ?? "dry-run-current";
            state.DesiredRevision = GetTerraformDesiredRevision(outputs) ?? "dry-run-desired";
            await RunCloudHttpChecksAsync(context, settings.AdminPassword, state.BaseUrl, settings.TimeoutSeconds, settings.ReadySloSeconds, settings.LoadRequests == 120 ? 40 : settings.LoadRequests, settings.LoadConcurrency == 20 ? 5 : settings.LoadConcurrency, settings.MaxLoadErrorRatePercent, settings.SkipProtocolChecks);
            if (runPlatformValidation)
            {
                await RunCloudPlatformValidationAsync(context, validationEnvironment, state.BaseUrl, "aws-lambda", outputs, state.DbHost!, settings.AdminPassword, settings.DbAdminPassword, currentRevision, desiredRevision, settings.RunUpgradeRollback);
            }
        }

        if (settings.RunUpgradeRollback)
        {
            if (string.IsNullOrWhiteSpace(settings.ServerlessPreviousImage) || string.Equals(settings.ServerlessPreviousImage, settings.ServerlessImage, StringComparison.Ordinal))
            {
                throw new ValidationException("Serverless upgrade/rollback requires HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE different from HONUA_AWS_SERVERLESS_IMAGE.");
            }

            await ApplyRevisionAsync(settings.ServerlessPreviousImage!, null, "serverless-previous", false);
            currentRevision = state.CurrentRevision;
            await ApplyRevisionAsync(settings.ServerlessImage, currentRevision, "serverless-stage-current", true);
            desiredRevision = state.DesiredRevision;
            if (!settings.AutoDestroy)
            {
                await ApplyRevisionAsync(settings.ServerlessImage, null, "serverless-reconcile-current", false);
            }
        }
        else
        {
            await ApplyRevisionAsync(settings.ServerlessImage, null, "serverless", true);
        }

        if (!settings.SkipIdempotency)
        {
            await AssertIdempotentPlanAsync(context, terraformRoot, BuildAwsServerlessEnvironment(settings, state, validationEnvironment, settings.ServerlessImage, null));
        }
    }

    private static async Task DestroyAwsStacksAsync(
        RunnerContext context,
        AwsLiveSettings settings,
        AwsLiveState state,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        IsolatedTerraformWorkspace workspace)
    {
        if (state.EcsApplied)
        {
            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + Path.Combine(workspace.TerraformRoot, "examples", "aws"), "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, BuildAwsEcsEnvironment(settings, state, validationEnvironment, settings.EcsImage, settings.EcsDesiredCount));
        }

        if (state.ServerlessApplied)
        {
            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + Path.Combine(workspace.TerraformRoot, "examples", "aws-serverless"), "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, BuildAwsServerlessEnvironment(settings, state, validationEnvironment, settings.ServerlessImage, null));
        }

        if (state.DataApplied && state.DataCreated && settings.DestroyData)
        {
            await context.ProcessRunner.RunAsync("terraform", ["-chdir=" + Path.Combine(workspace.TerraformRoot, "examples", "aws-data"), "destroy", "-input=false", "-auto-approve", "-no-color"], context.RepoRoot, BuildAwsDataEnvironment(settings, validationEnvironment));
            ClearDataReuseCache(settings.DataCacheFile);
        }
    }

    private static Dictionary<string, string?> BuildAwsDataEnvironment(AwsLiveSettings settings, IReadOnlyDictionary<string, string?> baseEnvironment)
    {
        return new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_IN_AUTOMATION"] = "true",
            ["AWS_REGION"] = settings.Region,
            ["AWS_DEFAULT_REGION"] = settings.Region,
            ["TF_VAR_region"] = settings.Region,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = settings.DataNamePrefix,
            ["TF_VAR_honua_admin_password"] = settings.AdminPassword,
            ["TF_VAR_db_password"] = settings.DbAdminPassword,
            ["TF_VAR_existing_db_endpoint"] = string.Empty,
            ["TF_VAR_existing_db_connection_string"] = string.Empty,
            ["TF_VAR_existing_vpc_id"] = string.Empty,
            ["TF_VAR_existing_vpc_cidr"] = string.Empty,
            ["TF_VAR_existing_public_subnet_ids"] = "[]",
            ["TF_VAR_existing_private_subnet_ids"] = "[]",
            ["TF_VAR_enable_postgis"] = "true",
            ["TF_VAR_redis_enabled"] = "true",
            ["TF_VAR_redis_connection_string"] = string.Empty,
            ["TF_VAR_db_publicly_accessible"] = "true",
            ["TF_VAR_allow_http_ingress_cidrs"] = JsonSerializer.Serialize(new[] { settings.HttpIngressCidr! }),
            ["TF_VAR_db_additional_ingress_cidrs"] = JsonSerializer.Serialize(new[] { settings.DbIngressCidr! }),
            ["TF_VAR_tags"] = BuildValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
        };
    }

    private static Dictionary<string, string?> BuildAwsEcsEnvironment(AwsLiveSettings settings, AwsLiveState state, IReadOnlyDictionary<string, string?> baseEnvironment, string image, int desiredCount)
    {
        return BuildAwsAppEnvironment(settings, state, baseEnvironment, "ecs", image, desiredCount, null);
    }

    private static Dictionary<string, string?> BuildAwsServerlessEnvironment(AwsLiveSettings settings, AwsLiveState state, IReadOnlyDictionary<string, string?> baseEnvironment, string image, string? aliasVersion)
    {
        return BuildAwsAppEnvironment(settings, state, baseEnvironment, "serverless", image, null, aliasVersion);
    }

    private static Dictionary<string, string?> BuildAwsAppEnvironment(AwsLiveSettings settings, AwsLiveState state, IReadOnlyDictionary<string, string?> baseEnvironment, string kind, string image, int? desiredCount, string? aliasVersion)
    {
        var reusingExistingData = !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString);
        var environment = new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_IN_AUTOMATION"] = "true",
            ["AWS_REGION"] = settings.Region,
            ["AWS_DEFAULT_REGION"] = settings.Region,
            ["TF_VAR_region"] = settings.Region,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_honua_admin_password"] = settings.AdminPassword,
            ["TF_VAR_db_password"] = settings.DbAdminPassword,
            ["TF_VAR_existing_db_endpoint"] = state.ExistingDbEndpoint,
            ["TF_VAR_existing_db_connection_string"] = state.ExistingDbConnectionString,
            ["TF_VAR_existing_vpc_id"] = state.ExistingVpcId,
            ["TF_VAR_existing_vpc_cidr"] = state.ExistingVpcCidr,
            ["TF_VAR_existing_public_subnet_ids"] = state.ExistingPublicSubnetIdsJson ?? "[]",
            ["TF_VAR_existing_private_subnet_ids"] = state.ExistingPrivateSubnetIdsJson ?? "[]",
            ["TF_VAR_enable_postgis"] = (!reusingExistingData).ToString().ToLowerInvariant(),
            ["TF_VAR_redis_enabled"] = "true",
            ["TF_VAR_redis_connection_string"] = state.ExistingRedisConnectionString,
            ["TF_VAR_redis_connection_cidrs"] = string.IsNullOrWhiteSpace(state.ExistingRedisConnectionString) || string.IsNullOrWhiteSpace(state.ExistingVpcCidr)
                ? "[]"
                : JsonSerializer.Serialize(new[] { state.ExistingVpcCidr }),
            ["TF_VAR_db_publicly_accessible"] = "true",
            ["TF_VAR_allow_http_ingress_cidrs"] = JsonSerializer.Serialize(new[] { settings.HttpIngressCidr! }),
            ["TF_VAR_db_additional_ingress_cidrs"] = string.IsNullOrWhiteSpace(state.ExistingDbConnectionString) ? JsonSerializer.Serialize(new[] { settings.DbIngressCidr! }) : "[]",
            ["TF_VAR_tags"] = BuildValidationTagsJson(settings.ValidationRunId, settings.TtlHours),
        };

        if (kind == "ecs")
        {
            environment["TF_VAR_name_prefix"] = settings.EcsNamePrefix;
            environment["TF_VAR_honua_image"] = image;
            environment["TF_VAR_desired_count"] = desiredCount?.ToString(CultureInfo.InvariantCulture);
            environment["TF_VAR_alb_deletion_protection"] = "false";
            environment["TF_VAR_canary_enabled"] = settings.EcsCanaryEnabled.ToString().ToLowerInvariant();
            environment["TF_VAR_canary_image"] = settings.EcsCanaryImage ?? image;
            environment["TF_VAR_canary_desired_count"] = settings.EcsCanaryDesiredCount.ToString(CultureInfo.InvariantCulture);
            environment["TF_VAR_canary_weight_percentage"] = settings.EcsCanaryWeightPercentage.ToString(CultureInfo.InvariantCulture);
            environment["TF_VAR_canary_header_name"] = settings.EcsCanaryHeaderName;
            environment["TF_VAR_canary_header_value"] = settings.EcsCanaryHeaderValue;
        }
        else
        {
            environment["TF_VAR_name_prefix"] = settings.ServerlessNamePrefix;
            environment["TF_VAR_honua_image_uri"] = image;
            environment["TF_VAR_skip_migrations"] = "true";
            if (!string.IsNullOrWhiteSpace(aliasVersion))
            {
                environment["TF_VAR_lambda_alias_version"] = aliasVersion;
            }
        }

        return environment;
    }

    private static async Task<string> ReadAwsSecretAsync(RunnerContext context, string? secretArn, IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        if (string.IsNullOrWhiteSpace(secretArn))
        {
            throw new ValidationException("AWS secret reference was empty");
        }

        return await context.ProcessRunner.CaptureAsync("aws", ["secretsmanager", "get-secret-value", "--secret-id", secretArn, "--query", "SecretString", "--output", "text"], context.RepoRoot, credentialsEnvironment, redactOutput: true);
    }

    private static async Task WaitForEcsRunningCountAsync(RunnerContext context, IReadOnlyDictionary<string, string?> credentialsEnvironment, string clusterName, string serviceName, int expectedMinCount, int timeoutSeconds)
    {
        var startedAt = DateTimeOffset.UtcNow;
        while (true)
        {
            var countRaw = await context.ProcessRunner.CaptureAsync("aws", ["ecs", "describe-services", "--cluster", clusterName, "--services", serviceName, "--query", "services[0].runningCount", "--output", "text"], context.RepoRoot, credentialsEnvironment);
            if (int.TryParse(countRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) && count >= expectedMinCount)
            {
                return;
            }

            if ((DateTimeOffset.UtcNow - startedAt).TotalSeconds > timeoutSeconds)
            {
                throw new ValidationException($"Timed out waiting for ECS running count >= {expectedMinCount}");
            }

            await Task.Delay(TimeSpan.FromSeconds(15));
        }
    }

    private static async Task EnsureLambdaCanPullEcrImageAsync(
        RunnerContext context,
        string image,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string region)
    {
        if (!TryGetEcrRepositoryName(image, region, out var repositoryName))
        {
            return;
        }

        var (hasExistingPolicy, existingPolicyText) = await context.ProcessRunner.TryCaptureAsync(
            "aws",
            ["ecr", "get-repository-policy", "--repository-name", repositoryName, "--query", "policyText", "--output", "text"],
            context.RepoRoot,
            credentialsEnvironment,
            redactOutput: true);

        using var policyDocument = JsonDocument.Parse(hasExistingPolicy && !string.IsNullOrWhiteSpace(existingPolicyText) && existingPolicyText != "None"
            ? existingPolicyText
            : """{"Version":"2012-10-17","Statement":[]}""");
        var existingPolicyRoot = policyDocument.RootElement.Clone();
        if (PolicyAllowsLambdaImagePull(existingPolicyRoot))
        {
            return;
        }

        var statements = new List<object>();
        if (existingPolicyRoot.TryGetProperty("Statement", out var existingStatements))
        {
            if (existingStatements.ValueKind == JsonValueKind.Array)
            {
                foreach (var statement in existingStatements.EnumerateArray())
                {
                    statements.Add(JsonSerializer.Deserialize<object>(statement.GetRawText())!);
                }
            }
            else
            {
                statements.Add(JsonSerializer.Deserialize<object>(existingStatements.GetRawText())!);
            }
        }

        statements.Add(new
        {
            Sid = "AllowLambdaImageRetrieval",
            Effect = "Allow",
            Principal = new { Service = "lambda.amazonaws.com" },
            Action = new[] { "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer" }
        });

        var mergedPolicy = JsonSerializer.Serialize(new
        {
            Version = existingPolicyRoot.TryGetProperty("Version", out var version) ? version.GetString() ?? "2012-10-17" : "2012-10-17",
            Statement = statements
        });

        await context.ProcessRunner.RunAsync(
            "aws",
            ["ecr", "set-repository-policy", "--repository-name", repositoryName, "--policy-text", mergedPolicy, "--force"],
            context.RepoRoot,
            credentialsEnvironment);
    }

    private static bool TryGetEcrRepositoryName(string image, string region, out string repositoryName)
    {
        repositoryName = string.Empty;
        if (string.IsNullOrWhiteSpace(image))
        {
            return false;
        }

        var imageWithoutDigest = image.Split('@', 2, StringSplitOptions.TrimEntries)[0];
        var parts = imageWithoutDigest.Split('/', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || !parts[0].EndsWith($".dkr.ecr.{region}.amazonaws.com", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        repositoryName = string.Join("/", parts[1..]);
        var tagIndex = repositoryName.LastIndexOf(':');
        if (tagIndex >= 0)
        {
            repositoryName = repositoryName[..tagIndex];
        }

        return !string.IsNullOrWhiteSpace(repositoryName);
    }

    private static bool PolicyAllowsLambdaImagePull(JsonElement policyRoot)
    {
        if (!policyRoot.TryGetProperty("Statement", out var statements))
        {
            return false;
        }

        var elements = statements.ValueKind == JsonValueKind.Array
            ? statements.EnumerateArray().ToArray()
            : new[] { statements };
        foreach (var statement in elements)
        {
            if (StatementAllowsLambdaImagePull(statement))
            {
                return true;
            }
        }

        return false;
    }

    private static bool StatementAllowsLambdaImagePull(JsonElement statement)
    {
        if (!statement.TryGetProperty("Effect", out var effect) ||
            !string.Equals(effect.GetString(), "Allow", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!statement.TryGetProperty("Principal", out var principal) ||
            !principal.TryGetProperty("Service", out var service))
        {
            return false;
        }

        var services = service.ValueKind == JsonValueKind.Array
            ? service.EnumerateArray().Select(static value => value.GetString())
            : new[] { service.GetString() };
        if (!services.Any(static value => string.Equals(value, "lambda.amazonaws.com", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        if (!statement.TryGetProperty("Action", out var action))
        {
            return false;
        }

        var actions = action.ValueKind == JsonValueKind.Array
            ? action.EnumerateArray()
                .Select(static value => value.GetString())
                .Where(static value => !string.IsNullOrWhiteSpace(value))
                .Select(static value => value!)
                .ToHashSet(StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(new[] { action.GetString() ?? string.Empty }, StringComparer.OrdinalIgnoreCase);
        return actions.Contains("ecr:BatchGetImage") && actions.Contains("ecr:GetDownloadUrlForLayer");
    }

    private static string? GetTerraformClusterName(string rawJson) => GetTerraformOutputString(rawJson,
        ["validation_contract", "value", "artifacts", "cluster_name"],
        ["deployment_contract", "value", "workload", "cluster_name"],
        ["ecs_cluster_name", "value"],
        ["cluster_name", "value"]);

    private static string? GetTerraformNetworkId(string rawJson) => GetTerraformOutputString(rawJson, ["vpc_id", "value"]);

    private static string? GetTerraformNetworkCidr(string rawJson) => GetTerraformOutputString(rawJson, ["vpc_cidr", "value"]);

    private static string? GetTerraformPublicSubnetIdsJson(string rawJson) => GetTerraformOutputRawJson(rawJson, ["public_subnet_ids", "value"]);

    private static string? GetTerraformPrivateSubnetIdsJson(string rawJson) => GetTerraformOutputRawJson(rawJson, ["private_subnet_ids", "value"]);

    private static string? GetTerraformOutputRawJson(string rawJson, params string[][] candidatePaths)
    {
        using var document = JsonDocument.Parse(rawJson);
        foreach (var path in candidatePaths)
        {
            if (TryGetJsonPath(document.RootElement, path, out var value))
            {
                return value.GetRawText();
            }
        }

        return null;
    }

    private static void PersistAwsDataReuseCache(AwsLiveSettings settings, AwsLiveState state)
    {
        WriteKeyValueCache(settings.DataCacheFile, AwsDataCacheFormat, new Dictionary<string, string?>
        {
            ["EXISTING_DB_ENDPOINT"] = state.ExistingDbEndpoint,
            ["EXISTING_DB_CONNECTION_STRING"] = state.ExistingDbConnectionString,
            ["EXISTING_REDIS_CONNECTION_STRING"] = state.ExistingRedisConnectionString,
            ["EXISTING_VPC_ID"] = state.ExistingVpcId,
            ["EXISTING_VPC_CIDR"] = state.ExistingVpcCidr,
            ["EXISTING_PUBLIC_SUBNET_IDS"] = state.ExistingPublicSubnetIdsJson,
            ["EXISTING_PRIVATE_SUBNET_IDS"] = state.ExistingPrivateSubnetIdsJson,
        });
    }

    private static string BuildSyntheticAwsEcsOutputs(AwsLiveSettings settings)
    {
        return JsonSerializer.Serialize(new
        {
            validation_contract = new { value = new { tests = new { base_url = NormalizeBaseUrl($"https://{settings.EcsNamePrefix}.example.test") }, artifacts = new { workload_name = $"{settings.EcsNamePrefix}-service", cluster_name = $"{settings.EcsNamePrefix}-cluster" } } },
            deployment_contract = new { value = new { endpoints = new { public_base_url = NormalizeBaseUrl($"https://{settings.EcsNamePrefix}.example.test") }, dependencies = new { database = new { host = settings.ExistingDbEndpoint ?? "dry-run-db" } } } },
        });
    }

    private static string BuildSyntheticAwsServerlessOutputs(AwsLiveSettings settings)
    {
        return JsonSerializer.Serialize(new
        {
            validation_contract = new { value = new { tests = new { base_url = NormalizeBaseUrl($"https://{settings.ServerlessNamePrefix}.example.test") }, artifacts = new { workload_name = $"{settings.ServerlessNamePrefix}-lambda" } } },
            deployment_contract = new { value = new { endpoints = new { public_base_url = NormalizeBaseUrl($"https://{settings.ServerlessNamePrefix}.example.test") }, dependencies = new { database = new { host = settings.ExistingDbEndpoint ?? "dry-run-db" } }, rollout = new { current_revision = "dry-run-current", desired_revision = "dry-run-desired" } } },
        });
    }

    private sealed class AzureLiveSettings
    {
        public required AzureStack Stack { get; init; }
        public required string Location { get; init; }
        public required string Environment { get; init; }
        public required string DataNamePrefix { get; init; }
        public required string AcaNamePrefix { get; init; }
        public required string FunctionsNamePrefix { get; init; }
        public required string PlanArtifactDir { get; init; }
        public required string ValidationRunId { get; init; }
        public required string AdminPassword { get; init; }
        public required string DbAdminPassword { get; init; }
        public required decimal MaxRunCostUsd { get; init; }
        public required int TimeoutSeconds { get; init; }
        public required int ReadySloSeconds { get; init; }
        public required decimal MaxLoadErrorRatePercent { get; init; }
        public required int LoadRequests { get; init; }
        public required int LoadConcurrency { get; init; }
        public required int TtlHours { get; init; }
        public required bool AllowDestroyPlan { get; init; }
        public required bool AutoDestroy { get; init; }
        public required bool DestroyData { get; init; }
        public required bool SkipQuotaPreflight { get; init; }
        public required bool SkipIdempotency { get; init; }
        public required bool SkipProtocolChecks { get; init; }
        public required bool SkipScaleCheck { get; init; }
        public required bool RunUpgradeRollback { get; init; }
        public required string AcaImage { get; init; }
        public string? AcaPreviousImage { get; init; }
        public required string FunctionsImage { get; init; }
        public string? FunctionsPreviousImage { get; init; }
        public required string FunctionsPlanSku { get; init; }
        public required bool FunctionsSkipMigrations { get; init; }
        public required bool FunctionsDeploymentSlotEnabled { get; init; }
        public required string FunctionsDeploymentSlotName { get; init; }
        public string? FunctionsDeploymentSlotImage { get; init; }
        public required int AcaMinReplicas { get; init; }
        public required int AcaMaxReplicas { get; init; }
        public required int AcaScaleTargetMinReplicas { get; init; }
        public string? RegistryResourceId { get; set; }
        public string? RegistryServer { get; set; }
        public string? RegistryUsername { get; set; }
        public string? RegistryPassword { get; set; }
        public required string DataCacheFile { get; init; }
        public required bool ForceNewDataInfra { get; init; }
        public string? ExistingDbFqdn { get; set; }
        public string? ExistingDbResourceGroup { get; set; }
        public string? ExistingDbConnectionString { get; set; }
        public string? ExistingRedisConnectionString { get; set; }
        public string? DbFirewallStartIp { get; set; }
        public string? DbFirewallEndIp { get; set; }
    }

    private sealed class AwsLiveSettings
    {
        public required AwsStack Stack { get; init; }
        public required string Region { get; init; }
        public required string Environment { get; init; }
        public required string DataNamePrefix { get; init; }
        public required string EcsNamePrefix { get; init; }
        public required string ServerlessNamePrefix { get; init; }
        public required string PlanArtifactDir { get; init; }
        public required string ValidationRunId { get; init; }
        public required string AdminPassword { get; init; }
        public required string DbAdminPassword { get; init; }
        public required decimal MaxRunCostUsd { get; init; }
        public required int TimeoutSeconds { get; init; }
        public required int ReadySloSeconds { get; init; }
        public required decimal MaxLoadErrorRatePercent { get; init; }
        public required int LoadRequests { get; init; }
        public required int LoadConcurrency { get; init; }
        public required int TtlHours { get; init; }
        public required bool AllowDestroyPlan { get; init; }
        public required bool AutoDestroy { get; init; }
        public required bool DestroyData { get; init; }
        public required bool SkipQuotaPreflight { get; init; }
        public required bool SkipIdempotency { get; init; }
        public required bool SkipProtocolChecks { get; init; }
        public required bool SkipScaleCheck { get; init; }
        public required bool RunUpgradeRollback { get; init; }
        public required string EcsImage { get; init; }
        public string? EcsPreviousImage { get; init; }
        public required bool EcsCanaryEnabled { get; init; }
        public string? EcsCanaryImage { get; init; }
        public required int EcsCanaryDesiredCount { get; init; }
        public required int EcsCanaryWeightPercentage { get; init; }
        public required string EcsCanaryHeaderName { get; init; }
        public required string EcsCanaryHeaderValue { get; init; }
        public required int EcsDesiredCount { get; init; }
        public required int EcsScaleTargetDesiredCount { get; init; }
        public required string ServerlessImage { get; init; }
        public string? ServerlessPreviousImage { get; init; }
        public required string DataCacheFile { get; init; }
        public required bool ForceNewDataInfra { get; init; }
        public required bool AutoRepairVpcEgress { get; init; }
        public string? ExistingDbEndpoint { get; set; }
        public string? ExistingDbConnectionString { get; set; }
        public string? ExistingRedisConnectionString { get; set; }
        public string? ExistingVpcId { get; set; }
        public string? ExistingVpcCidr { get; set; }
        public string? ExistingPublicSubnetIdsJson { get; set; }
        public string? ExistingPrivateSubnetIdsJson { get; set; }
        public string? DbIngressCidr { get; set; }
        public string? HttpIngressCidr { get; set; }
    }

    private sealed class AzureLiveState
    {
        public bool HasReusableDataInputs { get; set; }
        public bool DataApplied { get; set; }
        public bool DataCreated { get; set; }
        public bool AcaApplied { get; set; }
        public bool FunctionsApplied { get; set; }
        public string? ExistingDbFqdn { get; set; }
        public string? ExistingDbConnectionString { get; set; }
        public string? ExistingRedisConnectionString { get; set; }
        public string? DataResourceGroup { get; set; }
        public string? BaseUrl { get; set; }
        public string? ActiveBaseUrl { get; set; }
        public string? DbHost { get; set; }
        public string? ResourceGroupName { get; set; }
        public string? WorkloadName { get; set; }
        public string? CurrentRevision { get; set; }
        public string? DesiredRevision { get; set; }
        public List<(string ResourceGroup, string ServerName, string RuleName)> AcaFirewallRules { get; } = [];
        public List<(string ResourceGroup, string ServerName, string RuleName)> RunnerFirewallRules { get; } = [];
    }

    private sealed class AwsLiveState
    {
        public bool HasReusableDataInputs { get; set; }
        public bool DataApplied { get; set; }
        public bool DataCreated { get; set; }
        public bool EcsApplied { get; set; }
        public bool ServerlessApplied { get; set; }
        public string? ExistingDbEndpoint { get; set; }
        public string? ExistingDbConnectionString { get; set; }
        public string? ExistingRedisConnectionString { get; set; }
        public string? ExistingVpcId { get; set; }
        public string? ExistingVpcCidr { get; set; }
        public string? ExistingPublicSubnetIdsJson { get; set; }
        public string? ExistingPrivateSubnetIdsJson { get; set; }
        public string? BaseUrl { get; set; }
        public string? DbHost { get; set; }
        public string? ClusterName { get; set; }
        public string? WorkloadName { get; set; }
        public string? CurrentRevision { get; set; }
        public string? DesiredRevision { get; set; }
        public bool CanaryEnabled { get; set; }
        public string? CanaryServiceName { get; set; }
        public string? CanaryHeaderName { get; set; }
        public string? CanaryHeaderValue { get; set; }
        public List<string> DbIngressSecurityGroupIds { get; } = [];
    }
}
