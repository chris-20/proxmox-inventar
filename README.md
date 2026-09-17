# proxmox-inventar

Liest einen Proxmox-VE-Cluster **nur lesend** aus und schreibt zwei CSV-Dateien.

Dieses Repo traegt genau ein Skript und nichts sonst. Es ist die
Auslieferungsstelle: hier wird geholt, nicht entwickelt.

**Der Bestand ist abschliessend:**

| Datei | wofuer |
|---|---|
| `Export-ProxmoxInventar.sh` | das Skript |
| `README.md` | wie man es holt und benutzt |
| `SHA256SUMS` | die Pruefsumme |
| `.gitignore` | verbietet alles, erlaubt die vier anderen |
| `.githooks/pre-commit` | haelt jeden Commit auf, der etwas anderes bringt |

Nichts anderes kommt hinzu - kein zweites Werkzeug, kein Hilfsskript, keine
Tests, keine Beispieldaten. Ein Repo mit einem Zweck laesst sich in zwei
Minuten vollstaendig pruefen; eines mit dreien nicht mehr. Braucht ein anderes
Werkzeug eine oeffentliche Auslieferung, bekommt es ein eigenes Repo.

## Was es tut

`proxmox-vms.csv` - alle VMs **und** LXC-Container **aller** Nodes des
Clusters. Auf jedem Node dieselbe Datei; einmal reicht.

`proxmox-host-<nodename>.csv` - eine Datenzeile, der Node, auf dem das Skript
laeuft. Hersteller, Modell und Seriennummer stehen nur im DMI und sind nur
lokal lesbar - darum laeuft das Skript je Node einmal. Danach die Host-Dateien
zu einer zusammenfuegen: Kopfzeile aus **einer** Datei, darunter die
Datenzeile jeder weiteren. Bei einem einzelnen Node entfaellt das; das Skript
sagt am Ende selbst, was ansteht.

Die Spalte `Physischer Server` der VM-Datei traegt den Node-Namen und trifft
auf die Spalte `Name` der Host-Datei.

Was Proxmox nicht weiss, bleibt leer. Hardware-RAID ist ueber die API
unsichtbar; dann bleibt auch das RAID-Feld leer und die Notiz sagt warum.

## Nur lesen

Das Skript setzt genau zwei Befehle ab: die Proxmox-API lesend und die
DMI-Abfrage. Drei Schichten halten das:

1. Jeder API-Zugriff geht durch eine einzige Funktion; das lesende Verb steht
   in deren Rumpf, nicht im Parameter.
2. Beim Start liest das Skript seinen **eigenen Quelltext** und verweigert den
   Dienst, wenn darin ein Schreibverb, `ssh`, `curl`, `wget` oder `nc` steht.
3. Scheitert ein lesender Zugriff, bleibt das Feld leer. Es gibt keinen
   Rueckfall auf eine andere Methode.

Eine vorhandene Zieldatei wird nie ueberschrieben. Beide CSVs entstehen in
einem Temp-Verzeichnis und werden erst am Ende an ihren Platz gelegt - ein
Abbruch mit Strg-C laesst nichts Halbes zurueck.

Voraussetzungen: Bash (3.2 genuegt), Perl mit `JSON::PP` (Kernmodul),
`pvesh`, `dmidecode`. Kein `jq`, keine Installation, kein Netzwerkzugriff zur
Laufzeit.

## Holen

**Nie in eine Shell pipen.** `wget -qO- ... | bash` ist auf einem Hypervisor
mit root-Rechten die schlechteste aller Moeglichkeiten: Du siehst nie, was
laeuft, eine abgebrochene Uebertragung fuehrt ein halbes Skript aus, und der
Selbsttest aus Schicht 2 faellt dabei aus - er liest `$0`, und bei einer Pipe
gibt es keine Datei zu lesen.

```bash
mkdir -p ~/inventar && cd ~/inventar

wget -q --https-only \
  -O Export-ProxmoxInventar.sh \
  https://github.com/chris-20/proxmox-inventar/releases/download/v1.1.0/Export-ProxmoxInventar.sh

sha256sum Export-ProxmoxInventar.sh    # gegen den Wert, den du dir notiert hast

less Export-ProxmoxInventar.sh         # ansehen, vor allem den Kopf

chmod +x Export-ProxmoxInventar.sh
```

`--https-only` ist kein Beiwerk: ohne den Schalter folgt `wget` einer Umleitung
auch nach `http://` - und GitHub leitet Release-Downloads tatsaechlich um.

`wget` steht in `Depends` von `pve-manager` und ist damit auf jedem PVE-Node
vorhanden; `curl` wird von keinem PVE-Paket vorausgesetzt. Wer trotzdem `curl`
nimmt, braucht `-f` - ohne das landet eine HTTP-Fehlerseite in der Zieldatei
und curl meldet trotzdem Erfolg:

```bash
curl -fsSL --proto '=https' --proto-redir '=https' \
  -o Export-ProxmoxInventar.sh <url>
```

`SHA256SUMS` in diesem Repo ist Bequemlichkeit, kein Beweis - es liegt auf
derselben Seite wie die Datei. Beweis ist ein Wert, den du auf einem anderen
Weg bekommen hast.

## Rechte: root oder sudo

`pvesh` und `dmidecode` lesen nur als root. Der uebliche Fall ist ein
persoenliches Admin-Konto mit sudo-Rechten - dann gehoert `sudo` vor jeden
lesenden Aufruf. Es gibt aber auch Nodes, auf denen man direkt als root
arbeitet und auf denen `sudo` nicht einmal installiert ist; eine
Standardinstallation von Proxmox bringt es nicht mit.

Damit dieselben Befehle in beiden Faellen stimmen, einmal diese Zeile setzen:

```bash
[ "$(id -u)" -eq 0 ] && SUDO= || SUDO=sudo
```

Als Admin-Konto wird daraus `sudo`, als root bleibt es leer. Danach funktioniert
jeder Befehl unten unveraendert, egal wie man angemeldet ist.

Ohne die Rechte bricht das Skript mit einer Ansage ab, statt zwei fast leere
Dateien zu hinterlassen. `--version` und `--zeige-befehle` brauchen nichts
davon - die laufen auch als normaler Benutzer.

## In fuenf Stufen zum ersten Ergebnis

Erst die letzte Stufe redet mit einer laufenden VM, und auch die nur lesend.

| Stufe | Befehl | Beruehrt |
|---|---|---|
| 1 | `./Export-ProxmoxInventar.sh --zeige-befehle` | nichts: zeigt jeden Befehl, fuehrt keinen aus, schreibt nichts |
| 2 | `$SUDO ./Export-ProxmoxInventar.sh --pruefen` | API lesend, ein Gast: berichtet, welche Felder da sind |
| 3 | `$SUDO ./Export-ProxmoxInventar.sh --nur-hosts --ohne-agent` | nur den Node |
| 4 | `$SUDO ./Export-ProxmoxInventar.sh --nur-vms --ohne-agent` | alle Gaeste, ohne den Guest-Agent zu fragen |
| 5 | `$SUDO ./Export-ProxmoxInventar.sh` | alle Gaeste, lesend, mit Guest-Agent |

Die erzeugten CSVs gehoeren danach root. Damit du sie abholen kannst:

```bash
$SUDO chown "$USER": proxmox-*.csv
```

## Was du beim Laufen siehst

Am Terminal eine Zeile, die sich selbst ueberschreibt:

```
Node <name>
  [########################] 100%  17/17  lxc 112 <gastname>
```

Umgeleitet in eine Datei wird daraus je Schritt eine eigene Zeile - ein Logfile
voller Wagenrueclaeufe waere wertlos. `--fortschritt immer` bzw. `nie`
erzwingt das eine oder andere.

## Schalter

```
--zeige-befehle    zeigt jeden Befehl, fuehrt keinen aus, schreibt nichts
--pruefen          fragt jeden Pfad einmal ab, berichtet, schreibt nichts
--ziel <verz>      Ausgabeverzeichnis, Vorgabe .
--nur-hosts        nur die Host-Datei
--nur-vms          nur die Gaeste-Datei
--ohne-agent       den Guest-Agent gar nicht fragen
--fortschritt <w>  auto (Vorgabe), immer oder nie
--timeout <n>      Zeitschranke je Aufruf in Sekunden, Vorgabe 5
--version          Versionsnummer
--hilfe            Uebersicht
```

## Entwicklung

Findet nicht hier statt. Dieses Repo bekommt nur fertige Fassungen.
