using System.Text.Json;
using System.Text.Json.Serialization;

namespace Honua.TerraformValidation.Runner;

internal static class ScenarioManifestLoader
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = false,
    };

    public static ScenarioManifest Load(RunnerContext context, ScenarioName scenario)
    {
        var manifestPath = context.ResolveRepoRelativePath($"infrastructure/terraform/validation/scenarios/{scenario.ToScenarioId()}.json");
        if (!File.Exists(manifestPath))
        {
            throw new ValidationException($"Scenario manifest was not found: {manifestPath}");
        }

        ScenarioManifest? manifest;
        try
        {
            manifest = JsonSerializer.Deserialize<ScenarioManifest>(File.ReadAllText(manifestPath), SerializerOptions);
        }
        catch (JsonException exception)
        {
            throw new ValidationException($"Failed to parse scenario manifest {manifestPath}: {exception.Message}");
        }

        if (manifest is null)
        {
            throw new ValidationException($"Scenario manifest was empty: {manifestPath}");
        }

        ValidateManifest(manifest, manifestPath, scenario);
        return manifest;
    }

    private static void ValidateManifest(ScenarioManifest manifest, string manifestPath, ScenarioName scenario)
    {
        if (!string.Equals(manifest.SchemaVersion, "v1", StringComparison.Ordinal))
        {
            throw new ValidationException($"Unsupported scenario manifest schema in {manifestPath}: {manifest.SchemaVersion}");
        }

        if (!string.Equals(manifest.Name, scenario.ToScenarioId(), StringComparison.Ordinal))
        {
            throw new ValidationException($"Scenario manifest name mismatch in {manifestPath}: expected '{scenario.ToScenarioId()}', found '{manifest.Name}'");
        }

        if (scenario is ScenarioName.AzureLive or ScenarioName.AwsLive or ScenarioName.AksLive or ScenarioName.EksLive)
        {
            if (string.IsNullOrWhiteSpace(manifest.PlanArtifactRoot))
            {
                throw new ValidationException($"Scenario manifest is missing planArtifactRoot: {manifestPath}");
            }
        }

        if (scenario is ScenarioName.AzureLive or ScenarioName.AwsLive or ScenarioName.AksLive or ScenarioName.EksLive)
        {
            if (string.IsNullOrWhiteSpace(manifest.BootstrapRoot))
            {
                throw new ValidationException($"Scenario manifest is missing bootstrapRoot: {manifestPath}");
            }

            if (manifest.BootstrapModules is null || manifest.BootstrapModules.Count == 0)
            {
                throw new ValidationException($"Scenario manifest is missing bootstrapModules: {manifestPath}");
            }
        }

        if (scenario == ScenarioName.Drift && manifest.DriftDefaults is null)
        {
            throw new ValidationException($"Drift scenario manifest is missing driftDefaults: {manifestPath}");
        }

        if (scenario == ScenarioName.PolicyGates && string.IsNullOrWhiteSpace(manifest.RootPath))
        {
            throw new ValidationException($"Policy gate scenario manifest is missing rootPath: {manifestPath}");
        }

        if (scenario == ScenarioName.PolicyGates)
        {
            if (manifest.TflintRoots is null || manifest.TflintRoots.Count == 0)
            {
                throw new ValidationException($"Policy gate scenario manifest is missing tflintRoots: {manifestPath}");
            }

            if (manifest.CheckovTargets is null || manifest.CheckovTargets.Count == 0)
            {
                throw new ValidationException($"Policy gate scenario manifest is missing checkovTargets: {manifestPath}");
            }

            if (manifest.TfsecTargets is null || manifest.TfsecTargets.Count == 0)
            {
                throw new ValidationException($"Policy gate scenario manifest is missing tfsecTargets: {manifestPath}");
            }
        }

        if (scenario == ScenarioName.StaticValidate)
        {
            if (manifest.FormatPaths is null || manifest.FormatPaths.Count == 0)
            {
                throw new ValidationException($"Static validate scenario manifest is missing formatPaths: {manifestPath}");
            }

            if (manifest.TerraformRoots is null || manifest.TerraformRoots.Count == 0)
            {
                throw new ValidationException($"Static validate scenario manifest is missing terraformRoots: {manifestPath}");
            }

            if (manifest.ModuleTestRoots is not null)
            {
                var invalidRoots = new List<string>();
                foreach (var moduleTestRoot in manifest.ModuleTestRoots)
                {
                    if (!manifest.TerraformRoots.Contains(moduleTestRoot, StringComparer.Ordinal))
                    {
                        invalidRoots.Add(moduleTestRoot);
                    }
                }

                if (invalidRoots.Count > 0)
                {
                    throw new ValidationException($"Static validate scenario manifest has moduleTestRoots outside terraformRoots: {string.Join(", ", invalidRoots)}");
                }
            }
        }
    }
}

internal sealed class ScenarioManifest
{
    [JsonPropertyName("schemaVersion")]
    public required string SchemaVersion { get; init; }

    [JsonPropertyName("name")]
    public required string Name { get; init; }

    [JsonPropertyName("kind")]
    public required string Kind { get; init; }

    [JsonPropertyName("planArtifactRoot")]
    public string? PlanArtifactRoot { get; init; }

    [JsonPropertyName("bootstrapRoot")]
    public string? BootstrapRoot { get; init; }

    [JsonPropertyName("bootstrapModules")]
    public Dictionary<string, BootstrapModuleManifest>? BootstrapModules { get; init; }

    [JsonPropertyName("driftDefaults")]
    public DriftDefaultsManifest? DriftDefaults { get; init; }

    [JsonPropertyName("defaults")]
    public Dictionary<string, string>? Defaults { get; init; }

    [JsonPropertyName("passthroughEnvironment")]
    public List<string>? PassthroughEnvironment { get; init; }

    [JsonPropertyName("formatPaths")]
    public List<string>? FormatPaths { get; init; }

    [JsonPropertyName("terraformRoots")]
    public List<string>? TerraformRoots { get; init; }

    [JsonPropertyName("moduleTestRoots")]
    public List<string>? ModuleTestRoots { get; init; }

    [JsonPropertyName("rootPath")]
    public string? RootPath { get; init; }

    [JsonPropertyName("tflintRoots")]
    public List<string>? TflintRoots { get; init; }

    [JsonPropertyName("checkovTargets")]
    public List<string>? CheckovTargets { get; init; }

    [JsonPropertyName("tfsecTargets")]
    public List<string>? TfsecTargets { get; init; }
}

internal sealed class BootstrapModuleManifest
{
    [JsonPropertyName("sourcePath")]
    public required string SourcePath { get; init; }

    [JsonPropertyName("appNameTemplate")]
    public string? AppNameTemplate { get; init; }

    [JsonPropertyName("roleNameTemplate")]
    public string? RoleNameTemplate { get; init; }

    [JsonPropertyName("userNameTemplate")]
    public string? UserNameTemplate { get; init; }

    public string ExpandAppName(RunnerContext context) => ExpandTemplate(AppNameTemplate, context);

    public string ExpandRoleName(RunnerContext context) => ExpandTemplate(RoleNameTemplate, context);

    public string ExpandUserName(RunnerContext context) => ExpandTemplate(UserNameTemplate, context);

    private static string ExpandTemplate(string? template, RunnerContext context)
    {
        if (string.IsNullOrWhiteSpace(template))
        {
            throw new ValidationException("Scenario bootstrap module template was not defined.");
        }

        return template
            .Replace("{runId}", context.GitHubRunId, StringComparison.Ordinal)
            .Replace("{runAttempt}", context.GitHubRunAttempt, StringComparison.Ordinal);
    }
}

internal sealed class DriftDefaultsManifest
{
    [JsonPropertyName("azureBaseRoots")]
    public required List<string> AzureBaseRoots { get; init; }

    [JsonPropertyName("azureManagedRoot")]
    public string? AzureManagedRoot { get; init; }

    [JsonPropertyName("awsBaseRoots")]
    public required List<string> AwsBaseRoots { get; init; }

    [JsonPropertyName("awsManagedRoot")]
    public string? AwsManagedRoot { get; init; }

    [JsonPropertyName("alwaysRoots")]
    public required List<string> AlwaysRoots { get; init; }
}

internal static class ScenarioNameExtensions
{
    public static string ToScenarioId(this ScenarioName scenario) =>
        scenario switch
        {
            ScenarioName.StaticValidate => "static-validate",
            ScenarioName.PolicyGates => "policy-gates",
            ScenarioName.AzureLive => "azure-live",
            ScenarioName.AwsLive => "aws-live",
            ScenarioName.K8sLive => "k8s-live",
            ScenarioName.AksLive => "aks-live",
            ScenarioName.EksLive => "eks-live",
            ScenarioName.Drift => "drift",
            _ => throw new ValidationException($"Unsupported scenario enum value: {scenario}"),
        };
}
