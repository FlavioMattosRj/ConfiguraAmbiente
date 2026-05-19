﻿#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$logPath = Join-Path $env:TEMP "Install-DevEnv.log"
$wingetRawLogPath = Join-Path $env:TEMP "Install-DevEnv-Winget-Raw.log"
$summaryPath = Join-Path $env:TEMP "Install-DevEnv-Summary.csv"

Start-Transcript -Path $logPath -Append

$results = New-Object System.Collections.Generic.List[object]

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
    param([Parameter(Mandatory)][string]$PathEntry)

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

function Install-VSCodePowerShellExtension {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "🧩 Instalando extensão PowerShell para VS Code..." -ForegroundColor Yellow

    try {
        # O PATH já deve ter sido sincronizado antes desta função ser chamada.
        # Não há fallback manual aqui: se 'code' não estiver no PATH, isso será registrado como pendência.
        $codeCmd = Get-Command code -ErrorAction SilentlyContinue

        if ($codeCmd) {
            $extInstallCmd = "& '$($codeCmd.Source)' --install-extension ms-vscode.powershell"
            Write-Host "Executando: $extInstallCmd" -ForegroundColor DarkGray

            $extOutput = Invoke-Expression $extInstallCmd 2>&1 | Out-String
            $extExitCode = $LASTEXITCODE

            Write-RawWingetLog -CommandLine $extInstallCmd -ExitCode $extExitCode -Output $extOutput

            if ($extExitCode -eq 0) {
                Write-Host "✅ Extensão PowerShell instalada com sucesso no VS Code." -ForegroundColor Green
                Add-Result -Name "PowerShell Extension (VS Code)" -Id "ms-vscode.powershell" -Source "VS Code CLI" -Status "OK" -Details "Extensão instalada via code --install-extension."
            }
            else {
                Write-Warning "⚠️ Instalação da extensão retornou código $extExitCode. Verifique o log."
                Add-Result -Name "PowerShell Extension (VS Code)" -Id "ms-vscode.powershell" -Source "VS Code CLI" -Status "Verificar" -Details "Código $extExitCode. Saída no log bruto."
            }
        }
        else {
            Write-Warning "⚠️ Comando 'code' não encontrado no PATH após a sincronização. A extensão não foi instalada."
            Add-Result -Name "PowerShell Extension (VS Code)" -Id "ms-vscode.powershell" -Source "VS Code CLI" -Status "Pendente" -Details "Comando code não encontrado no PATH após sincronização. Abra uma nova sessão ou verifique se o VS Code adicionou o diretório bin ao PATH."
        }
    }
    catch {
        Write-Warning "⚠️ Erro ao instalar extensão PowerShell: $_"
        Add-Result -Name "PowerShell Extension (VS Code)" -Id "ms-vscode.powershell" -Source "VS Code CLI" -Status "Erro" -Details "$_"
    }
}


function Initialize-PowerShellGallery {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📚 Preparando PowerShell Gallery para instalação de módulos..." -ForegroundColor Yellow

    try {
        $nuGetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuGetProvider) {
            Write-Host "⬇️ Instalando provedor NuGet para PowerShellGet..." -ForegroundColor Cyan
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -ErrorAction Stop | Out-Null
        }

        $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($psGallery -and $psGallery.InstallationPolicy -ne "Trusted") {
            Write-Host "🔧 Marcando PSGallery como repositório confiável para evitar prompts interativos." -ForegroundColor Cyan
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }

        Add-Result -Name "PowerShell Gallery readiness" -Id "PSGallery/NuGet" -Source "PowerShellGet" -Status "OK" -Details "Provedor NuGet e PSGallery preparados para instalação não interativa de módulos."
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

try {
    Write-Host "🚀 Iniciando configuração do ambiente de desenvolvimento PowerShell..." -ForegroundColor Green

    if (-not (Test-CommandExists -Command "winget")) {
        throw "WinGet não foi encontrado nesta máquina. Instale ou atualize o App Installer pela Microsoft Store."
    }

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

    # Pacotes gratuitos no escopo de um ambiente Visual Studio Code para desenvolvimento PowerShell.
    $wingetPackages = @(
        (New-Package -Name "Visual Studio Code" -Id "Microsoft.VisualStudioCode" -Source "winget" -Notes "Editor de código principal.")
        (New-Package -Name "PowerShell 7" -Id "Microsoft.PowerShell" -Source "winget" -Notes "Runtime PowerShell 7.x.")
        (New-Package -Name "Git" -Id "Git.Git" -Source "winget" -Notes "Controle de versão para scripts e projetos.")
        (New-Package -Name "Windows Terminal" -Id "Microsoft.WindowsTerminal" -Source "winget" -Notes "Terminal moderno para múltiplos perfis e abas.")
    )

    foreach ($pkg in $wingetPackages) {
        Install-OrUpgrade-WingetPackage -Package $pkg
    }

    # Sincronizar PATH antes de chamar o CLI 'code'.
    Update-SessionPath

    # Extensão oficial da Microsoft para desenvolvimento PowerShell no VS Code.
    Install-VSCodePowerShellExtension

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

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📋 Resumo da execução" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray

    $results | Select-Object Name, Id, Source, Status | Format-Table -AutoSize
    $results | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "📄 Resumo CSV salvo em: $summaryPath" -ForegroundColor Cyan
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
