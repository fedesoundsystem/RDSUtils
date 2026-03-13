################################################################################################################################################################
#Variables.
################################################################################################################################################################
$FileServer = "FileServer.domain.tld"

$ConnectionBrokers = "ConnectionBroker1.domain.tld","ConnectionBroker2.domain.tld","ConnectionBroker3.domain.tld"
foreach ($ConnectionBroker in $ConnectionBrokers)
    {
#Lists collections with UPD set up.
    $Collections = (Get-RDSessionCollection -ConnectionBroker $ConnectionBroker).CollectionName
    $UPDCollections = @()
    foreach ($Collection in $Collections)
        {
        $UPDPath = Get-RDSessionCollectionConfiguration -ConnectionBroker $ConnectionBroker -CollectionName $Collection -UserProfileDisk | select -ExpandProperty DiskPath
        if ($UPDPath -ne "")
            {
            $Table = @{
                Collection = $Collection
                UPDPath = $UPDPath.split("\")[3]
                Servers = (Get-RDSessionHost -ConnectionBroker $ConnectionBroker -CollectionName $Collection).SessionHost
                }
            $UPDCollections += New-Object PSObject -Property $Table
            }
        }

#Lists users currently connected to an UPD Collection.
    $Sessions = Get-RDUserSession -ConnectionBroker $ConnectionBroker | where { $UPDCollections.Collection -contains $_.CollectionName }

#Lists open UPD profiles.
    $SessionOption = New-PSSessionOption -NoMachineProfile
    $RemoteFiles = Invoke-Command $FileServer {
        $RemoteFiles = @()
        $OpenFiles = Get-SmbOpenFile | where { $_.Path -match ($($Using:UPDCollections.updpath | foreach {"\\$_\\"}) -join "|")}
        foreach ($OpenFile in $OpenFiles)
            {
            $File = @{
                FileID = $OpenFile.FileId
                Filename = (($OpenFile).ShareRelativePath).Replace("UVHD-","")
                Server = (($OpenFile.ClientUserName).split("\")[1]) -replace("\$","")
                }
            $RemoteFiles += [pscustomobject]$File
            }
         return $RemoteFiles
        } -SessionOption $SessionOption

#Creates a table with connected users data.
    $LoggedOnUsers = @()
    foreach ($Session in $Sessions)
        {
        $LoggedOnUser = @{
            User = $Session.UserName
            Server = $Session.HostServer.Split(".")[0]
            SID = (New-Object System.Security.Principal.NTAccount($Session.UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            UnifiedSessionId = $Session.UnifiedSessionId
            }
        $LoggedOnUsers += [pscustomobject]$LoggedOnUser
        }

#Not an PS expert, so table made up from prior table so I can get the same object type. Apart from that, also deduping files.
    $Openfiles = @()
    foreach ($RemoteFile in $RemoteFiles| where {$_.filename -clike "*VHDX"})
        {
        $File = @{
            SID = $RemoteFile.Filename -replace(".VHDX","")
            Server = $RemoteFile.Server
            }
        $Openfiles += New-Object PSObject -Property $File
        }

#Table comparison
    $Comparison = Compare-Object -ReferenceObject $LoggedOnUsers -DifferenceObject $OpenFiles -Property SID,Server
    $ConnectionBroker
    if (($Comparison |measure).count -eq 0)
        {
        Write-Information -Message "No temporary profiles nor open files found." -InformationAction Continue
        }
    else
        {
        $Comparison
        }
################################################################################################################################################################
#Closes open files.
################################################################################################################################################################
#If there's an open file and no matching session, it means that the RD SessionHost didn't close the file properly.
    foreach ($Difference in $Comparison | where {$_.SideIndicator -eq "=>"})
        {
#As getting sessions info can take a while, maybe there's some difference. This double checks again.
#This uses $RemoteFiles as we need to close duplicated files.
        $User = (New-Object System.Security.Principal.SecurityIdentifier($Difference.SID)).Translate([System.Security.Principal.NTAccount]).Value.Split("\")[1]
        $SessionCheck = (Get-RDUserSession -ConnectionBroker $ConnectionBroker | where {$_.UserName -like "*$User*" -and $_.HostServer -eq "$Difference.server" } | measure).Count
        if ($SessionCheck -ne 1)
            {
            $FileID = $RemoteFiles | where {$_.Filename -like "*$($Difference.SID)*" -and $_.Server -eq $Difference.Server} | select -ExpandProperty FileID
            Invoke-Command $FileServer {
                foreach ($File in $Using:FileID)
                    {
                    Close-SmbOpenFile -FileId $File -Force
                    }
                } -SessionOption $SessionOption
            }
        }

################################################################################################################################################################
#Closes temporary profiles.
################################################################################################################################################################
#If an active session appears without a matching open file, that means a temporary profile being used.
#This logs off all users and deletes temporary profile one by one, with the intend to have everything already clean by the time the user logs in again, hoping to get them a clean session with UPD correctly connected.
    foreach ($Difference in $Comparison | where {$_.SideIndicator -eq "<="})
        {
#As getting sessions info can take a while, maybe there's some difference. This double checks again.
#If there's no matching open file where the user logged on, the session is logged off and cleaning takes place.

        $OpenFileCheck = Invoke-Command $FileServer {
            (Get-SmbOpenFile | where {$_.ShareRelativePath -like "*$($Using:Difference.SID)*" -and $_.ClientUserName -like "*$($Using:Difference.server)*"} | measure).count
            } -SessionOption $SessionOption
        if ($OpenFileCheck -eq 0)
            {
            $HostServer = "$($Difference.server)"+".domain.tld"
            $ProfileImagePath = Invoke-Command $HostServer {
                $ProfileImagePath = @()
                $RegeditPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
                foreach ($Key in Get-ChildItem "$RegeditPath\$($Using:Difference.SID)*")
                    {
                    $SID = ($Key).name.Split("\")[6]
                    $ProfileImagePath += (Get-ItemProperty "$RegeditPath\$SID").ProfileImagePath
                    }
                return $ProfileImagePath
                } -SessionOption $SessionOption

            $UnifiedSessionID = $LoggedOnUsers | where {$_.server -eq "$($Difference.server)" -and $_.sid -eq "$($Difference.SID)"} | select -ExpandProperty UnifiedSessionID
#User is logged off.
            Invoke-RDUserLogoff -HostServer $HostServer -UnifiedSessionID $UnifiedSessionID -Force
            Invoke-Command $HostServer {
#First attemp to delete user profile instance cleanly.
                Get-CimInstance -class Win32_UserProfile | where {$_.sid -eq "$($Using:Difference.SID)"} | Remove-CimInstance -ErrorAction SilentlyContinue
#Second attemp to clean leftover data, if any.
                $RegeditPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
                if(Get-Item "$RegeditPath\$($Using:Difference.SID)")
                    {
                    Remove-Item "$RegeditPath\$($Using:Difference.SID)" -Force -ErrorAction SilentlyContinue
                    }
#Also delete regedit info to not find any temporary profile and load it.
                foreach ($Path in $Using:ProfileImagePath)
                    {
                    if (Get-Item $Path)
                        {
                        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                } -SessionOption $SessionOption
            }
        }

################################################################################################################################################################
#Deleting any existing regedit entries left.
################################################################################################################################################################
    foreach ($Server in $UPDCollections | select -ExpandProperty servers)
        {
        Invoke-Command $Server {
            $RegeditPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
            foreach ($Key in Get-ChildItem $RegeditPath)
                {
                $SID = ($Key).name.Split("\")[6]
                $TempProfile = ((Get-ItemProperty "$RegeditPath\$SID").ProfileImagePath -match "your domain, as in domain.user-backup, or domain.user.000|\\Temp" -and ((Get-ItemProperty "$RegeditPath\$SID").ProfileImagePath -notmatch "\\ServiceProfiles\\TEMP" ))
                $Bak = $SID -match '.bak'
                if($TempProfile -or $bak)
                    {
                    Remove-Item $Key.PSPath
                    }
                }
            } -SessionOption $SessionOption
        }

################################################################################################################################################################
#Deleting any existing C:\Users folders left.
################################################################################################################################################################
    $FoldersInSH = @()
    foreach ($Server in $UPDCollections | select -ExpandProperty servers)
        {
        $FoldersInSH += Get-ChildItem "\\$Server\c$\users\" | where {$_.name -notmatch "your existing folders that you would not like to be deleted"} | select -ExpandProperty FullName
        }

    $RDUsers = $LoggedOnUsers | foreach {"\\$($_.server)\c$\Users\$($_.user)"}

    foreach ($FolderInSH in $FoldersInSH)
        {
        if (($FolderInSH -notin $RDUsers) -and ($FolderInSH -notlike "*public*"))
            {
            Invoke-Command $($FolderInSH.split("\")[2]) {
                $Folder = $Using:FolderInSH
                $Folder = $Folder.split('\')[5]
                Remove-Item "C:\Users\$Folder" -Recurse -Force
                } -SessionOption $SessionOption
            }
        }
    }
