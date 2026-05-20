﻿#Requires -RunAsAdministrator

param(
    [Alias("DruRun")]
    [switch]$DryRun,

    [ValidateSet("Base", "PowerShell", "Java", "Maven", "Node", "Python", "IDE", "Servers", "Database", "Cli", "DataScience")]
    [string[]]$Only = @()
)

$ErrorActionPreference = "Stop"

$logPath = Join-Path $env:TEMP "Install-DevEnv.log"
$wingetRawLogPath = Join-Path $env:TEMP "Install-DevEnv-Winget-Raw.log"
$summaryPath = Join-Path $env:TEMP "Install-DevEnv-Summary.csv"

Start-Transcript -Path $logPath -Append

$results = New-Object System.Collections.Generic.List[object]

function Test-SectionEnabled {
    param([Parameter(Mandatory)][string]$Section)

    if (-not $Only -or $Only.Count -eq 0) { return $true }
    return ($Only -contains $Section)
}

function Write-SectionSkipped {
    param([Parameter(Mandatory)][string]$Section)

    Write-Host ""
    Write-Host "⏭️ Pulando seção '$Section' por filtro -Only." -ForegroundColor DarkGray
}

function Invoke-Section {
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    if (Test-SectionEnabled -Section $Section) {
        & $ScriptBlock
    }
    else {
        Write-SectionSkipped -Section $Section
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Write-RawWingetLog {
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Output = ""
    )

    $separator = "============================================================"
    Add-Content -Path $wingetRawLogPath -Value $separator
    Add-Content -Path $wingetRawLogPath -Value ("Data/Hora: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    Add-Content -Path $wingetRawLogPath -Value ("Comando: " + $CommandLine)
    Add-Content -Path $wingetRawLogPath -Value ("ExitCode: " + $ExitCode)
    Add-Content -Path $wingetRawLogPath -Value "Saída:"
    Add-Content -Path $wingetRawLogPath -Value $Output
    Add-Content -Path $wingetRawLogPath -Value ""
}

function Invoke-WingetQuiet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $commandLine = "winget $($Arguments -join ' ')"
    Write-Host ""
    Write-Host "Executando: $commandLine" -ForegroundColor DarkGray

    if ($DryRun -and ($Arguments[0] -in @("install", "upgrade", "source"))) {
        Write-Host "DRY-RUN: comando não executado." -ForegroundColor Yellow
        Write-RawWingetLog -CommandLine $commandLine -ExitCode 0 -Output "DRY-RUN: comando não executado."

        return [PSCustomObject]@{
            ExitCode = 0
            Output   = "DRY-RUN: comando não executado."
        }
    }

    $output = & winget @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    Write-RawWingetLog -CommandLine $commandLine -ExitCode $exitCode -Output $output

    return [PSCustomObject]@{
        ExitCode = [int]$exitCode
        Output   = $output
    }
}

function Get-WingetErrorText {
    param([Parameter(Mandatory)][int]$ExitCode)

    if ($ExitCode -eq 0) { return "" }

    $result = Invoke-WingetQuiet -Arguments @("error", "$ExitCode")
    if ($result.ExitCode -eq 0 -and $result.Output.Trim()) {
        return ($result.Output.Trim())
    }

    return "Código não traduzido pelo winget error."
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Status,
        [string]$Details = ""
    )

    if ($null -eq $script:results) {
        $script:results = New-Object System.Collections.Generic.List[object]
    }

    [void]$script:results.Add([PSCustomObject]@{
        Name    = $Name
        Id      = $Id
        Source  = $Source
        Status  = $Status
        Details = $Details
    })
}

function New-Package {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet("winget", "msstore")][string]$Source,
        [string]$InstallerType = "",
        [string]$FallbackId = "",
        [ValidateSet("", "winget", "msstore")][string]$FallbackSource = "",
        [AllowNull()][object]$Notes = $null
    )

    $notesText = if ($null -eq $Notes) { "" } else { ($Notes | Out-String).Trim() }

    return [PSCustomObject]@{
        Name          = $Name
        Id            = $Id
        Source        = $Source
        InstallerType = $InstallerType
        FallbackId    = $FallbackId
        FallbackSource = $FallbackSource
        Notes         = $notesText
    }
}

function Get-WingetIdentityArguments {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object]$Package
    )

    $args = @($Command)

    # Usa identidade exata por ID. Isso evita falso positivo por nome parecido.
    $args += "-e"
    $args += "--id"
    $args += $Package.Id
    $args += "--source"
    $args += $Package.Source

    return $args
}

function Test-WingetPackageAvailable {
    param([Parameter(Mandatory)][object]$Package)

    Write-Host "🔎 Procurando no catálogo: $($Package.Name) [$($Package.Id)] em $($Package.Source)" -ForegroundColor DarkGray

    $args = Get-WingetIdentityArguments -Command "show" -Package $Package
    $args += "--accept-source-agreements"

    $result = Invoke-WingetQuiet -Arguments $args
    return ($result.ExitCode -eq 0)
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][object]$Package)

    # Validação local somente por ID exato, evitando a busca frágil por nome.
    $args = Get-WingetIdentityArguments -Command "list" -Package $Package
    $args += "--accept-source-agreements"

    $result = Invoke-WingetQuiet -Arguments $args
    return ($result.ExitCode -eq 0)
}

function Install-WingetPackage {
    param([Parameter(Mandatory)][object]$Package)

    $args = Get-WingetIdentityArguments -Command "install" -Package $Package
    $args += "--accept-package-agreements"
    $args += "--accept-source-agreements"
    $args += "--disable-interactivity"

    if ($Package.Source -eq "winget") { $args += "--silent" }
    if (($Package.InstallerType) -and ($Package.InstallerType.Trim() -ne "")) {
        $args += "--installer-type"
        $args += $Package.InstallerType
    }

    $result = Invoke-WingetQuiet -Arguments $args

    if (($result.ExitCode -ne 0) -and ($Package.InstallerType) -and ($Package.InstallerType.Trim() -ne "")) {
        Write-Warning "⚠️ $($Package.Name): tentativa com --installer-type $($Package.InstallerType) falhou. Tentando sem forçar tipo."

        $args = Get-WingetIdentityArguments -Command "install" -Package $Package
        $args += "--accept-package-agreements"
        $args += "--accept-source-agreements"
        $args += "--disable-interactivity"
        if ($Package.Source -eq "winget") { $args += "--silent" }

        $result = Invoke-WingetQuiet -Arguments $args
    }

    if (($result.ExitCode -ne 0) -and ($Package.Source -eq "winget")) {
        Write-Warning "⚠️ $($Package.Name): tentativa silenciosa falhou. Tentando sem --silent."

        $args = Get-WingetIdentityArguments -Command "install" -Package $Package
        $args += "--accept-package-agreements"
        $args += "--accept-source-agreements"
        $args += "--disable-interactivity"
        if (($Package.InstallerType) -and ($Package.InstallerType.Trim() -ne "")) {
            $args += "--installer-type"
            $args += $Package.InstallerType
        }

        $result = Invoke-WingetQuiet -Arguments $args
    }

    return $result
}

function Upgrade-WingetPackage {
    param([Parameter(Mandatory)][object]$Package)

    $args = Get-WingetIdentityArguments -Command "upgrade" -Package $Package
    $args += "--accept-package-agreements"
    $args += "--accept-source-agreements"
    $args += "--disable-interactivity"

    if ($Package.Source -eq "winget") { $args += "--silent" }

    return Invoke-WingetQuiet -Arguments $args
}

function Invoke-PackageFallback {
    param([Parameter(Mandatory)][object]$Package)

    if (($Package.FallbackId) -and ($Package.FallbackSource)) {
        Write-Host ""
        Write-Host "🔁 Tentando fallback para $($Package.Name): $($Package.FallbackId) em $($Package.FallbackSource)" -ForegroundColor Cyan

        $fallbackPackage = [PSCustomObject]@{
            Name           = "$($Package.Name) - fallback"
            Id             = $Package.FallbackId
            Source         = $Package.FallbackSource
            InstallerType  = ""
            FallbackId     = ""
            FallbackSource = ""
            Notes          = "Fallback automático do pacote $($Package.Id)."
        }

        Install-OrUpgrade-WingetPackage -Package $fallbackPackage
        return $true
    }

    return $false
}

function Install-OrUpgrade-WingetPackage {
    param([Parameter(Mandatory)][object]$Package)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📦 Verificando: $($Package.Name)" -ForegroundColor Yellow
    Write-Host "ID: $($Package.Id)" -ForegroundColor DarkGray
    Write-Host "Fonte: $($Package.Source)" -ForegroundColor DarkGray
    if ($Package.Notes) { Write-Host "Nota: $($Package.Notes)" -ForegroundColor DarkGray }

    try {
        if ($DryRun) {
            Write-Host "DRY-RUN: instalação/atualização planejada para $($Package.Name)." -ForegroundColor Yellow
            Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "Pendente" -Details "DRY-RUN: pacote seria instalado ou atualizado por winget."
            return
        }

        $isAvailable = Test-WingetPackageAvailable -Package $Package
        if (-not $isAvailable) {
            Write-Warning "⚠️ Pacote não encontrado no catálogo: $($Package.Name) [$($Package.Id)]"

            $fallbackUsed = Invoke-PackageFallback -Package $Package
            if ($fallbackUsed) { return }

            Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "Não encontrado" -Details "Pacote não encontrado no catálogo $($Package.Source)."
            return
        }

        $isInstalled = Test-WingetPackageInstalled -Package $Package
        if ($isInstalled) {
            Write-Host "🔄 Já instalado. Tentando atualizar: $($Package.Name)" -ForegroundColor Cyan

            $result = Upgrade-WingetPackage -Package $Package
            $exitCode = $result.ExitCode
            $stillInstalled = Test-WingetPackageInstalled -Package $Package

            if ($stillInstalled) {
                Write-Host "✅ OK: $($Package.Name) está instalado/presente." -ForegroundColor Green

                $details = if ($result.Output -match "No available upgrade found|No newer package versions are available") {
                    "Já instalado; nenhuma atualização disponível."
                }
                else {
                    "Já instalado; tentativa de atualização concluída ou presença confirmada. Código retornado pelo upgrade: $exitCode."
                }

                Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "OK" -Details $details
                return
            }

            $errorText = Get-WingetErrorText -ExitCode $exitCode
            Write-Warning "⚠️ Upgrade retornou código $exitCode e o pacote não foi confirmado como instalado."
            Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "Verificar" -Details "Upgrade retornou código $exitCode. $errorText."
            return
        }

        Write-Host "⬇️ Instalando: $($Package.Name)" -ForegroundColor Cyan

        $result = Install-WingetPackage -Package $Package
        $exitCode = $result.ExitCode
        $installedAfterAttempt = Test-WingetPackageInstalled -Package $Package

        if ($installedAfterAttempt) {
            Write-Host "✅ OK: $($Package.Name) está instalado/presente." -ForegroundColor Green
            Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "OK" -Details "Instalado com sucesso. Código: $exitCode."
            return
        }

        $fallbackUsed = Invoke-PackageFallback -Package $Package
        if ($fallbackUsed) { return }

        $errorText = Get-WingetErrorText -ExitCode $exitCode
        Write-Warning "⚠️ Instalação não confirmada para $($Package.Name). Código: $exitCode"
        Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "Verificar" -Details "Instalação retornou código $exitCode. $errorText."
    }
    catch {
        Write-Warning "⚠️ Erro ao tratar pacote $($Package.Name): $_"

        $fallbackUsed = Invoke-PackageFallback -Package $Package
        if ($fallbackUsed) { return }

        Add-Result -Name $Package.Name -Id $Package.Id -Source $Package.Source -Status "Erro" -Details "$_"
    }
}

function Normalize-PathEntry {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$PathEntry)

    if ($null -eq $PathEntry) { return $null }
    $entry = $PathEntry.Trim()

    if (-not $entry) { return $null }

    # Remove aspas externas acidentais sem mexer no conteúdo interno.
    if ($entry.StartsWith('"') -and $entry.EndsWith('"') -and $entry.Length -ge 2) {
        $entry = $entry.Substring(1, $entry.Length - 2).Trim()
    }

    # Remove barra final, exceto em raiz de unidade, por exemplo C:\.
    if ($entry.Length -gt 3) {
        $entry = $entry.TrimEnd('\')
    }

    return $entry
}

function Update-SessionPath {
    Write-Host ""
    Write-Host "🔄 Sincronizando PATH da sessão com as variáveis do sistema..." -ForegroundColor DarkGray

    try {
        $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")

        # Reproduz o comportamento efetivo usual do ambiente de processo no Windows:
        # PATH de máquina primeiro, PATH de usuário depois.
        $rawEntries = @()
        if ($machinePath) { $rawEntries += ($machinePath -split ";") }
        if ($userPath) { $rawEntries += ($userPath -split ";") }

        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $normalizedEntries = New-Object System.Collections.Generic.List[string]

        foreach ($rawEntry in $rawEntries) {
            $normalized = Normalize-PathEntry -PathEntry $rawEntry
            if ($normalized -and $seen.Add($normalized)) {
                [void]$normalizedEntries.Add($normalized)
            }
        }

        $env:PATH = ($normalizedEntries -join ";")

        Write-Host "✅ PATH da sessão atualizado com sucesso." -ForegroundColor Green
    }
    catch {
        Write-Warning "⚠️ Falha ao atualizar PATH da sessão: $_"
        Add-Result -Name "Session PATH Sync" -Id "N/A" -Source "System" -Status "Erro" -Details "$_"
    }
}

function Add-MachinePathEntry {
    param([Parameter(Mandatory)][string]$PathEntry)

    $normalizedTarget = Normalize-PathEntry -PathEntry $PathEntry
    if (-not $normalizedTarget) { return }

    try {
        $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        $entries = @()
        if ($machinePath) { $entries = $machinePath -split ";" }

        $exists = $false
        foreach ($entry in $entries) {
            $normalized = Normalize-PathEntry -PathEntry $entry
            if ($normalized -and ($normalized -ieq $normalizedTarget)) {
                $exists = $true
                break
            }
        }

        if ($exists) {
            Write-Host "✅ PATH de máquina já contém: $normalizedTarget" -ForegroundColor Green
            return
        }

        if ($DryRun) {
            Write-Host "DRY-RUN: adicionaria ao PATH de máquina: $normalizedTarget" -ForegroundColor Yellow
            return
        }

        $newPath = if ($machinePath) { "$machinePath;$normalizedTarget" } else { $normalizedTarget }
        [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
        Write-Host "✅ PATH de máquina atualizado com: $normalizedTarget" -ForegroundColor Green
        Update-SessionPath
    }
    catch {
        Write-Warning "⚠️ Falha ao adicionar entrada ao PATH de máquina: $_"
        Add-Result -Name "Machine PATH update" -Id $normalizedTarget -Source "System" -Status "Erro" -Details "$_"
    }
}

function Install-VSCodeExtension {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ExtensionId,
        [string]$Notes = ""
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🧩 Instalando extensão VS Code: $DisplayName" -ForegroundColor Yellow
    Write-Host "ID: $ExtensionId" -ForegroundColor DarkGray
    if ($Notes) { Write-Host "Nota: $Notes" -ForegroundColor DarkGray }

    try {
        # O PATH já deve ter sido sincronizado antes desta função ser chamada.
        # Não há fallback manual aqui: se 'code' não estiver no PATH, isso será registrado como pendência.
        $codeCmd = Get-Command code -ErrorAction SilentlyContinue

        if ($codeCmd) {
            $extInstallCmd = "`"$($codeCmd.Source)`" --install-extension $ExtensionId"
            Write-Host "Executando: $extInstallCmd" -ForegroundColor DarkGray

            if ($DryRun) {
                Write-Host "DRY-RUN: extensão não instalada." -ForegroundColor Yellow
                Write-RawWingetLog -CommandLine $extInstallCmd -ExitCode 0 -Output "DRY-RUN: comando não executado."
                Add-Result -Name "$DisplayName (VS Code)" -Id $ExtensionId -Source "VS Code CLI" -Status "Pendente" -Details "DRY-RUN: extensão seria instalada via code --install-extension."
                return
            }

            $extOutput = & $codeCmd.Source --install-extension $ExtensionId 2>&1 | Out-String
            $extExitCode = $LASTEXITCODE

            Write-RawWingetLog -CommandLine $extInstallCmd -ExitCode $extExitCode -Output $extOutput

            if ($extExitCode -eq 0) {
                Write-Host "✅ Extensão instalada/presente no VS Code: $DisplayName." -ForegroundColor Green
                Add-Result -Name "$DisplayName (VS Code)" -Id $ExtensionId -Source "VS Code CLI" -Status "OK" -Details "Extensão instalada/presente via code --install-extension."
            }
            else {
                Write-Warning "⚠️ Instalação da extensão retornou código $extExitCode. Verifique o log."
                Add-Result -Name "$DisplayName (VS Code)" -Id $ExtensionId -Source "VS Code CLI" -Status "Verificar" -Details "Código $extExitCode. Saída no log bruto."
            }
        }
        else {
            Write-Warning "⚠️ Comando 'code' não encontrado no PATH após a sincronização. A extensão não foi instalada."
            Add-Result -Name "$DisplayName (VS Code)" -Id $ExtensionId -Source "VS Code CLI" -Status "Pendente" -Details "Comando code não encontrado no PATH após sincronização. Abra uma nova sessão ou verifique se o VS Code adicionou o diretório bin ao PATH."
        }
    }
    catch {
        Write-Warning "⚠️ Erro ao instalar extensão VS Code ${DisplayName}: $_"
        Add-Result -Name "$DisplayName (VS Code)" -Id $ExtensionId -Source "VS Code CLI" -Status "Erro" -Details "$_"
    }
}

function Install-VSCodeExtensions {
    param([Parameter(Mandatory)][object[]]$Extensions)

    Update-SessionPath

    foreach ($extension in $Extensions) {
        Install-VSCodeExtension -DisplayName ([string]$extension.Name) -ExtensionId ([string]$extension.Id) -Notes ([string]$extension.Notes)
    }
}


function Initialize-PowerShellGallery {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📚 Preparando PowerShell Gallery para instalação de módulos..." -ForegroundColor Yellow

    try {
        $nuGetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuGetProvider) {
            if ($DryRun) {
                Write-Host "DRY-RUN: provedor NuGet seria instalado para PowerShellGet." -ForegroundColor Yellow
                Add-Result -Name "PowerShell Gallery readiness" -Id "PSGallery/NuGet" -Source "PowerShellGet" -Status "Pendente" -Details "DRY-RUN: provedor NuGet seria instalado."
                return
            }

            Write-Host "⬇️ Instalando provedor NuGet para PowerShellGet..." -ForegroundColor Cyan
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -ErrorAction Stop | Out-Null
        }

        $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($psGallery -and $psGallery.InstallationPolicy -ne "Trusted") {
            Write-Host "🔎 PSGallery não está marcada como Trusted. O script manterá a política atual e usará -Force nas instalações." -ForegroundColor DarkGray
        }

        Add-Result -Name "PowerShell Gallery readiness" -Id "PSGallery/NuGet" -Source "PowerShellGet" -Status "OK" -Details "Provedor NuGet disponível. Política da PSGallery preservada."
    }
    catch {
        Write-Warning "⚠️ Falha ao preparar PowerShell Gallery: $_"
        Add-Result -Name "PowerShell Gallery readiness" -Id "PSGallery/NuGet" -Source "PowerShellGet" -Status "Verificar" -Details "$_"
    }
}

function Install-PSGalleryModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Notes = $null
    )

    $notesText = if ($null -eq $Notes) { "" } else { ($Notes | Out-String).Trim() }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📚 Verificando módulo PowerShell: $Name" -ForegroundColor Yellow
    if ($notesText) { Write-Host "Nota: $notesText" -ForegroundColor DarkGray }

    try {
        $module = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1

        if ($module) {
            Write-Host "✅ Módulo já encontrado: $Name versão $($module.Version)." -ForegroundColor Green
            Add-Result -Name $Name -Id $Name -Source "PowerShell Gallery" -Status "OK" -Details "Módulo já instalado. Versão encontrada: $($module.Version)."
            return
        }

        if ($DryRun) {
            Write-Host "DRY-RUN: módulo seria instalado: $Name" -ForegroundColor Yellow
            Add-Result -Name $Name -Id $Name -Source "PowerShell Gallery" -Status "Pendente" -Details "DRY-RUN: módulo seria instalado via Install-Module."
            return
        }

        Write-Host "⬇️ Instalando módulo: $Name" -ForegroundColor Cyan
        Install-Module -Name $Name -Scope AllUsers -Force -AllowClobber -ErrorAction Stop

        $installed = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
        if ($installed) {
            Write-Host "✅ Módulo instalado: $Name versão $($installed.Version)." -ForegroundColor Green
            Add-Result -Name $Name -Id $Name -Source "PowerShell Gallery" -Status "OK" -Details "Módulo instalado. Versão encontrada: $($installed.Version)."
        }
        else {
            Write-Warning "⚠️ Instalação do módulo $Name não foi confirmada."
            Add-Result -Name $Name -Id $Name -Source "PowerShell Gallery" -Status "Verificar" -Details "Install-Module executou sem exceção, mas o módulo não foi localizado depois."
        }
    }
    catch {
        Write-Warning "⚠️ Erro ao instalar módulo ${Name}: $_"
        Add-Result -Name $Name -Id $Name -Source "PowerShell Gallery" -Status "Erro" -Details "$_"
    }
}

function Add-ManualResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Reason
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📋 Instalação manual necessária: $Name" -ForegroundColor Yellow
    Write-Host "Motivo: $Reason" -ForegroundColor DarkGray

    Add-Result -Name $Name -Id $Id -Source "Manual" -Status "Pendente" -Details $Reason
}

function Install-NpmGlobalTool {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$NpmPackage,
        [Parameter(Mandatory)][string]$ValidateCommand,
        [string]$Notes = ""
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📦 Verificando npm global: $DisplayName ($NpmPackage)" -ForegroundColor Yellow
    if ($Notes) { Write-Host "Nota: $Notes" -ForegroundColor DarkGray }

    try {
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if (-not $npmCmd) {
            Write-Warning "⚠️ npm não encontrado no PATH. Não é possível instalar $DisplayName."
            Add-Result -Name $DisplayName -Id $NpmPackage -Source "npm" -Status "Pendente" -Details "npm não encontrado no PATH. Instale Node.js e sincronize o PATH antes de tentar novamente."
            return
        }

        $existingCmd = Get-Command $ValidateCommand -ErrorAction SilentlyContinue
        if ($existingCmd) {
            $version = & $ValidateCommand --version 2>&1 | Out-String
            Write-Host "✅ $DisplayName já disponível: $($version.Trim())" -ForegroundColor Green
            Add-Result -Name $DisplayName -Id $NpmPackage -Source "npm" -Status "OK" -Details "Já instalado. Versão: $($version.Trim())"
            return
        }

        if ($DryRun) {
            Write-Host "DRY-RUN: npm install -g $NpmPackage não executado." -ForegroundColor Yellow
            Add-Result -Name $DisplayName -Id $NpmPackage -Source "npm" -Status "Pendente" -Details "DRY-RUN: ferramenta seria instalada globalmente via npm."
            return
        }

        Write-Host "⬇️ Instalando $DisplayName via: npm install -g $NpmPackage" -ForegroundColor Cyan
        $cmdLine = "npm install -g $NpmPackage"
        Write-Host "Executando: $cmdLine" -ForegroundColor DarkGray

        $installOutput = & npm install -g $NpmPackage 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        Write-RawWingetLog -CommandLine $cmdLine -ExitCode $exitCode -Output $installOutput

        Update-SessionPath

        $validateAfter = Get-Command $ValidateCommand -ErrorAction SilentlyContinue
        if ($validateAfter) {
            $version = & $ValidateCommand --version 2>&1 | Out-String
            Write-Host "✅ $DisplayName instalado com sucesso. Versão: $($version.Trim())" -ForegroundColor Green
            Add-Result -Name $DisplayName -Id $NpmPackage -Source "npm" -Status "OK" -Details "Instalado via npm. Versão: $($version.Trim())"
        }
        else {
            Write-Warning "⚠️ ${DisplayName}: npm install executou (código $exitCode) mas o comando '$ValidateCommand' não foi encontrado no PATH."
            Add-Result -Name $DisplayName -Id $NpmPackage -Source "npm" -Status "Verificar" -Details "npm install retornou código $exitCode, mas '$ValidateCommand' não localizado no PATH após sincronização."
        }
    }
    catch {
        Write-Warning "⚠️ Erro ao instalar $DisplayName via npm: $_"
        Add-Result -Name $DisplayName -Id $NpmPackage -Source "npm" -Status "Erro" -Details "$_"
    }
}

function Install-JupyterViaPip {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📦 Verificando Jupyter (jupyterlab + notebook)..." -ForegroundColor Yellow

    try {
        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pythonCmd) {
            Write-Warning "⚠️ python não encontrado no PATH. Não é possível instalar Jupyter."
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip" -Status "Pendente" -Details "Python não encontrado no PATH. Instale Python e sincronize o PATH antes de tentar novamente."
            return
        }

        $jupyterCmd = Get-Command jupyter -ErrorAction SilentlyContinue
        if ($jupyterCmd) {
            $version = & jupyter --version 2>&1 | Out-String
            Write-Host "✅ Jupyter já disponível." -ForegroundColor Green
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip" -Status "OK" -Details "Já instalado. Saída de 'jupyter --version': $($version.Trim())"
            return
        }

        $jupyterRoot = "C:\DevTools\Jupyter"
        $venvPath = Join-Path $jupyterRoot ".venv"
        $venvPython = Join-Path $venvPath "Scripts\python.exe"
        $venvScripts = Join-Path $venvPath "Scripts"

        if ($DryRun) {
            Write-Host "DRY-RUN: criaria venv em $venvPath e instalaria jupyterlab + notebook." -ForegroundColor Yellow
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip/venv" -Status "Pendente" -Details "DRY-RUN: Jupyter seria instalado em venv dedicada: $venvPath."
            return
        }

        Write-Host "⬇️ Criando venv dedicada e instalando jupyterlab + notebook..." -ForegroundColor Cyan

        if (-not (Test-Path $jupyterRoot)) {
            New-Item -Path $jupyterRoot -ItemType Directory -Force | Out-Null
        }

        if (-not (Test-Path $venvPython)) {
            $venvOut = & python -m venv $venvPath 2>&1 | Out-String
            $venvCode = $LASTEXITCODE
            Write-RawWingetLog -CommandLine "python -m venv $venvPath" -ExitCode $venvCode -Output $venvOut

            if ($venvCode -ne 0) {
                Write-Warning "⚠️ Jupyter: falha ao criar venv. Código: $venvCode"
                Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip/venv" -Status "Erro" -Details "Falha ao criar venv em $venvPath. Código: $venvCode."
                return
            }
        }

        $pipUpgradeOut = & $venvPython -m pip install --upgrade pip 2>&1 | Out-String
        $pipUpgradeCode = $LASTEXITCODE
        Write-RawWingetLog -CommandLine "`"$venvPython`" -m pip install --upgrade pip" -ExitCode $pipUpgradeCode -Output $pipUpgradeOut

        if ($pipUpgradeCode -ne 0) {
            Write-Warning "⚠️ Jupyter: falha ao atualizar pip na venv. Código: $pipUpgradeCode"
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip/venv" -Status "Verificar" -Details "Falha ao atualizar pip na venv. Código: $pipUpgradeCode."
            return
        }

        $installOut = & $venvPython -m pip install jupyterlab notebook 2>&1 | Out-String
        $installCode = $LASTEXITCODE
        Write-RawWingetLog -CommandLine "`"$venvPython`" -m pip install jupyterlab notebook" -ExitCode $installCode -Output $installOut

        if ($installCode -ne 0) {
            Write-Warning "⚠️ Jupyter: falha ao instalar jupyterlab + notebook. Código: $installCode"
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip/venv" -Status "Verificar" -Details "pip install retornou código $installCode na venv $venvPath."
            return
        }

        Add-MachinePathEntry -PathEntry $venvScripts

        Update-SessionPath

        $jupyterAfter = Get-Command jupyter -ErrorAction SilentlyContinue
        if ($jupyterAfter) {
            $version = & jupyter --version 2>&1 | Out-String
            Write-Host "✅ Jupyter instalado com sucesso." -ForegroundColor Green
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip/venv" -Status "OK" -Details "Instalado em venv dedicada ($venvPath). Saída: $($version.Trim())"
        }
        else {
            Write-Warning "⚠️ Jupyter: pip install executou (código $installCode) mas 'jupyter' não encontrado no PATH."
            Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip/venv" -Status "Verificar" -Details "Instalado em $venvPath, mas 'jupyter' não localizado no PATH. Verifique a entrada $venvScripts."
        }
    }
    catch {
        Write-Warning "⚠️ Erro ao instalar Jupyter via pip: $_"
        Add-Result -Name "Jupyter" -Id "jupyterlab+notebook" -Source "pip" -Status "Erro" -Details "$_"
    }
}

function Resolve-LatestWingetPackageByIdPrefix {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$IdPrefix,
        [Parameter(Mandatory)][ValidateSet("winget", "msstore")][string]$Source,
        [string]$Notes = ""
    )

    Write-Host ""
    Write-Host "🔎 Procurando versão mais nova no WinGet para: $Name ($IdPrefix*)" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host "DRY-RUN: usaria busca winget para resolver o ID mais novo por prefixo." -ForegroundColor Yellow
    }

    try {
        $searchOutput = & winget search $IdPrefix --source $Source --accept-source-agreements 2>&1 | Out-String
        Write-RawWingetLog -CommandLine "winget search $IdPrefix --source $Source --accept-source-agreements" -ExitCode $LASTEXITCODE -Output $searchOutput

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "⚠️ Busca winget falhou para $Name. Código: $LASTEXITCODE"
            return $null
        }

        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($line in ($searchOutput -split "`r?`n")) {
            if ($line -match "($([regex]::Escape($IdPrefix))\d+)\s+([0-9][^\s]*)") {
                [void]$candidates.Add([PSCustomObject]@{
                    Id      = $Matches[1]
                    Version = [version](($Matches[2] -replace '[^\d\.].*$', '').TrimEnd('.'))
                })
            }
        }

        $latest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $latest) {
            Write-Warning "⚠️ Nenhum pacote encontrado por prefixo para $Name ($IdPrefix*)."
            return $null
        }

        Write-Host "✅ ID escolhido para ${Name}: $($latest.Id) (versão $($latest.Version))" -ForegroundColor Green
        return (New-Package -Name $Name -Id $latest.Id -Source $Source -Notes $Notes)
    }
    catch {
        Write-Warning "⚠️ Erro ao resolver pacote mais novo para ${Name}: $_"
        return $null
    }
}

function Get-LatestMavenVersion {
    $fallbackVersion = "3.9.16"

    try {
        $downloadPage = Invoke-WebRequest -Uri "https://maven.apache.org/download.cgi" -UseBasicParsing -ErrorAction Stop
        $versions = [regex]::Matches($downloadPage.Content, "apache-maven-([0-9]+(?:\.[0-9]+)+)-bin\.zip") |
            ForEach-Object { [version]$_.Groups[1].Value } |
            Sort-Object -Descending

        if ($versions -and $versions.Count -gt 0) {
            return $versions[0].ToString()
        }
    }
    catch {
        Write-Warning "⚠️ Não foi possível descobrir a versão mais nova do Maven no site oficial: $_"
    }

    Write-Warning "⚠️ Usando versão fallback do Maven: $fallbackVersion"
    return $fallbackVersion
}

function Install-MavenFromApacheZip {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📦 Instalando Apache Maven via ZIP oficial..." -ForegroundColor Yellow

    try {
        $latestVersion = Get-LatestMavenVersion
        $installRoot = "C:\DevTools"
        $mavenHome = Join-Path $installRoot "apache-maven-$latestVersion"
        $mavenBin = Join-Path $mavenHome "bin"
        $zipPath = Join-Path $env:TEMP "apache-maven-$latestVersion-bin.zip"
        $downloadUrl = "https://dlcdn.apache.org/maven/maven-3/$latestVersion/binaries/apache-maven-$latestVersion-bin.zip"
        $archiveUrl = "https://archive.apache.org/dist/maven/maven-3/$latestVersion/binaries/apache-maven-$latestVersion-bin.zip"

        $mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
        if ($mvnCmd) {
            $mvnVersionOutput = & mvn -v 2>&1 | Out-String
            if ($mvnVersionOutput -match "Apache Maven\s+$([regex]::Escape($latestVersion))") {
                Write-Host "✅ Apache Maven já está na versão mais nova encontrada: $latestVersion." -ForegroundColor Green
                Add-Result -Name "Apache Maven" -Id "Apache.Maven.Zip" -Source "Apache ZIP" -Status "OK" -Details "Já instalado. $($mvnVersionOutput.Trim())"
                return
            }

            Write-Host "🔄 Maven encontrado, mas não é a versão mais nova localizada. Será instalado/configurado Maven $latestVersion." -ForegroundColor Cyan
        }

        if ($DryRun) {
            Write-Host "DRY-RUN: baixaria $downloadUrl, extrairia em $mavenHome e configuraria MAVEN_HOME/PATH." -ForegroundColor Yellow
            Add-Result -Name "Apache Maven" -Id "Apache.Maven.Zip" -Source "Apache ZIP" -Status "Pendente" -Details "DRY-RUN: Maven $latestVersion seria instalado em $mavenHome."
            return
        }

        if (-not (Test-Path $installRoot)) {
            New-Item -Path $installRoot -ItemType Directory -Force | Out-Null
        }

        if (-not (Test-Path $mavenHome)) {
            Write-Host "⬇️ Baixando Maven $latestVersion..." -ForegroundColor Cyan
            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            }
            catch {
                Write-Warning "⚠️ Download via espelho principal falhou. Tentando archive.apache.org."
                Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            }

            Write-Host "📦 Extraindo Maven em $installRoot..." -ForegroundColor Cyan
            Expand-Archive -Path $zipPath -DestinationPath $installRoot -Force
        }
        else {
            Write-Host "✅ Diretório do Maven já existe: $mavenHome" -ForegroundColor Green
        }

        [System.Environment]::SetEnvironmentVariable("MAVEN_HOME", $mavenHome, "Machine")
        $env:MAVEN_HOME = $mavenHome
        Add-MachinePathEntry -PathEntry $mavenBin
        Update-SessionPath

        $mvnAfter = Get-Command mvn -ErrorAction SilentlyContinue
        if ($mvnAfter) {
            $version = & mvn -v 2>&1 | Out-String
            Write-Host "✅ Apache Maven instalado/configurado com sucesso." -ForegroundColor Green
            Add-Result -Name "Apache Maven" -Id "Apache.Maven.Zip" -Source "Apache ZIP" -Status "OK" -Details "MAVEN_HOME=$mavenHome. Saída: $($version.Trim())"
        }
        else {
            Write-Warning "⚠️ Maven foi extraído, mas 'mvn' não foi localizado no PATH."
            Add-Result -Name "Apache Maven" -Id "Apache.Maven.Zip" -Source "Apache ZIP" -Status "Verificar" -Details "Maven extraído em $mavenHome, mas mvn não localizado no PATH."
        }
    }
    catch {
        Write-Warning "⚠️ Erro ao instalar Maven via ZIP oficial: $_"
        Add-Result -Name "Apache Maven" -Id "Apache.Maven.Zip" -Source "Apache ZIP" -Status "Erro" -Details "$_"
    }
}

try {
    Write-Host "🚀 Iniciando configuração do ambiente de desenvolvimento PowerShell..." -ForegroundColor Green

    if ($DryRun) {
        Write-Host "Modo DRY-RUN ativo: comandos de instalação, download e alteração de ambiente serão apenas relatados." -ForegroundColor Yellow
    }
    if ($Only -and $Only.Count -gt 0) {
        Write-Host "Filtro -Only ativo: $($Only -join ', ')" -ForegroundColor Cyan
    }

    $wingetSections = @("Base", "Java", "Node", "Python", "IDE", "Database", "Cli", "DataScience")
    $requiresWinget = (-not $Only -or $Only.Count -eq 0 -or @($Only | Where-Object { $wingetSections -contains $_ }).Count -gt 0)

    if ($requiresWinget -and -not (Test-CommandExists -Command "winget")) {
        throw "WinGet não foi encontrado nesta máquina. Instale ou atualize o App Installer pela Microsoft Store."
    }

    if ($requiresWinget) {
        Write-Host ""
        Write-Host "🔎 Versão do WinGet:" -ForegroundColor Cyan
        & winget --version

        Write-Host ""
        Write-Host "📚 Fontes configuradas no WinGet:" -ForegroundColor Cyan
        & winget source list

        Write-Host ""
        Write-Host "🔄 Atualizando catálogo do WinGet..." -ForegroundColor Cyan
        $sourceUpdate = Invoke-WingetQuiet -Arguments @("source", "update")
        if ($sourceUpdate.ExitCode -ne 0) {
            Write-Warning "⚠️ winget source update retornou código $($sourceUpdate.ExitCode). O script continuará mesmo assim."
        }
    }

    Invoke-Section -Section "Base" -ScriptBlock {
        # Pacotes gratuitos de base para o ambiente de desenvolvimento.
        $wingetPackages = @(
            (New-Package -Name "Visual Studio Code" -Id "Microsoft.VisualStudioCode" -Source "winget" -Notes "Editor de código principal.")
            (New-Package -Name "PowerShell 7" -Id "Microsoft.PowerShell" -Source "winget" -Notes "Runtime PowerShell 7.x.")
            (New-Package -Name "Git" -Id "Git.Git" -Source "winget" -Notes "Controle de versão para scripts e projetos.")
            (New-Package -Name "Windows Terminal" -Id "Microsoft.WindowsTerminal" -Source "winget" -Notes "Terminal moderno para múltiplos perfis e abas.")
        )

        foreach ($pkg in $wingetPackages) {
            Install-OrUpgrade-WingetPackage -Package $pkg
        }

        Update-SessionPath

        Install-VSCodeExtensions -Extensions @(
            [PSCustomObject]@{ Name = "EditorConfig"; Id = "EditorConfig.EditorConfig"; Notes = "Suporte a .editorconfig para padronização de indentação e fim de linha." },
            [PSCustomObject]@{ Name = "GitLens"; Id = "eamodio.gitlens"; Notes = "Recursos avançados de Git dentro do VS Code." }
        )
    }

    Invoke-Section -Section "PowerShell" -ScriptBlock {
        # Sincronizar PATH antes de chamar o CLI 'code'.
        Update-SessionPath

        # Extensão oficial da Microsoft para desenvolvimento PowerShell no VS Code.
        Install-VSCodeExtensions -Extensions @(
            [PSCustomObject]@{ Name = "PowerShell"; Id = "ms-vscode.powershell"; Notes = "Extensão oficial da Microsoft para edição, debug e IntelliSense PowerShell." }
        )

        # Módulos gratuitos úteis ao desenvolvimento PowerShell.
        $psGalleryModules = @(
            [PSCustomObject]@{ Name = "Pester"; Notes = "Framework de testes automatizados para PowerShell." },
            [PSCustomObject]@{ Name = "PSScriptAnalyzer"; Notes = "Análise estática, qualidade e boas práticas de scripts." },
            [PSCustomObject]@{ Name = "platyPS"; Notes = "Geração de documentação Markdown para módulos PowerShell." },
            [PSCustomObject]@{ Name = "Microsoft.PowerShell.Crescendo"; Notes = "Criação de cmdlets PowerShell em volta de ferramentas CLI externas." },
            [PSCustomObject]@{ Name = "Microsoft.PowerShell.SecretManagement"; Notes = "Camada padronizada para acesso a segredos." },
            [PSCustomObject]@{ Name = "Microsoft.PowerShell.SecretStore"; Notes = "Cofre local para uso com SecretManagement." }
        )

        Initialize-PowerShellGallery

        foreach ($psGalleryModule in $psGalleryModules) {
            $moduleName  = [string]$psGalleryModule.Name
            $moduleNotes = [string]$psGalleryModule.Notes
            Install-PSGalleryModule -Name $moduleName -Notes $moduleNotes
        }
    }

    Invoke-Section -Section "Java" -ScriptBlock {
    # ===========================================================
    # JDKs — Eclipse Adoptium Temurin (distribuição OpenJDK)
    # ===========================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "☕ Instalando JDKs (Eclipse Adoptium Temurin / OpenJDK)..." -ForegroundColor Cyan

    $jdkPackages = @(
        (New-Package -Name "JDK 8 (Temurin)" -Id "EclipseAdoptium.Temurin.8.JDK" -Source "winget" -Notes "OpenJDK 8 LTS — Eclipse Adoptium Temurin.")
        (New-Package -Name "JDK 17 (Temurin)" -Id "EclipseAdoptium.Temurin.17.JDK" -Source "winget" -Notes "OpenJDK 17 LTS — Eclipse Adoptium Temurin.")
        (New-Package -Name "JDK 21 (Temurin)" -Id "EclipseAdoptium.Temurin.21.JDK" -Source "winget" -Notes "OpenJDK 21 LTS — Eclipse Adoptium Temurin.")
    )
    foreach ($pkg in $jdkPackages) {
        Install-OrUpgrade-WingetPackage -Package $pkg
    }

    # Confirmação adicional por diretório, complementar à validação via winget list já feita acima.
    $adoptiumBase = "C:\Program Files\Eclipse Adoptium"
    foreach ($majorVer in @("8", "17", "21")) {
        if (Test-Path $adoptiumBase) {
            $jdkDir = Get-ChildItem -Path $adoptiumBase -Directory -Filter "jdk-$majorVer.*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($jdkDir) {
                Write-Host "🔎 JDK $majorVer encontrado em: $($jdkDir.FullName)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "🔎 JDK ${majorVer}: diretório não encontrado em $adoptiumBase\jdk-$majorVer.*" -ForegroundColor DarkGray
            }
        }
    }

    Update-SessionPath

    Install-VSCodeExtensions -Extensions @(
        [PSCustomObject]@{ Name = "Extension Pack for Java"; Id = "vscjava.vscode-java-pack"; Notes = "Pacote principal de extensões Java para VS Code." }
    )
    }

    Invoke-Section -Section "Maven" -ScriptBlock {
    # ===========================================================
    # Apache Maven
    # ===========================================================
    Install-MavenFromApacheZip

    Update-SessionPath

    Install-VSCodeExtensions -Extensions @(
        [PSCustomObject]@{ Name = "Maven for Java"; Id = "vscjava.vscode-maven"; Notes = "Gerenciamento de projetos Maven no VS Code." }
    )
    }

    Invoke-Section -Section "Node" -ScriptBlock {
    # ===========================================================
    # Node.js LTS
    # ===========================================================
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "Node.js LTS" -Id "OpenJS.NodeJS.LTS" -Source "winget" -Notes "Runtime JavaScript LTS. npm é instalado automaticamente junto.")

    Update-SessionPath

    # npm vem junto com Node.js — validar apenas, não instalar separadamente.
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🔎 Validando npm (componente do Node.js)..." -ForegroundColor Yellow
    $npmValidateCmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($npmValidateCmd) {
        $npmVersion = & npm --version 2>&1 | Out-String
        Write-Host "✅ npm disponível: v$($npmVersion.Trim())" -ForegroundColor Green
        Add-Result -Name "npm" -Id "npm" -Source "Node.js" -Status "OK" -Details "Incluído com Node.js. Versão: $($npmVersion.Trim())"
    }
    else {
        Write-Warning "⚠️ npm não encontrado no PATH após instalação do Node.js."
        Add-Result -Name "npm" -Id "npm" -Source "Node.js" -Status "Verificar" -Details "npm esperado como parte do Node.js, mas não localizado no PATH após sincronização."
    }

    # ===========================================================
    # Angular CLI e Yeoman — instalados via npm global
    # ng é o comando fornecido pelo Angular CLI; não é pacote separado.
    # ===========================================================
    Install-NpmGlobalTool -DisplayName "Angular CLI" -NpmPackage "@angular/cli" -ValidateCommand "ng" `
        -Notes "O comando 'ng' é provido pelo Angular CLI; não é um pacote independente."
    Install-NpmGlobalTool -DisplayName "Yeoman" -NpmPackage "yo" -ValidateCommand "yo" `
        -Notes "Framework de scaffolding de projetos."

    # ===========================================================
    # Yarn — via winget (Yarn Classic v1, estável para Windows)
    # ===========================================================
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "Yarn" -Id "Yarn.Yarn" -Source "winget" `
        -Notes "Gerenciador de pacotes JavaScript. Instalado via winget (Yarn Classic v1).")

    Update-SessionPath

    Install-VSCodeExtensions -Extensions @(
        [PSCustomObject]@{ Name = "Angular Language Service"; Id = "angular.ng-template"; Notes = "Suporte oficial a templates Angular." },
        [PSCustomObject]@{ Name = "ESLint"; Id = "dbaeumer.vscode-eslint"; Notes = "Integração ESLint para JavaScript/TypeScript." },
        [PSCustomObject]@{ Name = "Prettier"; Id = "esbenp.prettier-vscode"; Notes = "Formatador comum para JS/TS/JSON/YAML/Markdown." }
    )
    }

    Invoke-Section -Section "Python" -ScriptBlock {
    # ===========================================================
    # Python 3
    # ===========================================================
    $pythonPackage = Resolve-LatestWingetPackageByIdPrefix -Name "Python 3" -IdPrefix "Python.Python.3." -Source "winget" `
        -Notes "Interpretador Python 3. O script escolhe a maior versão Python.Python.3.x encontrada no winget."
    if ($pythonPackage) {
        Install-OrUpgrade-WingetPackage -Package $pythonPackage
    }
    else {
        Add-Result -Name "Python 3" -Id "Python.Python.3.*" -Source "winget" -Status "Não encontrado" -Details "Não foi possível resolver a versão mais nova de Python 3 no catálogo winget."
    }
    $pythonPackageId = if ($pythonPackage) { $pythonPackage.Id } else { "Python.Python.3.*" }

    Update-SessionPath

    # Validar python e pip explicitamente — winget list confirma o pacote, mas aqui confirmamos os comandos.
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🔎 Validando python e pip..." -ForegroundColor Yellow
    $pyValidateCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyValidateCmd) {
        $pyVersion = & python --version 2>&1 | Out-String
        $pyExitCode = $LASTEXITCODE
        if ($pyExitCode -eq 0 -and $pyVersion.Trim() -match '^Python\s+\d') {
            Write-Host "✅ python disponível: $($pyVersion.Trim())" -ForegroundColor Green
            Add-Result -Name "python (validação de comando)" -Id $pythonPackageId -Source "winget" -Status "OK" -Details "Comando disponível. $($pyVersion.Trim())"
        }
        else {
            Write-Warning "⚠️ Comando python encontrado, mas não retornou uma versão válida."
            Add-Result -Name "python (validação de comando)" -Id $pythonPackageId -Source "winget" -Status "Verificar" -Details "python retornou código $pyExitCode. Saída: $($pyVersion.Trim())"
        }
    }
    else {
        Write-Warning "⚠️ python não encontrado no PATH após instalação."
        Add-Result -Name "python (validação de comando)" -Id $pythonPackageId -Source "winget" -Status "Verificar" -Details "python não localizado no PATH. Reinstale com a opção 'Add Python to PATH' habilitada."
    }
    $pipValidateCmd = Get-Command pip -ErrorAction SilentlyContinue
    if ($pipValidateCmd) {
        $pipVersion = & pip --version 2>&1 | Out-String
        $pipExitCode = $LASTEXITCODE
        if ($pipExitCode -eq 0 -and $pipVersion.Trim() -match '^pip\s+\d') {
            Write-Host "✅ pip disponível: $($pipVersion.Trim())" -ForegroundColor Green
            Add-Result -Name "pip (validação de comando)" -Id "pip" -Source "Python" -Status "OK" -Details "Incluído com Python. $($pipVersion.Trim())"
        }
        else {
            Write-Warning "⚠️ Comando pip encontrado, mas não retornou uma versão válida."
            Add-Result -Name "pip (validação de comando)" -Id "pip" -Source "Python" -Status "Verificar" -Details "pip retornou código $pipExitCode. Saída: $($pipVersion.Trim())"
        }
    }
    else {
        Write-Warning "⚠️ pip não encontrado no PATH."
        Add-Result -Name "pip (validação de comando)" -Id "pip" -Source "Python" -Status "Verificar" -Details "pip não localizado no PATH. Tente: python -m ensurepip"
    }

    # ===========================================================
    # Jupyter (via pip)
    # ===========================================================
    Install-JupyterViaPip

    Install-VSCodeExtensions -Extensions @(
        [PSCustomObject]@{ Name = "Python"; Id = "ms-python.python"; Notes = "Extensão oficial Python para VS Code." },
        [PSCustomObject]@{ Name = "Pylance"; Id = "ms-python.vscode-pylance"; Notes = "Language server Python da Microsoft." },
        [PSCustomObject]@{ Name = "Jupyter"; Id = "ms-toolsai.jupyter"; Notes = "Suporte a notebooks Jupyter no VS Code." }
    )
    }

    Invoke-Section -Section "IDE" -ScriptBlock {
    # ===========================================================
    # IDEs de desenvolvimento
    # ===========================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🖥️ Instalando IDEs de desenvolvimento..." -ForegroundColor Cyan

    $idePackages = @(
        (New-Package -Name "IntelliJ IDEA Community" -Id "JetBrains.IntelliJIDEA.Community" -Source "winget" -Notes "IDE Java/Kotlin — edição gratuita Community.")
        (New-Package -Name "PyCharm Community" -Id "JetBrains.PyCharm.Community" -Source "winget" -Notes "IDE Python — edição gratuita Community.")
        (New-Package -Name "Sublime Text" -Id "SublimeHQ.SublimeText.4" -Source "winget" -Notes "Editor de texto leve e rápido com suporte a múltiplas linguagens.")
        (New-Package -Name "Apache NetBeans" -Id "Apache.NetBeans" -Source "winget" -Notes "IDE Java. Instalado após os JDKs para satisfazer dependência de JDK.")
    )
    foreach ($pkg in $idePackages) {
        Install-OrUpgrade-WingetPackage -Package $pkg
    }
    }

    Invoke-Section -Section "Servers" -ScriptBlock {
    # ===========================================================
    # Servidores e runtimes Java
    # ===========================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "☕ Servidores e runtimes Java..." -ForegroundColor Cyan

    # Apache Tomcat — sem pacote winget confiável; instalação manual via ZIP/instalador oficial.
    Add-ManualResult -Name "Apache Tomcat" -Id "Apache.Tomcat" `
        -Reason "Sem pacote winget confiável para Tomcat. Baixe o instalador/ZIP em https://tomcat.apache.org/, extraia em C:\DevTools\Tomcat e configure CATALINA_HOME."

    # WildFly — sem pacote winget; instalação manual via ZIP.
    Add-ManualResult -Name "WildFly" -Id "WildFly.WildFly" `
        -Reason "Sem pacote winget para WildFly. Baixe o ZIP em https://www.wildfly.org/downloads/, extraia em C:\DevTools\WildFly e execute bin\standalone.bat."

    # Open Liberty — sem pacote winget; instalação manual via ZIP. Não usar IBM/WebSphere Liberty comercial.
    Add-ManualResult -Name "Open Liberty" -Id "OpenLiberty.OpenLiberty" `
        -Reason "Sem pacote winget para Open Liberty. Baixe o ZIP em https://openliberty.io/downloads/, extraia em C:\DevTools\OpenLiberty. Usar Open Liberty (gratuito), nao IBM/WebSphere Liberty comercial."

    Update-SessionPath

    Install-VSCodeExtensions -Extensions @(
        [PSCustomObject]@{ Name = "YAML"; Id = "redhat.vscode-yaml"; Notes = "Suporte YAML com validação e schemas." }
    )
    }

    Invoke-Section -Section "Database" -ScriptBlock {
    # ===========================================================
    # Bancos de Dados e Modelagem
    # ===========================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🗄️ Ferramentas de banco de dados e modelagem..." -ForegroundColor Cyan

    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "DBeaver Community" -Id "DBeaver.DBeaver.Community" -Source "winget" `
        -Notes "Cliente SQL universal, edição Community gratuita.")

    # Oracle SQL Developer — requer download manual, conta Oracle e aceite de licença.
    Add-ManualResult -Name "Oracle SQL Developer" -Id "Oracle.SQLDeveloper" `
        -Reason "Sem pacote winget confiavel. Requer login Oracle e aceite de licenca. Baixe em: https://www.oracle.com/tools/downloads/sqldev-downloads.html"

    # Oracle Data Modeler — idem.
    Add-ManualResult -Name "Oracle Data Modeler" -Id "Oracle.DataModeler" `
        -Reason "Sem pacote winget confiavel. Requer login Oracle e aceite de licenca. Baixe em: https://www.oracle.com/database/technologies/datamodeler-downloads.html"

    # Modelio — tentar via winget; se não encontrado, ficará registrado como tal no relatório.
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "Modelio" -Id "Modeliosoft.Modelio" -Source "winget" `
        -Notes "Ferramenta de modelagem OO/UML/BPMN.")
    }

    Invoke-Section -Section "Cli" -ScriptBlock {
    # ===========================================================
    # Utilitários CLI: jq e yq
    # ===========================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🔧 Utilitários CLI para dados estruturados..." -ForegroundColor Cyan

    # jq — processador JSON amplamente utilizado.
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "jq" -Id "jqlang.jq" -Source "winget" `
        -Notes "Processador JSON para linha de comando.")

    # yq — processador YAML. Implementação em Go de Mike Farah: mais adotada e com sintaxe similar ao jq.
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "yq (Mike Farah)" -Id "MikeFarah.yq" -Source "winget" `
        -Notes "Processador YAML. Implementacao em Go de Mike Farah, escolhida por ser amplamente adotada e compativel com sintaxe similar ao jq.")

    Update-SessionPath
    }

    Invoke-Section -Section "DataScience" -ScriptBlock {
    # ===========================================================
    # Machine Learning / Ciência de Dados: WEKA e Orange
    # ===========================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🤖 Ferramentas de Machine Learning / Ciência de Dados..." -ForegroundColor Cyan

    # WEKA — tentar via winget; requer JDK (instalado acima).
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "WEKA" -Id "UniversityOfWaikato.Weka" -Source "winget" `
        -Notes "Ferramenta de ML/Data Mining. Requer JDK. Se nao encontrado no winget, baixe em https://waikato.github.io/weka-wiki/downloading-weka/")

    # Orange Data Mining — tentar via winget.
    Install-OrUpgrade-WingetPackage -Package (New-Package -Name "Orange Data Mining" -Id "UniversityOfLjubljana.Orange" -Source "winget" `
        -Notes "Plataforma visual de data mining e ML. Se nao encontrado no winget, baixe em https://orangedatamining.com/download/")
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📋 Resumo da execução" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray

    $statusDisplay = [ordered]@{
        "OK"             = @{ Label = "✅ Instaladas / Ja presentes";          Color = "Green"      }
        "Pendente"       = @{ Label = "📋 Instalacao manual necessaria";        Color = "Yellow"     }
        "Não encontrado" = @{ Label = "🔍 Nao encontradas no catalogo winget";  Color = "DarkYellow" }
        "Verificar"      = @{ Label = "⚠️  Verificar manualmente";              Color = "Yellow"     }
        "Erro"           = @{ Label = "❌ Erro durante o processamento";        Color = "Red"        }
    }

    foreach ($kvp in $statusDisplay.GetEnumerator()) {
        $group = $results | Where-Object { $_.Status -eq $kvp.Key }
        if ($group) {
            Write-Host ""
            Write-Host "$($kvp.Value.Label) ($(@($group).Count)):" -ForegroundColor $kvp.Value.Color
            $group | Select-Object Name, Source, Details | Format-Table -AutoSize -Wrap
        }
    }
    try {
        $results | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Host "📄 Resumo CSV salvo em: $summaryPath" -ForegroundColor Cyan
    }
    catch {
        Write-Warning "⚠️ Não foi possível salvar o resumo CSV em ${summaryPath}: $_"
        Add-Result -Name "Resumo CSV" -Id $summaryPath -Source "Sistema" -Status "Erro" -Details "$_"
    }

    Write-Host "📝 Log completo salvo em: $logPath" -ForegroundColor Cyan
    Write-Host "🧾 Log bruto do WinGet/CLI salvo em: $wingetRawLogPath" -ForegroundColor Cyan

    $problemResults = $results | Where-Object { $_.Status -in @("Erro", "Verificar", "Pendente", "Não encontrado") }

    Write-Host ""
    if ($problemResults) {
        Write-Warning "⚠️ Execução concluída com pendências. Verifique o resumo e os logs acima."
    }
    else {
        Write-Host "🏁 Ambiente configurado com sucesso." -ForegroundColor Green
    }
}
catch {
    Write-Host ""
    Write-Error "❌ Erro geral no script: $_"
}
finally {
    Stop-Transcript

    Write-Host ""
    Write-Host "Locais dos arquivos de diagnóstico desta execução:" -ForegroundColor DarkGray
    Write-Host "📝 Log completo: $logPath" -ForegroundColor DarkGray
    Write-Host "🧾 Log bruto do WinGet/CLI: $wingetRawLogPath" -ForegroundColor DarkGray
    Write-Host "📄 Resumo CSV: $summaryPath" -ForegroundColor DarkGray
}
