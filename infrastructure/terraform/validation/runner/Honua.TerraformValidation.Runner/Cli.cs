using System.Collections.ObjectModel;

namespace Honua.TerraformValidation.Runner;

internal enum ScenarioName
{
    StaticValidate,
    PolicyGates,
    AzureLive,
    AwsLive,
    K8sLive,
    AksLive,
    EksLive,
    Drift,
}

internal sealed class ParsedCommand
{
    public required ScenarioName Scenario { get; init; }

    public required IReadOnlyDictionary<string, IReadOnlyList<string>> Options { get; init; }

    public bool ShowHelp { get; init; }

    public bool DryRun => GetBoolean("dry-run", defaultValue: false);

    public string RepoRoot => GetString("repo-root", Directory.GetCurrentDirectory());

    public bool HasOption(string name) => Options.ContainsKey(name);

    public string GetRequiredString(string name)
    {
        if (!Options.TryGetValue(name, out var values) || values.Count == 0)
        {
            throw new CommandLineException($"Missing required option --{name}");
        }

        return values[^1];
    }

    public string GetString(string name, string defaultValue)
    {
        if (!Options.TryGetValue(name, out var values) || values.Count == 0)
        {
            return defaultValue;
        }

        return values[^1];
    }

    public IReadOnlyList<string> GetStrings(string name)
    {
        if (!Options.TryGetValue(name, out var values))
        {
            return Array.Empty<string>();
        }

        return values;
    }

    public bool GetBoolean(string name, bool defaultValue)
    {
        if (!Options.TryGetValue(name, out var values) || values.Count == 0)
        {
            return defaultValue;
        }

        return ParseBoolean(values[^1], name);
    }

    public static bool ParseBoolean(string value, string sourceName)
    {
        return value.Trim().ToLowerInvariant() switch
        {
            "" => true,
            "1" or "true" or "yes" or "y" or "on" => true,
            "0" or "false" or "no" or "n" or "off" => false,
            _ => throw new CommandLineException($"Invalid boolean value for {sourceName}: '{value}'"),
        };
    }
}

internal static class CommandLine
{
    private static readonly IReadOnlyDictionary<ScenarioName, IReadOnlySet<string>> AllowedOptions =
        new Dictionary<ScenarioName, IReadOnlySet<string>>
        {
            [ScenarioName.StaticValidate] = new HashSet<string>(StringComparer.Ordinal)
            {
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.PolicyGates] = new HashSet<string>(StringComparer.Ordinal)
            {
                "strict",
                "root",
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.AzureLive] = new HashSet<string>(StringComparer.Ordinal)
            {
                "deployment-profile",
                "apply-confirmation",
                "reuse-data-stack",
                "allow-destroy-plan",
                "no-destroy",
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.AwsLive] = new HashSet<string>(StringComparer.Ordinal)
            {
                "deployment-profile",
                "apply-confirmation",
                "reuse-data-stack",
                "allow-destroy-plan",
                "no-destroy",
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.K8sLive] = new HashSet<string>(StringComparer.Ordinal)
            {
                "deployment-profile",
                "apply-confirmation",
                "cluster-name",
                "cluster-mode",
                "access-mode",
                "kubeconfig",
                "kube-context",
                "http-port",
                "https-port",
                "api-port",
                "forward-port",
                "namespace",
                "observability-namespace",
                "release-name",
                "ingress-host",
                "aot",
                "image",
                "previous-image",
                "upgrade-rollback",
                "timeout-seconds",
                "max-ready-seconds",
                "max-load-error-rate",
                "skip-idempotency",
                "skip-protocol-checks",
                "skip-observability",
                "skip-db-resilience",
                "skip-helm-static-validation",
                "no-scale-check",
                "no-destroy",
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.AksLive] = new HashSet<string>(StringComparer.Ordinal)
            {
                "deployment-profile",
                "apply-confirmation",
                "location",
                "environment",
                "name-prefix-base",
                "node-count",
                "node-vm-size",
                "aot",
                "image",
                "previous-image",
                "upgrade-rollback",
                "skip-idempotency",
                "skip-protocol-checks",
                "skip-observability",
                "skip-db-resilience",
                "skip-helm-static-validation",
                "skip-quota-preflight",
                "max-run-cost-usd",
                "max-ready-seconds",
                "max-load-error-rate",
                "plan-artifact-dir",
                "ttl-hours",
                "no-scale-check",
                "allow-destroy-plan",
                "no-destroy",
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.EksLive] = new HashSet<string>(StringComparer.Ordinal)
            {
                "deployment-profile",
                "apply-confirmation",
                "region",
                "environment",
                "name-prefix-base",
                "node-instance-type",
                "node-min-size",
                "node-max-size",
                "node-desired-size",
                "aot",
                "image",
                "previous-image",
                "upgrade-rollback",
                "skip-idempotency",
                "skip-protocol-checks",
                "skip-observability",
                "skip-db-resilience",
                "skip-helm-static-validation",
                "skip-quota-preflight",
                "max-run-cost-usd",
                "max-ready-seconds",
                "max-load-error-rate",
                "plan-artifact-dir",
                "ttl-hours",
                "no-scale-check",
                "allow-destroy-plan",
                "no-destroy",
                "repo-root",
                "dry-run",
                "help",
            },
            [ScenarioName.Drift] = new HashSet<string>(StringComparer.Ordinal)
            {
                "cloud",
                "run-aks",
                "run-eks",
                "root",
                "var-file",
                "plan-artifact-dir",
                "backend-false",
                "repo-root",
                "dry-run",
                "help",
            },
        };

    public static ParsedCommand Parse(string[] args)
    {
        if (args.Length == 0)
        {
            return new ParsedCommand
            {
                ShowHelp = true,
                Scenario = ScenarioName.AzureLive,
                Options = new ReadOnlyDictionary<string, IReadOnlyList<string>>(new Dictionary<string, IReadOnlyList<string>>()),
            };
        }

        var scenarioToken = args[0];
        if (scenarioToken is "--help" or "-h" or "help")
        {
            return new ParsedCommand
            {
                ShowHelp = true,
                Scenario = ScenarioName.AzureLive,
                Options = new ReadOnlyDictionary<string, IReadOnlyList<string>>(new Dictionary<string, IReadOnlyList<string>>()),
            };
        }

        var scenario = scenarioToken switch
        {
            "static-validate" => ScenarioName.StaticValidate,
            "policy-gates" => ScenarioName.PolicyGates,
            "azure-live" => ScenarioName.AzureLive,
            "aws-live" => ScenarioName.AwsLive,
            "k8s-live" => ScenarioName.K8sLive,
            "aks-live" => ScenarioName.AksLive,
            "eks-live" => ScenarioName.EksLive,
            "drift" => ScenarioName.Drift,
            _ => throw new CommandLineException($"Unknown scenario '{scenarioToken}'"),
        };

        var allowedOptions = AllowedOptions[scenario];
        var mutableOptions = new Dictionary<string, List<string>>(StringComparer.Ordinal);

        for (var index = 1; index < args.Length; index++)
        {
            var token = args[index];
            if (token is "--help" or "-h")
            {
                mutableOptions.TryAdd("help", new List<string>());
                mutableOptions["help"].Add("true");
                continue;
            }

            if (!token.StartsWith("--", StringComparison.Ordinal))
            {
                throw new CommandLineException($"Unexpected positional argument '{token}'");
            }

            var optionName = token[2..];
            if (!allowedOptions.Contains(optionName))
            {
                throw new CommandLineException($"Unknown option for {scenarioToken}: --{optionName}");
            }

            string optionValue;
            if (index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal))
            {
                optionValue = args[++index];
            }
            else
            {
                optionValue = string.Empty;
            }

            mutableOptions.TryAdd(optionName, new List<string>());
            mutableOptions[optionName].Add(optionValue);
        }

        var options = mutableOptions.ToDictionary(
            entry => entry.Key,
            entry => (IReadOnlyList<string>)entry.Value.AsReadOnly(),
            StringComparer.Ordinal);

        return new ParsedCommand
        {
            Scenario = scenario,
            ShowHelp = mutableOptions.ContainsKey("help"),
            Options = new ReadOnlyDictionary<string, IReadOnlyList<string>>(options),
        };
    }

    public static void WriteUsage()
    {
        Console.WriteLine(
            """
            Honua Terraform validation runner (.NET 10)

            Usage:
              dotnet run --project infrastructure/terraform/validation/runner/Honua.TerraformValidation.Runner -- <scenario> [options]

            Scenarios:
              static-validate  Run terraform fmt/init/validate across the maintainer validation roots
              policy-gates     Run policy/security gates
              azure-live   Bootstrap Azure validation identities, then run ACA / Functions validation
              aws-live     Bootstrap AWS validation identities, then run ECS / Lambda validation
              k8s-live     Run local Kubernetes validation
              aks-live     Bootstrap AKS validation identity, then run managed Kubernetes validation
              eks-live     Bootstrap EKS validation identity, then run managed Kubernetes validation
              drift        Run Terraform drift detection for selected roots

            Common options:
              --repo-root <path>                Repo root (defaults to current directory)
              --dry-run                         Validate inputs and print commands without executing them

            Live scenario options:
              --deployment-profile <ephemeral|persistent>
              --apply-confirmation <value>
              --allow-destroy-plan <true|false>
              --no-destroy <true|false>

            Kubernetes live options:
              --cluster-name <name>
              --cluster-mode <k3d|external>
              --access-mode <ingress|port-forward>
              --kubeconfig <path>
              --kube-context <name>
              --http-port <port>
              --https-port <port>
              --api-port <port>
              --forward-port <port>
              --namespace <name>
              --observability-namespace <name>
              --release-name <name>
              --ingress-host <hostname>
              --aot <true|false>
              --image <repo:tag>
              --previous-image <repo:tag>
              --upgrade-rollback <true|false>
              --timeout-seconds <n>
              --max-ready-seconds <n>
              --max-load-error-rate <percent>
              --skip-idempotency <true|false>
              --skip-protocol-checks <true|false>
              --skip-observability <true|false>
              --skip-db-resilience <true|false>
              --skip-helm-static-validation <true|false>
              --no-scale-check <true|false>

            Managed Kubernetes options:
              --location <azure-region>
              --region <aws-region>
              --environment <name>
              --name-prefix-base <prefix>
              --node-count <n>
              --node-vm-size <sku>
              --node-instance-type <type>
              --node-min-size <n>
              --node-max-size <n>
              --node-desired-size <n>
              --max-run-cost-usd <n>
              --plan-artifact-dir <path>
              --ttl-hours <n>
              --skip-quota-preflight <true|false>

            Cloud live scenario options:
              --reuse-data-stack <true|false>

            Drift options:
              --cloud <both|azure|aws>         Optional cloud selector for default drift roots (default: both)
              --run-aks <true|false>
              --run-eks <true|false>
              --root <path>                    Optional explicit drift root (repeatable)
              --var-file <path>                Optional explicit var-file (repeatable)
              --plan-artifact-dir <path>       Optional drift artifact directory
              --backend-false                  Run terraform init with -backend=false

            Policy options:
              --strict <true|false>            Fail on tool findings (default: true)
              --root <path>                    Optional policy root override (defaults to scenario manifest)
            """);
    }
}

internal sealed class CommandLineException(string message) : Exception(message);
