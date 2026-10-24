# Existing static campaign cleanup is preserved independently of installed mode.
locals {
  static_reaper = {
    StartAt = "CheckExpiry", TimeoutSeconds = 300
    States = {
      CheckExpiry = {
        Type    = "Choice"
        Choices = [{ Variable = "$$.State.EnteredTime", TimestampGreaterThanEquals = local.expires_at, Next = "ListTasks" }]
        Default = "NotExpired"
      }
      NotExpired = { Type = "Fail", Error = "AttemptNotExpired" }
      ListTasks = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:listTasks"
        Parameters = local.list_expired, ResultPath = "$.page", Next = "StopTasks"
      }
      ListNextPage = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:listTasks"
        Parameters = merge(local.list_expired, { "NextToken.$" = "$.page.NextToken" })
        ResultPath = "$.page", Next = "StopTasks"
      }
      StopTasks = {
        Type         = "Map", ItemsPath = "$.page.TaskArns", MaxConcurrency = 1, ResultPath = null, Next = "HasMore"
        ItemSelector = { "taskArn.$" = "$$.Map.Item.Value" }
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }, StartAt = "StopTask"
          States = {
            StopTask = {
              Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:stopTask", ResultPath = null, Next = "WaitForStop"
              Parameters = { Cluster = var.cluster_arn, "Task.$" = "$.taskArn", Reason = "Agent attempt absolute expiry" }
            }
            WaitForStop = { Type = "Wait", Seconds = 5, Next = "ObserveTask" }
            ObserveTask = {
              Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:describeTasks", ResultPath = "$.observed", Next = "Stopped"
              Parameters = { Cluster = var.cluster_arn, "Tasks.$" = "States.Array($.taskArn)" }
            }
            Stopped = {
              Type = "Choice"
              Choices = [
                { Variable = "$.observed.Failures[0]", IsPresent = true, Next = "Unobserved" },
                { Variable = "$.observed.Tasks[0].LastStatus", StringEquals = "STOPPED", Next = "Confirmed" }
              ]
              Default = "WaitForStop"
            }
            Unobserved = { Type = "Fail", Error = "CleanupNotObserved" }
            Confirmed  = { Type = "Succeed" }
          }
        }
      }
      HasMore = {
        Type = "Choice"
        Choices = [{ And = [
          { Variable = "$.page.NextToken", IsPresent = true },
          { Variable = "$.page.NextToken", IsNull = false },
          { Not = { Variable = "$.page.NextToken", StringEquals = "" } }
        ], Next = "ListNextPage" }]
        Default = "Complete"
      }
      Complete = { Type = "Succeed" }
    }
  }
}
