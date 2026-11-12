Function Restore-ProPresenterLibraryItem {
    <#
        .SYNOPSIS
            Copies a ProPresenter Library Item from backup copy of a workspace to an active workspace
        .DESCRIPTION
            Since ProPresenter stores presentations in a SQLite Database, the PSSQLite module is required.  If it isn't installed, this function will install it.
            Since ProPresenter presentations are Loro Documents, this function requires LoroCS.dll and Loro.cll available here: https://github.com/sensslen/loro-cs
            If Loro.dll or LoroCs.dll are not present in the same directory, this function fails.  This function is currently tested on release 1.16
            WARNING:  Consider this an Alpha/Beta release. USE AT YOUR OWN RISK!!!!!
            I would not use this function to copy to a production workspace.  Additionally, since it took several iterations to figure out how to use LoroCS, there is probably some easier way to do some of this.
        .PARAMETER BackupPathSource
            The source directory.  This parameter expects a backup copy of the "%AppData%\Renewed Vision\Propresenter" folder
        .PARAMETER SourceWorkspaceName
            The name of the workspace in the source directory
        .PARAMETER ItemToRestore
            The exact library path of the presentation to restore
        .PARAMETER DestinationWorkspaceName
            What workspace to restore to.  WARNING: This should be a separate workspace than your production workspace.  If something goes wrong ProPresenter will refuse to open the workspace!!!!
        .PARAMETER DestinationLibrary
            What library to restore to
        .EXAMPLE
            Restore-ProPresenterLibraryItem -BackupPathSource 'C:\Temp\ProPresenter' -SourceWorkspaceName 'ProPresenter' -ItemToRestore '2026 BOP/PSALM 119' -DestinationWorkspaceName 'New Test' -DestinationLibrary 'Default'
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path (Join-Path $_ -ChildPath 'Workspaces\registry-v1.sqlite3') })]
        [string]$BackupPathSource,

        [Parameter(Mandatory = $true)]
        [string]$SourceWorkspaceName,

        [Parameter(Mandatory = $true)]
        [string]$ItemToRestore,

        [Parameter(Mandatory = $true)]
        [string]$DestinationWorkspaceName,

        [string]$DestinationLibrary = 'Restored'
    )
    Begin {
        # Ensure ProPresenter is closed (use 'throw' so execution halts immediately)
        if (Get-Process 'ProPresenter' -ErrorAction SilentlyContinue) {
            throw 'ProPresenter must be closed to complete the restoration, to avoid conflicts and file locking.'
        } else {
            Get-Process 'ProPresenter Helper - Snapshots' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process $_ -Force }
            Get-Process 'ProPresenter Helper - Workspaces' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process $_ -Force }
        }

        # Load Prerequisites
        if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
            Install-Module -Name PSSQLite -Scope CurrentUser -Force
        }
        Import-Module PSSQLite

        $DllPath = $PSScriptroot # <-- Update to your exact folder path

        # Define the Windows API method to force-load native binaries
        $MethodDefinition = @'
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        public static extern IntPtr LoadLibrary(string lpFileName);
'@

        if (-not ([System.Management.Automation.PSTypeName]'Win32.Kernel32Utils').Type) {
            $Kernel32 = Add-Type -MemberDefinition $MethodDefinition -Name "Kernel32Utils" -Namespace "Win32" -PassThru -ErrorAction SilentlyContinue 
        } else {
            $Kernel32 = ([System.Management.Automation.PSTypeName]'Win32.Kernel32Utils').Type
        }

        # Inject the unmanaged 'loro.dll' explicitly into process memory
        $NativeDllPath = Join-Path $DllPath "loro.dll"
        $LoadResult = $Kernel32::LoadLibrary($NativeDllPath)

        # Verify the native module loaded successfully
        if ($LoadResult -eq 0) {
            throw "Failed to map native library at $NativeDllPath. Error code: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        [System.IO.Directory]::SetCurrentDirectory($DllPath)
        Add-Type -Path (Join-Path $DllPath 'LoroCs.dll') -ReferencedAssemblies $NativeDllPath -ErrorAction SilentlyContinue
        $loroPath = [LoroCs.LoroMap].Assembly.Location
        $netStandardPath = [System.IO.Path]::Combine([System.Runtime.InteropServices.RuntimeInformation]::RuntimeDirectory, "netstandard.dll")

        # Define LoroValueLike class required for map insert
        # Had difficulty with inserts.  Used this C# code to return a LoroValueLike type
        $csharpCode = @"
        using LoroCs;

        public class MyLoroValue : LoroValueLike {
            private readonly LoroValue _val;

            public MyLoroValue(LoroValue val) {
                _val = val;
            }

            public LoroValue AsLoroValue() {
                return _val;
            }
        }
"@

        # Compile the wrapper into your PowerShell session
        if (-not ([System.Management.Automation.PSTypeName]'MyLoroValue').Type) {
            Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies @($loroPath, $netStandardPath)
        }

        # Find destination Workspace
        $destRootPath = "$($env:Appdata)\RenewedVision\ProPresenter\Workspaces"
        $destRegistryDb = Join-Path $destRootPath -ChildPath "registry-v1.sqlite3"
        $destWorkspaces = Invoke-SqliteQuery -DataSource $destRegistryDb -Query "SELECT * FROM workspaces"
        $DestinationWorkspace = $destWorkspaces | Where-Object { $_.display_name -eq $DestinationWorkspaceName }

        if (-not $DestinationWorkspace) {
            throw "Destination workspace '$DestinationWorkspaceName' not found."
        }

        # Resolve destination DB path safely
        $script:destDbPath = Join-Path $destRootPath "$($DestinationWorkspace.local_uuid)\DocumentStore\workspace-v1.sqlite3"
        if (-not (Test-Path $script:destDbPath)) {
            throw "Failed to find destination workspace database at $script:destDbPath"
        }

        # Find source Workspace
        $srcRootPath = "$BackupPathSource\Workspaces"
        $srcRegistryDb = Join-Path $srcRootPath -ChildPath "registry-v1.sqlite3"
        $srcWorkspaces = Invoke-SqliteQuery -DataSource $srcRegistryDb -Query "SELECT * FROM workspaces"
        $SourceWorkspace = $srcWorkspaces | Where-Object { $_.display_name -eq $SourceWorkspaceName }

        if (-not $SourceWorkspace) {
            throw "Source workspace '$SourceWorkspaceName' not found in backup."
        }

        # Resolve source DB path relative to BackupPathSource (in case backup was moved)
        $script:srcDbPath = Join-Path $srcRootPath "$($SourceWorkspace.local_uuid)\DocumentStore\workspace-v1.sqlite3"
        if (-not (Test-Path $script:srcDbPath)) {
            # Fallback to stored root_path if backup structure differs
            $script:srcDbPath = "$($SourceWorkspace.root_path)\DocumentStore\workspace-v1.sqlite3"
            if (-not (Test-Path $script:srcDbPath)) {
                throw "Failed to find source workspace database."
            }
        }
    }
    Process {
        # Parameterized query to safely handle apostrophes/special characters in presentation names
        $query = "SELECT * FROM workspace_streams WHERE core_path = @corePath"
        $presentation = Invoke-SqliteQuery -DataSource $script:srcDbPath -Query $query -SqlParameters @{ corePath = $ItemToRestore }

        if (-not $presentation) {
            throw "Failed to find requested item '$ItemToRestore' in source."
        }

        $lorodoc = New-Object LoroCs.LoroDoc
        try {
            # Generate a unique non-zero 64-bit PeerId to prevent CRDT causal collisions across runs
            [uint64]$uniquePeerId = Get-Random -Minimum 0L -Maximum 9007199254740991L
            if ($uniquePeerId -eq 0) { $uniquePeerId = 1 }
            $lorodoc.SetPeerId($uniquePeerId)

            # Load the existing document snapshot
            $lorodoc.Import($presentation.snapshot) | Out-Null

            # Generate new GUID and unique restored name (prevents sub-second core_path collisions)
            $newGuid = [Guid]::NewGuid()
            $shortId = $newGuid.ToString().Substring(0, 4)
            $ItemToRestoreName = Split-Path $ItemToRestore -Leaf
            $RestoredName = "$($ItemToRestoreName) - Restored $(Get-Date -Format 'yyyy-MM-dd HH-mm-ss') ($shortId)"

            # Update internal Loro document name and UUID
            $RootId = [LoroCs.Extensions.StringExtensions]::ToLoroContainerIdLike("root")
            $Map = $lorodoc.GetMap($RootId)

            #Add the presentation name to the LoroDoc
            $nameVariant = [LoroCs.LoroValue+String]::new($RestoredName)
            $Map.Insert("name", [MyLoroValue]::new($nameVariant))

            #Add the GUID to the LoroDoc
            $uuidVariant = [LoroCs.LoroValue+String]::new($newGuid.ToString())
            $Map.Insert("uuid", [MyLoroValue]::new($uuidVariant))

            # Commit changes once
            $lorodoc.Commit()

            # Export updated snapshot and calculate matching Version Vector
            $exportMode = [LoroCs.ExportMode+Snapshot]::new()
            [byte[]]$updatedSnapshot = $lorodoc.Export($exportMode)

            # Derive the Version Vector directly from the exported snapshot bytes
            # This guarantees RustCore sees an exact match between the snapshot and version_vector column
            $SnapshotVerifyDoc = New-Object LoroCs.LoroDoc
            try {
                [void]$SnapshotVerifyDoc.Import($updatedSnapshot)
                #$ExactVersionVector = $SnapshotVerifyDoc.OplogVv()
                $ExactVersionVector = $SnapshotVerifyDoc.statevv()
                [byte[]]$VersionVectorBytes = $ExactVersionVector.Encode()
            } finally {
                $SnapshotVerifyDoc.Dispose()
            }

            # Validate Version Vector
            if (-not (Validate-LoroVersionVector -updatedSnapshot $updatedSnapshot -newVersionVector $ExactVersionVector)) {
                throw 'Failed to validate new LoroDoc version vector.'
            }

            # Prepare SQLite metadata fields
            [byte[]]$newDocumentIdBytes = ConvertGuidTo-BigEndianByte -guid $newGuid
            $CorePath = "$DestinationLibrary/$RestoredName"
            $CorePathKey = $CorePath.ToLowerInvariant()
            $byteCount = $updatedSnapshot.Length
            $currentMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

            $sha256Provider = [System.Security.Cryptography.SHA256]::Create()
            try {
                [byte[]]$sha256Bytes = $sha256Provider.ComputeHash($updatedSnapshot)
            } finally {
                $sha256Provider.Dispose()
            }

            $insertQuery = @"
INSERT INTO workspace_streams (
    document_id, scope, location_type, kind, 
    core_path, core_path_key, availability, 
    snapshot, version_vector, sha256, byte_count, updated_at_ms, 
    last_shared_version_vector_absence_reason
) VALUES (
    @id, @scope, @locType, @kind, 
    @corePath, @corePathKey, @avail, 
    @snapshot, @versionVector, @sha256, @byteCount, @ms, 
    @absenceReason
);
"@

            $queryParams = @{
                id            = $newDocumentIdBytes
                scope         = $presentation.scope
                locType       = $presentation.location_type
                kind          = $presentation.kind
                corePath      = $CorePath
                corePathKey   = $CorePathKey
                avail         = $presentation.availability
                snapshot      = $updatedSnapshot
                versionVector = $VersionVectorBytes
                sha256        = $sha256Bytes
                byteCount     = $byteCount
                ms            = $currentMs
                absenceReason = $presentation.last_shared_version_vector_absence_reason
            }

            Invoke-SqliteQuery -DataSource $script:destDbPath -Query $insertQuery -SqlParameters $queryParams | Out-Null
            Write-Output "Successfully restored '$ItemToRestore' to '$CorePath' (PeerId: $uniquePeerId)."
} finally {
$lorodoc.Dispose()
}
}
End {}
}

Function Get-ProPresenterWorkspaceItems {
<#
        .SYNOPSIS
            Gets Library items from a ProPresenter Workspace
        .DESCRIPTION
            Since ProPresenter stores presentations in a SQLite Database, the PSSQLite module is required.  If it isn't installed, this function will install it.
            No parsing of workspace items is done except adding a property to convert the document_id to a guid.  This is useful to search the ProPresenter log file for this guid if something went wrong.
            WARNING:  Consider this an Alpha/Beta release. USE AT YOUR OWN RISK!!!!!
        .PARAMETER Workspaces_Root_Path
            The source directory.  This parameter expects a backup copy of the "%AppData%\Renewed Vision\Propresenter\Workspaces" folder
        .PARAMETER WorkspaceName
            The name of the workspace in the source directory
        .EXAMPLE
            Get-PropresenterWorkspaceItems -WorkspaceName 'ProPresenter'
    #>

Param(
[string]$Workspaces_Root_Path = "$($env:Appdata)\RenewedVision\ProPresenter\Workspaces",
[string]$WorkspaceName = 'ProPresenter'
)
Begin {
    #Install PSSQLite
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Install-Module -Name PSSQLite -Scope CurrentUser -Force
    }
    Import-Module PSSQLite

    #Get Workspaces
    $workspaces = Get-ProPresenterWorkspaces -rootpath $Workspaces_Root_Path
    $Workspace = $workspaces | Where-Object { $_.display_name -eq $WorkspaceName }
    if (-not $Workspace) {
    throw "Workspace '$WorkspaceName' not found."
    }

    #Get the datasource for the workspace
    $datasource = "$($Workspaces_Root_Path)\$($Workspace.local_uuid)\DocumentStore\workspace-v1.sqlite3"
    if (-not (Test-Path $datasource)) {
    throw "Failed to find workspace database at $datasource"
    }
    $script:datasource = $datasource
    }
Process {
    #Get the workspace items
    $workspaceitems = Invoke-SqliteQuery -DataSource $script:datasource -Query "SELECT * FROM workspace_streams"
    if (-not $workspaceitems) {
        Write-Warning 'No items found in workspace.'
    } else {
        $workspaceitems | ForEach-Object {
            #Add the converted guid
            Add-Member -InputObject $_ -MemberType NoteProperty -Name 'ConvertedDocID' -Value (ConvertGuidFrom-BigEndianByte $_.document_id) -Force -PassThru
        }
    }
}
End {}
}

Function Get-ProPresenterWorkspaces {
<#
        .SYNOPSIS
            Gets Library items from a ProPresenter Workspace
        .DESCRIPTION
            Since ProPresenter stores presentations in a SQLite Database, the PSSQLite module is required.  If it isn't installed, this function will install it.
            WARNING:  Consider this an Alpha/Beta release. USE AT YOUR OWN RISK!!!!!
        .PARAMETER rootpath
            The source directory.  This parameter expects a backup copy of the "%AppData%\Renewed Vision\Propresenter\Workspaces" folder
        .EXAMPLE
            Get-PropresenterWorkspaces
    #>
    Param(
        $rootpath = "$($env:Appdata)\RenewedVision\ProPresenter\Workspaces"
    )
    #Install PSSQLite module
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Install-Module -Name PSSQLite -Scope CurrentUser -Force
    }
    Import-Module PSSQLite

    #Load the source DB
    $sourcedbpath = Join-Path $rootpath -ChildPath "registry-v1.sqlite3"
    if(!(Test-path $sourcedbpath)){
        Throw "Unable to find source registry-v1.sqlite3 database!!!"
    }

    #Get the workspaces
    Invoke-SqliteQuery -DataSource $sourcedbpath -Query "SELECT * FROM workspaces"
}

Function Validate-LoroVersionVector {
<#
        .SYNOPSIS
            Attempts to validate a Loro document
        .DESCRIPTION
            This function is likely not required.  Built it hoping it would help with troubleshooting,.
        .PARAMETER updatedSnapshot
            A snapshot of the lorodocument you want to validate
        .PARAMETER newVersionVector
            A version vector that you expect to match the snapshot
        .EXAMPLE
            Get-PropresenterWorkspaces
    #>
    Param(
        $updatedSnapshot,
        [LoroCs.VersionVector]$newVersionVector
    )

    $VerifyDoc = New-Object LoroCs.LoroDoc
    $EmptyVv = New-Object LoroCs.VersionVector
    try {
        [void]$VerifyDoc.Import($updatedSnapshot)
        $UpdateJson = $VerifyDoc.ExportJsonUpdates($EmptyVv, $newVersionVector)
        if ($UpdateJson -and $UpdateJson -ne '{}' -and $UpdateJson -ne '[]') {
            return $true
        } else {
            return $false
        }
    } catch {
        Write-Error $_.Exception.Message
        return $false
    } finally {
        $VerifyDoc.Dispose()
    }
}

Function ConvertGuidFrom-BigEndianByte {
<#
        .SYNOPSIS
            Converts a bigEndianByte array to a Guid based on a ittleEndianByte Array
    #>
    Param($bigEndianBytes)
    [byte[]]$littleEndianBytes = [byte[]]::new(16)
    [Array]::Copy($bigEndianBytes, $littleEndianBytes, 16)
    [Array]::Reverse($littleEndianBytes, 0, 4)
    [Array]::Reverse($littleEndianBytes, 4, 2)
    [Array]::Reverse($littleEndianBytes, 6, 2)

    # Create the Guid
    [Guid]::New($littleEndianBytes)
}

Function ConvertGuidTo-BigEndianByte {
<#
        .SYNOPSIS
            Converts a GUID back to a BigEndianByte Array
    #>
    Param(
    [guid]$guid
    )
    $cleanGuidString = $guid.ToString().Replace("-", "")
    [byte[]]$byteArray = [byte[]] -split ($cleanGuidString -replace '..', '0x$& ')
    $byteArray
}
