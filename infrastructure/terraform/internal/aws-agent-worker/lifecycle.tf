# A candidate-wide claim does not expire or follow the controller lease. Only
# observing this execution's exact task STOPPED permits a successor worker.
locals {
  claim_identity = {
    attemptId         = { S = var.attempt_id }, "executionArn" = { "S.$" = "$$.Execution.Id" }
    taskDefinitionArn = { S = aws_ecs_task_definition.worker.arn }
  }
  worker_lifecycle = {
    StartAt = "CheckExpiry", TimeoutSeconds = var.lifetime_seconds + 300
    States = {
      CheckExpiry = {
        Type    = "Choice"
        Choices = [{ Variable = "$$.State.EnteredTime", TimestampGreaterThanEquals = local.expires_at, Next = "Expired" }]
        Default = "ClaimAttempt"
      }
      Expired = { Type = "Fail", Error = "AttemptExpired" }
      ClaimAttempt = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:dynamodb:transactWriteItems", TimeoutSeconds = 30
        ResultPath = null, Next = "RecheckExpiry"
        Parameters = { TransactItems = [
          { Put = {
            TableName = var.claim_table_name, ConditionExpression = "attribute_not_exists(candidateKey)"
            Item      = merge(local.claim_identity, { candidateKey = { S = local.claim_key } })
          } },
          { Put = {
            TableName                 = var.claim_table_name
            ConditionExpression       = "attribute_not_exists(candidateKey) OR #state = :stopped"
            ExpressionAttributeNames  = { "#state" = "state" }
            ExpressionAttributeValues = { ":stopped" = { S = "STOPPED" } }
            Item                      = merge(local.claim_identity, { candidateKey = { S = local.candidate_claim_key }, state = { S = "ACTIVE" } })
          } }
        ] }
      }
      RecheckExpiry = {
        Type    = "Choice"
        Choices = [{ Variable = "$$.State.EnteredTime", TimestampGreaterThanEquals = local.expires_at, Next = "Expired" }]
        Default = "RunWorker"
      }
      RunWorker = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:runTask", TimeoutSeconds = 30
        ResultPath = "$.launched", Next = "CheckLaunch"
        Parameters = {
          Cluster    = var.cluster_arn, TaskDefinition = aws_ecs_task_definition.worker.arn
          Count      = 1, ClientToken = var.attempt_id
          LaunchType = "FARGATE", PlatformVersion = "1.4.0", EnableExecuteCommand = false, PropagateTags = "TASK_DEFINITION"
          NetworkConfiguration = { AwsvpcConfiguration = {
            Subnets = sort(tolist(var.subnet_ids)), SecurityGroups = sort(tolist(var.security_group_ids)), AssignPublicIp = "DISABLED"
          } }
        }
      }
      CheckLaunch = {
        Type = "Choice", Choices = [
          { Variable = "$.launched.Failures[0]", IsPresent = true, Next = "Unobserved" },
          { Variable = "$.launched.Tasks[1]", IsPresent = true, Next = "Unobserved" },
          { Not = { Variable = "$.launched.Tasks[0].TaskArn", IsPresent = true }, Next = "Unobserved" }
        ], Default = "WaitForTask"
      }
      WaitForTask = { Type = "Wait", Seconds = 5, Next = "ObserveTask" }
      ObserveTask = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:describeTasks", TimeoutSeconds = 30
        Parameters = { Cluster = var.cluster_arn, "Tasks.$" = "States.Array($.launched.Tasks[0].TaskArn)" }
        ResultPath = "$.observed", Next = "CheckObservation"
      }
      CheckObservation = {
        Type = "Choice", Choices = [
          { Variable = "$.observed.Failures[0]", IsPresent = true, Next = "Unobserved" },
          { Variable = "$.observed.Tasks[1]", IsPresent = true, Next = "Unobserved" },
          { Not = { Variable = "$.observed.Tasks[0].TaskArn", IsPresent = true }, Next = "Unobserved" },
          { Not = { Variable = "$.observed.Tasks[0].TaskArn", StringEqualsPath = "$.launched.Tasks[0].TaskArn" }, Next = "Unobserved" },
          { Not = { Variable = "$.observed.Tasks[0].ClusterArn", StringEquals = var.cluster_arn }, Next = "Unobserved" },
          { Not = { Variable = "$.observed.Tasks[0].TaskDefinitionArn", StringEquals = aws_ecs_task_definition.worker.arn }, Next = "Unobserved" },
          { Variable = "$.observed.Tasks[0].LastStatus", StringEquals = "STOPPED", Next = "RecordStopped" }
        ], Default = "CheckStopTime"
      }
      CheckStopTime = {
        Type    = "Choice"
        Choices = [{ Variable = "$$.State.EnteredTime", TimestampGreaterThanEquals = local.expires_at, Next = "StopWorker" }]
        Default = "WaitForTask"
      }
      StopWorker = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:stopTask", TimeoutSeconds = 30
        Parameters = { Cluster = var.cluster_arn, "Task.$" = "$.launched.Tasks[0].TaskArn", Reason = "Agent attempt absolute expiry" }
        ResultPath = null, Next = "WaitForTask"
      }
      RecordStopped = {
        Type = "Task", Resource = "arn:aws:states:::aws-sdk:dynamodb:transactWriteItems", TimeoutSeconds = 30, End = true
        Parameters = { TransactItems = [
          { Put = {
            TableName = var.claim_table_name, ConditionExpression = "attribute_not_exists(candidateKey)"
            Item = merge(local.claim_identity, { candidateKey = { S = local.stopped_key },
            taskArn = { "S.$" = "$.observed.Tasks[0].TaskArn" }, state = { S = "STOPPED" } })
          } },
          { Put = {
            TableName                 = var.claim_table_name
            ConditionExpression       = "executionArn = :execution AND attemptId = :attempt AND #state = :active"
            ExpressionAttributeNames  = { "#state" = "state" }
            ExpressionAttributeValues = { ":execution" = { "S.$" = "$$.Execution.Id" }, ":attempt" = { S = var.attempt_id }, ":active" = { S = "ACTIVE" } }
            Item = merge(local.claim_identity, { candidateKey = { S = local.candidate_claim_key },
            taskArn = { "S.$" = "$.observed.Tasks[0].TaskArn" }, state = { S = "STOPPED" } })
          } }
        ] }
      }
      Unobserved = { Type = "Fail", Error = "WorkerStateUnobserved" }
    }
  }
}
