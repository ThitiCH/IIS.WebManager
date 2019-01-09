[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('install', 'ensure-permission')]
    [string]
    $command,

    [string]
    $adminAPILocation,

    [string]
    $dotnetCoreLocation,

    ## Not doing anything with this parameter yet
    [string]
    $sessionId,

    [string]
    $serviceName = "Microsoft IIS Administration",

    [string]
    $iisAdminOwners = "IIS Administration API Owners",

    [int]
    $adminAPIPort = 55539
)

$ErrorActionPreference = "Stop"

######################## Param checks ###############################
$install = $command -eq 'install'

function VerifySource([string] $source) {
    if (Test-Path -IsValid $source) {
        return "file"
    }
    if ([Uri]::TryCreate($source, [UriKind]::Absolute, [ref]$null)) {
        return "uri"
    }
    throw "Invalid install source $source"
}

$dotnetCoreInstallType = $null
$iisAdminInstallType = $null
if ($install) {
    if ($dotnetCoreLocation) {
        $dotnetCoreInstallType = VerifySource $dotnetCoreLocation
    }

    if (!$adminAPILocation) {
        throw "Missing admin API installer location for install command"
    }

    $iisAdminInstallType = VerifySource $adminAPILocation
}

######################## Utilities ###############################
$verbose = $PSBoundParameters['verbose']

if ($verbose) {
    $logDir = Join-Path $env:UserProfile 'wac-iis-logs'
    if (!(Test-Path $logDir)) {
        mkdir $logDir
    }
    $logFile = Join-Path $logDir 'admin-api-util.log'
}

function LogVerbose([string] $msg) {
    if ($verbose) {
        Add-Content -Value $msg -Path $logFile -Force
    }
}

function WaitForServerToStart($service) {
    $waitPeriod = 1
    $remainingTime = 600

    while (!(Get-Service $service -ErrorAction SilentlyContinue | Where-Object {$_.Status -eq "Running"})) {
        Start-Sleep -Seconds $waitPeriod
        $remainingTime -= $waitPeriod
        if ($remainingTime -lt 0) {
            throw "Timeout waiting for service to start"
        }
    }
    LogVerbose "Server started, time remaining ${remainingTime}..."
}

$adminAPIInstalled = $false
function InstallComponents {
    if ($dotnetCoreLocation) {
        Install "dotnet-core-runtime" $dotnetCoreInstallType $dotnetCoreLocation
    }
    Install "iis-administration-api" $iisAdminInstallType $adminAPILocation
    WaitForServerToStart $serviceName
    $adminAPIInstalled = $true
}

function Install([string] $scenario, [string] $installType, [string] $location) {
    $installer = Join-Path $env:TEMP "${scenario}.exe"
    LogVerbose "source: $location will be copied to $installer"
    if ($installType -eq "file") {
        Copy-Item -Path $location -Destination $installer -Force
    } elseif ($installType -eq "uri") {
        Download $location $installer
    } else {
        throw "Invalid install type $installType"
    }
    LogVerbose "Running $installer"
    & $installer /s
    LogVerbose "Successfully installed $scenario"
}

function Download([string] $uri, [string] $location) {
    Invoke-WebRequest $uri -OutFile $location
    LogVerbose "Downloaded $uri to $location"
}

function EnsureGroup($group) {
    if (!(Get-LocalGroup -Name $group -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $group | Out-Null
        LogVerbose "Group $group added"
    }
}

function EnsureMember($group, $userOrGroup) {
    $modify = !(Get-LocalGroupMember -Group $group -Member $userOrGroup -ErrorAction SilentlyContinue)
    if ($modify) {
        Add-LocalGroupMember -Group $group -Member $userOrGroup | Out-Null
        LogVerbose "Member $userOrGroup added"
    }
    return $modify
}

function GetIISAdminHome($procs) {
    foreach ($proc in $procs) {
        $iisMainModule = $proc.Modules | Where-Object { $_.ModuleName -eq "Microsoft.IIS.Administration.dll" }
        if ($iisMainModule) {
            LogVerbose "IIS Admin module found at $($iisMainModule.FileName)"
            return Split-Path $iisMainModule.FileName
        }
    }
}

####################### Main script ################################

## TODO: Consider creating a lock around this script because it is not concurrency safe

LogVerbose 'Started admin_api_util...'

if ($install) {
    InstallComponents
} else {
    try {
        $pingEndpoint = "https://localhost:$adminAPIPort"
        LogVerbose "Pinging Admin API at $pingEndpoint"
        Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing $pingEndpoint | Out-Null
    } catch {
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (!$service) {
                throw "IIS Administration API is not installed"
            }
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                throw "IIS Administration API is not found at: $pingEndpoint"
            }
            throw "Unexpected service status for IIS Administration API: ""$($service.Status)"""
        }
        throw $_
    }
}

$service = Get-WmiObject win32_service | Where-Object {$_.name -eq $serviceName}
if ($service) {
    if ($service.StartInfo.EnvironmentVariables -and $service.StartInfo.EnvironmentVariables["USE_CURRENT_DIRECTORY_AS_ROOT"] -and $service.StartInfo.WorkingDirectory) {
        $workingDirectory = $service.StartInfo.WorkingDirectory
    } else {
        $proc = Get-Process -id $service.ProcessId
        $workingDirectory = GetIISAdminHome $proc
    }
} else {
    ## dev-mode support, no restart can be perfomed
    LogVerbose "Dev mode, scanning processes for IIS Admin API"
    $devMode = $true
    $workingDirectory = GetIISAdminHome (Get-Process -ProcessName dotnet)
}

$configLocation = [System.IO.Path]::Combine($workingDirectory, "config", "appsettings.json")
if ($devMode -and !(Test-Path $configLocation)) {
    $configLocation = [System.IO.Path]::Combine($workingDirectory, "..", "..", "..", "config", "appsettings.json")
}
LogVerbose "Config Location $configLocation"
$config = Get-Content -Raw -Path $configLocation | ConvertFrom-Json
$user = $(whoami)

$groupModified = $false

## Install process adds $user in the config file. We don't want that, we want $iisAdminOwners in there instead
if ($install) {
    $config.security.users.owners = @()
    $config.security.users.administrators = @()
}

if (!$config.security.users.owners.Contains($user)) {
    EnsureGroup $iisAdminOwners
    $groupModified = EnsureMember $iisAdminOwners $user

    if (!$config.security.users.owners.Contains($iisAdminOwners)) {
        $config.security.users.owners += $iisAdminOwners
        $saveConfig = $true
    }
    if (!$config.security.users.administrators.Contains($iisAdminOwners)) {
        $config.security.users.administrators += $iisAdminOwners
        $saveConfig = $true
    }

    if ($saveConfig) {
        LogVerbose "Saving config..."
        if ($devMode) {
            throw "Cannot edit config file in dev mode, please add $user to ""$iisAdminOwners"" group manually"
        }
        if (!(Get-LocalGroupMember -Group "Administrators" -Member $user -ErrorAction SilentlyContinue)) {
            throw "User $user lacks administrator privilege which is needed to initiate IIS Administration API"
        }
        $apiHome = [System.IO.Path]::Combine($workingDirectory, "..")
        ## Installer added a read-only rule on current user to the directory, delete it
        $dirAcl = Get-Acl $apiHome
        foreach ($access in $dirAcl.Access | Where-Object { $_.IdentityReference.Value -eq $user }) {
            $dirAcl.RemoveAccessRule($access) | Out-Null
            $updateAcl = $true
        }
        if ($updateAcl) {
            LogVerbose "Updating Acl to remove readonly access..."
            Set-Acl -Path $apiHome -AclObject $dirAcl | Out-Null
        }
        $rights = [System.Security.AccessControl.FileSystemRights]::Traverse `
            -bOr [System.Security.AccessControl.FileSystemRights]::Modify `
            -bOr [System.Security.AccessControl.FileSystemRights]::ChangePermissions
        $dirAccessGranted = $dirAcl.Access | Where-Object {(($_.IdentityReference.Value -eq "BUILTIN\Administrators") -and (($_.FileSystemRights -bAnd $rights) -eq $rights))}
        if (!$dirAccessGranted) {
            $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit `
                -bOr [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            $propFlags = [System.Security.AccessControl.PropagationFlags]::InheritOnly
            $ar = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", $rights, $inheritFlags, $propFlags, "allow")
            $dirAcl.SetAccessRule($ar) | Out-Null
            LogVerbose "Setting Acl to enable administrators' write access"
            Set-Acl -Path $apiHome -AclObject $dirAcl | Out-Null
        }
        LogVerbose "Saving new configuration"
        $config | ConvertTo-Json -depth 100 | Out-File $configLocation
        LogVerbose "Restarting service"
        Restart-Service -Name $serviceName | Out-Null
        WaitForServerToStart $serviceName
    }
}

ConvertTo-Json @{
    "adminAPIInstalled" = $adminAPIInstalled;
    "groupModified" = $groupModified
} -Compress -Depth 100