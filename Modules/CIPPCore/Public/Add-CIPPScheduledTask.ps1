function Add-CIPPScheduledTask {
    [CmdletBinding()]
    param(
        [pscustomobject]$Task,
        [bool]$Hidden,
        $DisallowDuplicateName = $false,
        [string]$SyncType = $null,
        $Headers
    )

    $Table = Get-CIPPTable -TableName 'ScheduledTasks'
    if ($DisallowDuplicateName) {
        $Filter = "PartitionKey eq 'ScheduledTask' and Name eq '$($Task.Name)'"
        $ExistingTask = (Get-CIPPAzDataTableEntity @Table -Filter $Filter)
        if ($ExistingTask) {
            return "Task with name $($Task.Name) already exists"
        }
    }

    $propertiesToCheck = @('Webhook', 'Email', 'PSA')
    $PostExecutionObject = ($propertiesToCheck | Where-Object { $task.PostExecution.$_ -eq $true })
    $PostExecution = $PostExecutionObject ? ($PostExecutionObject -join ',') : ($Task.PostExecution.value -join ',')
    $Parameters = [System.Collections.Hashtable]@{}
    foreach ($Key in $task.Parameters.PSObject.Properties.Name) {
        $Param = $task.Parameters.$Key

        if ($null -eq $Param -or $Param -eq '' -or ($Param | Measure-Object).Count -eq 0) {
            continue
        }
        if ($Param -is [System.Collections.IDictionary] -or $Param.Key) {
            $ht = @{}
            foreach ($p in $Param.GetEnumerator()) {
                $ht[$p.Key] = $p.Value
            }
            $Parameters[$Key] = [PSCustomObject]$ht
        } else {
            $Parameters[$Key] = $Param
        }
    }

    if ($Headers) {
        $Parameters.Headers = $Headers | Select-Object -Property 'x-forwarded-for', 'x-ms-client-principal', 'x-ms-client-principal-idp', 'x-ms-client-principal-name'
    }

    $Parameters = ($Parameters | ConvertTo-Json -Depth 10 -Compress)
    $AdditionalProperties = [System.Collections.Hashtable]@{}
    foreach ($Prop in $task.AdditionalProperties) {
        $AdditionalProperties[$Prop.Key] = $Prop.Value
    }
    $AdditionalProperties = ([PSCustomObject]$AdditionalProperties | ConvertTo-Json -Compress)
    if ($Parameters -eq 'null') { $Parameters = '' }
    if (!$Task.RowKey) {
        $RowKey = (New-Guid).Guid
    } else {
        $RowKey = $Task.RowKey
    }

    $Recurrence = if ([string]::IsNullOrEmpty($task.Recurrence.value)) {
        $task.Recurrence
    } else {
        $task.Recurrence.value
    }

    if ([int64]$task.ScheduledTime -eq 0 -or [string]::IsNullOrEmpty($task.ScheduledTime)) {
        $task.ScheduledTime = [int64](([datetime]::UtcNow) - (Get-Date '1/1/1970')).TotalSeconds
    }
    $excludedTenants = if ($task.excludedTenants.value) {
        $task.excludedTenants.value -join ','
    }
    $entity = @{
        PartitionKey         = [string]'ScheduledTask'
        TaskState            = [string]'Planned'
        RowKey               = [string]$RowKey
        Tenant               = $task.TenantFilter.value ? "$($task.TenantFilter.value)" : "$($task.TenantFilter)"
        excludedTenants      = [string]$excludedTenants
        Name                 = [string]$task.Name
        Command              = [string]$task.Command.value
        Parameters           = [string]$Parameters
        ScheduledTime        = [string]$task.ScheduledTime
        Recurrence           = [string]$Recurrence
        PostExecution        = [string]$PostExecution
        AdditionalProperties = [string]$AdditionalProperties
        Hidden               = [bool]$Hidden
        Results              = 'Planned'
    }
    if ($SyncType) {
        $entity.SyncType = $SyncType
    }
    try {
        Add-CIPPAzDataTableEntity @Table -Entity $entity -Force
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        return "Could not add task: $ErrorMessage"
    }
    return "Successfully added task: $($entity.Name)"
}
