# Installed executions use the existing worker primitive and fixed resources.
# Only the private controller may later retire a slot; STOPPED is observation.
locals {
  execution_key_prefix  = "${var.candidate_digest}/runtime/${local.slot.runtime_id}/execution/"
  execution_key_pattern = "${local.execution_key_prefix}execution-????????????????????????????????"
  slot_claim_key        = "${var.candidate_digest}/runtime/${local.slot.runtime_id}/slot/${local.slot.slot_id}"
  execution_key_path    = "States.Format('${local.execution_key_prefix}{}', $.executionId)"
  installed_claim_identity = {
    candidateDigest     = { S = var.candidate_digest }
    runtimeId           = { S = local.slot.runtime_id }
    slotId              = { S = local.slot.slot_id }
    executionId         = { "S.$" = "$.executionId" }
    executionArn        = { "S.$" = "$$.Execution.Id" }
    taskDefinitionArn   = { S = aws_ecs_task_definition.worker.arn }
    inputDigest         = { "S.$" = "$.installation.hash.inputDigest" }
    claimGeneration     = { "N.$" = "States.Format('{}', $.claimGeneration)" }
    expiresEpoch        = { "N.$" = "States.Format('{}', $.expiresEpoch)" }
    nativeBindingDigest = { "S.$" = "$.nativeBindingDigest" }
    targetId            = { "S.$" = "$.targetId" }
    workspaceId         = { "S.$" = "$.workspaceId" }
    turnId              = { "S.$" = "$.turnId" }
  }
  slot_owner_values = {
    ":execution"  = { "S.$" = "$$.Execution.Id" }
    ":native"     = { "S.$" = "$.executionId" }
    ":digest"     = { "S.$" = "$.installation.hash.inputDigest" }
    ":definition" = { S = aws_ecs_task_definition.worker.arn }
  }
  slot_owner_condition = "activeExecutionId = :native AND inputDigest = :digest AND executionArn = :execution AND taskDefinitionArn = :definition"
  installed_worker_lifecycle = {
    StartAt = "ValidateInstalledInput", TimeoutSeconds = local.slot.max_execution_seconds + 300
    States = {
      ValidateInstalledInput = {
        Type = "Choice", QueryLanguage = "JSONata"
        Choices = [{
          Condition = trimspace(<<-JSONATA
            {% $count($keys($states.input)) = 11 and
              $type($states.input.schemaVersion) = 'number' and $states.input.schemaVersion = 1 and
              $type($states.input.candidateKey) = 'string' and $states.input.candidateKey = '${var.candidate_digest}' and
              $type($states.input.runtimeId) = 'string' and $states.input.runtimeId = '${local.slot.runtime_id}' and
              $type($states.input.slotId) = 'string' and $states.input.slotId = '${local.slot.slot_id}' and
              $type($states.input.executionId) = 'string' and $count($match($states.input.executionId, /^execution-[0-9a-f]{32}$/)) = 1 and
              $type($states.input.targetId) = 'string' and $length($states.input.targetId) > 0 and $length($states.input.targetId) <= 256 and
              $type($states.input.workspaceId) = 'string' and $length($states.input.workspaceId) > 0 and $length($states.input.workspaceId) <= 256 and
              $type($states.input.turnId) = 'string' and $length($states.input.turnId) > 0 and $length($states.input.turnId) <= 256 and
              $type($states.input.nativeBindingDigest) = 'string' and $count($match($states.input.nativeBindingDigest, /^sha256:[0-9a-f]{64}$/)) = 1 and
              $type($states.input.claimGeneration) = 'number' and $floor($states.input.claimGeneration) = $states.input.claimGeneration and
              $states.input.claimGeneration >= 1 and $states.input.claimGeneration <= 9007199254740991 and
              $type($states.input.expiresEpoch) = 'number' and $floor($states.input.expiresEpoch) = $states.input.expiresEpoch and
              $states.input.expiresEpoch > $floor($toMillis($states.context.State.EnteredTime) / 1000) and
              $states.input.expiresEpoch <= ${local.slot.original_funding_expires_epoch} and
              $states.input.expiresEpoch <= $floor($toMillis($states.context.Execution.StartTime) / 1000) + ${local.slot.max_execution_seconds} %}
          JSONATA
          )
          Next = "CanonicalInstalledInput"
        }]
        Default = "InvalidInstalledInput"
      }
      CanonicalInstalledInput = {
        Type = "Pass", QueryLanguage = "JSONata", Next = "HashInstalledInput"
        Output = trimspace(<<-JSONATA
          {% ($j := function($v) { $substring($string([$v]), 1, $length($string([$v])) - 2) };
            $merge([$states.input, {'installation': {
              'nameInput': '{"candidateKey":' & $j($states.input.candidateKey) & ',"executionId":' & $j($states.input.executionId) & '}',
              'inputString': '{' & $join($map($sort($keys($states.input)), function($k) { $j($k) & ':' & $j($lookup($states.input, $k)) }), ',') & '}'
            }}])) %}
        JSONATA
        )
      }
      HashInstalledInput = {
        Type = "Pass", ResultPath = "$.installation.hash", Next = "CheckExecutionName"
        Parameters = {
          "name.$"        = "States.Format('worker-{}', States.Hash($.installation.nameInput, 'SHA-256'))"
          "inputDigest.$" = "States.Format('sha256:{}', States.Hash($.installation.inputString, 'SHA-256'))"
        }
      }
      CheckExecutionName = {
        Type    = "Choice", Choices = [{ Variable = "$$.Execution.Name", StringEqualsPath = "$.installation.hash.name", Next = "ClaimInstalledExecution" }]
        Default = "InvalidInstalledInput"
      }
      ClaimInstalledExecution = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:dynamodb:transactWriteItems", TimeoutSeconds = 30
        ResultPath = null, Next = "RecheckInstalledExpiry"
        Parameters = { TransactItems = [
          { Put = {
            TableName = var.claim_table_name, ConditionExpression = "attribute_not_exists(candidateKey)"
            Item      = merge(local.installed_claim_identity, { candidateKey = { "S.$" = local.execution_key_path } })
          } },
          { Update = {
            TableName           = var.claim_table_name, Key = { candidateKey = { S = local.slot_claim_key } }
            ConditionExpression = "attribute_not_exists(activeExecutionId)"
            UpdateExpression    = "SET activeExecutionId = :native, inputDigest = :digest, executionArn = :execution, taskDefinitionArn = :definition, claimGeneration = :generation, expiresEpoch = :expiry, nativeBindingDigest = :binding, runtimeId = :runtime, slotId = :slot"
            ExpressionAttributeValues = merge(local.slot_owner_values, {
              ":generation" = { "N.$" = "States.Format('{}', $.claimGeneration)" }
              ":expiry"     = { "N.$" = "States.Format('{}', $.expiresEpoch)" }
              ":binding"    = { "S.$" = "$.nativeBindingDigest" }
              ":runtime"    = { S = local.slot.runtime_id }, ":slot" = { S = local.slot.slot_id }
            })
          } }
        ] }
      }
      RecheckInstalledExpiry = {
        Type    = "Choice", QueryLanguage = "JSONata"
        Choices = [{ Condition = "{% $toMillis($states.context.State.EnteredTime) / 1000 < $states.input.expiresEpoch and $states.input.expiresEpoch <= ${local.slot.original_funding_expires_epoch} %}", Next = "RunWorker" }]
        Default = "Expired"
      }
      RunWorker = merge(local.worker_lifecycle.States.RunWorker, {
        Next = "CheckInstalledLaunch"
        Parameters = merge({ for key, value in local.worker_lifecycle.States.RunWorker.Parameters : key => value if key != "ClientToken" }, {
          "ClientToken.$" = "$.executionId",
          "StartedBy.$"   = "$.executionId"
          Tags = [
            { Key = "honua-agent-execution", "Value.$" = "$.executionId" },
            { Key = "honua-agent-execution-expires", "Value.$" = "States.Format('{}', $.expiresEpoch)" }
          ]
        })
      })
      CheckInstalledLaunch = {
        Type = "Choice", Choices = concat(local.worker_lifecycle.States.CheckLaunch.Choices, [
          { Not = { Variable = "$.launched.Tasks[0].TaskDefinitionArn", StringEquals = aws_ecs_task_definition.worker.arn }, Next = "Unobserved" },
          { Not = { Variable = "$.launched.Tasks[0].ClusterArn", StringEquals = var.cluster_arn }, Next = "Unobserved" }
        ]), Default = "RecordInstalledLaunch"
      }
      RecordInstalledLaunch = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:dynamodb:transactWriteItems", TimeoutSeconds = 30
        ResultPath = null, Next = "WaitForTask"
        Parameters = { TransactItems = [
          { Put = {
            TableName = var.claim_table_name, ConditionExpression = "attribute_not_exists(candidateKey)"
            Item = merge(local.installed_claim_identity, {
              candidateKey = { "S.$" = "States.Format('${local.execution_key_prefix}{}/launched', $.executionId)" },
              taskArn      = { "S.$" = "$.launched.Tasks[0].TaskArn" }
            })
          } },
          { Update = {
            TableName                 = var.claim_table_name, Key = { candidateKey = { S = local.slot_claim_key } }
            ConditionExpression       = local.slot_owner_condition
            UpdateExpression          = "SET taskArn = :task"
            ExpressionAttributeValues = merge(local.slot_owner_values, { ":task" = { "S.$" = "$.launched.Tasks[0].TaskArn" } })
          } }
        ] }
      }
      WaitForTask = local.worker_lifecycle.States.WaitForTask
      CheckObservationDeadline = {
        Type    = "Choice", QueryLanguage = "JSONata"
        Choices = [{ Condition = "{% $toMillis($states.context.State.EnteredTime) / 1000 >= $states.input.expiresEpoch + 300 %}", Next = "ObservationExpired" }]
        Default = "ObserveTask"
      }
      ObserveTask = merge(local.worker_lifecycle.States.ObserveTask, { Next = "CheckObservedExpiry" })
      CheckObservedExpiry = {
        Type    = "Choice", QueryLanguage = "JSONata"
        Choices = [{ Condition = "{% $toMillis($states.context.State.EnteredTime) / 1000 >= $states.input.expiresEpoch + 300 %}", Next = "ObservationExpired" }]
        Default = "CheckObservation"
      }
      CheckObservation = merge(local.worker_lifecycle.States.CheckObservation, {
        Choices = slice(local.worker_lifecycle.States.CheckObservation.Choices, 1, length(local.worker_lifecycle.States.CheckObservation.Choices))
      })
      CheckStopTime = {
        Type = "Choice", QueryLanguage = "JSONata"
        Choices = [
          { Condition = "{% $toMillis($states.context.State.EnteredTime) / 1000 >= $states.input.expiresEpoch + 300 %}", Next = "ObservationExpired" },
          { Condition = "{% $toMillis($states.context.State.EnteredTime) / 1000 >= $states.input.expiresEpoch %}", Next = "StopWorker" }
        ], Default = "WaitForTask"
      }
      StopWorker = local.worker_lifecycle.States.StopWorker
      RecordStopped = {
        Type = "Task", Resource = "arn:aws:states:::aws-sdk:dynamodb:transactWriteItems", TimeoutSeconds = 30, End = true
        Parameters = { TransactItems = [{ Put = {
          TableName = var.claim_table_name, ConditionExpression = "attribute_not_exists(candidateKey)"
          Item = merge(local.installed_claim_identity, {
            candidateKey = { "S.$" = "States.Format('${local.execution_key_prefix}{}/stopped', $.executionId)" },
            taskArn      = { "S.$" = "$.observed.Tasks[0].TaskArn" }, state = { S = "STOPPED" }
          })
        } }] }
      }
      InvalidInstalledInput = { Type = "Fail", Error = "InvalidInstalledExecution" }
      Expired               = local.worker_lifecycle.States.Expired
      Unobserved            = local.worker_lifecycle.States.Unobserved
      ObservationExpired    = local.worker_lifecycle.States.ObservationExpired
    }
  }
}

locals {
  installed_lifecycle_claim_statements = [
    {
      Effect = "Allow", Action = "dynamodb:PutItem", Resource = local.table_arn
      Condition = {
        "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = [local.execution_key_pattern, "${local.execution_key_pattern}/launched", "${local.execution_key_pattern}/stopped"] }
        StringEquals              = { "dynamodb:EnclosingOperation" = "TransactWriteItems" }
      }
    },
    {
      Effect = "Allow", Action = "dynamodb:UpdateItem", Resource = local.table_arn
      Condition = {
        "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [local.slot_claim_key] }
        StringEquals                = { "dynamodb:EnclosingOperation" = "TransactWriteItems" }
      }
    }
  ]
  installed_controller_claim_statements = [
    {
      Effect = "Allow", Action = "dynamodb:GetItem", Resource = local.table_arn
      Condition = { "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = [
        local.slot_claim_key, local.execution_key_pattern,
        "${local.execution_key_pattern}/launched", "${local.execution_key_pattern}/stopped", "${local.execution_key_pattern}/retired"
      ] } }
    },
    {
      Effect = "Allow", Action = "dynamodb:PutItem", Resource = local.table_arn
      Condition = {
        "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = ["${local.execution_key_pattern}/retired"] }
        StringEquals              = { "dynamodb:EnclosingOperation" = "TransactWriteItems" }
      }
    },
    {
      Effect = "Allow", Action = "dynamodb:UpdateItem", Resource = local.table_arn
      Condition = {
        "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [local.slot_claim_key] }
        StringEquals                = { "dynamodb:EnclosingOperation" = "TransactWriteItems" }
      }
    }
  ]
}
