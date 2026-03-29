using System.Globalization;
using System.Text.Json;

namespace Honua.TerraformValidation.Runner;

internal static partial class ValidationRunner
{
    private static Dictionary<string, string?> BuildAzureAcaEnvironment(
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> baseEnvironment,
        string image,
        int minReplicas)
    {
        var reusingExistingData = !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString);
        var callerIpAddress = GetRequiredAzureValidationCallerIp(settings);
        var environment = BuildAzureBaseTerraformEnvironment(settings, state, baseEnvironment, settings.AcaNamePrefix, image);

        environment["TF_VAR_db_public_network_access"] = (!reusingExistingData).ToString().ToLowerInvariant();
        environment["TF_VAR_db_firewall_start_ip"] = reusingExistingData ? callerIpAddress : "0.0.0.0";
        environment["TF_VAR_db_firewall_end_ip"] = reusingExistingData ? settings.DbFirewallEndIp : "0.0.0.0";
        environment["TF_VAR_min_replicas"] = minReplicas.ToString(CultureInfo.InvariantCulture);
        environment["TF_VAR_max_replicas"] = settings.AcaMaxReplicas.ToString(CultureInfo.InvariantCulture);
        environment["TF_VAR_enable_ingress"] = "true";
        environment["TF_VAR_ingress_allowed_cidrs"] = BuildAzureCallerIngressCidrsJson(callerIpAddress);
        environment["TF_VAR_additional_env"] = JsonSerializer.Serialize(new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["HONUA_SKIP_MIGRATIONS"] = "false",
        });

        return environment;
    }

    private static Dictionary<string, string?> BuildAzureFunctionsEnvironment(
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> baseEnvironment,
        string image,
        string? slotImage,
        bool deploymentSlotEnabled)
    {
        var callerIpAddress = GetRequiredAzureValidationCallerIp(settings);
        var environment = BuildAzureBaseTerraformEnvironment(settings, state, baseEnvironment, settings.FunctionsNamePrefix, image);

        environment["TF_VAR_db_firewall_start_ip"] = callerIpAddress;
        environment["TF_VAR_db_firewall_end_ip"] = settings.DbFirewallEndIp;
        environment["TF_VAR_deployment_slot_enabled"] = deploymentSlotEnabled.ToString().ToLowerInvariant();
        environment["TF_VAR_deployment_slot_name"] = settings.FunctionsDeploymentSlotName;
        environment["TF_VAR_deployment_slot_image"] = slotImage ?? settings.FunctionsDeploymentSlotImage ?? image;
        environment["TF_VAR_plan_sku_name"] = settings.FunctionsPlanSku;
        environment["TF_VAR_skip_migrations"] = settings.FunctionsSkipMigrations.ToString().ToLowerInvariant();
        // Azure currently rejects the provider's Application Insights billing update for
        // workspace-based components in validation subscriptions. Keep live validation
        // focused on the Function App path until that control-plane issue is resolved.
        environment["TF_VAR_app_insights_enabled"] = "false";
        environment["TF_VAR_key_vault_diagnostics_enabled"] = "false";
        environment["TF_VAR_public_network_access_enabled"] = "true";
        environment["TF_VAR_allowed_ip_cidrs"] = BuildAzureCallerIngressCidrsJson(callerIpAddress);

        return environment;
    }

    private static Dictionary<string, string?> BuildAzureBaseTerraformEnvironment(
        AzureLiveSettings settings,
        AzureLiveState state,
        IReadOnlyDictionary<string, string?> baseEnvironment,
        string namePrefix,
        string image)
    {
        var reusingExistingData = !string.IsNullOrWhiteSpace(state.ExistingDbConnectionString);
        var callerIpAddress = GetRequiredAzureValidationCallerIp(settings);
        var environment = new Dictionary<string, string?>(baseEnvironment, StringComparer.Ordinal)
        {
            ["TF_IN_AUTOMATION"] = "true",
            ["TF_VAR_location"] = settings.Location,
            ["TF_VAR_environment"] = settings.Environment,
            ["TF_VAR_name_prefix"] = namePrefix,
            ["TF_VAR_honua_admin_password"] = settings.AdminPassword,
            ["TF_VAR_db_admin_password"] = settings.DbAdminPassword,
            ["TF_VAR_enable_postgis"] = (!reusingExistingData).ToString().ToLowerInvariant(),
            // Azure live validation exercises the control-plane and runtime stack wiring.
            // Reused Redis has introduced readiness flakiness without adding useful signal.
            ["TF_VAR_redis_enabled"] = "false",
            ["TF_VAR_existing_db_fqdn"] = state.ExistingDbFqdn,
            ["TF_VAR_existing_db_connection_string"] = state.ExistingDbConnectionString,
            ["TF_VAR_redis_connection_string"] = string.Empty,
            ["TF_VAR_honua_image"] = image,
            ["TF_VAR_registry_auth_mode"] = settings.RegistryAuthMode,
            ["TF_VAR_registry_resource_id"] = settings.RegistryResourceId,
            ["TF_VAR_registry_server"] = settings.RegistryServer,
            ["TF_VAR_registry_username"] = settings.RegistryUsername,
            ["TF_VAR_registry_password"] = settings.RegistryPassword,
            ["TF_VAR_tags"] = settings.ValidationTagsJson,
        };

        ApplyAzureValidationNetworkOverrides(environment, callerIpAddress);
        return environment;
    }

    private static string GetRequiredAzureValidationCallerIp(AzureLiveSettings settings)
    {
        return settings.DbFirewallStartIp
            ?? throw new ValidationException("Azure live validation requires a resolved DB firewall start IP before building Terraform overrides.");
    }

    private static void ApplyAzureValidationNetworkOverrides(IDictionary<string, string?> environment, string callerIpAddress)
    {
        environment["TF_VAR_app_storage_enabled"] = "true";
        environment["TF_VAR_app_storage_default_action"] = "Allow";
        environment["TF_VAR_app_storage_ip_rules"] = BuildAzureAppStorageIpRulesJson(callerIpAddress);
        environment["TF_VAR_key_vault_public_network_access_enabled"] = "true";
        environment["TF_VAR_key_vault_default_action"] = "Allow";
    }

    private static string BuildAzureCallerIngressCidrsJson(string callerIpAddress)
    {
        return JsonSerializer.Serialize(new[] { $"{callerIpAddress}/32" });
    }

    private static string BuildAzureAppStorageIpRulesJson(string callerIpAddress)
    {
        return JsonSerializer.Serialize(new[] { callerIpAddress });
    }
}
