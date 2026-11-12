# ProPresenterWorkspaceManagement
Powershell module for managing ProPresenter 22 workspaces

# WARNING!!!!!!

At best this is a beta release.  I only have a very small understanding of Loro documents.  Most of the Loro document actions were built with AI.
Do NOT restore items to your production workspace.
It is better to restore to a working workspace and then copy/export the restored items so you let ProPresenter manage your production workspace
 1. Create a blank local workspace in ProPresenter version 22
 2. Restore an item from your backup to the blank local workspace
 3. Copy the restored presentation to your production workspace, or export the presentation to a probundle.

Note, I've only tested this on library items with no media. However I am making this available provide some rudimentary documentation on how the presentations are stored in ProPresenter 22
This script is provided as is and without warrenty.  
Although I've gotten it this far, I likely don't have time to build it much further.
Please fork this repository, build on it and share with the community.


# EXAMPLES

#Get workspaces in default folder

Get-ProPresenterWorkspaces

#Get Workspaces in a backup folder 

Get-PropresenterWorkspaces -rootpath 'C:\temp\ProPresenter\Workspaces'

#List existing items in a workspace

$ExistingItems = Get-PropresenterWorkspaceItems -WorkspaceName 'New Test'

#List existing items in a workspace from a backup folder

$ItemsAvailableToRestore = Get-PropresenterWorkspaceItems -Workspaces_Root_Path 'C:\temp\ProPresenter\Workspaces' -WorkspaceName 'ProPresenter'

#Attempt to restore an item from a backup source

Restore-ProPresenterLibraryItem -BackupPathSource 'C:\Temp\ProPresenter' -SourceWorkspaceName 'ProPresenter' -ItemToRestore '2026 BOP/PSALM 119' -DestinationWorkspaceName 'New Test' -DestinationLibrary 'Default'

#Get Restored Item

Get-PropresenterWorkspaceItems -WorkspaceName 'ProPresenter' | Where{$_.core_path -like '*PSALM 119*'}
