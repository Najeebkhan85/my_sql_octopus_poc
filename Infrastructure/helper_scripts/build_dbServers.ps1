param(
    $instanceType = "t2.micro", # 1 vCPU, 1GiB Mem, free tier elligible: https://aws.amazon.com/ec2/instance-types/
    $ami = "ami-0d2455a34bf134234", # Microsoft Windows Server 2019 Base with Containers
    $dbServerRole = "RandomQuotes_SQL-DbServer",
    $tagValue = "Created manually",
    $octoUrl = "",
    $octoEnv = "",
    [Switch]$Wait,
    $timeout = 4800 # seconds
)

$ErrorActionPreference = "Stop"

# Reading VM_UserData
$userDataFile = "VM_UserData_SQL.ps1"
$userDataPath = "$PSScriptRoot\$userDataFile"
$userData = Get-Content -Path $userDataPath -Raw

# Preparing startup script for VM
if ($DeployTentacle){
    # And substitute the octopus URL and environment
    $userData = $userData.replace("__OCTOPUSURL__",$octoUrl)
    $userData = $userData.replace("__ENV__",$octoEnv)
    $userData = $userData.replace("__OCTOPUSURL__",$octoUrl)
    $userData = $userData.replace("__ROLE__",$dbServerRole)
}

if (Test-Path $userDataPath){
    Write-Output "    Reading UserData (VM startup script) from $userDataPath."
}
else {
    Write-Error "No UserData (VM startup script) found at $userDataPath!"
}
# Base 64 encoding the setup script. More info here: 
# https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2-windows-user-data.html
Write-Output "    Base 64 encoding UserData."
$encodedUserData = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($userData))

# Checking how many instances are already running
Write-Output "    Checking how many instances are already running with tag $dbServerRole and value $tagValue..."
$acceptableStates = @("pending", "running")
$PreExistingInstances = (Get-EC2Instance -Filter @{Name="tag:$dbServerRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances 
$before = $PreExistingInstances.count
Write-Output "      $before instances are already running." 
$totalRequired = 1 - $PreExistingInstances.count # We only ever want 1 SQL instance per env!
if ($totalRequired -lt 0){
    $totalRequired = 0
}
Write-Output "      $totalRequired more instances required." 

if ($totalRequired -gt 0){
    Write-Output "    Launching $totalRequired instances of type $instanceType and ami $ami."
    

    Write-Output "      Instances will each have tag $dbServerRole with value $tagValue."

    $NewInstance = New-EC2Instance -ImageId $ami -MinCount $totalRequired -MaxCount $totalRequired -InstanceType $instanceType -UserData $encodedUserData -KeyName RandomQuotes_SQL -SecurityGroup RandomQuotes_SQL -IamInstanceProfile_Name RandomQuotes_SQL

    # Tagging all the instances
    ForEach ($InstanceID  in ($NewInstance.Instances).InstanceId){
        New-EC2Tag -Resources $( $InstanceID ) -Tags @(
            @{ Key=$dbServerRole; Value=$tagValue}
        );
    }
}
# Initializing potential error data
$oops = $false
$err = "There is a problem with the following instances: "

# Checking if it worked
Write-Output "    Verifying that 1 SQL instance in running in $octoEnv environment: "
$instances = (Get-EC2Instance -Filter @{Name="tag:$dbServerRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances

ForEach ($instance in $instances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "      Instance $id is in state: $state"
}

if ($instances.count -ne $count){
    $errmsg = "Expected to see $count instances, but actually see " + $instances.count + " instances."
    Write-Warning "$errmsg"
    $err = $err + ". Also, $errmsg"
    $oops = $true
}

# Logging results
if ($oops){
    Write-Error $err
} else {
    $msg = "    " + $instances.count + " instances have been launched successfully."
    Write-Output $msg
}

if ($Wait -and ($totalRequired -gt 0)){
    $allRunning = $false
    $runningWarningGiven = $false
    $ipAddress = ""

    Write-Output "    Waiting for instances to start. (This normally takes about 30 seconds.)"
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

    While (-not $allRunning){
        $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
        
        if ($time -gt $timeout){
            Write-Error "Timed out at $time seconds. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
        }
        
        if (($time -gt 60) -and (-not $runningWarningGiven)){
            Write-Warning "EC2 instances are taking an unusually long time to start."
            $runningWarningGiven = $true
        }
        
        $runningInstances = (Get-EC2Instance -Filter @{Name="tag:$dbServerRole";Values=$tagValue}, @{Name="instance-state-name";Values="running"}).Instances
        $NumRunning = $runningInstances.count
        
        if ($NumRunning -eq $count){
            $allRunning = $true
            Write-Output "      $time seconds: All instances are running!"
            ForEach ($instance in $runningInstances){
                $id = $instance.InstanceId
                $ipAddress = $instance.PublicIpAddress
                Write-Output "        Instance $id is available at the public IP: $ipAddress"
            }
            break
        }
        else {
            Write-Output "      $time seconds: $NumRunning out of $count instances are running."
        }

        Start-Sleep -s 10
    }

    Write-Output "    While we wait for SQL Server to install, ensuring dbatools is installed on worker."
    Write-Output "      (We will use DBA tools to ping SQL Server to see when it comes online.)"

    Write-Output "      Installing NuGet package provider (required for dbatools)..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force 
    Write-Output "      Installing dbatools..."
    Install-Module dbatools -Force

    if ($Installedmodules.name -contains "dbatools"){
        Write-Output "    Module dbatools is already installed "
    }
    else {
        Write-Output "    dbatools is not installed."
        Write-Output "      Installing dbatools..."
        Install-Module dbatools -Force
    }

    Write-Output "    Retrieving SQL credentials from AWS Secrets Manager."
    

    function Test-SQL {
        param (
            $ip,
            $cred
        )
        try { 
            Invoke-DbaQuery -SqlInstance $ip -Query 'SELECT @@version' -SqlCredential $cred -EnableException
        }
        catch {
            return $false
        }
        return $true
    }

    $connectedAsSa = $false
    $connectedAsOctopus = $false
    $saPassword = $OctopusParameters["sqlSaPassword"] | ConvertTo-SecureString -AsPlainText -Force
    $saUsername = "sa"
    $saCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $saUsername, $saPassword
    $octopusPassword = $OctopusParameters["sqlOctopusPassword"] | ConvertTo-SecureString -AsPlainText -Force
    $octopusUsername = "octopus"
    $octoCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $octopusUsername, $octopusPassword

    While (-not $connectedAsSa){   
        $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
        if ($time -gt $timeout){
            Write-Error "Timed out at $time seconds. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
        }    
        if (($time -gt 2400) -and (-not $runningWarningGiven)){
            Write-Warning "SQL Server is taking an unusually long time to start."
            $runningWarningGiven = $true
        }
        # Testing if SQL Server is online
        try {
            if (Test-SQL -ip $ipAddress -cred $saCred){
                    $connectedAsSa = $true
                    Write-Output "        $time seconds: SQL Server running. Will now wait for Octopus Login to be deployed."
            } 
            else {
                Write-Output "      $time seconds: SQL Server is not available to sa yet."
            }
        }
        catch {
            Write-Warning "something broke"
        }
        Start-Sleep -s 30
    }

    While (-not $connectedAsOctopus){   
        $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
        if ($time -gt $timeout){
            Write-Error "Timed out at $time seconds. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
        }    
        if (($time -gt 2400) -and (-not $runningWarningGiven)){
            Write-Warning "SQL Server is taking an unusually long time to start."
            $runningWarningGiven = $true
        }
        # Testing if SQL Server is online
        try {
            if (Test-SQL -ip $ipAddress -cred $octoCred){
                    $connectedAsOctopus = $true
                    Write-Output "      SUCCESS! SQL Server is available at: $ipAddress"
            } 
            else {
                Write-Output "      $time seconds: Octopus and student logins not yet deployed."
            }
        }
        catch {
            Write-Warning "something broke"
        }
        Start-Sleep -s 30
    }

}