# Workouts: trainingen bijhouden in Haltewekker

Ontwerp, 15 november 2026. Alleen de iPhone-app (`ios/`). Dit project komt na Recomp en het betrouwbaarheidsproject, en vóór de nieuwe vormgeving van de hele app.

Punten met **⚙︎** zijn keuzes van de ontwerper (Claude) die de gebruiker nog kan terugdraaien. De rest heeft de gebruiker zelf zo gezegd. Het programma staat in `.superpowers/workouts/program.md`. Het formaat van zijn Hevy-export staat in `.superpowers/workouts/hevy-summary.md`.

## Waarom

De gebruiker wil dat Haltewekker ook zijn trainingen bijhoudt: "tracks my workouts and sets/reps and lets me compare to previous days and sets", met alle functies van Hevy behalve de sociale.

- Nu logt hij in **Hevy** (gratis, zonder Pro): 119 trainingen in het afgelopen jaar. Hevy stuurt de trainingen naar Apple Gezondheid. Hij heeft een Apple Watch.
- Zijn programma heeft vaste regels: Push → Pull → rust, benen bij elke tweede Pull-dag, RIR-doelen, rusttijden, dubbele progressie, deloads en sets per spiergroep per week. Hevy toont alleen wat hij vorige keer deed. **Wat hij vandaag moet tillen**, rekent hij zelf uit. Deze app rekent het voor hem uit, en een set loggen kost dan één tik.
- Hij opent Haltewekker al elke dag. Een aparte app zou een van de 3 plekken voor zelf geïnstalleerde apps op een gratis Apple ID kosten. Recomp heeft zijn lichaamsgewicht al, en dat is nodig voor pull-ups en dips.
- Wat Hevy achter Pro zet (warm-upcalculator, grafieken over de hele geschiedenis, onbeperkt eigen oefeningen en routines), krijgt hij hier gewoon.

## Wat het moet doen

Vier momenten.

### Vóór de training

- Het startscherm zegt welke training volgens de rotatie aan de beurt is, bijvoorbeeld **"Pull + legs"**, met het aantal oefeningen, sets en de geschatte duur. Eén grote knop: **Start Pull + legs**. Klein eronder: de andere routine starten, of een lege training.
- Is het volgens de rotatie een rustdag, dan staat er rustig "Rest day. Next: Push". De startknop blijft gewoon werken.
- Is er een training bezig (de app is gesloten of de telefoon is herstart), dan staat bovenaan **Resume**, met de verstreken tijd.
- Valt er een deload, dan staat dat er in één regel bij (zie "Deload").

### Tijdens de training

- Bovenaan staat de **huidige oefening, groot**: naam, eventueel de stap op de ladder ("tuck negatives"), het doel ("3 × 6–10 · RIR 1–2 · rest 2:30") en de vaste notitie ("Upper chest priority").
- Elke set staat op een rij: **wat je vorige keer bij deze set deed**, en de voorgestelde kg × reps al ingevuld. Klopt dat, dan is **één tik op ✓ genoeg**. Anders tikt hij op het getal en zet het met − en + goed. Tikken met komma of punt werkt allebei.
- Onderaan, waar de duim zit, staat dezelfde actie als grote knop: **"Set 2 of 3 · 26 kg × 10 · Done"**. Dezelfde knop staat ook in de Live Activity.
- ⚙︎ **RIR** is niet verplicht. Na ✓ staat er in de rij een klein "RIR 1–2". Wie niets aantikt, logt "zoals gepland". Tikken geeft 0, 1, 2, 3 of 4+. Bij de dragon flag ("stop before form breaks") staat er geen RIR.
- Na een set start de **rusttimer** vanzelf, met de rusttijd van die oefening. Er zijn knoppen −15 s, +15 s en Skip. Is de rust voorbij, dan komt er een melding met geluid. Is de telefoon vergrendeld, dan tikt de Apple Watch tegen zijn pols, want iPhone-meldingen komen daar vanzelf op.
- **Superset** (lateral raise + rear delt fly): na een set van de eerste oefening springt de app zonder rust naar de tweede. Na die tweede volgt de rust en daarna weer de eerste.
- **Warm-up:** bij de eerste compound na de skills stelt de app ramp-up-sets voor (⚙︎ Push: incline DB press 50 % × 8 en 75 % × 4; Pull: pull-up 1 makkelijke set; legs: leg press 1 set). Warm-upsets tellen nergens mee. Boven de eerste oefening staat "Warm up 5 min".
- **Nieuw record:** een korte regel "New best: 28 kg × 8" met een tik van de haptiek. Geen geluid en geen confetti.
- Tijdens de training kan hij oefeningen toevoegen, weghalen, verslepen en **vervangen**. Bij vervangen staan de alternatieven uit zijn programma bovenaan (lat pulldown ⇄ single-arm cable pulldown, leg press ⇄ hack squat ⇄ goblet squat, cable ⇄ DB lateral raise). Hij kan ook sets toevoegen of wegvegen, het settype kiezen (warm-up, normal, failure, drop) en een notitie maken.
- Bij oefeningen op tijd (hollow-body hold, handstand hold, dead hang) staat een stopwatch in de rij.
- Alles wordt na elke tik op de telefoon bewaard. Een gesloten app, een lege batterij of een herstart kost hooguit de laatste tik.

### Na de training

- **Finish** geeft een samenvatting met een kopje dat iets zegt: "Pull + legs · 84 min · 27 sets". Daaronder: de nieuwe records; per oefening de vergelijking met vorige keer ("Pull-up 9 · 9 · 8, +2 reps"; een daling staat er in gewone inkt, niet in rood); de voorstellen voor de volgende keer ("All sets at 12. Next time 57.5 kg", of "Ready for tuck reps? **Move up**"); en een veld voor een notitie bij de training.
- Een training met 0 gelogde sets wordt niet bewaard. ⚙︎ Hij krijgt de vraag "Discard?".

### Tussen trainingen

- **Geschiedenis:** een maandkalender met een stip op elke trainingsdag (zonder reeks) en een lijst met trainingen. Een training kan hij openen, achteraf aanpassen, verwijderen of opslaan als routine.
- **Per oefening:** een grafiek (beste set, e1RM, volume of reps; periode 3 maanden, 1 jaar of alles), de records en een lijst met alle keren dat hij de oefening deed, elke dag op één regel: "Thu 13 Nov · 26×10 · 26×10 · 26×9". Zo ziet hij precies hoe die dag zich verhoudt tot eerdere dagen en sets.
- **Sets per spiergroep** tegen zijn doelen (zie hieronder).
- Routines, oefeningen en instellingen aanpassen, de Hevy-geschiedenis importeren, en een back-up maken of terugzetten.

## Het programma in de app

### Routines

⚙︎ De app begint met drie routines, gevuld uit `program.md`: **Push**, **Pull** en **Legs (add-on)**. Per oefening bewaart de app: sets, herhalingsbereik, RIR-bereik, rusttijd, kleinste gewichtsstap, spiergroepen (primair en secundair), notitie, alternatieven en eventueel een ladder.

| Routine | Oefening | Doel | Rust ⚙︎ | Telt voor |
|---|---|---|---|---|
| Push | Dragon flag (ladder) | 3 × 3–6, tot de vorm breekt | 2:00 | core |
| | Pike push-up (ladder) | 3 × 5–10 · RIR 1–2 | 2:30 | front delts (triceps ½) |
| | Incline DB press 30–45° | 3 × 6–10 · RIR 1–2 | 2:30 | chest (front delts, triceps ½) |
| | Weighted dip | 3 × 6–10 · RIR 1–2 | 2:30 | chest (triceps, front delts ½) |
| | Flat DB press | 2 × 8–12 · RIR 1 | 2:00 | chest; notitie "drop first if recovery suffers" |
| | Lateral raise (cable/DB) | 4 × 12–20 · RIR 0–1 | 1:15 | side delts; notitie over partials |
| | Overhead triceps extension | 3 × 10–15 · RIR 0–1 | 1:15 | triceps |
| Pull | Dragon flag (ladder) | 3 × 3–6 | 2:00 | core |
| | Pull-up (ladder) | 3 × 5–10 · RIR 1–2 | 2:30 | lats & upper back (biceps ½) |
| | Lat pulldown / single-arm cable pulldown | 3 × 8–12 · RIR 0–1 | 2:00 | lats & upper back |
| | Seated cable row | 3 × 8–12 · RIR 1 | 2:00 | lats & upper back (rear delts, biceps ½) |
| | 5a Lateral raise + 5b Rear delt fly | 3 + 3 × 12–20 · RIR 0–1 | 0 tussen, 1:15 na 5b | side delts / rear delts |
| | Bayesian curl | 3 × 10–15 · RIR 0–1 | 1:15 | biceps |
| | Hammer curl | 2 × 8–12 · RIR 0–1 | 1:00 | biceps; **valt weg op beendagen** |
| Legs | Leg press / hack squat / goblet squat | 3 × 8–12 · RIR 1–2 | 2:00 | legs |
| | Romanian deadlift | 3 × 6–10 · RIR 2 | 2:00 | legs; notitie "straps after pulling" |
| | Optioneel: leg curl of calf raise | 2 × 10–15 · RIR 1 | 1:15 | legs; staat dicht, met één tik erbij |

- ⚙︎ Rust: het midden van de rusttijd uit het programma, afgerond op 15 s (2–3 min → 2:30, 60–90 s → 1:15). Per oefening aan te passen.
- **Legs, eerste twee weken:** 2 sets per oefening. Daarna 3. ⚙︎ De twee weken tellen vanaf de eerste Legs add-on in Haltewekker. Beendagen uit de Hevy-import tellen niet mee, want het programma is nieuw.

### Rotatie

- Volgorde: **Push → Pull → rust**, steeds opnieuw. ⚙︎ De app kijkt naar de laatste afgeronde training, niet naar de kalender. Na Push komt Pull. Na Pull komt een rustdag en dan Push. Een gemiste dag schuift alles gewoon op: geen inhalen, geen "missed".
- **Benen bij elke tweede Pull:** had de vorige Pull geen benen, dan heeft deze ze wel. De app hangt Legs achter Pull en laat de hammer curl weg (die staat dan als dichte regel "Skipped on leg days · Add").
- Wil hij iets anders doen dan de app voorstelt, dan kiest hij gewoon een andere routine. De rotatie telt verder vanaf wat hij echt deed.

### Dubbele progressie

⚙︎ Per oefening, op basis van de laatste keer (alleen werksets, geen warm-up):

1. **Haalde elke set de top van het bereik bij het RIR-doel** (gelogde RIR ≥ ondergrens van het doel, of geen RIR gelogd), dan stelt de app de **kleinste stap** voor: dumbbells +2 kg per hand, kabel/machine +2,5 kg, halter +2,5 kg, extra gewicht bij dip/pull-up +2,5 kg. De herhalingen beginnen dan weer onderaan het bereik. Bij een calisthenics-oefening wordt het **de volgende stap op de ladder**. De stap is per oefening aan te passen (een sportschool met dumbbells in stappen van 1 kg).
2. **Anders:** hetzelfde gewicht, en per set 1 herhaling meer dan vorige keer, tot aan de top. Dat is het voorstel dat met één tik wordt gelogd.
3. De app verhoogt nooit zelf. Op het startscherm van de oefening staat het voorstel ("28 kg × 6+"), en in de samenvatting staat "Next time 28 kg". Hij kan altijd een ander gewicht kiezen.

### Calisthenics-ladders

Een ladder is één plek in de routine met stappen. Elke stap heeft een eigen doel. Bovenaan de oefening staat "Dragon flag · tuck negatives (2 of 7)".

- **Pull-up:** negatives (3–5 s) + assisted → bodyweight 3 × 5–10 at RIR 1–2 → weighted 3 × 5–8. ⚙︎ Naar weighted zodra de eerste set 12 schone reps haalt, of als alle sets op 10 zitten met RIR ≥ 2.
- **Pike → HSPU:** floor pike 3 × 10 → feet-elevated pike 3 × 8–10 → wall HSPU negatives 5 slow → partial wall HSPU (pad) → full wall HSPU. Los erbij, als stap zonder ladder: chest-to-wall handstand hold, 30–60 s.
- **Dragon flag:** hollow-body hold → tuck negatives 3 × 5 (5–8 s lowering) → tuck reps → one-leg → straddle → full negatives → full reps.
- Een stap omhoog gaat met de regel van de dubbele progressie, maar alleen met een tik op **Move up**. **Step back** staat er altijd bij, met de regel uit het programma als hint: "Lower back arching or hips piking? Go back one step."

### Deload

- ⚙︎ **Herhalingen dalen twee keer achter elkaar:** per oefening vergelijkt de app de beste werkset met de keer ervoor (e1RM bij gewicht, reps bij lichaamsgewicht). Daalt die twee keer achter elkaar (dus drie keer op rij omlaag), dan krijgt die oefening een vlag. Hebben twee of meer oefeningen in de laatste cyclus een vlag, dan staat er in de samenvatting en op het startscherm: "Reps fell two sessions running on Pull-up and Seated row. Deload this cycle?" Bij één vlag staat het alleen bij die oefening.
- **Deload this cycle:** één Push en één Pull (met benen als die aan de beurt zijn) met **⅓ minder sets**, afgerond (4 → 3, 3 → 2, 2 → 1). Het gewicht blijft gelijk en er komen geen progressievoorstellen. Daarna gaat de deload vanzelf uit. De knop staat ook altijd in het menu van de startkaart, voor als zijn gewrichten pijn doen.
- **Gepland, elke 6–8 weken:** vanaf week 6 na de laatste deload staat er één rustige regel: "Week 6 since your last deload. Take one this cycle?" met de knoppen **Deload** en **Not yet**. "Not yet" verbergt de regel een week. Er komt nooit een melding en nooit rood. ⚙︎ Zonder eerdere deload telt de app vanaf de eerste training in Haltewekker, niet vanaf de import; anders zou de regel na de import meteen verschijnen.

### Sets per spiergroep

- De app telt **harde sets**: alle sets behalve warm-up, ook failure en drop. ⚙︎ Een primaire spier telt 1, een secundaire ½ (klein, als "indirect").
- ⚙︎ Venster: **gemiddeld per week over de laatste 21 dagen**. 21 dagen zijn precies 7 cycli van 3 dagen, dus het getal springt niet heen en weer met de rotatie.
- Het doel rekent de app uit de routines zelf (sets per cyclus × 7/3). Uit het programma komt dan side delts 16, lats & upper back 21, chest 19, rear delts 7, triceps 7, biceps 12 en legs ~9. Past hij een routine aan, dan verandert het doel mee. Bij de prioriteitsspieren (side delts, lats) staat ook de grens van 12.
- Er staan 7 rijen, zoals in het programma: side delts, lats & upper back, chest, rear delts, triceps, biceps, legs. Onder "More" staan front delts, core, forearms, traps en de benen per spier. Die oefent hij volgens zijn Hevy-geschiedenis ook.

## Hevy-functies: wat wel, later of niet

Bron: Hevy's featurelijst en instellingen (hevyapp.com/features, /features/workout-settings, /features/exercise-programming-options, /features/live-activity), november 2026. De sociale functies staan hier niet; die komen er allemaal niet in (zie "Wat er bewust niet in komt").

| Hevy-functie | Keuze | Waarom |
|---|---|---|
| Training starten (routine of leeg), gewicht × reps, sets toevoegen/wegvegen | v1 | basis |
| Vorige waarden in de rij (per set) | v1 | dit is zijn vraag. ⚙︎ Eerst dezelfde routine, anders de laatste keer ergens |
| Set loggen met één tik | v1 | zijn eis. Hier met het progressievoorstel in plaats van de vorige waarde |
| RPE-kolom | v1 als RIR | zijn programma werkt met RIR. RPE uit Hevy wordt RIR = 10 − RPE |
| Settypes warm-up, normal, failure, drop | v1 | warm-up telt niet mee |
| Supersets (ook meer dan 2) + automatisch doorschuiven | v1 | zijn Pull-dag heeft er een |
| Notities per oefening (blijvend) en per training | v1 | de notities uit het programma |
| Rusttimer per oefening, automatisch, ±15 s, overslaan, geluid | v1 | rusttijden uit het programma |
| Oefening vervangen/toevoegen/herordenen tijdens de training | v1 | alternatieven bovenaan |
| Stopwatch per set (holds) | v1 | hollow-body hold, handstand hold, dead hang |
| Types: gewicht, lichaamsgewicht, weighted, assisted, tijd | v1 | dip en pull-up zijn weighted, negatives assisted |
| Types met afstand (cardio) | alleen uit de import | Walking, Treadmill en Cycling uit Hevy blijven zichtbaar. Nieuw loggen kan als tijd. Zijn Watch meet de rest |
| Warm-upcalculator (Pro) | v1 | het programma vraagt 1–2 ramp-up-sets |
| Plate calculator | v1, klein | ⚙︎ alleen bij oefeningen met halter: één grijze regel "20 + 2 × 15", geen apart scherm |
| Live PR-melding | v1 | regel + haptiek, geen geluid ⚙︎ |
| Scherm aan houden | v1 | instelling, ⚙︎ standaard uit (hij vergrendelt en gebruikt de Live Activity) |
| Warm-upsets tellen mee in statistiek | niet als keuze | ⚙︎ ze tellen nooit mee, één keuze minder |
| Live Activity met "set done" en rusttimer | v1 | besloten |
| Apple Watch-app | niet | besloten. De Live Activity komt vanzelf in de Smart Stack |
| Routines maken/aanpassen (herhalingsbereik); trainingen achteraf aanpassen, verwijderen, opslaan als routine | v1 | |
| Training herhalen | later | de rotatie en de routines dekken het |
| Mappen voor routines | later | met 3 routines is een map alleen een extra tik (Hick) |
| Routinebibliotheek, Hevy Trainer (AI-schema) | niet | hij heeft een eigen programma. De progressieregels doen het nuttige deel |
| Oefenbibliotheek met spiergroepen, zoeken, filter | v1 | zijn programma + alle 66 oefeningen uit zijn export, alleen tekst |
| Video's en animaties bij oefeningen | niet | grootte van de app en rechten |
| Eigen oefeningen (gratis Hevy: beperkt) | v1, onbeperkt | ladderstappen en zijn eigen Hevy-namen |
| Grafieken per oefening (zwaarste, e1RM, beste set, volume, reps) en records, ook per aantal reps | v1 | Swift Charts, over de hele geschiedenis |
| Samenvatting na de training; sets per spiergroep per week | v1 | met vergelijking en voorstellen; tegen zijn doelen |
| Spierverdeling-grafiek, lichaamskaart | later | de 7 rijen doen het werk; een lichaamskaart vraagt tekenwerk |
| Kalender | v1 | stippen, geen reeks |
| Streak / "workout consistency" | niet | geeft schuldgevoel |
| Maandrapport, jaaroverzicht | later | leuk, maar niet dagelijks |
| Lichaamsmaten | v1 alleen tonen | gewicht en taille komen uit Recomp. ⚙︎ Schouderomtrek (V-taper) later, in Recomp |
| Voortgangsfoto's | later | ⚙︎ privé en veel opslag. Eerst de rest goed |
| kg / lbs | alleen kg | zijn export is al in kg |
| Widgets op het beginscherm | later | een widget kan zonder App Group de gegevens van de app niet lezen. Een App Group is een entitlement |
| Apple Gezondheid; Strava, Garmin, ChatGPT/Claude-connector, web-app, coach | later / niet | HealthKit later (besloten). De rest is sociaal of vraagt een server |
| Exporteren | v1 als back-up | ⚙︎ "Save a backup" (JSON via het deelvenster) en "Restore". CSV-export later |
| Hevy-CSV importeren | v1 | besloten, zie hieronder |

## Hevy-geschiedenis importeren

Besloten. De gebruiker wil zijn Hevy-geschiedenis erin en heeft zijn echte export gestuurd: 2.241 sets in 119 trainingen (23 Nov 2025 – 13 Nov 2026), 66 oefeningen.

- **In Hevy:** Profile → Settings → Export & Import Data → Export Data → Workouts. Het CSV-bestand bewaart hij in de Bestanden-app.
- **In Haltewekker:** Workouts → Settings → **Import from Hevy** → het bestand kiezen in Bestanden (`.fileImporter`; daar is geen entitlement voor nodig).
- **Eerst een voorbeeld:** "119 workouts · 2,241 sets · 23 Nov 2025 – 13 Nov 2026 · 66 of 66 exercises matched". Wordt een oefening niet herkend, dan staat die eronder met één voorbeeldset. Hij kiest dan een oefening uit de bibliotheek, of **Keep as is** (dan wordt het een eigen oefening met de naam uit Hevy). ⚙︎ Per DB-oefening staat er een schakelaar "Hevy weight was both dumbbells → halve", voor het geval hij in Hevy het totaal logde.
- Pas na **Import** wordt er iets opgeslagen, en dan alles in één keer: eerst alles inlezen en controleren, dan de maandbestanden schrijven.

**Het formaat**, uit zijn echte export (UTF-8, tekstvelden tussen aanhalingstekens, één rij per set):

```
"title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe"
"Push","13 Nov 2026, 19:16","13 Nov 2026, 20:31","","Incline Bench Press (Dumbbell)",,"",0,"warmup",14,8,,,
```

- **Trainingen:** rijen met dezelfde `title` + `start_time` zijn één training. De nieuwste training staat bovenaan het bestand; de app sorteert zelf.
- **Datum:** `13 Nov 2026, 19:16`: dag, Engelse maandafkorting, jaar en 24-uurs tijd, lokaal en zonder tijdzone. De app leest het als Europe/Amsterdam, met `en_US_POSIX`. ⚙︎ Als terugval leest hij ook `Nov 13, 2026, 7:16 PM` en ISO 8601, voor als Hevy het formaat verandert.
- **Oefeningen:** binnen een training zijn rijen met dezelfde `exercise_title` één oefening, in de volgorde waarin ze voor het eerst voorkomen. ⚙︎ Begint `set_index` weer bij 0 bij een oefening die al voorkwam, dan worden het twee blokken.
- **Sets:** `set_index` begint per oefening bij 0. `set_type` is `normal`, `warmup`, `dropset` of `failure`; iets anders wordt normal (bij hem: 1.779 normal, 437 warm-up, 25 drop). Leeg `weight_kg` = lichaamsgewicht; bij weighted en assisted is het getal het extra gewicht of de hulp. Leeg `reps` = op tijd of cardio, met `duration_seconds` en `distance_km`. `rpe` is leeg in zijn export; staat er toch iets, dan RIR = 10 − RPE, afgerond. `superset_id` is bij hem leeg; een getal betekent een superset binnen die training.
- **Notities:** `exercise_notes` staat op elke rij van die oefening herhaald; de app neemt het één keer over. `description` is de notitie van de training. Zijn notities zijn in het Nederlands en blijven zoals ze zijn.
- **Nooit dubbel:** de sleutel is `title` + `start_time`. Hetzelfde bestand twee keer importeren voegt niets toe; een nieuwere export voegt alleen de nieuwe trainingen toe. ⚙︎ Een training die hij na de import in Hevy aanpaste, wordt niet overschreven. ⚙︎ Logde hij in de overgangsweek in beide apps, dan wordt een Hevy-training overgeslagen als die begint binnen de tijd van een training die al in Haltewekker staat ("2 skipped: already logged here").
- **Robuust:** kolommen worden op naam gelezen, niet op positie. Een rij die niet te lezen is, wordt overgeslagen en geteld ("3 rows skipped"). Ontbreekt `title`, `start_time` of `exercise_title`, dan weigert de import rustig, met uitleg.
- **In de rest van de app:** geïmporteerde trainingen tellen mee voor de vorige waarden, de records, de grafieken en de sets per week. ⚙︎ Voor de rotatie tellen alleen trainingen met de titel Push of Pull. Een Legs op dezelfde dag als een Pull telt als Pull met benen. "1", "2", "3", "Bro split 1/2" en de rest zijn alleen geschiedenis.
- **Privé:** zijn echte bestand komt **nooit in de repo**. `.superpowers/workouts/` wordt door git genegeerd. De tests gebruiken een klein **verzonnen** bestand in precies dit formaat. ⚙︎ Dat staat als tekst in het testbestand zelf, zodat de hostless testtarget geen resources nodig heeft. Het bevat 3 trainingen met de settypes normal, warmup, dropset en failure; een leeg gewicht, een hold, een cardiorij en een superset; aanhalingstekens, een komma, een regeleinde en een emoji in een titel; en een Nederlandse notitie.

## Oefenbibliotheek

⚙︎ De bibliotheek begint met de oefeningen uit zijn programma én alle 66 uit zijn Hevy-export, zodat de import zonder koppelwerk gaat. Elke oefening heeft een Engelse naam, uitrusting, type, primaire en secundaire spieren, de kleinste stap en de Hevy-naam (of -namen) waaraan de import hem herkent. Hieronder per spiergroep, met de Hevy-naam tussen haakjes als die anders is:

- **Chest:** Incline DB press (Incline Bench Press (Dumbbell)), Flat DB press (Bench Press (Dumbbell)), Smith bench press, Machine chest fly, Pec deck (Butterfly (Pec Deck)), Cable fly crossover, Weighted dip (Triceps Dip Weighted), Dip (Triceps Dip).
- **Shoulders:** Pike push-up (Pike Pushup) als ladder, Chest-to-wall handstand hold, DB shoulder press, Machine shoulder press, DB lateral raise, Single-arm cable lateral raise, Rear delt fly cable/machine/single-arm (Rear Delt Reverse Fly (Cable), (Machine), Reverse Fly Single Arm (Cable)), Machine shrug.
- **Back:** Pull-up als ladder, met Pull Up (Assisted), Pull Up en Pull Up (Weighted) als stappen. Verder Lat pulldown (Lat Pulldown (Cable)), Single-arm cable pulldown, Seated cable row V-grip / bar grip, Dead hang.
- **Arms:** Bayesian curl, Cable curl, DB curl, Machine preacher curl, Hammer curl DB/cable, Barbell reverse curl, Rope pushdown (Triceps Rope Pushdown), Pushdown, V-grip pushdown, Single-arm pushdown (Tricep Push downs Single Handed), Overhead triceps extension cable/DB (Overhead Triceps Extension (Cable)), DB kickback.
- **Forearms:** Seated palms-up wrist curl, Seated barbell wrist extension, Behind-the-back barbell wrist curl.
- **Legs:** Leg press, Horizontal leg press, Hack squat, Goblet squat, Smith squat, Machine squat, Romanian deadlift (Smith en barbell), Lying leg curl, Seated leg curl, Leg extension, Hip abduction, Hip adduction, Calf press (machine), Seated calf raise.
- **Core:** Dragon flag als ladder (hollow-body hold, tuck negatives, …), Machine crunch, Cable crunch, Parallel-bar leg raise (Leg Raise Parallel Bars), Hanging leg raise, Weighted sit-up, Weighted decline crunch, Ab wheel.
- **Other** (op tijd; de afstand komt uit de import): Walking, Treadmill, Cycling, Stretching.
- **Zijn eigen Hevy-namen** worden eigen oefeningen met dezelfde naam: "Cat Girl" en "For Arm Go Brr Between Legs" (⚙︎ forearms). Bij "Cat Girl" blijven de spieren leeg. Zo'n oefening telt niet mee in de sets per week tot hij de spieren kiest.

## Schermen

**Startscherm** (sheet "Workouts"):

```
Pull + legs                                   ⋯
9 exercises · 25 sets · about 90 min
Dragon flag · Pull-up · Lat pulldown · Row · …
[            Start Pull + legs             ]
Push instead  ·  Empty workout
Last: Push · Thu 13 Nov · 75 min · 22 sets
Week 6 since your last deload. Take one this cycle?   [Deload] [Not yet]
SETS PER WEEK                         last 3 weeks
Side delts      ▓▓▓▓▓▓▓▓▓▓▓▓▓▓░  15 / 16
Lats & back     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  21 / 21
Chest  …  Rear delts  …  Triceps  …  Biceps  …  Legs  …
History  ·  Exercises  ·  Routines  ·  Settings
```

**Training bezig** (schermvullend):

```
Pull · 32:10                                   [Finish]
LAT PULLDOWN                                   ⋯
3 × 8–12 · RIR 0–1 · rest 2:00 · "1–1.5× shoulder width"
SET   LAST TIME   KG      REPS
1     55 × 12     57.5    8       ✓   RIR 1
2     55 × 11    [57.5]  [8]     ( ✓ )          ← now
3     55 × 11     57.5    8
Seated cable row        0/3    last 50 × 10, 10, 9
5a/5b Lateral raise + Rear delt fly    0/6
+ Add exercise
Rest 1:42  ▓▓▓▓▓▓▓░░░░        −15   +15   Skip
[   Set 2 of 3 · 57.5 kg × 8              Done   ]
```

**Live Activity** (vergrendelscherm en Dynamic Island):

```
During a set                              Resting
PULL · 32:10                    3 of 9    REST                       1:42
Lat pulldown · set 2/3                    ▓▓▓▓▓▓▓▓▓▓░░░░░░
57.5 kg × 8        last time 55 × 11      Next: set 3/3 · 57.5 kg × 8
[ ✓ Set done  57.5 × 8 ]                  [ +15 s ]  [ ✓ Set done 57.5 × 8 ]
Island compact: [dumbbell] 2/3  ·  1:42      minimal: the countdown
```

**Samenvatting:** het kopje, de records, één regel per oefening met de vergelijking en het voorstel, de notitie en **Done**. **Oefening:** de grafiek met de keuze (beste set / e1RM / volume), de records en de lijst met dagen; bij een ladder ook de stappen, met de huidige gemarkeerd, en **Move up** / **Step back**. **Routines, Exercises, Settings:** gewone iOS-lijsten. Settings bevat: rest-geluid, scherm aan, lichaamsgewicht (uit Recomp of vast), kleinste stappen, Import from Hevy, Save a backup en Restore.

## Live Activity: hoe het werkt

- De Live Activity start bij **Start** (de app is dan open) en eindigt bij **Finish** of **Discard**. Het eigen type `WorkoutAttributes` staat in `Shared/`, net als `TripAttributes`. Een reis en een training kunnen tegelijk lopen.
- **"Set done"** is een `LiveActivityIntent` in `Shared/`, net als `StopAlarmIntent`. iOS voert die uit **in het proces van de app** en start de app daarvoor op de achtergrond als dat nodig is. De intent logt de voorgestelde set, start de rust, plant de melding voor het einde van de rust en werkt de Live Activity bij. **+15 s** werkt op dezelfde manier. Skip is niet nodig: een set afvinken tijdens de rust beëindigt de rust. ⚙︎ Dat zijn twee knoppen in plaats van Hevy's drie (Hick).
- De widget kan zonder App Group de bestanden van de app niet lezen. Alles wat de Live Activity toont, zit dus in de `ContentState` (onder 4 KB).
- Een tik naast de knoppen opent `haltewekker://workout`. Let op: `onOpenURL` in `HaltewekkerApp.swift` stuurt nu alles naar Spotify en moet dus op host gaan sorteren.
- Klopt de set niet met het voorstel, dan opent hij de app. ⚙︎ Er komen geen −/+ knoppen op het vergrendelscherm.
- **Apple Watch:** vanaf watchOS 11 staat de Live Activity vanzelf in de Smart Stack (⚙︎ met een eigen `.small`-weergave via `supplementalActivityFamilies` achter `#available(iOS 18)`). **Of de knop "Set done" op de Watch werkt, is niet zeker.** Op Apple's ontwikkelaarsforum werkte hij in de bèta's van watchOS 11 niet en zou dat later opgelost zijn, maar daar is geen bevestiging van. Op het apparaat testen. Werkt de knop niet, dan heeft de Watch nog steeds de timer en de tik op de pols aan het einde van de rust.

## Waar het in de app zit

⚙︎ Hetzelfde patroon als Outfit en Recomp:

- In het "meer"-blok (`moreContent` in `Screens.swift`) komt een kaart **Workouts** (SF Symbol `dumbbell.fill`), **bovenaan**, boven Outfit en Recomp, omdat hij die het vaakst gebruikt. De tweede regel zegt iets: "Next: Pull + legs · Push 2 days ago", of "Push in progress · 32 min".
- Op de kaart, linksboven naast de bel, `OutfitTag` en het eiwitlabel van Recomp, komt een `WorkoutTag`. Die staat er **alleen op trainingsdagen** volgens de rotatie ("Pull") en **tijdens een training** (de verstreken tijd, één tik terug). Op rustdagen staat hij er niet. Wordt de rij te breed, dan toont de tag alleen het icoon.
- Het startscherm opent als sheet (`.presentationDetents([.large])`), net als `OutfitSheet` en `RecompSheet`. Een lopende training opent als `.fullScreenCover`, zodat hij niet per ongeluk wordt weggeveegd. Met **Minimize** gaat hij terug naar de app, en de tag brengt hem weer terug.
- De instellingen staan onderaan het Workouts-scherm, niet in de algemene instellingen.
- Niets op het ritscherm of het ochtendscherm. De reisschermen blijven zoals ze zijn.

**Samen met Recomp:** voor pull-up en dip (weighted en assisted) neemt de app bij de start het **weekgemiddelde uit `RecompStore`** (of anders het laatste gewicht) en bewaart dat bij de training. Zo verschuift de geschiedenis niet als hij afvalt. Records en e1RM rekenen met lichaamsgewicht + extra gewicht; ⚙︎ in het totale volume telt alleen het extra gewicht, zoals bij Hevy. Voor geïmporteerde trainingen neemt de app het Recomp-gewicht dat het dichtst bij die datum ligt. Is er nooit een gewicht ingevuld, dan vraagt de app het één keer. Op het startscherm staan gewicht en taille uit Recomp klein bij "Body". ⚙︎ Later kan de wekelijkse check van Recomp zeggen "your lifts are dropping too", als hij snel afvalt en zijn reps dalen.

## Hoe het eruitziet

De twee lijstjes (`.superpowers/redesign/rules.md`), toegepast op dit onderdeel:

- **Het eigen ontwerpsysteem:** Paper (`Paper`, `HWFont`, `.brass(...)`, `PaperFill`), licht, net als Recomp. De grote vormgeving komt later. Nu geen nieuwe stijl.
- **Eén accentkleur:** ⚙︎ `Paper.green`, dezelfde als Recomp, voor alles wat "gedaan" of "start" is (✓, Done, Start, de rustbalk, "New best"). In de Live Activity dezelfde groen op donker.
- **Vaak gebruikt = groot en dichtbij** (Fitts, frequency of use): ✓ en Done minstens 56 pt, Done onderaan bij de duim, de stappers minstens 44 pt. De huidige set is de enige rij die oplicht (staging).
- **Weinig keuzes** (Hick, Miller): één grote startknop, 7 spiergroepen, 2 knoppen in de Live Activity, de andere oefeningen ingeklapt.
- **Cijfers in vaste breedte** overal (`.monospacedDigit()`): kg, reps, timers, sets. Timers met `Text(timerInterval:)`.
- **Snel en met laadtoestand** (Doherty): een tik is meteen zichtbaar. Opslaan gebeurt erachter. De Live Activity loopt binnen ~1 s gelijk. Geschiedenis en grafieken laden op de achtergrond, met een rustige plaatsaanduiding. De import toont een voortgangsbalk met aantallen.
- **Nuttige animatie**, kort (onder ~300 ms): na ✓ drukt de rij even in en schuift de volgende set omhoog (squash, follow-through). Getallen veranderen met `.numericText()`. De rustbalk loopt lineair, want het is tijd. Een record krijgt een korte opwelling plus haptiek.
- **Specifieke kopjes:** "Pull + legs · 84 min · 27 sets", niet "Great workout!". Geen badges, geen versiering, geen motivatieteksten. Taal: **Engels**, oefeningnamen ook.
- **Bekend** (Jakob): de setrij werkt zoals Hevy en Strong (vorige waarde, kg, reps, ✓). Verder vegen om te verwijderen, slepen om te ordenen, en sheets.

## Opslag

De geschiedenis groeit. Zijn eigen jaar in Hevy is 119 trainingen met 2.241 sets, en dat is minder dan 1 MB JSON. Bindend:

- **JSON-bestanden in Application Support**, map `Workouts/`: `library.json` (oefeningen), `routines.json`, `state.json` (rotatie, deload, instellingen), `current.json` (de lopende training, na elke tik opnieuw geschreven) en **één bestand per maand** in `history/2026-11.json`. Opslaan schrijft alleen het bestand dat veranderd is.
- Elk bestand heeft een `version`. Decoderen is **tolerant**, zoals in `RecompModel.swift`: elk veld met `decodeIfPresent` en een standaardwaarde.
- **Nooit wissen:** lukt het decoderen van een bestand niet, dan wordt het hernoemd naar `….corrupt-<datum>.json` en gaat de app verder met de andere maanden (net als `recomp.v1.corrupt`). Er wordt nooit een leeg bestand over een onleesbaar bestand geschreven.
- Schrijven gaat **atomisch** (`.atomic`). De bestandsbeveiliging blijft op de standaard (`completeUntilFirstUserAuthentication`), want "Set done" schrijft terwijl de telefoon vergrendeld is.
- Bij het opstarten leest de app alleen een kleine index (laatste keer en records per oefening). Die is uit de maandbestanden opnieuw op te bouwen. Oude maanden worden pas gelezen als hij de geschiedenis of een grafiek opent.
- Er wordt niets weggegooid, anders dan bij Recomp (90 dagen). De gegevens blijven staan als Sideloadly de app opnieuw installeert, maar niet als hij de app verwijdert. Daarom is er de back-up.

## Wat er bewust niet in komt

- **Alles wat sociaal is:** feed, volgers, profielen, likes, reacties, leaderboards, vergelijken met anderen, ontdekken, routines delen, deelplaatjes, foto's en video's uploaden, Strava en coach.
- **Een Apple Watch-app.** Sideloadly installeert die niet zeker, en een mislukte ondertekening kan de hele app breken. De Live Activity en de melding aan het einde van de rust zijn de Watch-kant.
- **HealthKit (voor nu).** Gevolg: trainingen uit Haltewekker komen niet in Apple Gezondheid, zoals nu vanuit Hevy wel. Wil hij hartslag en zijn ringen, dan kan hij op de Watch tegelijk "Traditional Strength Training" starten. Later, met een aparte testversie, zoals bij Recomp.
- **Herinneringen om te trainen**, reeksen en "missed"-dagen.
- **AI-schema's, kant-en-klare programma's, video's, nieuwe cardio met afstand, lbs, en synchroniseren of een back-up op een server.** Alles blijft op de telefoon.
- **Widgets, mappen, voortgangsfoto's, maandrapport en jaaroverzicht:** later (zie de tabel).

## Wat het niet mag worden

- **Traag.** Een set die klopt met het voorstel is **één tik**, ook vanaf het vergrendelscherm. Een afwijkende set kost hooguit twee of drie tikken.
- **Schuldgevoel.** Geen reeksen, geen rode dalingen, geen "missed". Een deload hoort bij het plan en is geen straf. De deload-herinnering is één regel die hij een week kan wegtikken.
- **Kwetsbaar.** Een gesloten app, een herstart, een vergrendelde telefoon of een kapot bestand kost geen trainingen. Zonder toestemming voor meldingen werkt alles; alleen de melding aan het einde van de rust valt weg.
- **Een risico voor installeren.** Geen nieuwe entitlements: geen HealthKit, geen App Groups, geen Watch-target, geen push, geen time-sensitive meldingen.
- **Last voor het reizen.** De reisschermen, de reis-Live Activity en de wekker blijven zoals ze zijn. Haltewekker start niet trager op door een grote geschiedenis.
- **Een lek.** Zijn echte Hevy-export en zijn trainingsgegevens komen nooit in de repo, in CI of in logs.

## Beperkingen

- SwiftUI, iOS 17+, XcodeGen (`ios/project.yml`). Er is geen lokale Swift-toolchain. CI bouwt en test bij een push (eerst "Unit tests", dan "Build (unsigned)"). Releases komen alleen van `main`, en elke push naar `main` vervangt `latest-ios`. Wat op `main` komt, moet dus werken.
- **Sideloadly met een gratis Apple ID:** elke 7 dagen opnieuw ondertekenen, maximaal 3 apps, geen Watch-app, geen nieuwe entitlements.
- Zijn telefoon draait iOS 26 (de app gebruikt AlarmKit). API's van na iOS 17 alleen achter `#available`.
- **Live Activity:** maximaal 8 uur actief, een ContentState onder 4 KB, en de widget leest geen bestanden van de app. Of `LiveActivityIntent` ook werkt na een koude start (de app is weggeveegd en de telefoon is vergrendeld), moet op het apparaat getest worden. Uit fora blijken randgevallen.
- **Rust voorbij:** een gewone lokale melding (de app vraagt die toestemming al in `Go.swift`). ⚙︎ Niet via AlarmKit: dat rinkelt door de stille modus heen, en dat is te hard voor 20 rustpauzes in een sportschool.
- **Geen HealthKit, geen server, geen pakketten van derden.**
- Versie: ⚙︎ `MARKETING_VERSION` 0.19.0, `CURRENT_PROJECT_VERSION` 84 (na Recomp 0.17.0/82 en betrouwbaarheid 0.18.0/83).

## Manieren om het te bouwen

1. **JSON per maand in Application Support, met de regels in losse Foundation-bestanden.** ← **gekozen.** Het past bij de app (Codable, tolerant decoderen, corrupte bestanden bewaren), alles is te testen in `HaltewekkerTests` zonder app, en het schrijven blijft klein. Nadeel: zoeken over jaren gebeurt in het geheugen, met een index. Bij minder dan 1 MB per jaar is dat geen probleem.
2. **SwiftData.** Minder code voor zoekvragen en relaties. Maar een mislukte migratie kan de hele database onleesbaar maken, wat ingaat tegen "nooit wissen". De `@Model`-types zijn ook geen gewone Foundation-bestanden. Het is nieuw in deze app en lastig te herstellen zonder Xcode bij de hand.
3. **Eén JSON-blok in UserDefaults, net als Recomp.** Het eenvoudigst en hetzelfde als Recomp. Maar UserDefaults wordt bij elke start helemaal ingelezen en is bedoeld voor kleine instellingen. Elke set zou de hele geschiedenis opnieuw schrijven, en Recomp blijft alleen klein omdat het na 90 dagen opruimt. Voor geschiedenis die blijft, past dat niet.

## Wat de gebruiker heeft besloten

- In Haltewekker, alleen op de iPhone. Engels in de app.
- Alle functies van Hevy behalve de sociale.
- Geen Apple Watch-app. Wel een interactieve Live Activity met de huidige oefening en set, wat hij vorige keer deed, de rusttimer en een knop "Set done".
- Geen HealthKit voor nu, geen sociale functies, en alle gegevens blijven op de telefoon.
- Een set die klopt met het voorstel loggen is één tik. De 40 ontwerpregels gelden.
- Zijn programma (`program.md`) is de basis: routines, rotatie, RIR, rusttijden, dubbele progressie, deload, sets per week en ladders.
- **Zijn Hevy-geschiedenis importeren uit de CSV-export: ja.** Hij heeft zijn echte export gestuurd.
- Volgorde: na Recomp en betrouwbaarheid, vóór de nieuwe vormgeving. Samenwerken met Recomp waar het helpt.
- De regels staan in losse Foundation-bestanden en worden getest in `HaltewekkerTests`.

Zijn ⚙︎-keuzes die hij misschien wil terugdraaien: kg per dumbbell (per hand); het voorstel "vorige keer + 1 rep"; het venster van 21 dagen; dat alleen Push- en Pull-titels uit Hevy meetellen voor de rotatie; de tag op de kaart op trainingsdagen; Workouts bovenaan het "meer"-blok; RIR als optionele tik; groen als accentkleur.

## Wat aan de bouwer is

- **Bestanden**, een voorstel: `App/WorkoutModel.swift` (types en tolerant decoderen), `App/WorkoutRules.swift` (rotatie, progressie, ladders, deload, sets per week, e1RM, records, warm-up, halterschijven), `App/WorkoutProgram.swift` (beginroutines en bibliotheek met Hevy-namen), `App/WorkoutStore.swift` (de bestanden, met een map die je kunt meegeven voor tests, en het lichaamsgewicht als closure, zodat tests Recomp niet nodig hebben), `App/HevyCSV.swift`, `App/WorkoutScreen.swift` en verwante schermen, en `Shared/WorkoutAttributes.swift`, `Shared/WorkoutIntents.swift` en `Widget/WorkoutLiveActivity.swift` (in `HaltewekkerWidgets`). De Foundation-bestanden gaan in de `sources:` van `HaltewekkerTests`, naast de Recomp-bestanden.
- **De koppeling tussen intent en app:** registreren in `HaltewekkerApp.init` (niet in `onAppear`), zodat het ook werkt als de app op de achtergrond start. Bij het opstarten pakt de app een Live Activity van een lopende training weer op. Alleen als er geen training loopt, beëindigt hij die.
- **Verder aan de bouwer:** de precieze velden, de index en de namen van de bestanden; de spieren per oefening in de bibliotheek; hoe de Live Activity eruitziet als de rust voorbij is (`staleDate` of de melding); de precieze maten, kleuren en animaties, binnen de regels hierboven.
- **Tests voor de regels:** de rotatie (na Push, na Pull, benen om en om, rustdag, titels uit de import); de dubbele progressie (alle sets op de top, RIR leeg, stap per uitrusting, reps terug naar onderen); de ladders (omhoog, terug, de 12-reps-regel bij pull-ups); deload (twee keer dalen, ⅓ minder sets met afronding, de herinnering na 6–8 weken met "Not yet", de klok niet vanaf de import); sets per week (21 dagen, ½ voor secundair, geen warm-up); e1RM en records (warm-up telt niet, lichaamsgewicht + extra); de warm-upcalculator en de halterschijven; invoer met komma en punt.
- **Tests voor opslag en import:** ontbrekende velden, een corrupt bestand dat bewaard en niet gewist wordt, maandbestanden, een lopende training terugzetten. De Hevy-CSV met het **verzonnen** bestand: aanhalingstekens, regeleinden en emoji in velden, leeg gewicht, holds en cardio, RPE naar RIR, het datumformaat en de terugvalformaten, groeperen op titel + starttijd en per oefening, elke Hevy-naam uit de bibliotheek, en twee keer hetzelfde bestand importeren zonder dubbele trainingen.
