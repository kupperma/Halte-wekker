# Recomp: afvallen en spier houden, in Haltewekker

Ontwerp, 15 november 2026. Alleen de iPhone-app (`ios/`). De website (`index.html`) blijft zoals hij is.

Punten met **⚙︎** zijn keuzes van de ontwerper (Claude) die de gebruiker nog kan terugdraaien. De rest heeft de gebruiker zelf zo gezegd.

## Waarom

De gebruiker (183 cm, 88 kg, traint bijna elke dag, heeft al een goede spierbasis) wil een **recomp**: vet verliezen terwijl hij spier opbouwt. Daarvoor is geen streng dieet nodig, wel:

- een klein tekort: ongeveer 2.400–2.500 kcal per dag (onderhoud is 2.800–3.000);
- veel eiwit: **150–170 g per dag**. Een kilo magere kwark geeft er 80–90 g, dus het gat is 60–80 g uit ander eten;
- tempo: **0,25–0,5 kg per week** eraf. Sneller kost spier en kracht.

Of het werkt, zie je aan het **weekgemiddelde** van je gewicht (niet losse dagen) en aan je **taille** (elke 2 weken). Staat het gewicht 3 weken stil, dan eet je ongeveer 200 kcal minder.

Hij opent Haltewekker al elke ochtend en op weg naar huis. Daarom komt dit in Haltewekker en niet in een aparte app. Een aparte app zou ook een van de 3 plekken voor zelf geïnstalleerde apps op een gratis Apple ID kosten.

## Wat het moet doen

Drie momenten op een dag:

1. **'s Ochtends: wegen.** Hij tikt zijn gewicht in. Groot op het scherm staat het weekgemiddelde en hoe dat verandert.
2. **Bij maaltijden: eiwit en gewoontes.** Met één tik voegt hij een eiwitbron toe, geteld in dingen die hij kent (eieren, glazen, bakjes) en **nooit in grammen**. Daarna vinkt hij af welke gewoontes vandaag gelukt zijn.
3. **Op weg naar huis:** op het ritscherm van Haltewekker staat één regel met wat er vandaag nog aan eiwit over is.

Daarnaast een wekelijkse check die zegt of hij moet bijsturen.

### Ochtend: gewicht

- Hij tikt zijn gewicht in. Zowel "88,4" als "88.4" werkt.
- ⚙︎ Per dag telt één gewicht. Tikt hij later die dag een nieuw gewicht in, dan vervangt dat het vorige (een tikfout herstellen).
- Groot staat het **weekgemiddelde**: het gemiddelde van de gewichten uit de afgelopen 7 dagen. Klein ernaast staat het gewicht van vandaag en het verschil met het weekgemiddelde van 7 dagen eerder.
- ⚙︎ **Taille:** is het 14 dagen of langer geleden dat hij zijn taille invulde, dan vraagt het ochtendscherm erom, in cm. Hij kan dit overslaan; dan vraagt de app het de volgende ochtend opnieuw.

### Maaltijden: eiwit

- Bovenaan staat de voortgang als **balk en percentage** van het dagdoel. Het aantal grammen staat er klein onder.
- ⚙︎ Dagdoel standaard **160 g**, aan te passen.
- ⚙︎ Een "dag" loopt van **04:00 tot 04:00**, zodat een late snack nog bij vandaag telt.
- Een raster met **vaste eiwitbronnen**. Tik je erop, dan zie je een teller met − en + en hoeveel eiwit dat is, en een knop Toevoegen:

| Bron | Je telt in | ≈ eiwit |
|---|---|---|
| Magere kwark | bakje van 500 g, in ¼, ½, ¾ of 1 | 40–45 g per bakje |
| Eieren | stuks | 6–7 g per ei |
| Melk | glazen | 8 g per glas |
| Tonijn | blikjes | 25 g per blik |
| Kip(dij) | porties ("1 hand") | 25–30 g |
| Linzen/bonen/kikkererwten | blikjes, in ½ of 1 | 15–20 g per blik |
| Whey | scheppen | 20–24 g per schep |

  ⚙︎ De app rekent met één vast getal per bron (bijvoorbeeld 42 g per bakje kwark). Hij kan dat getal, de eenheid en de naam van elke bron aanpassen, bronnen weghalen en zelf bronnen toevoegen.

- **Barcode scannen:** hij scant een product. De app zoekt het eiwit op bij **Open Food Facts**, dat ongeveer 390.000 Duitse en 58.000 Nederlandse producten kent. Daarna kiest hij hoeveel van de verpakking hij op heeft: **¼, ½, ¾ of alles**. De app rekent het eiwit uit.
  - ⚙︎ Kent Open Food Facts het product niet, of mist het eiwit, dan tikt hij één keer het eiwit per verpakking over van het etiket. De app onthoudt dat bij die barcode, op de telefoon.
  - ⚙︎ Een product dat hij vaker scant, kan hij met één tik bij zijn vaste bronnen zetten.
  - Zonder internet werken alleen de producten die al bekend zijn.
- **Vandaag-lijst:** alles wat hij vandaag heeft toegevoegd. Een vergissing kan hij weghalen of aanpassen.

### Maaltijden: gewoontes

⚙︎ Vijf gewoontes om per dag af te vinken, uit het advies:

1. Alleen zero-drankjes (geen frisdrank, sap of energiedrank)
2. Halve bord groente
3. Olie en saus afgemeten
4. Niet uit de zak gegeten
5. Eén geplande traktatie, niet de hele dag snaaien

Ze staan op hetzelfde scherm als het eiwit, onder de bronnen. Een gewoonte die niet gelukt is, blijft gewoon leeg: er komt geen rood kruis en geen melding. Hij kan de gewoontes zelf aanpassen, maar het blijven er maximaal 5.

### Op weg naar huis: ritscherm

- ⚙︎ Tijdens een rit naar huis staat op het ritscherm één regel, bijvoorbeeld "Nog 55 g eiwit vandaag". Is het doel gehaald, dan staat er "Eiwit gehaald" of verdwijnt de regel.
- Alleen op de rit naar **huis**, niet op de heenrit.
- De regel mag het ritscherm niet drukker maken dan nodig. De countdown, de wekker en de knoppen blijven het belangrijkst.

### Wekelijkse check

⚙︎ **Wanneer:** de check rekent **één keer per week, op maandag**. Hij vergelijkt vaste weken van maandag tot en met zondag, niet een schuivend venster van 7 dagen. Tot de volgende maandag blijft hetzelfde oordeel staan.

⚙︎ Regels, alleen als er genoeg gewichten zijn (minstens 4 in elk van de vergeleken weken):

- **Te langzaam:** is het weekgemiddelde nu minder dan 0,25 kg lager dan 3 weken geleden, dan staat er: "Your weight hasn't moved in 3 weeks. Eat about 200 kcal less a day." Met een korte tip, bijvoorbeeld een kleiner bord, olie afmeten of geen tweede portie.
  - ⚙︎ **Behalve als de taille daalt.** Is de taille in diezelfde 3 weken minstens 1 cm kleiner geworden, dan is dat precies wat een recomp moet doen: vet eraf, spier erbij. De app zegt dan: "Weight steady, waist down 1.5 cm. That's a recomp working." Er komt geen advies om minder te eten.
- **Te snel:** daalt het weekgemiddelde 2 weken achter elkaar met meer dan 0,5 kg per week, dan staat er: "You're losing faster than 0.5 kg a week. Eat a bit more so you keep your muscle."
- **Op koers:** anders staat er rustig dat hij op koers zit, met het tempo per week.
- ⚙︎ **Niet twee keer hetzelfde advies.** Bij "eet minder" of "eet meer" staat een knop "Done, I've adjusted". Een tik daarop, of 3 weken voorbij zonder tik, maakt van die maandag het nieuwe beginpunt. De check vergelijkt daarna alleen weken ná dat beginpunt. Zolang er nog geen 3 volledige weken na het beginpunt zijn, staat er: "Adjusted on 16 Nov. Next check on 14 Dec." (de week van het beginpunt telt mee als eerste week; de vergelijking met 3 weken later kan pas als die latere week af is). Zo leest hij het advies nooit als "nog eens 200 eraf" terwijl de vorige keer nog doorwerkt. De app bewaart wanneer het laatste advies kwam en wanneer hij het opvolgde.
- ⚙︎ De check staat op het Recomp-scherm. Er komt geen melding, want het moet niet zeuren.

### Taille tonen

⚙︎ Bij het gewicht staat klein de laatste taillemeting en het verschil met de eerste meting, bijvoorbeeld "Waist 92 cm · −2.5 since 16 Nov". Er komt geen grafiek.

## Waar het in de app zit

⚙︎ Hetzelfde patroon als Outfit:

- Op de kaart, linksboven naast de bel en het Outfit-label (`OutfitTag`), komt een klein label met het eiwitpercentage van vandaag. Een tik opent het Recomp-scherm.
- In het "meer"-blok (`moreContent` in `Screens.swift`) komt een Recomp-kaart naast Outfit en "How steady".
- Het Recomp-scherm opent als sheet (`.presentationDetents([.large])`), net als `OutfitSheet`.
- Op het Recomp-scherm staan van boven naar beneden: gewicht (en de taillevraag als die aan de beurt is), eiwit met bronnen, gewoontes en de wekelijkse check.
- ⚙︎ Instellingen (dagdoel, bronnen en gewoontes aanpassen) staan onderaan het Recomp-scherm, niet in de algemene instellingen.
- ⚙︎ **Ook op het ochtendscherm.** Het ochtendscherm na de schoolwekker (`MorningView` in `Morning.swift`) heeft al een Outfit-regel (`OutfitLine`). Daaronder komt een weegregel: een veld voor het gewicht en een knop Save. Is de taille aan de beurt, dan staat er nog een veld bij. Op schooldagen weegt hij zich zo in één stap, zonder het Recomp-scherm te openen. Op andere dagen gebruikt hij het weegblok bovenaan het Recomp-scherm. "Ochtendscherm" hierboven betekent dus allebei.

## Hoe het eruitziet

De gebruiker wil dat alle ontwerpen de twee lijstjes uit de video's volgen ("20 Principles of UX & Animation" en "20 Ways to Unslop AI Designs"). Voor dit onderdeel betekent dat:

- **Het eigen ontwerpsysteem:** de Paper-stijl van Haltewekker (`Paper`, `HWFont`, `.brass(...)`-kaarten, `paperSheet`). Geen nieuwe stijl.
- **Eén accentkleur** voor eiwit, steeds dezelfde (balk, label, knoppen). ⚙︎ Bijvoorbeeld `Paper.green`, of een nieuwe kleur die past bij Paper.
- **Cijfers in vaste breedte** (`.monospacedDigit()`), zodat de balk en het gewicht niet verspringen.
- **Grote tikvlakken** (minstens 44 pt, de eiwitknoppen groter) en **weinig keuzes per scherm**: maximaal 8 bronknoppen in het raster en 5 gewoontes.
- **De hoofdzaak groot:** het weekgemiddelde en de eiwitbalk. De rest is kleiner.
- **Geen versierende badges** en geen overbodige labels. Geen woorden met willekeurige hoofdletters, geen monospace-lettertype behalve voor cijfers waar het moet.
- **Kopjes die iets zeggen:** "Nog 55 g eiwit", niet "Je voortgang".
- **Laadtoestand** bij het opzoeken van een barcode, en een duidelijke melding als dat niet lukt.
- **Nuttige animatie:** de balk vult zich zichtbaar als hij iets toevoegt, en vinkjes geven een kleine, snelle tik (met haptische feedback). Animaties zijn kort (onder ~300 ms); gewoon tellen voelt direct.
- **Vriendelijk voor invoer:** komma en punt allebei goed; een verkeerde invoer wordt rustig geweigerd, niet met een foutmelding.
- **Bekend:** werkt zoals andere iPhone-apps (sheets, tellers met − en +, vegen om te verwijderen in de vandaag-lijst).

Taal: **Engels**, net als de rest van de app. ⚙︎ Etenswaren mogen Nederlandse namen houden waar dat logischer is ("Kwark").

## Wat er bewust niet in komt

- **Calorieën tellen.** Het weekgewicht laat zien of het tekort klopt.
- **Foto's van eten met AI.** Daarvoor is een betaalde API-sleutel nodig, en die zit niet in het educatieplan van de gebruiker. Misschien later, als hij gratis tegoed krijgt via Anthropic's Student Builders.
- **De website.** Die loopt al achter op de app (laatst bijgewerkt bij versie 0.9.1). De website bijwerken is een apart project.
- **Apple Gezondheid (voor nu).** Daarmee zouden het gewicht van een weegschaal en het aantal trainingen (van Hevy en zijn Apple Watch) vanzelf binnenkomen. Maar de toestemming die de app daarvoor nodig heeft, kan Sideloadly met een gratis Apple ID misschien niet aan. Dan zou hij ook de reiswekker niet meer kunnen vernieuwen. Het komt later, met een aparte testversie. Bouw de gegevens zo dat gewichten later uit Gezondheid kunnen komen, zonder alles om te gooien.
- **Slaap.** Hij draagt zijn Apple Watch niet in bed.
- **Krachtcijfers uit Hevy.** Daarvoor is Hevy Pro nodig, en die heeft hij niet.
- **Eetschema's of recepten.**
- **Synchroniseren of een back-up op een server.** Alles blijft op de telefoon.
- ⚙︎ **Meldingen of herinneringen.** Hij opent de app al elke ochtend en op weg naar huis.

## Wat het niet mag worden

- **Gedoe.** Een maaltijd vastleggen moet in **ongeveer 10 seconden** kunnen. Duurt het langer, dan houdt hij het niet vol.
- **Schuldgevoel.** Geen rode kruizen, geen reeksen die breken, geen zeurende meldingen.
- **AI-achtig ontwerp:** generieke kaarten, versiering en onduidelijke kopjes (zie de lijstjes hierboven).
- **Kwetsbaar.** Weigert hij camera-toegang of is er geen internet, dan werkt alles behalve het scannen van nieuwe producten. Barcode intikken blijft dan mogelijk.
- **Een risico voor installeren.** Er komen geen nieuwe entitlements bij die het ondertekenen met Sideloadly en een gratis Apple ID kunnen breken.
- **Last voor het reizen.** Haltewekker wordt niet trager en de reisschermen worden niet voller. Op het ritscherm komt alleen die ene regel bij.

## Beperkingen

- SwiftUI, iOS 17+, project via XcodeGen (`ios/project.yml`). GitHub Actions bouwt een **niet-ondertekende** `.ipa` (`.github/workflows/ios.yml`), die de gebruiker met **Sideloadly en een gratis Apple ID** installeert.
- **Geen HealthKit** in deze versie (zie "Wat er bewust niet in komt").
- **Camera** voor barcodes: er moet een uitleg in de Info.plist komen (`NSCameraUsageDescription`) via `project.yml`. Camera-toegang heeft geen entitlement nodig.
- Elke push naar `main` vervangt de enige release `latest-ios`, die hij installeert. Wat op `main` komt, moet dus bouwen en werken.
- **Opslag op de telefoon**, zoals de rest van Haltewekker (UserDefaults/JSON, `ObservableObject`-stores met `shared`, zoals `OutfitStore`). De gegevens moeten blijven staan als de app via Sideloadly opnieuw wordt geïnstalleerd. Dat gebeurt nu ook met de instellingen.
- **Open Food Facts** is gratis en vraagt geen sleutel. Het verwacht wel een herkenbare User-Agent met een algemene appnaam (geen persoonlijke gegevens).
- Versienummer ophogen in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), zoals bij elke release.

## Manieren om het te bouwen

1. **Een eigen versie voor de iPhone-app én voor de website.** Voelt in beide goed, maar de logica bestaat dan twee keer.
2. **Eén keer bouwen als webpagina en die in de app tonen.** Eén versie, maar in de app voelt het anders dan de rest, en Gezondheid en het ritscherm worden ingewikkeld.
3. **Alleen in de iPhone-app, in SwiftUI.** ← **gekozen.** De gebruiker wilde de website er eerst bij, maar liet die daarna vallen. Hij gebruikt de app elke dag; daar moet het het best werken, met de regel op het ritscherm en het ochtendscherm (en later Gezondheid).

## Wat de gebruiker heeft besloten

- In Haltewekker, niet in een aparte app.
- Alleen de iPhone-app, niet de website.
- Manier B: alleen eiwit tellen plus gewoontes afvinken, geen calorieën.
- Geen fotoherkenning (geen API-sleutel).
- Eiwit tellen in stuks, glazen, bakjes en porties, en bij gescande producten in ¼, ½, ¾ of alles. Nooit in grammen.
- Nederlandse en Duitse producten moeten scanbaar zijn.
- Geen krachtcijfers (geen Hevy Pro).
- Apple Gezondheid voor nu weglaten, later toevoegen.
- Geen slaap.
- Na Recomp volgt een apart project: de hele app nalopen met de twee lijstjes.
- Alle ontwerpen volgen de twee lijstjes uit de video's.

## Wat aan de bouwer is

- Bestandsindeling en namen (bijvoorbeeld `Recomp.swift` voor de store en `RecompScreen.swift` voor de schermen, naast `Outfit.swift` en `OutfitScreen.swift`).
- Hoe de gegevens precies worden opgeslagen.
- Hoe barcodes worden gescand: VisionKit `DataScannerViewController` of AVFoundation. Het moet werken op iOS 17 en een terugweg hebben als de camera niet beschikbaar is (barcode intikken).
- Welke Open Food Facts-velden de app gebruikt (eiwit per verpakking, of per 100 g maal de inhoud) en wat er gebeurt als een veld ontbreekt.
- De precieze kleur, maten en animaties, binnen de regels hierboven.
- Tests voor de rekenregels: weekgemiddelde, wekelijkse check, dagwissel om 04:00, delen van een verpakking en invoer met komma of punt.
