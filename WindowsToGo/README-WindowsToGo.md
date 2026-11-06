# Autopilot check op een Windows To Go-stick (Rufus)

Een USB-stick waarvan je een pc opstart om direct te zien of en in welke tenant die pc in Autopilot staat. Er wordt niets op de interne schijf van die pc gewijzigd.

## Bestanden

| Bestand | Waar draaien | Doel |
|---|---|---|
| `Prepare-WtgStick.ps1` | **Je eigen pc**, stick erin | Zet de tool op een met Rufus gemaakte stick en laat hem zichzelf installeren bij de eerste opstart |
| `Install-WtgAutopilotCheck.ps1` | Op de stick (normaal automatisch) | Maakt de logon-taak, de bureaubladsnelkoppeling en de energie-instellingen |
| `Start-AutopilotCheck.ps1` | Op de stick (automatisch na inloggen) | Wacht op internet en start daarna `Get-AutopilotProfile.ps1 -Gui` |
| `Reset-AutopilotProbeState.ps1` | Op de stick | Wist de gecachete marker/ticket/device identity: altijd clean beginnen |

## 1. Stick maken met Rufus

- Een **snelle** USB-stick/SSD van ≥ 64 GB (een USB 3.x SSD wordt sterk aangeraden)
- Een Windows 11 Enterprise/Pro-ISO
- Rufus → *Image option*: **Windows To Go**
- Vink in het dialoogvenster "Windows User Experience" aan:
  - **Prevent Windows To Go from accessing internal disks**
  - **Remove requirement for an online Microsoft account**
  - **Create a local account using username:** bv. `apcheck`
  - **Disable BitLocker automatic device encryption**

## 2. Stick klaarzetten (op je eigen pc)

Laat de stick na Rufus in je pc zitten en voer **als administrator** uit:

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1
```

Het script zoekt zelf de Windows-partitie van de stick: een USB-schijf met een Windows-installatie, die niet je eigen systeemschijf is. Vindt het er meerdere, of heeft de partitie geen schijfletter, geef dan `-DriveLetter E` mee. Er wordt **niets geformatteerd**. Het script:

- kopieert de tool naar `X:\AutopilotCheck` (elke keer een schone kopie)
- voegt aan `X:\Windows\Setup\Scripts\SetupComplete.cmd` een regel toe die de installatie start
- zet `Install Autopilot check.cmd` op het openbare bureaublad, als terugvaloptie

Je kunt het script opnieuw draaien om een nieuwere versie van de tool op de stick te zetten.

## 3. Eerste opstart van de stick

1. Boot een pc van de stick (F12/boot-menu; Secure Boot mag aan blijven) en rond de eerste setup af.
2. Normaal installeert `SetupComplete.cmd` de tool vanzelf.
3. Zie je na het inloggen toch de snelkoppeling **Install Autopilot check** op het bureaublad? Dubbelklik er dan één keer op en bevestig de UAC-vraag. Dat gebeurt als de stick al eerder is opgestart, of als Windows `SetupComplete.cmd` heeft overgeslagen. Dat laatste doet Windows bijvoorbeeld als de pc een OEM-productsleutel in de firmware heeft. Na de installatie verdwijnt de snelkoppeling.
4. Optioneel automatisch inloggen (alleen op een stick die je alleen voor deze check gebruikt):

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1 -AutoLogon
   ```

Installatielogs staan in `C:\ProgramData\AutopilotProbe\install-*.log`.

## 4. Gebruik

1. Steek de stick in de pc die je wilt controleren en boot ervan.
2. Log in (of automatisch). Na ~10 s verschijnt het venster *Waiting for internet*. Sluit een netwerkkabel aan of kies wifi; het wifi-scherm gaat vanzelf open.
3. Het resultaat verschijnt in het venster (Registered/Not registered/Unknown, met tenant en profiel).
4. Nog een keer uitvoeren: snelkoppeling **Autopilot check** op het bureaublad (vraagt om UAC).

**Is de controle echt online uitgevoerd?** Kijk in `C:\ProgramData\AutopilotProbe\`. Alleen een run die de dienst echt heeft bereikt, heeft een regel `HTTP <code>` in `autopilot-*.log` en een bestand `autopilot-*-response.json` met het antwoord van Microsoft.

Bij **HTTP 401** (ticket verlopen) of **"No device ticket"** start je de pc via de stick opnieuw op, met netwerk, en probeer je het nog eens.

## Wisselen van pc: verouderde gegevens

De check gebruikt de **AutopilotMarker** en het **serienummer** uit `HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo`, plus het MSA-**device ticket** van SYSTEM. Zijn die nog van een vorige pc, dan meldt `Get-AutopilotProfile.ps1` **Unknown** ("Cached hardware info belongs to another device"). Een verkeerde tenant krijg je dan dus niet te zien.

Getest op een Entra-joined pc: na het wissen maakte Windows `HardwareInfo` binnen enkele seconden opnieuw aan, met **dezelfde** marker. De marker is dus van de hardware afgeleid. Op de stick verwacht ik daarom dat hij per pc goed wordt opgebouwd. **Test dit op twee verschillende pc's** voordat je de stick in gebruik neemt.

### Clean beginnen: `Reset-AutopilotProbeState.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Reset-AutopilotProbeState.ps1
```

Draai dit als administrator; het script start zichzelf daarna opnieuw als SYSTEM. Er wordt **geen back-up** gemaakt. Het wist:

- `HardwareInfo`
- `AutopilotPolicyCache`
- de device tickets en de MSA device identity van SYSTEM

Daarna start het `wlidsvc` opnieuw. Herstart vervolgens met netwerk. Met `-WhatIf` zie je alleen wat er gewist zou worden; met `-KeepDeviceIdentity` blijft de MSA device identity staan.

**Beveiliging:** op een pc die Entra-joined, AD domain-joined of in Intune/MDM geënrolld is, weigert het script te draaien (exit code 3, er wordt niets gewijzigd), tenzij je `-Force` meegeeft. De stick heeft een lokaal account en valt hier dus niet onder.
