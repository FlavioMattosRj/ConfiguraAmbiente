#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$logPath = Join-Path $env:TEMP "Install-Software.log"
$wingetRawLogPath = Join-Path $env:TEMP "Install-Software-Winget-Raw.log"
$summaryPath = Join-Path $env:TEMP "Install-Software-Summary.csv"

Start-Transcript -Path $logPath -Append

$results = New-Object System.Collections.Generic.List[object]

function Test-CommandExists {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Write-RawWingetLog {
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine,

        [Parameter(Mandatory)]
        [int]$ExitCode,

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
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

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
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    if ($ExitCode -eq 0) {
        return ""
    }

    $result = Invoke-WingetQuiet -Arguments @("error", "$ExitCode")

    if ($result.ExitCode -eq 0 -and $result.Output.Trim()) {
        return ($result.Output.Trim())
    }

    return "Código não traduzido pelo winget error."
}

function Add-Result {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Status,

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
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet("winget", "msstore")]
        [string]$Source,

        [string]$InstalledName = "",

        [ValidateSet("", "office-clicktorun")]
        [string]$Verifier = "",

        [string]$InstallerType = "",

        [string]$FallbackId = "",

        [ValidateSet("", "winget", "msstore")]
        [string]$FallbackSource = "",

        [string]$FallbackInstalledName = "",

        [string]$Notes = ""
    )

    return [PSCustomObject]@{
        Name                  = $Name
        Id                    = $Id
        Source                = $Source
        InstalledName         = $InstalledName
        Verifier              = $Verifier
        InstallerType         = $InstallerType
        FallbackId            = $FallbackId
        FallbackSource        = $FallbackSource
        FallbackInstalledName = $FallbackInstalledName
        Notes                 = $Notes
    }
}

function Get-WingetIdentityArguments {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [object]$Package
    )

    $args = @($Command)

    if ($Package.Source -eq "winget") {
        $args += "-e"
    }

    $args += "--id"
    $args += $Package.Id
    $args += "--source"
    $args += $Package.Source

    return $args
}

function Test-OfficeClickToRunInstalled {
    $officeRegistryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
    )

    $hasClickToRunConfig = $false

    foreach ($path in $officeRegistryPaths) {
        if (Test-Path $path) {
            $config = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

            if ($config.ProductReleaseIds -or $config.ClientVersionToReport) {
                $hasClickToRunConfig = $true
                break
            }
        }
    }

    $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")

    $officeExeCandidates = @(
        "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE",
        "$env:ProgramFiles\Microsoft Office\root\Office16\EXCEL.EXE",
        "$env:ProgramFiles\Microsoft Office\root\Office16\POWERPNT.EXE",
        "$programFilesX86\Microsoft Office\root\Office16\WINWORD.EXE",
        "$programFilesX86\Microsoft Office\root\Office16\EXCEL.EXE",
        "$programFilesX86\Microsoft Office\root\Office16\POWERPNT.EXE"
    )

    $hasOfficeExecutable = $false

    foreach ($exe in $officeExeCandidates) {
        if ($exe -and (Test-Path $exe)) {
            $hasOfficeExecutable = $true
            break
        }
    }

    return ($hasClickToRunConfig -and $hasOfficeExecutable)
}

function Test-WingetPackageAvailable {
    param(
        [Parameter(Mandatory)]
        [object]$Package
    )

    Write-Host "🔎 Procurando no catálogo: $($Package.Name) [$($Package.Id)] em $($Package.Source)" -ForegroundColor DarkGray

    $args = Get-WingetIdentityArguments -Command "show" -Package $Package
    $args += "--accept-source-agreements"

    $result = Invoke-WingetQuiet -Arguments $args

    return ($result.ExitCode -eq 0)
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory)]
        [object]$Package
    )

    if ($Package.Verifier -eq "office-clicktorun") {
        return (Test-OfficeClickToRunInstalled)
    }

    if ($Package.Source -eq "winget") {
        $args = Get-WingetIdentityArguments -Command "list" -Package $Package
        $args += "--accept-source-agreements"

        $result = Invoke-WingetQuiet -Arguments $args

        if ($result.ExitCode -eq 0) {
            return $true
        }
    }

    if ($Package.InstalledName -and $Package.InstalledName.Trim() -ne "") {
        $args = @(
            "list",
            "--name", $Package.InstalledName,
            "--accept-source-agreements"
        )

        $result = Invoke-WingetQuiet -Arguments $args

        if ($result.ExitCode -eq 0) {
            return $true
        }
    }

    return $false
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [object]$Package
    )

    $args = Get-WingetIdentityArguments -Command "install" -Package $Package

    $args += "--accept-package-agreements"
    $args += "--accept-source-agreements"
    $args += "--disable-interactivity"

    if ($Package.Source -eq "winget") {
        $args += "--silent"
    }

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

        if ($Package.Source -eq "winget") {
            $args += "--silent"
        }

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
    param(
        [Parameter(Mandatory)]
        [object]$Package
    )

    $args = Get-WingetIdentityArguments -Command "upgrade" -Package $Package

    $args += "--accept-package-agreements"
    $args += "--accept-source-agreements"
    $args += "--disable-interactivity"

    if ($Package.Source -eq "winget") {
        $args += "--silent"
    }

    return Invoke-WingetQuiet -Arguments $args
}

function Invoke-PackageFallback {
    param(
        [Parameter(Mandatory)]
        [object]$Package
    )

    if (($Package.FallbackId) -and ($Package.FallbackSource)) {
        Write-Host ""
        Write-Host "🔁 Tentando fallback para $($Package.Name): $($Package.FallbackId) em $($Package.FallbackSource)" -ForegroundColor Cyan

        $fallbackPackage = [PSCustomObject]@{
            Name                  = "$($Package.Name) - fallback"
            Id                    = $Package.FallbackId
            Source                = $Package.FallbackSource
            InstalledName         = $Package.FallbackInstalledName
            Verifier              = ""
            InstallerType         = ""
            FallbackId            = ""
            FallbackSource        = ""
            FallbackInstalledName = ""
            Notes                 = "Fallback automático do pacote $($Package.Id)."
        }

        Install-OrUpgrade-WingetPackage -Package $fallbackPackage
        return $true
    }

    return $false
}

function Install-OrUpgrade-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [object]$Package
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📦 Verificando: $($Package.Name)" -ForegroundColor Yellow
    Write-Host "ID: $($Package.Id)" -ForegroundColor DarkGray
    Write-Host "Fonte: $($Package.Source)" -ForegroundColor DarkGray

    if ($Package.InstalledName) {
        Write-Host "Nome para validação local: $($Package.InstalledName)" -ForegroundColor DarkGray
    }

    if ($Package.Verifier) {
        Write-Host "Validador especial: $($Package.Verifier)" -ForegroundColor DarkGray
    }

    if ($Package.Notes) {
        Write-Host "Nota: $($Package.Notes)" -ForegroundColor DarkGray
    }

    try {
        $isAvailable = Test-WingetPackageAvailable -Package $Package

        if (-not $isAvailable) {
            Write-Warning "⚠️ Pacote não encontrado no catálogo: $($Package.Name) [$($Package.Id)]"

            $fallbackUsed = Invoke-PackageFallback -Package $Package
            if ($fallbackUsed) {
                return
            }

            Add-Result `
                -Name $Package.Name `
                -Id $Package.Id `
                -Source $Package.Source `
                -Status "Não encontrado" `
                -Details "Pacote não encontrado no catálogo $($Package.Source)."

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

                Add-Result `
                    -Name $Package.Name `
                    -Id $Package.Id `
                    -Source $Package.Source `
                    -Status "OK" `
                    -Details "Já instalado. Código retornado pelo upgrade: $exitCode. Saída completa no log bruto."

                return
            }

            $errorText = Get-WingetErrorText -ExitCode $exitCode

            Write-Warning "⚠️ Upgrade retornou código $exitCode e o pacote não foi confirmado como instalado."

            Add-Result `
                -Name $Package.Name `
                -Id $Package.Id `
                -Source $Package.Source `
                -Status "Verificar" `
                -Details "Upgrade retornou código $exitCode. $errorText. Pacote não confirmado como instalado. Veja log bruto."

            return
        }

        Write-Host "⬇️ Instalando: $($Package.Name)" -ForegroundColor Cyan

        $result = Install-WingetPackage -Package $Package
        $exitCode = $result.ExitCode

        $installedAfterAttempt = Test-WingetPackageInstalled -Package $Package

        if ($installedAfterAttempt) {
            Write-Host "✅ OK: $($Package.Name) está instalado/presente." -ForegroundColor Green

            Add-Result `
                -Name $Package.Name `
                -Id $Package.Id `
                -Source $Package.Source `
                -Status "OK" `
                -Details "Instalado ou já presente após tentativa. Código retornado pela instalação: $exitCode. Saída completa no log bruto."

            return
        }

        $fallbackUsed = Invoke-PackageFallback -Package $Package
        if ($fallbackUsed) {
            return
        }

        $errorText = Get-WingetErrorText -ExitCode $exitCode

        Write-Warning "⚠️ Instalação não confirmada para $($Package.Name). Código: $exitCode"

        Add-Result `
            -Name $Package.Name `
            -Id $Package.Id `
            -Source $Package.Source `
            -Status "Verificar" `
            -Details "Instalação retornou código $exitCode. $errorText. Pacote não confirmado como instalado pelo teste automatizado. Veja log bruto."
    }
    catch {
        Write-Warning "⚠️ Erro ao tratar pacote $($Package.Name): $_"

        $fallbackUsed = Invoke-PackageFallback -Package $Package
        if ($fallbackUsed) {
            return
        }

        Add-Result `
            -Name $Package.Name `
            -Id $Package.Id `
            -Source $Package.Source `
            -Status "Erro" `
            -Details "$_"
    }
}

try {
    Write-Host "🚀 Iniciando instalação da suíte de softwares..." -ForegroundColor Green

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

    $packages = @(
        New-Package `
            -Name "Brave Browser" `
            -Id "Brave.Brave" `
            -Source "winget" `
            -InstalledName "Brave"

        New-Package `
            -Name "Oracle VirtualBox" `
            -Id "Oracle.VirtualBox" `
            -Source "winget" `
            -InstalledName "Oracle VM VirtualBox"

        New-Package `
            -Name "LM Studio" `
            -Id "ElementLabs.LMStudio" `
            -Source "winget" `
            -InstalledName "LM Studio"

        New-Package `
            -Name "Obsidian" `
            -Id "Obsidian.Obsidian" `
            -Source "winget" `
            -InstalledName "Obsidian"

        New-Package `
            -Name "ClickUp" `
            -Id "ClickUp.ClickUp" `
            -Source "winget" `
            -InstalledName "ClickUp"

        New-Package `
            -Name "Comet Browser" `
            -Id "Perplexity.Comet" `
            -Source "winget" `
            -InstalledName "Comet" `
            -FallbackId "XPFFVLPJRVQTKM" `
            -FallbackSource "msstore" `
            -FallbackInstalledName "Comet Browser" `
            -Notes "Preferência por winget; fallback para Microsoft Store se necessário."

        New-Package `
            -Name "Perplexity Desktop App" `
            -Id "XP8JNQFBQH6PVF" `
            -Source "msstore" `
            -InstalledName "Perplexity" `
            -Notes "App da Microsoft Store."

        New-Package `
            -Name "Microsoft Office" `
            -Id "Microsoft.Office" `
            -Source "winget" `
            -Verifier "office-clicktorun" `
            -Notes "Validação especial: confirma Office Click-to-Run e executáveis como Word, Excel ou PowerPoint."

        New-Package `
            -Name "Adobe Creative Cloud" `
            -Id "Adobe.CreativeCloud" `
            -Source "winget" `
            -InstalledName "Adobe Creative Cloud" `
            -Notes "Instala o gerenciador Creative Cloud; apps individuais podem exigir login Adobe."

        New-Package `
            -Name "Claude Desktop" `
            -Id "Anthropic.Claude" `
            -Source "winget" `
            -InstalledName "Claude" `
            -InstallerType "msix" `
            -Notes "Tenta primeiro instalador MSIX; se falhar, tenta novamente sem forçar tipo."

        New-Package `
            -Name "Claude Code CLI" `
            -Id "Anthropic.ClaudeCode" `
            -Source "winget" `
            -InstalledName "Claude Code" `
            -Notes "Ferramenta de linha de comando da Anthropic."

        New-Package `
            -Name "ChatGPT Desktop App" `
            -Id "9NT1R1C2HH7J" `
            -Source "msstore" `
            -InstalledName "ChatGPT" `
            -Notes "App oficial distribuído pela Microsoft Store."

        New-Package `
            -Name "Codex Desktop App" `
            -Id "9PLM9XGG6VKS" `
            -Source "msstore" `
            -InstalledName "Codex" `
            -Notes "App desktop do Codex via Microsoft Store."

        New-Package `
            -Name "Codex CLI" `
            -Id "OpenAI.Codex" `
            -Source "winget" `
            -InstalledName "Codex" `
            -Notes "Ferramenta de linha de comando; diferente do app desktop."

        New-Package `
            -Name "Bible by Olive Tree" `
            -Id "9NRSP6BRXBZQ" `
            -Source "msstore" `
            -InstalledName "Bible by Olive Tree" `
            -Notes "App atual distribuído pela Microsoft Store."

        New-Package `
            -Name "WhatsApp" `
            -Id "9NKSQGP7F2NH" `
            -Source "msstore" `
            -InstalledName "WhatsApp" `
            -Notes "App oficial da Microsoft Store."

        New-Package `
            -Name "VeraCrypt" `
            -Id "IDRIX.VeraCrypt" `
            -Source "winget" `
            -InstalledName "VeraCrypt" `
            -Notes "Software de criptografia."
    )

    foreach ($pkg in $packages) {
        Install-OrUpgrade-WingetPackage -Package $pkg
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "📋 Resumo da execução" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray

    $results |
        Select-Object Name, Id, Source, Status |
        Format-Table -AutoSize

    $results | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "📄 Resumo CSV salvo em: $summaryPath" -ForegroundColor Cyan
    Write-Host "🧾 Log bruto do WinGet salvo em: $wingetRawLogPath" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "🏁 Finalizado." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Error "❌ Erro geral no script: $_"
}
finally {
    Stop-Transcript

    Write-Host ""
    Write-Host "📝 Log salvo em: $logPath" -ForegroundColor DarkGray
    Write-Host "🧾 Log bruto do WinGet salvo em: $wingetRawLogPath" -ForegroundColor DarkGray
    Write-Host "📄 Resumo salvo em: $summaryPath" -ForegroundColor DarkGray
}