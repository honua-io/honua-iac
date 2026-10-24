# Runs throughout the installation. It observes exact ECS identities before
# stopping, and has no authority to retire slots, release admissions or settle.
locals {
  installed_reaper = merge(local.static_reaper, {
    StartAt = "ListTasks"
    States = merge({ for key, state in local.static_reaper.States : key => state if !contains(["CheckExpiry", "NotExpired", "StopTasks"], key) }, {
      StopTasks = merge(local.static_reaper.States.StopTasks, {
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }, StartAt = "InspectTask"
          States = {
            InspectTask = {
              Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:describeTasks", TimeoutSeconds = 30
              Parameters = { Cluster = var.cluster_arn, "Tasks.$" = "States.Array($.taskArn)", Include = ["TAGS"] }
              ResultPath = "$.observed", Next = "CheckIdentity"
            }
            CheckIdentity = {
              Type = "Choice", QueryLanguage = "JSONata"
              Choices = [{
                Condition = trimspace(<<-JSONATA
                  {% $count($states.input.observed.Failures) = 0 and $count($states.input.observed.Tasks) = 1 and
                    $states.input.observed.Tasks[0].TaskArn = $states.input.taskArn and
                    $states.input.observed.Tasks[0].ClusterArn = '${var.cluster_arn}' and
                    $states.input.observed.Tasks[0].TaskDefinitionArn = '${aws_ecs_task_definition.worker.arn}' and
                    $count($states.input.observed.Tasks[0].Tags[Key = 'honua-agent-candidate' and Value = '${var.candidate_digest}']) = 1 and
                    $count($states.input.observed.Tasks[0].Tags[Key = 'honua-agent-attempt' and Value = '${var.attempt_id}']) = 1 and
                    $count($states.input.observed.Tasks[0].Tags[Key = 'honua-agent-runtime' and Value = '${local.slot.runtime_id}']) = 1 and
                    $count($states.input.observed.Tasks[0].Tags[Key = 'honua-agent-slot' and Value = '${local.slot.slot_id}']) = 1 %}
                JSONATA
                )
                Next = "AlreadyStopped"
              }]
              Default = "Unobserved"
            }
            AlreadyStopped = {
              Type    = "Choice"
              Choices = [{ Variable = "$.observed.Tasks[0].LastStatus", StringEquals = "STOPPED", Next = "Confirmed" }]
              Default = "CheckExecutionExpiry"
            }
            CheckExecutionExpiry = {
              Type = "Choice", QueryLanguage = "JSONata"
              Choices = [
                {
                  Condition = "{% $toMillis($states.context.State.EnteredTime) / 1000 >= ${local.slot.original_funding_expires_epoch} %}"
                  Next      = "StopTask"
                },
                {
                  Condition = trimspace(<<-JSONATA
                    {% ($t := $states.input.observed.Tasks[0];
                      $created := $type($t.CreatedAt) = 'number' ? $t.CreatedAt * 1000 : $toMillis($t.CreatedAt);
                      $e := $t.Tags[Key = 'honua-agent-execution'].Value;
                      $d := $t.Tags[Key = 'honua-agent-execution-expires'].Value;
                      $count($e) = 1 and $count($match($e, /^execution-[0-9a-f]{32}$/)) = 1 and
                      $count($d) = 1 and $count($match($d, /^[0-9]{1,12}$/)) = 1 and
                      $number($d) <= ${local.slot.original_funding_expires_epoch} and
                      $number($d) <= $floor($created / 1000) + ${local.slot.max_execution_seconds} and
                      $toMillis($states.context.State.EnteredTime) / 1000 >= $number($d)) %}
                  JSONATA
                  )
                  Next = "StopTask"
                },
                {
                  # A positively owned task without any execution binding is
                  # an orphan, not an execution that may acquire a new expiry.
                  Condition = trimspace(<<-JSONATA
                    {% ($t := $states.input.observed.Tasks[0];
                      $created := $type($t.CreatedAt) = 'number' ? $t.CreatedAt * 1000 : $toMillis($t.CreatedAt);
                      $count($t.Tags[Key = 'honua-agent-execution']) = 0 and
                      $count($t.Tags[Key = 'honua-agent-execution-expires']) = 0 and
                      $toMillis($states.context.State.EnteredTime) >= $created + 300000) %}
                  JSONATA
                  )
                  Next = "StopTask"
                }
              ]
              Default = "StillWithinExpiry"
            }
            StopTask = merge(local.static_reaper.States.StopTasks.ItemProcessor.States.StopTask, {
              Parameters = { Cluster = var.cluster_arn, "Task.$" = "$.taskArn", Reason = "Installed worker execution absolute expiry" }
            })
            WaitForStop = local.static_reaper.States.StopTasks.ItemProcessor.States.WaitForStop
            ObserveTask = {
              Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:describeTasks", TimeoutSeconds = 30
              Parameters = { Cluster = var.cluster_arn, "Tasks.$" = "States.Array($.taskArn)", Include = ["TAGS"] }
              ResultPath = "$.observed", Next = "CheckIdentity"
            }
            Unobserved        = { Type = "Fail", Error = "InstalledWorkerCleanupNotObserved" }
            Confirmed         = { Type = "Succeed" }
            StillWithinExpiry = { Type = "Succeed" }
          }
        }
      })
    })
  })
}
