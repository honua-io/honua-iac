using System.Globalization;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static Dictionary<string, string?> BuildAzureRootCredentials(EnvironmentReader environment)
    {
        return new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["ARM_CLIENT_ID"] = environment.GetRequired("BOOTSTRAP_ARM_CLIENT_ID"),
            ["ARM_CLIENT_SECRET"] = environment.GetRequired("BOOTSTRAP_ARM_CLIENT_SECRET"),
            ["ARM_TENANT_ID"] = environment.GetRequired("BOOTSTRAP_ARM_TENANT_ID"),
            ["ARM_SUBSCRIPTION_ID"] = environment.GetRequired("BOOTSTRAP_ARM_SUBSCRIPTION_ID"),
        };
    }

    private static Dictionary<string, string?> BuildAzureCredentialsEnvironment(
        AzureBootstrapCredentials credentials,
        string? azureCliConfigDir = null)
    {
        var credentialsEnvironment = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["ARM_CLIENT_ID"] = credentials.ClientId,
            ["ARM_CLIENT_SECRET"] = credentials.ClientSecret,
            ["ARM_TENANT_ID"] = credentials.TenantId,
            ["ARM_SUBSCRIPTION_ID"] = credentials.SubscriptionId,
        };

        if (!string.IsNullOrWhiteSpace(azureCliConfigDir))
        {
            credentialsEnvironment["AZURE_CONFIG_DIR"] = azureCliConfigDir;
        }

        return credentialsEnvironment;
    }

    private static async Task EnsureAzSessionAsync(
        RunnerContext context,
        IReadOnlyDictionary<string, string?> credentialsEnvironment,
        string subscriptionId)
    {
        var maxAttempts = GetAzureLoginRetrySetting(context.Environment, "HONUA_AZURE_LOGIN_MAX_ATTEMPTS", 12);
        var retrySeconds = GetAzureLoginRetrySetting(context.Environment, "HONUA_AZURE_LOGIN_RETRY_SECONDS", 10);

        Exception? lastFailure = null;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                await context.ProcessRunner.RunAsync(
                    "az",
                    BuildAzureServicePrincipalLoginArguments(credentialsEnvironment),
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

    private static IReadOnlyList<string> BuildAzureServicePrincipalLoginArguments(IReadOnlyDictionary<string, string?> credentialsEnvironment)
    {
        return
        [
            "login",
            "--service-principal",
            "--allow-no-subscriptions",
            "--username", credentialsEnvironment["ARM_CLIENT_ID"] ?? string.Empty,
            // Azure CLI treats secrets that start with '-' as another flag unless the
            // password is passed as a single assignment token.
            $"--password={credentialsEnvironment["ARM_CLIENT_SECRET"] ?? string.Empty}",
            "--tenant", credentialsEnvironment["ARM_TENANT_ID"] ?? string.Empty,
        ];
    }

    private static int GetAzureLoginRetrySetting(EnvironmentReader environment, string name, int defaultValue)
    {
        var rawValue = environment.GetOrDefault(name, defaultValue.ToString(CultureInfo.InvariantCulture));
        return int.TryParse(rawValue, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedValue)
            ? Math.Max(parsedValue, 1)
            : defaultValue;
    }
}
