using System.Text.RegularExpressions;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static readonly Regex TerraformProviderVersionRegexTemplate = new(
        "(?ms)\\b__PROVIDER__\\s*=\\s*\\{.*?\\bversion\\s*=\\s*\"([^\"]+)\"",
        RegexOptions.Compiled);
    private static readonly Regex TerraformNamedBlockRegex = new(
        "^(?<kind>output|check)\\s+\"(?<name>[^\"]+)\"\\s*\\{",
        RegexOptions.Compiled);
    private static readonly Regex TerraformStringAssignmentRegex = new(
        "^(?<key>description|error_message)\\s*=\\s*\"(?<value>[^\"]*)\"",
        RegexOptions.Compiled);
    private static readonly string[] TerraformConventionRoots =
    [
        "infrastructure/terraform/bootstrap",
        "infrastructure/terraform/examples",
        "infrastructure/terraform/modules",
    ];
    private static readonly string[] TerraformImperativeCheckMessagePrefixes =
    [
        "Set ",
        "Provide ",
        "Enable ",
        "When ",
    ];

    private readonly record struct TerraformBlockMetadata(int EndIndex, bool HasDescription, string? ErrorMessage);

    private static void ValidateTerraformConventions(RunnerContext context)
    {
        ValidateTerraformProviderConstraints(context);
        ValidateTerraformOutputDescriptions(context);
        ValidateTerraformCheckMessageStyle(context);
    }

    private static void ValidateTerraformProviderConstraints(RunnerContext context)
    {
        Console.WriteLine("[runner] Validating Terraform provider constraint alignment");

        ValidateProviderConstraintGroup(
            context,
            providerName: "aws",
            expectedVersion: "~> 6.30",
            files:
            [
                "infrastructure/terraform/bootstrap/aws-ecs/main.tf",
                "infrastructure/terraform/bootstrap/aws-eks/main.tf",
                "infrastructure/terraform/bootstrap/aws-serverless/main.tf",
                "infrastructure/terraform/examples/aws/versions.tf",
                "infrastructure/terraform/examples/aws-data/versions.tf",
                "infrastructure/terraform/examples/aws-eks/versions.tf",
                "infrastructure/terraform/examples/aws-serverless/versions.tf",
                "infrastructure/terraform/modules/aws-data/versions.tf",
                "infrastructure/terraform/modules/aws-ecs/versions.tf",
                "infrastructure/terraform/modules/aws-eks/versions.tf",
                "infrastructure/terraform/modules/aws-serverless/versions.tf",
            ]);

        ValidateProviderConstraintGroup(
            context,
            providerName: "azurerm",
            expectedVersion: "~> 4.58",
            files:
            [
                "infrastructure/terraform/bootstrap/azure-aca/main.tf",
                "infrastructure/terraform/bootstrap/azure-aks/main.tf",
                "infrastructure/terraform/bootstrap/azure-functions/main.tf",
                "infrastructure/terraform/examples/azure/versions.tf",
                "infrastructure/terraform/examples/azure-aks/versions.tf",
                "infrastructure/terraform/examples/azure-data/versions.tf",
                "infrastructure/terraform/examples/azure-functions/versions.tf",
                "infrastructure/terraform/modules/azure-aca/versions.tf",
                "infrastructure/terraform/modules/azure-aks/versions.tf",
                "infrastructure/terraform/modules/azure-data/versions.tf",
                "infrastructure/terraform/modules/azure-functions/versions.tf",
            ]);

        Console.WriteLine("[runner] Terraform provider constraint alignment validated successfully");
    }

    private static void ValidateTerraformOutputDescriptions(RunnerContext context)
    {
        Console.WriteLine("[runner] Validating Terraform output descriptions");

        var missingDescriptions = new List<string>();
        foreach (var filePath in EnumerateFirstPartyTerraformFiles(context))
        {
            var lines = File.ReadAllLines(filePath);
            for (var index = 0; index < lines.Length; index++)
            {
                if (!TryMatchTerraformNamedBlock(lines[index], expectedKind: "output", out var outputName))
                {
                    continue;
                }

                var blockMetadata = ScanTerraformBlock(lines, index);
                if (!blockMetadata.HasDescription)
                {
                    missingDescriptions.Add($"{NormalizeRepoRelativePath(context, filePath)}:{index + 1}:{outputName}");
                }

                index = blockMetadata.EndIndex;
            }
        }

        if (missingDescriptions.Count > 0)
        {
            throw new ValidationException($"Terraform outputs must declare description fields. Missing descriptions: {FormatConventionFailures(missingDescriptions)}");
        }

        Console.WriteLine("[runner] Terraform output descriptions validated successfully");
    }

    private static void ValidateTerraformCheckMessageStyle(RunnerContext context)
    {
        Console.WriteLine("[runner] Validating Terraform check message style");

        var invalidCheckMessages = new List<string>();
        foreach (var filePath in EnumerateFirstPartyTerraformFiles(context))
        {
            var lines = File.ReadAllLines(filePath);
            for (var index = 0; index < lines.Length; index++)
            {
                if (!TryMatchTerraformNamedBlock(lines[index], expectedKind: "check", out var checkName))
                {
                    continue;
                }

                var blockMetadata = ScanTerraformBlock(lines, index);
                if (string.IsNullOrWhiteSpace(blockMetadata.ErrorMessage))
                {
                    invalidCheckMessages.Add($"{NormalizeRepoRelativePath(context, filePath)}:{index + 1}:{checkName}:missing error_message");
                }
                else if (TerraformImperativeCheckMessagePrefixes.Any(prefix => blockMetadata.ErrorMessage.StartsWith(prefix, StringComparison.Ordinal)))
                {
                    invalidCheckMessages.Add($"{NormalizeRepoRelativePath(context, filePath)}:{index + 1}:{checkName}:{blockMetadata.ErrorMessage}");
                }

                index = blockMetadata.EndIndex;
            }
        }

        if (invalidCheckMessages.Count > 0)
        {
            throw new ValidationException($"Terraform check messages must be declarative and begin with the constrained surface. Violations: {FormatConventionFailures(invalidCheckMessages)}");
        }

        Console.WriteLine("[runner] Terraform check message style validated successfully");
    }

    private static void ValidateProviderConstraintGroup(
        RunnerContext context,
        string providerName,
        string expectedVersion,
        IReadOnlyList<string> files)
    {
        foreach (var relativePath in files)
        {
            var absolutePath = ResolveRepoRelativePath(context, relativePath);
            EnsureFileExists(absolutePath, $"Terraform provider constraint file '{relativePath}'");

            var contents = File.ReadAllText(absolutePath);
            var pattern = TerraformProviderVersionRegexTemplate.ToString().Replace("__PROVIDER__", Regex.Escape(providerName), StringComparison.Ordinal);
            var match = Regex.Match(contents, pattern, RegexOptions.Multiline | RegexOptions.Singleline);
            if (!match.Success)
            {
                throw new ValidationException($"Could not find required_providers version for '{providerName}' in {relativePath}");
            }

            var actualVersion = match.Groups[1].Value.Trim();
            if (!string.Equals(actualVersion, expectedVersion, StringComparison.Ordinal))
            {
                throw new ValidationException($"Terraform provider '{providerName}' must use version '{expectedVersion}' in {relativePath}; found '{actualVersion}'.");
            }
        }
    }

    private static IEnumerable<string> EnumerateFirstPartyTerraformFiles(RunnerContext context)
    {
        foreach (var root in TerraformConventionRoots)
        {
            var absoluteRoot = ResolveRepoRelativePath(context, root);
            RequireDirectory(absoluteRoot, $"Terraform conventions root '{root}'");

            foreach (var filePath in Directory.EnumerateFiles(absoluteRoot, "*.tf", SearchOption.AllDirectories))
            {
                var normalizedRelativePath = NormalizeRepoRelativePath(context, filePath);
                if (normalizedRelativePath.StartsWith("infrastructure/terraform/modules/vendor/", StringComparison.Ordinal))
                {
                    continue;
                }

                yield return filePath;
            }
        }
    }

    private static TerraformBlockMetadata ScanTerraformBlock(string[] lines, int startIndex)
    {
        var depth = CountBraces(lines[startIndex]);
        var hasDescription = false;
        string? errorMessage = null;

        for (var index = startIndex + 1; index < lines.Length; index++)
        {
            var trimmedLine = lines[index].Trim();
            if (!hasDescription && TryMatchTerraformStringAssignment(trimmedLine, expectedKey: "description", out _))
            {
                hasDescription = true;
            }

            if (errorMessage is null && TryMatchTerraformStringAssignment(trimmedLine, expectedKey: "error_message", out var value))
            {
                errorMessage = value;
            }

            depth += CountBraces(lines[index]);
            if (depth <= 0)
            {
                return new TerraformBlockMetadata(index, hasDescription, errorMessage);
            }
        }

        return new TerraformBlockMetadata(lines.Length - 1, hasDescription, errorMessage);
    }

    private static bool TryMatchTerraformNamedBlock(string line, string expectedKind, out string name)
    {
        var match = TerraformNamedBlockRegex.Match(line.Trim());
        if (match.Success && string.Equals(match.Groups["kind"].Value, expectedKind, StringComparison.Ordinal))
        {
            name = match.Groups["name"].Value;
            return true;
        }

        name = string.Empty;
        return false;
    }

    private static bool TryMatchTerraformStringAssignment(string line, string expectedKey, out string value)
    {
        var match = TerraformStringAssignmentRegex.Match(line);
        if (match.Success && string.Equals(match.Groups["key"].Value, expectedKey, StringComparison.Ordinal))
        {
            value = match.Groups["value"].Value;
            return true;
        }

        value = string.Empty;
        return false;
    }

    private static int CountBraces(string line)
        => line.Count(character => character == '{') - line.Count(character => character == '}');

    private static string NormalizeRepoRelativePath(RunnerContext context, string filePath)
        => Path.GetRelativePath(context.RepoRoot, filePath).Replace('\\', '/');

    private static string FormatConventionFailures(IReadOnlyList<string> failures, int limit = 20)
        => failures.Count <= limit
            ? string.Join(", ", failures)
            : $"{string.Join(", ", failures.Take(limit))} (+{failures.Count - limit} more)";
}
