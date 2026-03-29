namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static Dictionary<string, string?> BuildValidationEnvironment(
        RunnerContext context,
        EnvironmentReader environment,
        IReadOnlyDictionary<string, string?> baseEnvironment,
        string validationRunId,
        IEnumerable<string> adapterEnvironmentVariables,
        ParsedCommand? command = null)
    {
        var validationEnvironment = new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["HONUA_VALIDATION_RUN_ID"] = validationRunId,
        };

        AddConfigEnvironmentVariables(environment, validationEnvironment, adapterEnvironmentVariables);
        ApplyPlatformValidationDefaults(validationEnvironment, context, command);
        return validationEnvironment;
    }

    private static void ApplyPlatformValidationDefaults(
        IDictionary<string, string?> validationEnvironment,
        RunnerContext context,
        ParsedCommand? command = null)
    {
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_SCRIPT", TryGetDefaultPlatformValidationScript(context));
        SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_ROOT", TryGetDefaultPlatformValidationRoot(context));

        if (command is not null)
        {
            SetDefaultEnvironmentVariable(validationEnvironment, "HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX", BuildImportTablePrefix(context, command));
        }
    }

    private static string? TryGetDefaultPlatformValidationScript(RunnerContext context)
    {
        foreach (var candidate in EnumeratePlatformValidationScriptCandidates(context))
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static string? TryGetDefaultPlatformValidationRoot(RunnerContext context)
    {
        foreach (var candidate in EnumeratePlatformValidationRootCandidates(context))
        {
            if (Directory.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static IEnumerable<string> EnumeratePlatformValidationScriptCandidates(RunnerContext context)
    {
        yield return context.ResolveRepoPath(
            "infrastructure",
            "terraform",
            "validation",
            "scripts",
            "shared",
            "run-cloud-post-apply-validation-wrapper.sh");

        foreach (var validationRoot in EnumeratePlatformValidationRootCandidates(context))
        {
            yield return Path.Combine(validationRoot, "scripts", "run-cloud-post-apply-validation.sh");
        }
    }

    private static IEnumerable<string> EnumeratePlatformValidationRootCandidates(RunnerContext context)
    {
        yield return context.ResolveRepoPath("honua-server");
        yield return Path.GetFullPath(Path.Combine(context.RepoRoot, "..", "honua-server"));
    }

    private static string ResolvePlatformValidationWorkingDirectory(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> validationEnvironment,
        string scriptDirectory)
    {
        if (validationEnvironment.TryGetValue("HONUA_PLATFORM_VALIDATION_ROOT", out var validationRoot) &&
            !string.IsNullOrWhiteSpace(validationRoot))
        {
            var resolvedRoot = Path.IsPathRooted(validationRoot)
                ? Path.GetFullPath(validationRoot)
                : context.ResolveRepoRelativePath(validationRoot);
            if (Directory.Exists(resolvedRoot))
            {
                return resolvedRoot;
            }

            throw new ValidationException($"Platform validation root not found: {resolvedRoot}");
        }

        return Directory.GetParent(scriptDirectory)?.FullName ?? context.RepoRoot;
    }
}
