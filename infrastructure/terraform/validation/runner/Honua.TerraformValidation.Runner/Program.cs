using Honua.TerraformValidation.Runner;

var parsedCommand = CommandLine.Parse(args);
if (parsedCommand.ShowHelp)
{
    CommandLine.WriteUsage();
    return 0;
}

var context = RunnerContext.Create(parsedCommand);

try
{
    await ValidationRunner.RunAsync(parsedCommand, context);
    return 0;
}
catch (CommandLineException exception)
{
    Console.Error.WriteLine($"[runner] {exception.Message}");
    CommandLine.WriteUsage();
    return 1;
}
catch (ValidationException exception)
{
    Console.Error.WriteLine($"[runner] {exception.Message}");
    return 1;
}
catch (CommandExecutionException exception)
{
    Console.Error.WriteLine($"[runner] Command failed with exit code {exception.ExitCode}: {exception.CommandText}");
    if (!string.IsNullOrWhiteSpace(exception.Output))
    {
        Console.Error.WriteLine(exception.Output);
    }

    return exception.ExitCode == 0 ? 1 : exception.ExitCode;
}
catch (AggregateException exception)
{
    foreach (var innerException in exception.Flatten().InnerExceptions)
    {
        Console.Error.WriteLine($"[runner] {innerException.Message}");
    }

    return 1;
}
catch (Exception exception)
{
    Console.Error.WriteLine($"[runner] Unexpected failure: {exception.Message}");
    return 1;
}
