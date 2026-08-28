# modules/03-Debloat.ps1 - Suppression apps Store génériques + bloatware constructeur
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\03-Debloat.ps1 [-WhatIf] [-Force]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [switch]$RemoveOemBloat,
    [ValidateSet('Conservative', 'Standard', 'Aggressive')][string]$DebloatPolicy = 'Standard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 03-Debloat : début ===" -Level 'INFO'

# Contrat (a) de Get-ActiveThirdPartyAv (retour ,@(...), cf modules/02-Antivirus.ps1) :
# ASSIGNER puis envelopper. En enveloppe directe, .Count valait 1 même sans AV
# tiers : l'avertissement partait sur toutes les machines, avec une liste vide.
$avActifs = Get-ActiveThirdPartyAv
$activeAv = @($avActifs)
if ($activeAv.Count -gt 0) {
    Write-KitLog -Message "ATTENTION : antivirus tiers actif ($($activeAv -join ', '))." -Level 'WARN'
    Write-KitLog -Message "Il peut bloquer silencieusement les suppressions AppX. Le désinstaller (module 02) ou le désactiver d'abord pour un résultat fiable." -Level 'WARN'
}

$configDir  = Join-Path $PSScriptRoot '..\config'
$runtimeDir = Join-Path $PSScriptRoot '..\runtime'

# ---------------------------------------------------------------------------
# Chargement de la config debloat-store.json
# ---------------------------------------------------------------------------
$storeConfigPath = Join-Path $configDir 'debloat-store.json'
if (-not (Test-Path $storeConfigPath)) {
    Write-KitLog -Message "config/debloat-store.json introuvable. Debloat Store ignoré." -Level 'WARN'
}
else {
    $storeCfg    = Get-Content $storeConfigPath -Encoding UTF8 | ConvertFrom-Json
    $removeList  = $storeCfg.remove
    $keepList    = $storeCfg.keep

    # ---------------------------------------------------------------------------
    # Apps Store : suppression automatique
    # ---------------------------------------------------------------------------
    Write-KitLog -Message "--- Apps Store : suppression automatique ---" -Level 'INFO'

    foreach ($pattern in $removeList) {
        # Vérifier que le pattern n'est pas dans la liste keep (match bidirectionnel :
        # $pattern peut être plus large qu'une entrée keep, ou l'inverse)
        $isProtected = Test-InKeepList -Name $pattern -KeepList @($keepList) -Bidirectional
        if ($isProtected) {
            Write-KitLog -Message "SKIP (protégé) : $pattern" -Level 'INFO'
            continue
        }

        # Chercher les packages matches
        $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like $pattern })

        if ($pkgs.Count -eq 0) {
            Write-KitLog -Message "SKIP (absent) : $pattern" -Level 'INFO'
            continue
        }

        foreach ($pkg in $pkgs) {
            # Double-vérif que le package n'est pas dans keep
            if (Test-InKeepList -Name $pkg.Name -KeepList @($keepList)) {
                Write-KitLog -Message "SKIP (keep liste) : $($pkg.Name)" -Level 'INFO'
                continue
            }

            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: Remove-AppxPackage -AllUsers $($pkg.Name)" -Level 'WHATIF'
            }
            else {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    Write-KitLog -Message "Supprimé : $($pkg.Name)" -Level 'OK'
                }
                catch {
                    Write-KitLog -Message "Erreur suppression $($pkg.Name) : $_" -Level 'WARN'
                }
            }
        }

        # Empêcher la réinstallation pour les nouveaux profils
        $provPkgs = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -like $pattern })
        foreach ($pp in $provPkgs) {
            if (Test-InKeepList -Name $pp.DisplayName -KeepList @($keepList)) { continue }

            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: Remove-AppxProvisionedPackage $($pp.DisplayName)" -Level 'WHATIF'
            }
            else {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
                    Write-KitLog -Message "Provisioning supprimé : $($pp.DisplayName)" -Level 'OK'
                }
                catch {
                    Write-KitLog -Message "Erreur provisioning $($pp.DisplayName) : $_" -Level 'WARN'
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # Apps conditionnelles : détection d'usage avant suppression
    # -----------------------------------------------------------------------
    if ($storeCfg.PSObject.Properties.Name -contains 'conditional') {
        Write-KitLog -Message "--- Apps conditionnelles (détection d'usage) ---" -Level 'INFO'
        Write-KitLog -Message "Politique debloat : $DebloatPolicy" -Level 'INFO'
        $unattended = [bool]($Force -or $Unattended)
        foreach ($cond in $storeCfg.conditional) {
            # Détecter les packages présents pour ce groupe
            $matched = @()
            foreach ($pat in $cond.patterns) {
                $matched += @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pat })
            }
            $matched = @($matched | Sort-Object PackageFullName -Unique)   # @() : Sort-Object d'un vide renvoie $null, .Count leverait sous StrictMode 5.1
            if ($matched.Count -eq 0) {
                Write-KitLog -Message "SKIP (absent) : $($cond.label)" -Level 'INFO'
                continue
            }

            # Détection d'usage selon la stratégie
            if ($cond.detect -eq 'gamepass') {
                $inUse = Test-GamePassPresent
            }
            else {
                $inUse = $false
                foreach ($pkg in $matched) {
                    if (Test-AppxInUse -PackageFamilyName $pkg.PackageFamilyName) { $inUse = $true; break }
                }
            }

            $decision = Get-DebloatDecision -Detect $cond.detect -InUse $inUse -Unattended $unattended -Policy $DebloatPolicy

            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: $($cond.label) -> usage=$inUse, decision=$($decision.Action) ($($decision.Reason))" -Level 'WHATIF'
                continue
            }

            $doRemove = $false
            switch ($decision.Action) {
                'KEEP'   { Write-KitLog -Message "GARDÉ ($($decision.Reason)) : $($cond.label)" -Level 'OK' }
                'REMOVE' { $doRemove = $true; Write-KitLog -Message "Suppression ($($decision.Reason)) : $($cond.label)" -Level 'INFO' }
                'PROMPT' {
                    Write-Host ""
                    Write-Host "[CONDITIONNEL] $($cond.label) ne semble pas utilisé. Le supprimer ?" -ForegroundColor Cyan
                    $answer = Read-Host "Supprimer ? (O/N, défaut N)"
                    $doRemove = ($answer -match '^[Oo]')
                    if (-not $doRemove) { Write-KitLog -Message "GARDÉ (refus utilisateur) : $($cond.label)" -Level 'INFO' }
                }
            }

            if ($doRemove) {
                foreach ($pkg in $matched) {
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                        Write-KitLog -Message "Supprimé : $($pkg.Name)" -Level 'OK'
                    }
                    catch { Write-KitLog -Message "Erreur suppression $($pkg.Name) : $_" -Level 'WARN' }
                }
                foreach ($pat in $cond.patterns) {
                    $provPkgs = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pat })
                    foreach ($pp in $provPkgs) {
                        try {
                            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
                            Write-KitLog -Message "Provisioning supprimé : $($pp.DisplayName)" -Level 'OK'
                        }
                        catch { Write-KitLog -Message "Erreur provisioning $($pp.DisplayName) : $_" -Level 'WARN' }
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Bloatware constructeur
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Bloatware constructeur ---" -Level 'INFO'

# Lire la marque depuis le JSON de diagnostic si présent, sinon Get-MachineInfo
$manufacturer = $null
$diagJson     = Join-Path $runtimeDir "diagnostic-$env:COMPUTERNAME.json"
if (Test-Path $diagJson) {
    try {
        $diag         = Get-Content $diagJson -Encoding UTF8 | ConvertFrom-Json
        $manufacturer = $diag.Machine.Manufacturer
    }
    catch { }
}
if (-not $manufacturer) {
    $manufacturer = (Get-MachineInfo).Manufacturer
}

Write-KitLog -Message "Fabricant détecté : $manufacturer" -Level 'INFO'

# Normaliser le nom du fabricant pour trouver la fiche
$oemKey = $manufacturer -replace '\s.*$','' -replace '[^A-Za-z]',''
$oemKey = switch -Wildcard ($oemKey.ToUpper()) {
    'ASUS*'    { 'ASUS'   }
    'HP*'      { 'HP'     }
    'DELL*'    { 'DELL'   }
    'LENOVO*'  { 'LENOVO' }
    'ACER*'    { 'ACER'   }
    default    { $oemKey.ToUpper() }
}

$oemJsonPath = Join-Path $configDir "oem-bloat\$oemKey.json"

if (-not (Test-Path $oemJsonPath)) {
    Write-KitLog -Message "Pas de fiche pour '$oemKey' ($oemJsonPath). Détection générique des éditeurs OEM connus..." -Level 'WARN'

    # Détection générique : chercher des éditeurs OEM connus dans le registre
    $genericOemPatterns = @('HP ', 'Dell ', 'Lenovo', 'Acer ', 'ASUS ', 'Killer', 'McAfee', 'Norton', 'Webroot', 'Avira', 'Avast', 'AVG')
    $oemApps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                                -ErrorAction SilentlyContinue |
               Where-Object { (Get-JsonProp $_ 'DisplayName') } |
               Where-Object {
                   $name = Get-JsonProp $_ 'DisplayName'   # acces defensif (StrictMode 5.1 : cle Uninstall sans DisplayName)
                   $genericOemPatterns | Where-Object { $name -like "*$_*" }
               } |
               Select-Object DisplayName, DisplayVersion, Publisher

    if ($oemApps) {
        Write-KitLog -Message "Applications OEM potentielles détectées :" -Level 'WARN'
        foreach ($a in $oemApps) {
            Write-KitLog -Message "  > $($a.DisplayName) (v$($a.DisplayVersion)) - $($a.Publisher)" -Level 'WARN'
        }
        Write-KitLog -Message "Ces applications n'ont pas été touchées (pas de fiche pour ce constructeur). Supprimer manuellement si besoin." -Level 'WARN'
    }
    else {
        Write-KitLog -Message "Aucune application OEM générique détectée." -Level 'OK'
    }
}
else {
    Write-KitLog -Message "Fiche constructeur trouvée : $oemJsonPath" -Level 'INFO'
    $oemCfg = Get-Content $oemJsonPath -Encoding UTF8 | ConvertFrom-Json

    # Accès gardés : une fiche OEM peut omettre des clés (HP/Dell à venir) ;
    # un accès .prop direct sur une clé absente lève sous StrictMode Latest.
    # Piège : @($null) donne un tableau de 1 élément null, d'où le if.
    $oemMsiGuids = @(); $tmp = Get-JsonProp $oemCfg 'msiGuids';       if ($tmp) { $oemMsiGuids = @($tmp) }
    $oemSvcNames = @(); $tmp = Get-JsonProp $oemCfg 'orphanServices'; if ($tmp) { $oemSvcNames = @($tmp) }
    $oemKeepList = @(); $tmp = Get-JsonProp $oemCfg 'keep';           if ($tmp) { $oemKeepList = @($tmp) }
    $oemNative     = Get-JsonProp $oemCfg 'nativeUninstaller'
    $oemNativePath = if ($oemNative) { [string](Get-JsonProp $oemNative 'path') } else { '' }
    $oemNativeArgs = if ($oemNative) { Get-JsonProp $oemNative 'args' } else { $null }

    # Lister ce qui serait supprimé
    $toRemoveMsi  = @()
    $toRemoveSvcs = @()

    foreach ($m in $oemMsiGuids) {
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($m.guid)",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$($m.guid)"
        )
        $found = $regPaths | Where-Object { Test-Path $_ }
        if ($found) { $toRemoveMsi += $m }
    }

    foreach ($s in $oemSvcNames) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) { $toRemoveSvcs += $s }
    }

    $nativePresent = (-not [string]::IsNullOrWhiteSpace($oemNativePath)) -and (Test-Path $oemNativePath)

    Write-KitLog -Message "Plan de suppression OEM $oemKey :" -Level 'INFO'
    if ($nativePresent) {
        Write-KitLog -Message "  Uninstaller natif : $oemNativePath" -Level 'INFO'
    }
    if ($toRemoveMsi.Count -gt 0) {
        Write-KitLog -Message "  MSI à désinstaller ($($toRemoveMsi.Count)) :" -Level 'INFO'
        foreach ($m in $toRemoveMsi) { Write-KitLog -Message "    - $($m.name) [$($m.guid)]" -Level 'INFO' }
    }
    if ($toRemoveSvcs.Count -gt 0) {
        Write-KitLog -Message "  Services orphelins potentiels ($($toRemoveSvcs.Count)) :" -Level 'INFO'
        foreach ($s in $toRemoveSvcs) { Write-KitLog -Message "    - $s" -Level 'INFO' }
    }
    Write-KitLog -Message "  GARDER (ne pas toucher) :" -Level 'INFO'
    foreach ($k in $oemKeepList) { Write-KitLog -Message "    - $($k.name) ($($k.reason))" -Level 'INFO' }

    if ($toRemoveMsi.Count -eq 0 -and -not $nativePresent -and $toRemoveSvcs.Count -eq 0) {
        Write-KitLog -Message "Aucun bloatware $oemKey détecté. Étape ignorée." -Level 'OK'
    }
    else {
        # Demander confirmation (sauf WhatIf qui liste seulement)
        $proceed = $false
        if ($WhatIf) {
            Write-KitLog -Message "WHATIF: Aurait supprimé le bloatware $oemKey listé ci-dessus après confirmation" -Level 'WHATIF'
            $proceed = $false
        }
        elseif ($RemoveOemBloat) {
            Write-KitLog -Message "Debloat constructeur $oemKey demandé - suppression." -Level 'INFO'
            $proceed = $true
        }
        elseif ($Unattended) {
            Write-KitLog -Message "Debloat constructeur $oemKey : ignoré (non demandé, mode non-interactif)." -Level 'INFO'
            $proceed = $false
        }
        else {
            Write-Host ""
            Write-Host "[CONFIRMATION REQUISE] Supprimer le bloatware $oemKey listé ci-dessus ?" -ForegroundColor Yellow
            Write-Host "  GARDER : $(($oemKeepList | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor Green
            $answer = Read-Host "Confirmer (O/N)"
            $proceed = ($answer -match '^[Oo]')
        }

        if ($proceed) {
            # Étape 1 : uninstaller natif
            if ($nativePresent) {
                Write-KitLog -Message "Lancement de l'uninstaller natif : $oemNativePath" -Level 'INFO'
                Start-Process -FilePath $oemNativePath -ArgumentList $oemNativeArgs -Wait -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
            }

            # Étape 2 : MSI /x /qn /norestart
            foreach ($m in $toRemoveMsi) {
                Write-KitLog -Message "msiexec /x $($m.guid) /qn /norestart : $($m.name)" -Level 'INFO'
                $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $m.guid, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
                $rc = if ($proc) { $proc.ExitCode } else { -1 }
                # 0 = OK, 1605 = produit inconnu (déjà absent), 3010 = OK mais reboot requis
                if ($rc -in 0, 1605, 3010) {
                    Write-KitLog -Message "  OK ($($m.name), code $rc)" -Level 'OK'
                }
                else {
                    Write-KitLog -Message "  ÉCHEC $($m.name) (code $rc) - peut nécessiter une suppression manuelle" -Level 'WARN'
                }
            }

            # Étape 3 : services orphelins (binaire absent uniquement)
            foreach ($s in $toRemoveSvcs) {
                $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
                if (-not $svc) { continue }
                $reg     = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -ErrorAction SilentlyContinue
                $binPath = if ($reg.ImagePath) {
                    [Environment]::ExpandEnvironmentVariables(($reg.ImagePath -replace '^"','' -replace '".*$',''))
                } else { $null }

                $binExists = $binPath -and (Test-Path $binPath -ErrorAction SilentlyContinue)
                if (-not $binExists) {
                    if ($svc.Status -eq 'Running') {
                        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                    }
                    $scResult = & sc.exe delete $s 2>&1
                    Write-KitLog -Message "  Service orphelin $s supprimé : $scResult" -Level 'OK'
                }
                else {
                    Write-KitLog -Message "  Service $s : binaire présent, gardé." -Level 'INFO'
                }
            }

            Write-KitLog -Message "Bloatware $oemKey traité." -Level 'OK'
        }
        else {
            Write-KitLog -Message "Suppression bloatware $oemKey annulée." -Level 'WARN'
        }
    }
}

Write-KitLog -Message "=== 03-Debloat : terminé ===" -Level 'OK'
exit 0
