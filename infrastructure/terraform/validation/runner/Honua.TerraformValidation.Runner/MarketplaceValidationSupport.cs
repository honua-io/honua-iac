using System.Text.Json;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static readonly JsonSerializerOptions MarketplaceJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private static async Task ValidateMarketplaceAssetsAsync(RunnerContext context)
    {
        Console.WriteLine("[runner] Validating marketplace metadata and customer distribution");

        var marketplaceRoot = context.ResolveRepoPath("infrastructure", "terraform", "marketplace");
        RequireDirectory(marketplaceRoot, "marketplace metadata root");

        var targetsPath = Path.Combine(marketplaceRoot, "targets.json");
        EnsureFileExists(targetsPath, "marketplace target index");

        var targets = DeserializeJsonFile<MarketplaceTargetsDocument>(targetsPath, "marketplace target index");
        if (!string.Equals(targets.SchemaVersion, "v1", StringComparison.Ordinal))
        {
            throw new ValidationException($"Unsupported marketplace target index schema version '{targets.SchemaVersion}' in {targetsPath}");
        }

        if (targets.Targets.Count == 0)
        {
            throw new ValidationException($"Marketplace target index '{targetsPath}' does not define any targets.");
        }

        var bundleDirectory = Path.Combine(marketplaceRoot, "bundles");
        RequireDirectory(bundleDirectory, "marketplace bundle directory");

        var referencedBundlePaths = new HashSet<string>(StringComparer.Ordinal);
        foreach (var target in targets.Targets)
        {
            ValidateMarketplaceTarget(context, marketplaceRoot, target, referencedBundlePaths);
        }

        foreach (var bundlePath in Directory.GetFiles(bundleDirectory, "*.json", SearchOption.TopDirectoryOnly))
        {
            if (!referencedBundlePaths.Contains(Path.GetFullPath(bundlePath)))
            {
                throw new ValidationException($"Marketplace bundle manifest is not referenced by targets.json: {bundlePath}");
            }
        }

        var customerDistPath = context.ResolveTempPath("marketplace", "honua-terraform-customer-dist.tar.gz");
        Directory.CreateDirectory(Path.GetDirectoryName(customerDistPath)!);

        var packageScriptPath = context.ResolveRepoPath("scripts", "package-customer-dist.sh");
        EnsureFileExists(packageScriptPath, "customer distribution script");

        await context.ProcessRunner.RunAsync("bash", [packageScriptPath, customerDistPath], context.RepoRoot);
        if (context.DryRun)
        {
            return;
        }

        var archiveListing = await context.ProcessRunner.CaptureAsync("tar", ["-tzf", customerDistPath], context.RepoRoot);
        ValidateCustomerDistributionArchive(archiveListing, customerDistPath);

        Console.WriteLine("[runner] Marketplace metadata and customer distribution validated successfully");
    }

    private static void ValidateMarketplaceTarget(
        RunnerContext context,
        string marketplaceRoot,
        MarketplaceTarget target,
        ISet<string> referencedBundlePaths)
    {
        RequireNotBlank(target.Id, "marketplace target id");
        RequireNotBlank(target.ExampleRoot, $"marketplace target '{target.Id}' exampleRoot");
        RequireNotBlank(target.ModulePath, $"marketplace target '{target.Id}' modulePath");
        RequireNotBlank(target.Runtime, $"marketplace target '{target.Id}' runtime");
        RequireNotBlank(target.BundleProfile, $"marketplace target '{target.Id}' bundleProfile");

        RequireDirectory(
            ResolveRepoRelativePath(context, $"infrastructure/terraform/{target.ExampleRoot}"),
            $"marketplace target '{target.Id}' example root");
        RequireDirectory(
            ResolveRepoRelativePath(context, $"infrastructure/terraform/{target.ModulePath}"),
            $"marketplace target '{target.Id}' module path");

        if (target.TurnkeyRuntime)
        {
            RequireNotBlank(target.InstallSurfaceOutput, $"marketplace target '{target.Id}' installSurfaceOutput");
            RequireNotBlank(target.DeploySurfaceOutput, $"marketplace target '{target.Id}' deploySurfaceOutput");
        }

        if (!target.MarketplaceEligible && string.IsNullOrWhiteSpace(target.Reason) && !target.TurnkeyRuntime)
        {
            throw new ValidationException($"Marketplace target '{target.Id}' is not eligible and must explain why in reason.");
        }

        if (string.IsNullOrWhiteSpace(target.BundleManifest))
        {
            if (target.TurnkeyRuntime)
            {
                throw new ValidationException($"Marketplace target '{target.Id}' is turnkey and must declare a bundle manifest.");
            }

            return;
        }

        var bundlePath = Path.GetFullPath(Path.Combine(marketplaceRoot, target.BundleManifest));
        EnsureFileExists(bundlePath, $"marketplace bundle for target '{target.Id}'");
        if (!referencedBundlePaths.Add(bundlePath))
        {
            throw new ValidationException($"Marketplace bundle manifest is referenced more than once: {bundlePath}");
        }

        var bundle = DeserializeJsonFile<MarketplaceBundleManifest>(bundlePath, $"marketplace bundle '{target.Id}'");
        if (!string.Equals(bundle.TargetId, target.Id, StringComparison.Ordinal))
        {
            throw new ValidationException($"Marketplace bundle '{bundlePath}' targetId '{bundle.TargetId}' does not match targets.json id '{target.Id}'.");
        }

        if (!string.Equals(bundle.Runtime, target.Runtime, StringComparison.Ordinal))
        {
            throw new ValidationException($"Marketplace bundle '{bundlePath}' runtime '{bundle.Runtime}' does not match targets.json runtime '{target.Runtime}'.");
        }

        if (!string.Equals(bundle.BundleProfile, target.BundleProfile, StringComparison.Ordinal))
        {
            throw new ValidationException($"Marketplace bundle '{bundlePath}' bundleProfile '{bundle.BundleProfile}' does not match targets.json bundleProfile '{target.BundleProfile}'.");
        }

        if (bundle.MarketplaceEligible != target.MarketplaceEligible)
        {
            throw new ValidationException($"Marketplace bundle '{bundlePath}' eligibility does not match targets.json for target '{target.Id}'.");
        }

        ValidateInstallSurface(bundlePath, bundle.InstallSurface, target);
        ValidateDeploySurface(bundlePath, bundle.DeploySurface, target);

        if (target.MarketplaceEligible)
        {
            RequireNonEmptyCollection(bundle.SupportedRegions.Validated, $"marketplace bundle '{target.Id}' supported regions");
            RequireNonEmptyCollection(bundle.RequiredPermissions, $"marketplace bundle '{target.Id}' required permissions");
            RequireNonEmptyCollection(bundle.BillableComponents, $"marketplace bundle '{target.Id}' billable components");
            RequireNonEmptyCollection(bundle.ValidationScenarioRefs, $"marketplace bundle '{target.Id}' validation scenario refs");
            RequireNotBlank(bundle.UpgradePath.Strategy, $"marketplace bundle '{target.Id}' upgrade strategy");
            RequireNotBlank(bundle.UpgradePath.Rollback, $"marketplace bundle '{target.Id}' rollback strategy");
        }
    }

    private static void ValidateInstallSurface(string bundlePath, MarketplaceInstallSurface installSurface, MarketplaceTarget target)
    {
        RequireNotBlank(installSurface.InputVariable, $"marketplace install surface for '{target.Id}' inputVariable");
        RequireNotBlank(installSurface.NormalizedOutput, $"marketplace install surface for '{target.Id}' normalizedOutput");
        RequireNotBlank(installSurface.Schema, $"marketplace install surface for '{target.Id}' schema");
        RequireNotBlank(installSurface.SampleTfvars, $"marketplace install surface for '{target.Id}' sampleTfvars");

        if (!string.Equals(installSurface.NormalizedOutput, target.InstallSurfaceOutput, StringComparison.Ordinal))
        {
            throw new ValidationException($"Marketplace bundle '{bundlePath}' install surface output '{installSurface.NormalizedOutput}' does not match targets.json value '{target.InstallSurfaceOutput}'.");
        }

        EnsureFileExists(ResolveManifestRelativePath(bundlePath, installSurface.Schema), $"marketplace install schema for '{target.Id}'");
        EnsureFileExists(ResolveManifestRelativePath(bundlePath, installSurface.SampleTfvars), $"marketplace sample tfvars for '{target.Id}'");
    }

    private static void ValidateDeploySurface(string bundlePath, MarketplaceDeploySurface deploySurface, MarketplaceTarget target)
    {
        RequireNotBlank(deploySurface.Output, $"marketplace deploy surface for '{target.Id}' output");
        RequireNotBlank(deploySurface.Schema, $"marketplace deploy surface for '{target.Id}' schema");

        if (!string.Equals(deploySurface.Output, target.DeploySurfaceOutput, StringComparison.Ordinal))
        {
            throw new ValidationException($"Marketplace bundle '{bundlePath}' deploy surface output '{deploySurface.Output}' does not match targets.json value '{target.DeploySurfaceOutput}'.");
        }

        EnsureFileExists(ResolveManifestRelativePath(bundlePath, deploySurface.Schema), $"marketplace deploy schema for '{target.Id}'");
    }

    private static void ValidateCustomerDistributionArchive(string archiveListing, string archivePath)
    {
        var entries = archiveListing
            .Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(NormalizeArchiveEntry)
            .Where(static entry => entry.Length > 0)
            .ToArray();

        if (!entries.Any(static entry => entry == "README.md"))
        {
            throw new ValidationException($"Customer distribution archive '{archivePath}' is missing README.md.");
        }

        foreach (var requiredDirectory in new[] { "modules/", "examples/", "bootstrap/", "marketplace/" })
        {
            if (!entries.Any(entry => string.Equals(entry, requiredDirectory, StringComparison.Ordinal)))
            {
                throw new ValidationException($"Customer distribution archive '{archivePath}' is missing top-level entry '{requiredDirectory}'.");
            }
        }

        foreach (var entry in entries)
        {
            if (IsForbiddenArchiveEntry(entry))
            {
                throw new ValidationException($"Customer distribution archive '{archivePath}' contains a forbidden file: {entry}");
            }
        }
    }

    private static string NormalizeArchiveEntry(string entry)
    {
        return entry.StartsWith("./", StringComparison.Ordinal)
            ? entry[2..]
            : entry;
    }

    private static bool IsForbiddenArchiveEntry(string entry)
    {
        var fileName = Path.GetFileName(entry);
        return fileName.Equals("terraform.tfstate", StringComparison.Ordinal) ||
               fileName.Equals("terraform.tfstate.backup", StringComparison.Ordinal) ||
               fileName.Equals(".terraform.tfstate.lock.info", StringComparison.Ordinal) ||
               fileName.Equals("terraform.tfvars", StringComparison.Ordinal) ||
               fileName.Equals("backend.tf", StringComparison.Ordinal) ||
               fileName.Equals("crash.log", StringComparison.Ordinal) ||
               fileName.EndsWith(".tfplan", StringComparison.Ordinal) ||
               fileName.EndsWith(".auto.tfvars", StringComparison.Ordinal) ||
               fileName.EndsWith(".auto.tfvars.json", StringComparison.Ordinal) ||
               fileName.StartsWith("terraform.tfstate.", StringComparison.Ordinal);
    }

    private static string ResolveManifestRelativePath(string bundlePath, string relativePath)
    {
        return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(bundlePath)!, relativePath));
    }

    private static void EnsureFileExists(string path, string label)
    {
        if (!File.Exists(path))
        {
            throw new ValidationException($"File not found for {label}: {path}");
        }
    }

    private static void RequireNotBlank(string? value, string label)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ValidationException($"Missing required value for {label}.");
        }
    }

    private static void RequireNonEmptyCollection<T>(IReadOnlyCollection<T>? values, string label)
    {
        if (values is null || values.Count == 0)
        {
            throw new ValidationException($"Expected at least one value for {label}.");
        }
    }

    private static T DeserializeJsonFile<T>(string path, string label)
    {
        try
        {
            var value = JsonSerializer.Deserialize<T>(File.ReadAllText(path), MarketplaceJsonOptions);
            if (value is null)
            {
                throw new ValidationException($"Failed to deserialize {label}: {path}");
            }

            return value;
        }
        catch (JsonException exception)
        {
            throw new ValidationException($"Failed to parse {label} '{path}': {exception.Message}");
        }
    }

    private sealed class MarketplaceTargetsDocument
    {
        public string SchemaVersion { get; init; } = string.Empty;

        public string BundleProfile { get; init; } = string.Empty;

        public List<MarketplaceTarget> Targets { get; init; } = [];
    }

    private sealed class MarketplaceTarget
    {
        public string Id { get; init; } = string.Empty;

        public string ExampleRoot { get; init; } = string.Empty;

        public string ModulePath { get; init; } = string.Empty;

        public string Runtime { get; init; } = string.Empty;

        public bool TurnkeyRuntime { get; init; }

        public bool MarketplaceEligible { get; init; }

        public string BundleProfile { get; init; } = string.Empty;

        public string? BundleManifest { get; init; }

        public string? InstallSurfaceOutput { get; init; }

        public string? DeploySurfaceOutput { get; init; }

        public string? Reason { get; init; }
    }

    private sealed class MarketplaceBundleManifest
    {
        public string SchemaVersion { get; init; } = string.Empty;

        public string BundleId { get; init; } = string.Empty;

        public string TargetId { get; init; } = string.Empty;

        public string BundleProfile { get; init; } = string.Empty;

        public string Runtime { get; init; } = string.Empty;

        public bool MarketplaceEligible { get; init; }

        public MarketplaceInstallSurface InstallSurface { get; init; } = new();

        public MarketplaceDeploySurface DeploySurface { get; init; } = new();

        public MarketplaceSupportedRegions SupportedRegions { get; init; } = new();

        public List<string> RequiredPermissions { get; init; } = [];

        public List<string> BillableComponents { get; init; } = [];

        public MarketplaceUpgradePath UpgradePath { get; init; } = new();

        public List<MarketplaceValidationScenarioRef> ValidationScenarioRefs { get; init; } = [];
    }

    private sealed class MarketplaceInstallSurface
    {
        public string InputVariable { get; init; } = string.Empty;

        public string NormalizedOutput { get; init; } = string.Empty;

        public string Schema { get; init; } = string.Empty;

        public string SampleTfvars { get; init; } = string.Empty;
    }

    private sealed class MarketplaceDeploySurface
    {
        public string Output { get; init; } = string.Empty;

        public string Schema { get; init; } = string.Empty;
    }

    private sealed class MarketplaceSupportedRegions
    {
        public List<string> Validated { get; init; } = [];

        public string? Notes { get; init; }
    }

    private sealed class MarketplaceUpgradePath
    {
        public string Strategy { get; init; } = string.Empty;

        public string Rollback { get; init; } = string.Empty;

        public string? CurrentRevisionField { get; init; }

        public string? DesiredRevisionField { get; init; }
    }

    private sealed class MarketplaceValidationScenarioRef
    {
        public string Scenario { get; init; } = string.Empty;

        public string TargetDescriptor { get; init; } = string.Empty;
    }
}
