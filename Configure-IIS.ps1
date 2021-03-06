Function Configure-IIS {

  # TO DOs
  # Clean up logic.  Remove Switches when we can check for a null variable
  # Create an option to create an app pool without a specfifc app pool account
  # Support multiple URL bindings
  # Add some logging output or some such

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [String] $SiteName,

        [Switch] $ReUseAppPool,

        [String] $AppPoolName = $SiteName,
      
        [String] $Framework = 'v4.0',
      
        [String] $SvcAcctName,
        
        [String] $SvcAcctPW,
        
        [String[]] $URL,

        [String] $LogDir = 'C:\Logging',

        [String] $DevGroup = 'Users',
        
        [Switch] $SSL,
        
        [Switch] $WebApp,

        [String] $RedirectURL

    )

    # Disable TCP Window Scaling
    Set-NetTCPSetting -AutoTuningLevelLocal Disabled

    # Add SA-TFSBuildAgent to local administrators group
    $Group = [ADSI]"WinNT://Localhost/Administrators,group"
    $Members = $Group.psbase.invoke("Members") | ForEach-Object {$_.GetType().invokemember("Name","GetProperty",$null,$_,$null)}
    If ($Members -notcontains "SA-TFSBuildAgent") { $Group.add("WinNT://Freemanco/SA-TFSBuildAgent") }

    # Create Logging Directory
    If (!(Test-Path $LogDir)) {New-item -ItemType Directory -Path $LogDir}
    $Perms = Get-ACL $LogDir
    $ACE = New-Object System.Security.AccessControl.FileSystemAccessRule("Users","WriteData","allow")
    $Perms.AddAccessRule($ACE)
    Set-Acl $LogDir $Perms

    # Create Share
    If (Get-SmbShare -Name 'Logging' -ErrorAction SilentlyContinue) {
      New-SmbShare -Name 'Logging' -Path $LogDir -ReadAccess $DevGroup
    }

    # Set ExecutionPolicy to allow for the import of the WebAdministration Module
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted

    Import-Module ServerManager

    # Check for installed Modules and install missing ones.

    # Version Check - 6.2 or greater is WS 2012 and above
    $InstallFeatures = @()
    If ([System.Environment]::OSVersion.Version -ge 6.2) {
      $CheckFeatures = Get-WindowsFeature Web-Server, Web-Asp-Net, Web-Net-Ext, Web-Asp-Net45, Web-Net-Ext45, Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Log-Libraries, Web-Basic-Auth, Web-Windows-Auth, Web-Mgmt-Console, Web-Mgmt-Service, NET-HTTP-Activation, NET-HTTP-Activation45
    } Else {
      $CheckFeatures = Get-WindowsFeature Web-Server, Web-Asp-Net, Web-Net-Ext, Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Log-Libraries, Web-Basic-Auth, Web-Windows-Auth, Web-Mgmt-Console, Web-Mgmt-Service, NET-HTTP-Activation
    }
    $CheckFeatures | ForEach-Object {
      If ($_.Installed -eq $false) {
        $InstallFeatures += $_.Name
      }
    }
    If ($InstallFeatures -ne $null) {
      Add-WindowsFeature $InstallFeatures | Out-Null
    }

  Add-WindowsFeature Web-Performance -IncludeAllSubFeature | Out-Null

  Add-WindowsFeature WAS -IncludeAllSubFeature | Out-Null
   
    
  Import-Module WebAdministration


  # Get Cert
    If ($SSL) {
      $allCerts = Get-ChildItem cert:\localmachine\my
      # Find the Certificate that is defined for the domain name 
      ForEach ($cert in $allCerts) { 
          If ($cert.SubjectName.Name -match "freemanco.com") { 
              $WebCert = $cert
          } 
      }
    }


    # Create AppPool and assign values
    If ($ReuseAppPool) {
      If (!(Test-Path "IIS:\\AppPools\$AppPoolName")) {Throw "The app pool $AppPoolName does not exist"}
    }
    Else {
      If (!(Test-Path "IIS:\\AppPools\$AppPoolName")) {
        Write-Verbose "App Pool $AppPoolName does not exist, creating now"
        New-Item "IIS:\AppPools\$AppPoolName" | Out-Null
      }
      Set-Itemproperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value $Framework
      If ($SvcAcctName) {
        Write-Verbose "Setting app pool identity..."
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.identityType -Value 3
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.userName -Value $SvcAcctName
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.password -Value $SvcAcctPW
      }
      Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.loadUserProfile -Value $true
    }    
    
    # Create Web Site
    If (Test-Path "IIS:\Sites\$siteName") {
        $WebSite = Get-Item "IIS:\Sites\$SiteName"
    }
    Else {
        If (!(Test-Path "c:\inetpub\$SiteName")) {New-Item "c:\inetpub\$SiteName" -type Directory | Out-Null}
        $WebSite = New-Item "IIS:\Sites\$SiteName"  -bindings @{protocol="http";bindingInformation=":80:$($URL[0])"} -physicalPath "c:\inetpub\$SiteName" | Out-Null
    }
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPoolName
    
    # Add HTTPS binding
    If (!(Get-WebBinding -Name $SiteName -Protocol HTTPS) -and $SSL) {
        Write-Verbose 'Setting SSL Binding'
        New-WebBinding -Name $SiteName -IPAddress "*" -Port 443 -HostHeader $URL[0] -Protocol HTTPS | Out-Null
        Get-Item "Cert:\LocalMachine\my\$($WebCert.Thumbprint)" | new-item IIS:\sslbindings\0.0.0.0!443 | Out-Null
    }

    # Add additional URLs
    If ($URL.count -gt 1) {
      For ($i = 1; $i -le $URL.Count; $i++) {
        New-WebBinding -Name $SiteName -IPAddress "*" -Port 80 -HostHeader $URL[$i] -Protocol HTTP | Out-Null
      }
    }
    
    # Add Application
    If (!(Test-Path "IIS:\Sites\$SiteName\$SiteName") -and $WebApp) {
        If (!(Test-Path "c:\inetpub\$SiteName\$SiteName")) {New-Item "c:\inetpub\$SiteName\$SiteName" -type Directory | Out-Null}
        New-Item "IIS:\Sites\$SiteName\$SiteName"  -Type Application -PhysicalPath "c:\inetpub\$SiteName\$SiteName" | Out-Null
        Set-ItemProperty "IIS:\Sites\$SiteName\$SiteName" -Name applicationPool -Value $AppPoolName
    }
        
    # Remove the Default Web Site
    If (Test-Path "IIS:\Sites\Default Web Site") {Remove-Item "IIS:\Sites\Default Web Site" -Recurse}

    #Configure Redirect
    If ($RedirectURL) {
      If (!(Get-WindowsFeature Web-Http-Redirect).Installed) {Add-WindowsFeature Web-Http-Redirect}
      Set-WebConfiguration system.webServer/httpRedirect "IIS:\sites\$SiteName" -Value @{enabled="true";destination="$RedirectURL";exactDestination="true";httpResponseStatus="Found"}
    }

}


# LBT Prod
# DALPRDLBTWFE01/02
# Configure-IIS -SiteName "LBTProd" -URL "lbt.freemanco.com"
# new-smbshare -Name 'Logging' -Path 'C:\Logging' -ReadAccess 'Freemanco\GS-Developers-Project-SharePoint-LBT'


# LBT Test
# DALTSTLBTWFE01/02
# Configure-IIS -SiteName "LBTTest" -URL "lbttest.freemanco.com"


# EOS Prod
# DALDMZEOSWFE01/02
# Configure-IIS -SiteName "EOS" -URL "eos.encore-us.com" -SSL


# EOS Dev
# DALDEVEOSWCF01
# Configure-IIS -SiteName "EOSFileStorage" -URL "EOSFileStorageDev.freemanco.com" -SvcAcctName "SA-DEVEOS-FileStore" -SvcAcctPW "E?{:FPEkc>{qI:K" -WebApp

# CetePDF2
# DALPRDPSSPST01
# Configure-IIS -SiteName "CeTePDF2" -SvcAcctName "SA-PRDPSS-CeTePDF2" -SvcAcctPW "1z{R^V(;4K7wfRx" -URL "cetepdf2.freemanco.com" -WebApp


# EOS Training
# DALTSDEMSWFE01/02
# Configure-IIS -SiteName "EOS" -URL "eosuat.freemanco.com" -SSL

# DALTSTEMSWSV01/02
# Configure-IIS -SiteName "EOSAPI" -SvcAcctName "SA-TRNEOS-EOSAPI" -SvcAcctPW "P_=+e7QBO:7E/Fa" -URL "eosapiuat.freemanco.com" -SSL


# FAVEvents Redirect
# configure-iis -SiteName FAVEvents -ReUseAppPool -AppPoolName Redirects -URL "favevents.freemanco.com" -RedirectURL "https://adfs.freemanco.com/adfs/ls/?wa=wsignin1.0&wtrealm=urn:federation:MicrosoftOnline&wctx=MEST%3D0%26LoginOptions%3D2%26wa%3Dwsignin1.0%26rpsnv%3D2%26ct%3D1292977249%26rver%3D6.1.6206.0%26wp%3DMCMBI%26wreply%3Dhttps%3A%2F%2Ffreemanco.sharepoint.com%2Fsites%2Ffaveventstest%2FSitePages%2FHome.aspx%26lc%3D1033%26id%3D271345%26bk%3D1292977249"


# EMS Test
# DALTSDEMSWFE01/02
# Configure-IIS -SiteName "EOS" -URL "eostest.freemanco.com" -SSL

# DALTSTEMSWSV01/02
# Configure-IIS -SiteName "EOSAPI" -SvcAcctName "SA-TSTEOS-EOSAPI" -SvcAcctPW "" -URL "eosapitest.freemanco.com"



# Passport 2
# DALTRNWCF01
# Configure-IIS -SiteName "SimplifySvcs" -ReUseAppPool -AppPoolName "Freeman.Simplify.Services" -URL "SimplifySvcsTraining.freemanco.com" -WebApp
# Configure-IIS -SiteName "FacilityMaster" -AppPoolName "FacilityMaster" -URL "FacilityMasterTraining.freemanco.com" -WebApp
# Configure-IIS -SiteName "ShowDataSvcs" -AppPoolName "ShowDataSvcs" -URL "ShowDataSvcsTraining.freemanco.com" -WebApp
# Configure-IIS -SiteName "PMService" -AppPoolName "PMService" -URL "PMServiceTraining.freemanco.com" -WebApp


# Passport 2 HotFix
# DALTRDPSS01/02
# Configure-IIS -SiteName "PassportDesignHotFix" -ReUseAppPool -AppPoolName "PassportDesign" -URL "PassportDesignHotFix.freemanco.com" -SSL
# DALTRDPSP01/02
# Configure-IIS -SiteName "PassportPlusHotFix" -ReUseAppPool -AppPoolName "PassportPlus" -URL "PassportPlusHotFix.freemanco.com" -SSL
# DALTRDWSV01
# Configure-IIS -SiteName "PassportAPIHotFix" -ReUseAppPool -AppPoolName "ExpoAPI" -URL "PassportAPIHotFix.freemanco.com"
# DALTRNWCF01
# Configure-IIS -SiteName "CeTePDFHotFix" -ReUseAppPool -AppPoolName "CeTePDF2b" -URL "CeTePDFHotFix.freemanco.com" -WebApp
# Configure-IIS -SiteName "EventEngineHotFix" -ReUseAppPool -AppPoolName "EventEngine2b" -URL "EventEngineHotFix.freemanco.com" -WebApp
# Configure-IIS -SiteName "PassportETLHotFix" -ReUseAppPool -AppPoolName "PassportETL2b" -URL "PassportETL2bHotFix.freemanco.com" -WebApp
# Configure-IIS -SiteName "SimplifySvcsHotFix" -ReUseAppPool -AppPoolName "Freeman.Simplify.Services" -URL "SimplifySvcsHotFix.freemanco.com" -WebApp
# Configure-IIS -SiteName "FacilityMasterHotFix" -AppPoolName "FacilityMaster" -URL "FacilityMasterHotFix.freemanco.com" -WebApp
# Configure-IIS -SiteName "ShowDataSvcsHotFix" -AppPoolName "ShowDataSvcs" -URL "ShowDataSvcsHotFix.freemanco.com" -WebApp
# Configure-IIS -SiteName "PMServiceHotFix" -AppPoolName "PMService" -URL "PMServiceHotFix.freemanco.com" -WebApp
# DALTRDWCF01
# Configure-IIS -SiteName "LiveCycleHotFix" -AppPoolName "Freeman.Simplify.LiveCycleWebServices" -URL "LiveCycleHotFix.freemanco.com" -WebApp

# Passport 2 vNext
# DALTSDPSS01/02
# Configure-IIS -SiteName "PassportDesignvNext" -ReUseAppPool -AppPoolName "PassportTest" -URL "PassportDesignvNextTest.freemanco.com" -SSL
# DALTSDPSP01/02
# Configure-IIS -SiteName "PassportPlusvNext" -ReUseAppPool -AppPoolName "PassportPlus" -URL "PassportPlusvNextTest.freemanco.com" -SSL
# DALTSDWSV01
# Configure-IIS -SiteName "PassportAPIvNext" -ReUseAppPool -AppPoolName "ExpoAPI" -URL "PassportAPIvnexttest.freemanco.com" -SSL
# DALTSTWCF01
# Configure-IIS -SiteName "CeTePDFvNext" -ReUseAppPool -AppPoolName "CeTePDF" -URL "CeTePDFvnexttest.freemanco.com" -WebApp
# Configure-IIS -SiteName "EventEnginevNext" -ReUseAppPool -AppPoolName "EventEngine" -URL "EventEnginevnexttest.freemanco.com" -WebApp
# Configure-IIS -SiteName "PassportETLvNext" -ReUseAppPool -AppPoolName "Freeman.ETL.Services" -URL "PassportETL2bvnexttest.freemanco.com" -WebApp
# Configure-IIS -SiteName "SimplifySvcsvNext" -ReUseAppPool -AppPoolName "Freeman.Simplify.Services" -URL "SimplifySvcsvnexttest.freemanco.com" -WebApp
# Configure-IIS -SiteName "FacilityMastervNext" -ReUseAppPool -AppPoolName "FacilityMasterServices" -URL "FacilityMastervnexttest.freemanco.com" -WebApp
# Configure-IIS -SiteName "ShowDataSvcsvNext" -ReUseAppPool -AppPoolName "ShowDataServices" -URL "ShowDataSvcsvnexttest.freemanco.com" -WebApp
# Configure-IIS -SiteName "PMServicevNext" -AppPoolName "PMService" -URL "PMServicevnexttest.freemanco.com" -WebApp
# DALTSDWCF01
# Configure-IIS -SiteName "LiveCyclevNext" -AppPoolName "Freeman.Simplify.LiveCycleWebServices" -URL "LiveCyclevnexttest.freemanco.com" -WebApp


# FTS Portal Dev
# Configure-IIS -SiteName "FTSPortal" -URL "FTSPortalDev.Freemanco.com" -SSL

# FTS Portal Test
# Configure-IIS -SiteName "FTSPortal" -URL "FTSPortalTest.Freemanco.com" -SSL

# FTS Portal Prod
# Configure-IIS -SiteName "FTSPortal" -URL "FTSPortal.Freemanco.com"