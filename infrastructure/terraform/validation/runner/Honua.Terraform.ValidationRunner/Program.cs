using System.Text.Json;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

return ProgramEntry.Run(args);

static class ProgramEntry
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false
    };

    public static int Run(string[] args)
    {
        if (args.Length == 0)
        {
            PrintUsage();
            return 1;
        }

        try
        {
            var repoRoot = ResolveRepositoryRoot();
            var catalogRoot = Path.Combine(repoRoot, "infrastructure", "terraform", "validation", "scenarios");
            var catalog = ValidationCatalog.Load(catalogRoot);

            return args[0] switch
            {
                "roots" => HandleRoots(catalog, args.Skip(1).ToArray()),
                "workflow" => HandleWorkflow(catalog, args.Skip(1).ToArray()),
                "scenarios" => HandleScenarios(catalog, args.Skip(1).ToArray()),
                _ => Fail($"Unknown command '{args[0]}'.")
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ERROR] {ex.Message}");
            return 1;
        }
    }

    private static int HandleRoots(ValidationCatalog catalog, string[] args)
    {
        if (args.Length == 0)
        {
            return Fail("roots requires a group name.");
        }

        var options = CliOptions.Parse(args.Skip(1).ToArray());
        var groupName = args[0];
        var format = options.Get("format", "lines");
        var roots = catalog.GetRootGroup(groupName);

        WriteCollection(roots, format);
        return 0;
    }

    private static int HandleScenarios(ValidationCatalog catalog, string[] args)
    {
        var options = CliOptions.Parse(args);
        var format = options.Get("format", "json");
        var cloud = options.Get("cloud", "both");
        var scenarioSet = options.Get("scenario-set", string.Empty);
        var scenarioIds = options.GetCsv("scenario-ids");
        var runLive = options.GetBool("run-live", true);
        var runDrift = options.GetBool("run-drift", true);

        var selection = catalog.SelectScenarios(
            cloud,
            scenarioSet,
            scenarioIds,
            runLive,
            runDrift);

        if (format == "json")
        {
            Console.WriteLine(JsonSerializer.Serialize(selection.SelectedScenarios, JsonOptions));
            return 0;
        }

        if (format == "lines")
        {
            foreach (var scenario in selection.SelectedScenarios)
            {
                Console.WriteLine(scenario.Id);
            }

            return 0;
        }

        return Fail($"Unsupported scenarios format '{format}'.");
    }

    private static int HandleWorkflow(ValidationCatalog catalog, string[] args)
    {
        if (args.Length == 0)
        {
            return Fail("workflow requires a workflow name.");
        }

        if (!string.Equals(args[0], "manual", StringComparison.OrdinalIgnoreCase))
        {
            return Fail($"Unsupported workflow '{args[0]}'.");
        }

        var options = CliOptions.Parse(args.Skip(1).ToArray());
        var format = options.Get("format", "github-output");
        var cloud = options.Get("cloud", "both");
        var scenarioSet = options.Get("scenario-set", "standard");
        var scenarioIds = options.GetCsv("scenario-ids");
        var runLive = options.GetBool("run-live", false);
        var runDrift = options.GetBool("run-drift", false);

        var selection = catalog.SelectScenarios(
            cloud,
            scenarioSet,
            scenarioIds,
            runLive,
            runDrift);

        var payload = new Dictionary<string, object?>
        {
            ["selected_scenarios_json"] = JsonSerializer.Serialize(selection.SelectedScenarios.Select(static scenario => scenario.Id), JsonOptions),
            ["selected_scenarios_csv"] = string.Join(",", selection.SelectedScenarios.Select(static scenario => scenario.Id)),
            ["drift_roots_json"] = JsonSerializer.Serialize(selection.DriftRoots, JsonOptions),
            ["drift_roots_csv"] = string.Join(",", selection.DriftRoots),
            ["run_azure_live"] = selection.IsSelected("azure-live"),
            ["run_aws_live"] = selection.IsSelected("aws-live"),
            ["run_k8s_live"] = selection.IsSelected("kubernetes-live"),
            ["run_aks_live"] = selection.IsSelected("aks-live"),
            ["run_eks_live"] = selection.IsSelected("eks-live"),
            ["run_drift_detect"] = selection.IsSelected("drift-detect"),
            ["scenario_set"] = scenarioSet
        };

        return format switch
        {
            "github-output" => WriteGithubOutput(payload),
            "json" => WriteJson(payload),
            _ => Fail($"Unsupported workflow output format '{format}'.")
        };
    }

    private static int WriteGithubOutput(IReadOnlyDictionary<string, object?> payload)
    {
        foreach (var pair in payload)
        {
            Console.WriteLine($"{pair.Key}={FormatGithubValue(pair.Value)}");
        }

        return 0;
    }

    private static int WriteJson(IReadOnlyDictionary<string, object?> payload)
    {
        Console.WriteLine(JsonSerializer.Serialize(payload, JsonOptions));
        return 0;
    }

    private static string FormatGithubValue(object? value)
    {
        return value switch
        {
            bool booleanValue => booleanValue ? "true" : "false",
            null => string.Empty,
            _ => value.ToString() ?? string.Empty
        };
    }

    private static void WriteCollection(IReadOnlyCollection<string> values, string format)
    {
        switch (format)
        {
            case "lines":
                foreach (var value in values)
                {
                    Console.WriteLine(value);
                }

                return;
            case "csv":
                Console.WriteLine(string.Join(",", values));
                return;
            case "json":
                Console.WriteLine(JsonSerializer.Serialize(values, JsonOptions));
                return;
            default:
                throw new InvalidOperationException($"Unsupported roots format '{format}'.");
        }
    }

    private static string ResolveRepositoryRoot()
    {
        var candidates = new[]
        {
            Directory.GetCurrentDirectory(),
            AppContext.BaseDirectory
        };

        foreach (var candidate in candidates)
        {
            var current = new DirectoryInfo(candidate);
            while (current is not null)
            {
                var terraformRoot = Path.Combine(current.FullName, "infrastructure", "terraform", "validation", "scenarios");
                if (Directory.Exists(terraformRoot))
                {
                    return current.FullName;
                }

                current = current.Parent;
            }
        }

        throw new InvalidOperationException("Could not determine repository root containing infrastructure/terraform/validation/scenarios.");
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine($"[ERROR] {message}");
        PrintUsage();
        return 1;
    }

    private static void PrintUsage()
    {
        Console.Error.WriteLine("""
Usage:
  dotnet run --project infrastructure/terraform/validation/runner/Honua.Terraform.ValidationRunner -- roots <group> [--format lines|csv|json]
  dotnet run --project infrastructure/terraform/validation/runner/Honua.Terraform.ValidationRunner -- scenarios [--cloud both|aws|azure] [--scenario-set name] [--scenario-ids csv] [--run-live true|false] [--run-drift true|false] [--format json|lines]
  dotnet run --project infrastructure/terraform/validation/runner/Honua.Terraform.ValidationRunner -- workflow manual [--cloud both|aws|azure] [--scenario-set name] [--scenario-ids csv] [--run-live true|false] [--run-drift true|false] [--format github-output|json]
""");
    }
}

sealed class ValidationCatalog
{
    private readonly Dictionary<string, ValidationScenario> _scenarios;
    private readonly Dictionary<string, List<string>> _rootGroups;
    private readonly Dictionary<string, List<string>> _scenarioSets;
    private readonly List<string> _scenarioOrder;

    private ValidationCatalog(
        Dictionary<string, ValidationScenario> scenarios,
        Dictionary<string, List<string>> rootGroups,
        Dictionary<string, List<string>> scenarioSets,
        List<string> scenarioOrder)
    {
        _scenarios = scenarios;
        _rootGroups = rootGroups;
        _scenarioSets = scenarioSets;
        _scenarioOrder = scenarioOrder;
    }

    public static ValidationCatalog Load(string catalogRoot)
    {
        if (!Directory.Exists(catalogRoot))
        {
            throw new InvalidOperationException($"Catalog directory not found: {catalogRoot}");
        }

        var deserializer = new DeserializerBuilder()
            .IgnoreUnmatchedProperties()
            .WithNamingConvention(CamelCaseNamingConvention.Instance)
            .Build();

        var scenarios = new Dictionary<string, ValidationScenario>(StringComparer.OrdinalIgnoreCase);
        var rootGroups = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var scenarioSets = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var scenarioOrder = new List<string>();

        foreach (var path in Directory.GetFiles(catalogRoot, "*.yaml", SearchOption.TopDirectoryOnly).OrderBy(static path => path, StringComparer.OrdinalIgnoreCase))
        {
            var yaml = File.ReadAllText(path);
            var envelope = deserializer.Deserialize<ManifestEnvelope>(yaml);

            switch (envelope.Kind)
            {
                case "scenario":
                {
                    var scenario = deserializer.Deserialize<ValidationScenario>(yaml);
                    scenarios[scenario.Id] = scenario;
                    scenarioOrder.Add(scenario.Id);
                    break;
                }
                case "rootGroups":
                {
                    var rootGroupManifest = deserializer.Deserialize<RootGroupManifest>(yaml);
                    foreach (var pair in rootGroupManifest.Groups)
                    {
                        rootGroups[pair.Key] = pair.Value.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                    }

                    break;
                }
                case "scenarioSets":
                {
                    var scenarioSetManifest = deserializer.Deserialize<ScenarioSetManifest>(yaml);
                    foreach (var pair in scenarioSetManifest.Sets)
                    {
                        scenarioSets[pair.Key] = pair.Value.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                    }

                    break;
                }
                default:
                    throw new InvalidOperationException($"Unsupported manifest kind '{envelope.Kind}' in {path}.");
            }
        }

        return new ValidationCatalog(scenarios, rootGroups, scenarioSets, scenarioOrder);
    }

    public IReadOnlyCollection<string> GetRootGroup(string groupName)
    {
        if (!_rootGroups.TryGetValue(groupName, out var roots))
        {
            throw new InvalidOperationException($"Unknown root group '{groupName}'.");
        }

        return roots;
    }

    public ScenarioSelection SelectScenarios(
        string cloud,
        string scenarioSet,
        IReadOnlyCollection<string> scenarioIds,
        bool runLive,
        bool runDrift)
    {
        var requestedIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        if (!string.IsNullOrWhiteSpace(scenarioSet))
        {
            if (!_scenarioSets.TryGetValue(scenarioSet, out var scenarioSetMembers))
            {
                throw new InvalidOperationException($"Unknown scenario set '{scenarioSet}'.");
            }

            foreach (var scenarioId in scenarioSetMembers)
            {
                requestedIds.Add(scenarioId);
            }
        }

        foreach (var scenarioId in scenarioIds)
        {
            if (string.IsNullOrWhiteSpace(scenarioId))
            {
                continue;
            }

            requestedIds.Add(scenarioId);
        }

        var selected = _scenarioOrder
            .Select(id => _scenarios[id])
            .Where(scenario => requestedIds.Contains(scenario.Id))
            .Where(scenario => SupportsCloud(scenario, cloud))
            .Where(scenario => !scenario.RequiresLive || runLive)
            .Where(scenario => !scenario.RequiresDrift || runDrift)
            .ToList();

        var driftRoots = selected
            .Where(static scenario => string.Equals(scenario.Category, "live", StringComparison.OrdinalIgnoreCase))
            .SelectMany(static scenario => scenario.Roots)
            .Concat(selected
                .Where(static scenario => string.Equals(scenario.Category, "drift", StringComparison.OrdinalIgnoreCase))
                .SelectMany(static scenario => scenario.Roots))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new ScenarioSelection(selected, driftRoots);
    }

    private static bool SupportsCloud(ValidationScenario scenario, string requestedCloud)
    {
        if (string.Equals(requestedCloud, "both", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return scenario.Clouds.Any(cloud =>
            string.Equals(cloud, requestedCloud, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(cloud, "neutral", StringComparison.OrdinalIgnoreCase));
    }
}

sealed class ScenarioSelection
{
    public ScenarioSelection(IReadOnlyList<ValidationScenario> selectedScenarios, IReadOnlyList<string> driftRoots)
    {
        SelectedScenarios = selectedScenarios;
        DriftRoots = driftRoots;
    }

    public IReadOnlyList<ValidationScenario> SelectedScenarios { get; }

    public IReadOnlyList<string> DriftRoots { get; }

    public bool IsSelected(string scenarioId)
    {
        return SelectedScenarios.Any(scenario => string.Equals(scenario.Id, scenarioId, StringComparison.OrdinalIgnoreCase));
    }
}

sealed class CliOptions
{
    private readonly Dictionary<string, string> _values;

    private CliOptions(Dictionary<string, string> values)
    {
        _values = values;
    }

    public static CliOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        for (var index = 0; index < args.Length; index++)
        {
            var argument = args[index];
            if (!argument.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            var key = argument[2..];
            if (index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal))
            {
                values[key] = args[index + 1];
                index++;
                continue;
            }

            values[key] = "true";
        }

        return new CliOptions(values);
    }

    public string Get(string key, string defaultValue)
    {
        return _values.TryGetValue(key, out var value) ? value : defaultValue;
    }

    public bool GetBool(string key, bool defaultValue)
    {
        if (!_values.TryGetValue(key, out var value))
        {
            return defaultValue;
        }

        return value switch
        {
            "1" => true,
            "0" => false,
            _ => bool.Parse(value)
        };
    }

    public IReadOnlyCollection<string> GetCsv(string key)
    {
        if (!_values.TryGetValue(key, out var value) || string.IsNullOrWhiteSpace(value))
        {
            return Array.Empty<string>();
        }

        return value
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .ToArray();
    }
}

sealed class ManifestEnvelope
{
    public string Kind { get; init; } = string.Empty;
}

sealed class ValidationScenario
{
    public string Id { get; init; } = string.Empty;

    public string Name { get; init; } = string.Empty;

    public string Job { get; init; } = string.Empty;

    public string Category { get; init; } = string.Empty;

    public List<string> Clouds { get; init; } = [];

    public bool RequiresLive { get; init; }

    public bool RequiresDrift { get; init; }

    public List<string> Roots { get; init; } = [];
}

sealed class RootGroupManifest
{
    public Dictionary<string, List<string>> Groups { get; init; } = new(StringComparer.OrdinalIgnoreCase);
}

sealed class ScenarioSetManifest
{
    public Dictionary<string, List<string>> Sets { get; init; } = new(StringComparer.OrdinalIgnoreCase);
}
