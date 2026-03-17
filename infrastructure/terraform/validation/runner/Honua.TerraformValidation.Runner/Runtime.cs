using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Honua.TerraformValidation.Runner;

internal sealed class RunnerContext
{
    private RunnerContext(string repoRoot, string tempRoot, bool dryRun)
    {
        RepoRoot = repoRoot;
        TempRoot = tempRoot;
        DryRun = dryRun;
        Environment = new EnvironmentReader();
        ProcessRunner = new ProcessRunner(dryRun);
    }

    public string RepoRoot { get; }

    public string TempRoot { get; }

    public bool DryRun { get; }

    public EnvironmentReader Environment { get; }

    public ProcessRunner ProcessRunner { get; }

    public string GitHubRunId => Environment.GetOrDefault("GITHUB_RUN_ID", "local");

    public string GitHubRunAttempt => Environment.GetOrDefault("GITHUB_RUN_ATTEMPT", "0");

    public static RunnerContext Create(ParsedCommand command)
    {
        var repoRoot = Path.GetFullPath(command.RepoRoot);
        var tempRoot = EnvironmentReader.GetEnvironmentVariableOrDefault("RUNNER_TEMP", Path.GetTempPath());
        return new RunnerContext(repoRoot, tempRoot, command.DryRun);
    }

    public string ResolveRepoPath(params string[] segments)
    {
        return Path.GetFullPath(Path.Combine([RepoRoot, .. segments]));
    }

    public string ResolveRepoRelativePath(string relativePath)
    {
        return Path.GetFullPath(Path.Combine(RepoRoot, NormalizeRelativePath(relativePath)));
    }

    public string ResolveTempPath(params string[] segments)
    {
        return Path.GetFullPath(Path.Combine([TempRoot, .. segments]));
    }

    public string ResolveTempRelativePath(string relativePath)
    {
        return Path.GetFullPath(Path.Combine(TempRoot, NormalizeRelativePath(relativePath)));
    }

    private static string NormalizeRelativePath(string relativePath)
    {
        return relativePath.Replace('/', Path.DirectorySeparatorChar);
    }
}

internal sealed class EnvironmentReader
{
    private readonly IReadOnlyDictionary<string, string> githubVariables;

    public EnvironmentReader()
    {
        githubVariables = LoadGitHubVariables();
    }

    public static string GetEnvironmentVariableOrDefault(string name, string defaultValue)
    {
        return System.Environment.GetEnvironmentVariable(name) ?? defaultValue;
    }

    public string GetRequired(string name)
    {
        var value = GetOptional(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ValidationException($"Missing required environment variable: {name}");
        }

        return value;
    }

    public string? GetOptional(string name)
    {
        var environmentValue = System.Environment.GetEnvironmentVariable(name);
        if (!string.IsNullOrWhiteSpace(environmentValue))
        {
            return environmentValue;
        }

        if (githubVariables.TryGetValue(name, out var githubVariableValue) && !string.IsNullOrWhiteSpace(githubVariableValue))
        {
            return githubVariableValue;
        }

        return null;
    }

    public string GetOrDefault(string name, string defaultValue)
    {
        return GetOptional(name) ?? defaultValue;
    }

    public string GetRequiredAny(params string[] names)
    {
        foreach (var name in names)
        {
            var value = GetOptional(name);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        throw new ValidationException($"Missing required environment variable: {string.Join(" or ", names)}");
    }

    public string? GetOptionalAny(params string[] names)
    {
        foreach (var name in names)
        {
            var value = GetOptional(name);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }

    public string GetOrDefaultAny(string[] names, string defaultValue)
    {
        return GetOptionalAny(names) ?? defaultValue;
    }

    public bool GetBoolean(string name, bool defaultValue = false)
    {
        var value = GetOptional(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        return ParsedCommand.ParseBoolean(value, name);
    }

    public bool GetBooleanAny(string[] names, bool defaultValue = false)
    {
        foreach (var name in names)
        {
            var value = GetOptional(name);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return ParsedCommand.ParseBoolean(value, name);
            }
        }

        return defaultValue;
    }

    public IReadOnlyList<string> GetCsv(string name)
    {
        var raw = GetOptional(name);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return Array.Empty<string>();
        }

        return raw.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    }

    private static IReadOnlyDictionary<string, string> LoadGitHubVariables()
    {
        var raw = System.Environment.GetEnvironmentVariable("HONUA_VALIDATION_GHA_VARS_JSON");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return new Dictionary<string, string>(StringComparer.Ordinal);
        }

        try
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(raw);
            if (values is null)
            {
                return new Dictionary<string, string>(StringComparer.Ordinal);
            }

            return values.ToDictionary(
                pair => pair.Key,
                pair => pair.Value.ValueKind == JsonValueKind.String ? pair.Value.GetString() ?? string.Empty : pair.Value.ToString(),
                StringComparer.Ordinal);
        }
        catch (JsonException exception)
        {
            throw new ValidationException($"Failed to parse HONUA_VALIDATION_GHA_VARS_JSON: {exception.Message}");
        }
    }
}

internal sealed class ProcessRunner(bool dryRun)
{
    public async Task RunAsync(
        string fileName,
        IEnumerable<string> arguments,
        string workingDirectory,
        IReadOnlyDictionary<string, string?>? environmentOverrides = null)
    {
        await RunWithInputAsync(fileName, arguments, workingDirectory, standardInput: null, environmentOverrides);
    }

    public async Task RunWithInputAsync(
        string fileName,
        IEnumerable<string> arguments,
        string workingDirectory,
        string? standardInput,
        IReadOnlyDictionary<string, string?>? environmentOverrides = null)
    {
        var commandText = FormatCommand(fileName, arguments);
        Console.WriteLine($"[runner] {commandText}");
        if (dryRun)
        {
            return;
        }

        using var process = CreateProcess(
            fileName,
            arguments,
            workingDirectory,
            environmentOverrides,
            redirectStandardInput: standardInput is not null,
            captureStdout: true,
            captureStderr: true);
        process.OutputDataReceived += static (_, eventArgs) =>
        {
            if (eventArgs.Data is not null)
            {
                Console.WriteLine(eventArgs.Data);
            }
        };
        process.ErrorDataReceived += static (_, eventArgs) =>
        {
            if (eventArgs.Data is not null)
            {
                Console.Error.WriteLine(eventArgs.Data);
            }
        };

        process.Start();
        if (standardInput is not null)
        {
            await process.StandardInput.WriteAsync(standardInput);
            await process.StandardInput.FlushAsync();
            process.StandardInput.Close();
        }
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        if (process.ExitCode != 0)
        {
            throw new CommandExecutionException(commandText, process.ExitCode, output: null);
        }
    }

    public async Task<string> CaptureAsync(
        string fileName,
        IEnumerable<string> arguments,
        string workingDirectory,
        IReadOnlyDictionary<string, string?>? environmentOverrides = null,
        bool redactOutput = false)
    {
        return await CaptureWithInputAsync(fileName, arguments, workingDirectory, standardInput: null, environmentOverrides, redactOutput);
    }

    public async Task<string> CaptureWithInputAsync(
        string fileName,
        IEnumerable<string> arguments,
        string workingDirectory,
        string? standardInput,
        IReadOnlyDictionary<string, string?>? environmentOverrides = null,
        bool redactOutput = false)
    {
        var commandText = FormatCommand(fileName, arguments);
        Console.WriteLine($"[runner] {commandText}");
        if (dryRun)
        {
            return "<dry-run>";
        }

        using var process = CreateProcess(
            fileName,
            arguments,
            workingDirectory,
            environmentOverrides,
            redirectStandardInput: standardInput is not null,
            captureStdout: true,
            captureStderr: true);

        process.Start();
        if (standardInput is not null)
        {
            await process.StandardInput.WriteAsync(standardInput);
            await process.StandardInput.FlushAsync();
            process.StandardInput.Close();
        }
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        if (process.ExitCode != 0)
        {
            var output = redactOutput ? null : BuildOutput(stdout, stderr);
            throw new CommandExecutionException(commandText, process.ExitCode, output);
        }

        if (!redactOutput && !string.IsNullOrWhiteSpace(stderr))
        {
            Console.Error.WriteLine(stderr.TrimEnd());
        }

        return stdout.TrimEnd('\r', '\n');
    }

    private static Process CreateProcess(
        string fileName,
        IEnumerable<string> arguments,
        string workingDirectory,
        IReadOnlyDictionary<string, string?>? environmentOverrides,
        bool redirectStandardInput = false,
        bool captureStdout = false,
        bool captureStderr = false)
    {
        var processStartInfo = new ProcessStartInfo
        {
            FileName = fileName,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardInput = redirectStandardInput,
            RedirectStandardOutput = captureStdout,
            RedirectStandardError = captureStderr,
        };

        foreach (var argument in arguments)
        {
            processStartInfo.ArgumentList.Add(argument);
        }

        if (environmentOverrides is not null)
        {
            foreach (var (name, value) in environmentOverrides)
            {
                if (value is null)
                {
                    processStartInfo.Environment.Remove(name);
                }
                else
                {
                    processStartInfo.Environment[name] = value;
                }
            }
        }

        var process = new Process
        {
            StartInfo = processStartInfo,
            EnableRaisingEvents = true,
        };

        return process;
    }

    private static string FormatCommand(string fileName, IEnumerable<string> arguments)
    {
        static string Quote(string value)
        {
            return value.Any(char.IsWhiteSpace) || value.Contains('"')
                ? $"\"{value.Replace("\"", "\\\"", StringComparison.Ordinal)}\""
                : value;
        }

        var builder = new StringBuilder(fileName);
        foreach (var argument in arguments)
        {
            builder.Append(' ');
            builder.Append(Quote(argument));
        }

        return builder.ToString();
    }

    private static string? BuildOutput(string stdout, string stderr)
    {
        var builder = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(stdout))
        {
            builder.AppendLine(stdout.TrimEnd());
        }

        if (!string.IsNullOrWhiteSpace(stderr))
        {
            builder.AppendLine(stderr.TrimEnd());
        }

        return builder.Length == 0 ? null : builder.ToString().TrimEnd();
    }
}

internal sealed class ValidationException(string message) : Exception(message);

internal sealed class CommandExecutionException(string commandText, int exitCode, string? output) : Exception(commandText)
{
    public string CommandText { get; } = commandText;

    public int ExitCode { get; } = exitCode;

    public string? Output { get; } = output;
}
