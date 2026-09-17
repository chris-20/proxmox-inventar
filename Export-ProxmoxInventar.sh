#!/usr/bin/env bash
# Export-ProxmoxInventar.sh - liest einen Proxmox-VE-Cluster NUR LESEND aus und
# schreibt zwei CSV-Dateien.
#
# Das Skript ist allein lauffaehig und wird auch allein weitergegeben. Es
# verweist darum auf nichts, was der Leser nicht mitbekommt: die Regeln, nach
# denen es ausschliesslich liest, stehen im README unter "Nur lesen",
# die Pruefungen dazu im Projekt, aus dem es stammt.

set -u

# Festes Locale: BSD-sort bricht im UTF-8-Locale an einem Umlaut mit
# "Illegal byte sequence" ab, und die Sortierreihenfolge haenge sonst an der
# Umgebung des Aufrufers - beides toedlich fuer byte-gleiche Wiederhollaeufe.
LC_ALL=C
export LC_ALL

VERSION=1.1.0

PVESH=${PVESH:-pvesh}
DMIDECODE=${DMIDECODE:-dmidecode}
PVE_DIR=${PVE_DIR:-/etc/pve}
OUT_DIR=.
API_TIMEOUT=5
AGENT_TIMEOUT=5
SHOW_ONLY=0
CHECK_ONLY=0
NUR_HOSTS=0
NUR_VMS=0
OHNE_AGENT=0
FORTSCHRITT=auto
TMP_DIR=""
ZIEL_HOST=""
ZIEL_VMS=""

# Fd 3 ist die urspruengliche Ausgabe. Eine Kommandosubstitution biegt nur
# Fd 1 um - was nach Fd 3 geht, sieht der Nutzer also auch aus $(...) heraus.
# Ohne das verschluckte --zeige-befehle ausgerechnet die dmidecode-Zeilen.
exec 3>&1
zeige_befehl() { printf '%s\n' "$1" >&3; }

die() { fortschritt_ende; printf 'Abbruch: %s\n' "$1" >&2; exit 1; }

# hinweis raeumt zuerst eine offene Fortschrittszeile weg, sonst schriebe die
# Meldung mitten in den Balken.
hinweis() { fortschritt_ende; printf '%s\n' "$1" >&2; }

# --- Fortschritt -----------------------------------------------------------
# Am Terminal eine Zeile, die sich selbst ueberschreibt. Umgeleitet in eine
# Datei je Schritt eine eigene Zeile - sonst stuenden dort lauter \r und
# Steuerzeichen. `--fortschritt` erzwingt das eine oder andere.
FORTSCHRITT_AKTIV=0
BALKENBREITE=24

fortschritt_an() {
  # Im Trockenlauf und in der Vorflug-Kontrolle wuerde der Balken die Liste
  # zerschneiden, die der Nutzer gerade lesen will.
  [ "$SHOW_ONLY" -eq 1 ] && return 1
  [ "$CHECK_ONLY" -eq 1 ] && return 1
  case $FORTSCHRITT in
    immer) return 0 ;;
    nie)   return 1 ;;
    *)     [ -t 2 ] ;;
  esac
}

fortschritt_ende() {
  if [ "$FORTSCHRITT_AKTIV" -eq 1 ]; then
    printf '\r\033[K' >&2
    FORTSCHRITT_AKTIV=0
  fi
}

# fortschritt <nr> <gesamt> <text>
fortschritt() {
  local nr=$1 gesamt=$2 text=$3
  still && return
  if ! fortschritt_an; then
    printf '[%s/%s] %s\n' "$nr" "$gesamt" "$text" >&2
    return
  fi
  local voll=0 prozent=0 i=0 balken=""
  if [ "$gesamt" -gt 0 ]; then
    voll=$(( nr * BALKENBREITE / gesamt ))
    prozent=$(( nr * 100 / gesamt ))
  fi
  while [ "$i" -lt "$BALKENBREITE" ]; do
    if [ "$i" -lt "$voll" ]; then balken="$balken#"; else balken="$balken-"; fi
    i=$((i + 1))
  done
  printf '\r\033[K  [%s] %3s%%  %s/%s  %s' \
    "$balken" "$prozent" "$nr" "$gesamt" "$text" >&2
  FORTSCHRITT_AKTIV=1
}

# still - im Trockenlauf und in der Vorflug-Kontrolle gibt es keinen
# Fortschritt, auch keinen zeilenweisen: er zerschnitte die Liste, die der
# Nutzer gerade liest.
still() { [ "$SHOW_ONLY" -eq 1 ] || [ "$CHECK_ONLY" -eq 1 ]; }

# abschnitt <text> - Ueberschrift ueber einen Abschnitt
abschnitt() { still || hinweis "$1"; }

# schritt <text> - fuer Abschnitte ohne bekannte Gesamtzahl
schritt() {
  still && return
  if ! fortschritt_an; then
    printf '  %s\n' "$1" >&2
    return
  fi
  printf '\r\033[K  %s' "$1" >&2
  FORTSCHRITT_AKTIV=1
}

# WAECHTER-MARKE
# Die Zeile darueber ist der Angriffspunkt fuer Testfall 14: der Test schiebt
# dort ein Schreibverb ein und erwartet, dass selftest_source es findet.

# --- Selbsttest ueber den eigenen Quelltext (R2, R3, R7, R8) ---------------
# Ein manipuliertes oder halb editiertes Skript laeuft gar nicht erst an.
selftest_source() {
  local quelle=$1 fund muster
  # Ein unlesbarer Quelltext ist kein sauberer Quelltext: grep gibt dann leer und
  # Exitcode 2 zurueck, und der Waechter meldete "sauber", ohne etwas gesehen zu haben.
  if [ ! -r "$quelle" ]; then
    printf 'Selbsttest: eigener Quelltext nicht lesbar (%s)\n' "$quelle" >&2
    return 1
  fi
  muster='pvesh[[:space:]]+(set|create|delete|push)'
  # Auch ueber die Variable: das Skript ruft "$PVESH" auf, nicht pvesh.
  muster="$muster"'|\$\{?PVESH\}?"?[[:space:]]+(set|create|delete|push)'
  muster="$muster"'|\$\{?DMIDECODE\}?"?[[:space:]]+(--dump|--dump-bin)'
  muster="$muster"'|(^|[^a-z])(qm|pct)[[:space:]]+(set|start|stop|destroy|shutdown|reset)'
  muster="$muster"'|agent[[:space:]]+exec'
  muster="$muster"'|(^|[^a-z_-])(ssh|scp|curl|wget|nc)[[:space:]]'
  fund=$(grep -n -E "$muster" "$quelle" \
         | grep -v 'muster=' \
         | grep -v '^[0-9]*:[[:space:]]*#')
  if [ -n "$fund" ]; then
    printf 'Selbsttest: verbotener Befehl im eigenen Quelltext:\n%s\n' "$fund" >&2
    return 1
  fi
  return 0
}

# --- Zeitwaechter (R5) -----------------------------------------------------
# macOS bringt kein `timeout` mit. Eigener Waechter, damit Test und Node
# denselben Codepfad laufen. Rueckgabe 124 bei Abbruch.
run_limited() {
  local secs=$1; shift
  local pid wpid rc
  "$@" >"$TMP_DIR/out" 2>"$TMP_DIR/err" </dev/null &
  pid=$!
  # Die Umleitung ist nicht kosmetisch: ohne sie erbt der Waechter die
  # Ausgabe-Pipe einer Kommandosubstitution wie $(dmi ...). Die wartet dann
  # auf EOF, also die volle Zeitschranke - auch wenn der Befehl laengst
  # fertig ist.
  #
  # Der Waechter raeumt seinen eigenen sleep weg, wenn er abgebrochen wird.
  # Ohne den trap bliebe je Aufruf ein verwaister sleep stehen, bis die
  # Schranke abgelaufen ist - bei ueber hundert Aufrufen je Lauf sind das
  # hundert Prozesse, die auf dem Node nichts zu suchen haben.
  ( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
    sleep "$secs" &
    wait
    kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  # 143 = SIGTERM: der Waechter hat zugeschlagen
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}

# Strg-C: aufraeumen und beenden. Ohne eigenen Handler liefe das Skript nach
# dem Trap weiter (R11, R12).
abbruch() {
  hinweis ""
  hinweis "Abgebrochen. Es wurde nichts geschrieben."
  aufraeumen
  exit 130
}

aufraeumen() {
  # /bin/rm mit vollem Pfad: der Test legt eine rm-Attrappe auf PATH, und ein
  # Werkzeug, das sein eigenes Temp-Verzeichnis nicht loeschen kann, waere
  # kaputt. Der Stolperdraht faengt trotzdem jedes andere rm im Skript.
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && /bin/rm -rf "$TMP_DIR"
  return 0
}

# --- Luecken sammeln (Spec 4) ----------------------------------------------
# Ein fehlendes Feld kostet eine Zelle, nicht den Lauf. Der Exitcode bleibt 0.
LUECKEN=""
ANZ_GAST=0
ANZ_VM=0
ANZ_LXC=0
ANZ_AGENT=0            # gefragt und geantwortet oder nicht - jedenfalls gefragt
ANZ_OHNE_AGENT=0       # laeuft, hat aber keinen Agent konfiguriert
ANZ_NICHT_LAUFEND=0    # gestoppt oder pausiert - wird nie gefragt
ANZ_UEBERSPRUNGEN=0
ANZ_NODES=0

notiere_luecke() {
  case $LUECKEN in
    *"$1 ($2)"*) return ;;   # jede Luecke nur einmal
  esac
  LUECKEN="$LUECKEN  $1 ($2)
"
}

zusammenfassung() {
  hinweis ""
  hinweis "Export-ProxmoxInventar.sh $VERSION"
  # Die Zahlen muessen aufgehen: wer sie liest, sucht sonst die Differenz.
  # Und "0 Gaeste" darf nicht dastehen, wenn gar nicht nachgesehen wurde.
  if [ "$NUR_HOSTS" -eq 1 ]; then
    hinweis "Gaeste nicht gelesen (--nur-hosts)."
  else
    hinweis "Gelesen: $ANZ_GAST Gaeste - $ANZ_VM VMs, $ANZ_LXC LXC."
    if [ "$ANZ_VM" -gt 0 ]; then
      hinweis "  VMs: $ANZ_AGENT mit Agent gefragt, $ANZ_UEBERSPRUNGEN uebersprungen, $ANZ_OHNE_AGENT ohne Agent, $ANZ_NICHT_LAUFEND nicht laufend."
    fi
  fi
  if [ -n "$LUECKEN" ]; then
    hinweis "Leer geblieben:"
    printf '%s' "$LUECKEN" >&2
  else
    hinweis "Keine Luecken."
  fi
  hinweis ""
  [ "$NUR_HOSTS" -eq 1 ] || hinweis "Die Gaeste-Datei gilt fuer den ganzen Cluster - einmal reicht."
  # Den Rat, drei Dateien zusammenzufuegen, gibt es nur, wenn es drei gibt.
  if [ "$NUR_VMS" -eq 0 ]; then
    if [ "$ANZ_NODES" -gt 1 ]; then
      hinweis "Die Host-Datei gibt es je Node einmal; dieser Cluster hat $ANZ_NODES."
      hinweis "Zum Zusammenfuegen: Kopfzeile aus einer Datei, danach je eine Datenzeile."
    elif [ "$ANZ_NODES" -eq 1 ]; then
      hinweis "Einzelnode - die Host-Datei ist damit vollstaendig."
    fi
  fi
}

# --- JSON ohne jq (Spec 6.1) -----------------------------------------------
# jq gibt es auf Proxmox nicht und nachinstallieren faellt aus. Perl mit
# JSON::PP ist auf jedem Node da - die PVE-Werkzeuge sind selbst in Perl.
PERL=${PERL:-perl}

# jrows <pfad>... - JSON von stdin, je Element eine TSV-Zeile.
# Werte werden maskiert, damit ein Umbruch in einer Beschreibung die
# TSV-Struktur nicht sprengt; entmaskiere() dreht das vor dem Schreiben zurueck.
jrows() {
  "$PERL" -MJSON::PP -e '
    # decode_json macht aus den UTF-8-Bytes Zeichen. Ohne diese Schicht
    # schriebe print daraus wieder Latin-1-Einzelbytes, und jeder Umlaut in
    # einem VM-Namen oder einer Beschreibung waere zerstoert.
    binmode(STDOUT, ":utf8");
    local $/;
    my $roh = <STDIN>;
    exit 0 unless defined $roh && length $roh;
    my $d = eval { decode_json($roh) };
    exit 0 unless defined $d;
    my @rows = ref($d) eq "ARRAY" ? @$d : ($d);
    for my $r (@rows) {
      print join("\t", map { hole($r, $_) } @ARGV), "\n";
    }
    sub hole {
      my ($o, $p) = @_;
      for my $k (split /\./, $p) {
        return "" unless ref($o) eq "HASH" && exists $o->{$k};
        $o = $o->{$k};
      }
      return "" unless defined $o;
      if (ref($o) eq "ARRAY") { $o = join(",", map { ref($_) ? "" : $_ } @$o); }
      elsif (ref($o) eq "HASH") { return ""; }
      $o =~ s/\\/\\\\/g; $o =~ s/\t/\\t/g; $o =~ s/\r/\\r/g; $o =~ s/\n/\\n/g;
      return $o;
    }
  ' "$@" 2>/dev/null
}

# entmaskiere <wert> - Gegenstueck zu jrows, direkt vor dem Schreiben
entmaskiere() {
  # In EINEM Durchgang. Nacheinander ginge schief: jrows verdoppelt einen
  # echten Backslash, und ein zweiter Durchgang wuerde in "C:\\temp" das
  # "\t" als Tabulator lesen - aus C:\temp wuerde C:<Tab>emp.
  printf '%s' "$1" | "$PERL" -pe '
    s{\\(.)}{ $1 eq "n" ? "\n" : $1 eq "r" ? "\r" : $1 eq "t" ? "\t" : $1 }ge'
}

# api <pfad> [zusatz...] - DIE Schleuse. Das lesende Verb steht im Rumpf,
# nicht im Parameter (R1, R2). Antwort landet in $TMP_DIR/out.
api() {
  local pfad=$1; shift
  if [ "$SHOW_ONLY" -eq 1 ]; then
    if [ $# -gt 0 ]; then
      zeige_befehl "$PVESH get $pfad $* --output-format json"
    else
      zeige_befehl "$PVESH get $pfad --output-format json"
    fi
    return 0
  fi
  run_limited "$API_TIMEOUT" "$PVESH" get "$pfad" "$@" --output-format json
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    notiere_luecke "$pfad" "Zeitschranke"; return 1
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$TMP_DIR/out" ]; then
    notiere_luecke "$pfad" "keine Antwort"; return 1
  fi
  return 0
}

# --- CSV-Bausteine (Spec 9) ------------------------------------------------
CR=$(printf '\r')

# csv_feld <wert> - quotet nur, wenn noetig
csv_feld() {
  case $1 in
    *';'*|*'"'*|*"$CR"*|*'
'*)
      printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# csv_zeile <feld>... - Felder mit ; verbunden, Zeilenende CRLF
csv_zeile() {
  local erst=1 f
  for f in "$@"; do
    [ "$erst" -eq 0 ] && printf ';'
    erst=0
    csv_feld "$f"
  done
  printf '\r\n'
}

# Kopfzeilen, zeichengleich zur Vorlage der Zielanwendung. BOM \357\273\277, scharfes S
# \303\237 - so bleibt der Skripttext ASCII und die Datei trotzdem UTF-8.
kopf_hosts() {
  printf '\357\273\277'
  printf 'Name;Hersteller;Modell;IP-Adresse;Betriebssystem;'
  printf 'Server Rollen / Installationen;CPU;RAM (GB);HDD (GB);RAID;'
  printf 'Seriennummer;Standort;Inventar Nr.;Notizen;'
  printf 'Supportablauf/Austauschma\303\237nahmen;Kaufdatum\r\n'
}

kopf_vms() {
  printf '\357\273\277'
  printf 'Name;IP-Adresse;Betriebssystem;Server Rollen / Installationen;'
  printf 'CPU (Cores);RAM (GB);HDD (GB);Physischer Server;Notizen\r\n'
}

# node_name - der Node, auf dem das Skript laeuft. HOSTNAME_OVERRIDE nur
# fuer den Test, damit er nicht vom Rechnernamen abhaengt.
node_name() {
  printf '%s' "${HOSTNAME_OVERRIDE:-$(hostname -s)}"
}

# --- Die Host-Zeile (Spec 7) -----------------------------------------------

# dmi <keyword> - der zweite und letzte externe Lesebefehl (R1)
dmi() {
  if [ "$SHOW_ONLY" -eq 1 ]; then
    zeige_befehl "$DMIDECODE -s $1"
    return 0
  fi
  run_limited "$API_TIMEOUT" "$DMIDECODE" -s "$1" || return 0
  tr -d '\r\n' < "$TMP_DIR/out"
}

# gb <bytes> - auf ganze GB, leer bei leerer Eingabe
gb() {
  [ -n "${1:-}" ] || { printf ''; return; }
  printf '%s' "$(( $1 / 1073741824 ))"
}

# zfs_level - liest den RAID-Level aus der Pool-Antwort auf stdin.
# Es gibt dort KEIN Feld "type": Proxmox parst die Ausgabe von `zpool status`,
# und der Level steht nur als Praefix im Namen eines Kindknotens
# ("mirror-0", "raidz1-0", "draid2-0"). Ein Pool ohne solchen Knoten ist ein
# Stripe aus einzelnen Platten.
zfs_level() {
  "$PERL" -MJSON::PP -e '
    local $/; my $d = eval { decode_json(<STDIN>) } or exit 0;
    my $k = $d->{children} || [];
    for my $c (@$k) {
      my $n = $c->{name} || "";
      if ($n =~ /^(mirror|raidz[123]?|draid[123]?)/) { print $1; exit }
    }
    print "stripe" if @$k;
  ' 2>/dev/null
}

schreibe_host() {
  local ziel=$1 node cpu ram hdd raid ip os rollen notizen platten
  node=$(node_name)
  abschnitt "Node $node"
  schritt "Status"

  # cpuinfo.model enthaelt Leerzeichen - Wortzerlegung ueber `set --` oder
  # `read a b c` zerreisst es. Feldweise mit `cut -f` lesen.
  local zeile modell sockel threads bytes kernel pve
  api "/nodes/$node/status"
  zeile=$(jrows cpuinfo.model cpuinfo.sockets cpuinfo.cpus memory.total \
                kversion pveversion current-kernel.release cpuinfo.cores \
                < "$TMP_DIR/out" | head -1)
  modell=$(printf '%s' "$zeile" | cut -f1)
  sockel=$(printf '%s' "$zeile" | cut -f2)
  threads=$(printf '%s' "$zeile" | cut -f3)
  bytes=$(printf '%s' "$zeile" | cut -f4)
  kernel=$(printf '%s' "$zeile" | cut -f5)
  pve=$(printf '%s' "$zeile" | cut -f6)
  # kversion ist im Quelltext als "for legacy compat" markiert; dokumentiert
  # ist current-kernel.release. Erst das Dokumentierte, dann das Alte.
  local kernel_neu; kernel_neu=$(printf '%s' "$zeile" | cut -f7)
  [ -n "$kernel_neu" ] && kernel="$kernel_neu"

  # cpuinfo.cores ist die Kernzahl JE SOCKEL - auf dem Testnode meldet die
  # API cores=6 sockets=1 fuer eine 6-Kern-CPU, genau wie "cpu cores" in
  # /proc/cpuinfo. Ohne die Kerne liesse sich 32C/64T nicht von 64C/64T
  # unterscheiden.
  local kerne; kerne=$(printf '%s' "$zeile" | cut -f8)
  cpu=""
  if [ -n "$modell" ]; then
    cpu="${sockel}x $modell"
    if [ -n "$kerne" ]; then
      if [ "${sockel:-1}" -gt 1 ] 2>/dev/null; then
        cpu="$cpu, $kerne Kerne je Sockel"
      else
        cpu="$cpu, $kerne Kerne"
      fi
    fi
    [ -n "$threads" ] && cpu="$cpu, $threads Threads"
  fi
  [ -n "$modell" ]  || notiere_luecke "/nodes/$node/status" "Feld cpuinfo.model fehlt"
  [ -n "$threads" ] || notiere_luecke "/nodes/$node/status" "Feld cpuinfo.cpus fehlt"
  [ -n "$bytes" ]   || notiere_luecke "/nodes/$node/status" "Feld memory.total fehlt"
  ram=$(gb "$bytes")
  os=""
  # pveversion ist "pve-manager/9.2.5/<buildhash>" - der Hash gehoert nicht in
  # eine Ausgabespalte.
  if [ -n "$pve" ]; then
    local pvenr=${pve#pve-manager/}
    pvenr=${pvenr%%/*}
    os="Proxmox VE $pvenr (Kernel $kernel)"
  fi

  schritt "Netzwerk"
  api "/nodes/$node/network"
  # active wird nur bei aktiven Schnittstellen gesetzt; eine abgeschaltete
  # Bruecke mit alter Adresse stuende sonst in der Doku als erreichbar.
  ip=$(jrows iface type address active < "$TMP_DIR/out" \
       | awk -F'\t' '$2=="bridge" && $3!="" && $4=="1" {print $3; exit}')
  [ -n "$ip" ] || notiere_luecke "/nodes/$node/network" "keine Bruecke mit Adresse"

  schritt "Datentraeger"
  # --skipsmart: die Vorgabe fragt SMART ab und kann Platten im Standby
  # aufwecken. Ein Werkzeug, das nur liest, hat dafuer keinen Grund.
  api "/nodes/$node/disks/list" --skipsmart 1
  hdd=$(jrows size < "$TMP_DIR/out" \
        | awk '{s+=$1} END {if (s>0) printf "%d", s/1073741824}')
  [ -n "$hdd" ] || notiere_luecke "/nodes/$node/disks/list" "keine Groessen lesbar"
  platten=$(jrows model serial size < "$TMP_DIR/out" \
            | awk -F'\t' '$1!="" {printf "%s (SN %s, %d GB); ", $1, $2, $3/1073741824}')

  raid=""
  schritt "ZFS"
  api "/nodes/$node/disks/zfs"
  local pool; pool=$(jrows name < "$TMP_DIR/out" | head -1)
  if [ -n "$pool" ]; then
    api "/nodes/$node/disks/zfs/$pool"
    local level; level=$(zfs_level < "$TMP_DIR/out")
    [ -n "$level" ] && raid="ZFS $level ($pool)"
    [ -n "$level" ] || notiere_luecke "/nodes/$node/disks/zfs/$pool" "RAID-Level nicht erkannt"
  fi

  schritt "Cluster"
  # Was nicht gelesen wurde, wird auch nicht behauptet: eine unlesbare Abfrage
  # machte aus einem Cluster sonst einen "Einzelnode, 0 VMs, 0 LXC". Die Luecke
  # steht dank api() ohnehin im Bericht.
  local cluster_gelesen=1 gaeste_gelesen=1
  api "/cluster/status" || cluster_gelesen=0
  local cluster; cluster=$(jrows name type < "$TMP_DIR/out" \
                           | awk -F'\t' '$2=="cluster" {print $1; exit}')
  ANZ_NODES=$(jrows type < "$TMP_DIR/out" | awk '$1=="node"' | wc -l | tr -d ' ')

  local anzahl_vm anzahl_lxc
  api "/cluster/resources" --type vm || gaeste_gelesen=0
  anzahl_vm=$(jrows node type < "$TMP_DIR/out" \
              | awk -F'\t' -v n="$node" '$1==n && $2=="qemu"' | wc -l | tr -d ' ')
  anzahl_lxc=$(jrows node type < "$TMP_DIR/out" \
               | awk -F'\t' -v n="$node" '$1==n && $2=="lxc"' | wc -l | tr -d ' ')
  # Ein Einzelnode hat keinen Eintrag mit type=cluster - dann stuende dort
  # "Cluster ," mit leerem Namen.
  rollen="Hypervisor"
  if [ "$cluster_gelesen" -eq 1 ]; then
    if [ -n "$cluster" ]; then rollen="$rollen, Cluster $cluster"; else rollen="$rollen, Einzelnode"; fi
  fi
  [ "$gaeste_gelesen" -eq 1 ] && rollen="$rollen, $anzahl_vm VMs, $anzahl_lxc LXC"

  notizen="Platten: ${platten%; }"
  # Kein ZFS heisst nicht zwingend Hardware-RAID - die alte Formulierung
  # behauptete einen Controller, den es auf einem Einzelnode selten gibt.
  [ -z "$raid" ] && notizen="$notizen | RAID nicht auslesbar (kein ZFS-Pool; ein Hardware-Controller waere ueber die API ohnehin unsichtbar)"

  schritt "Hardware (DMI)"
  local hersteller modell_dmi serie
  hersteller=$(dmi system-manufacturer)
  modell_dmi=$(dmi system-product-name)
  serie=$(dmi system-serial-number)
  # dmidecode fuehrt kein Proxmox-Paket als Abhaengigkeit - fehlt es, bleiben
  # die drei Spalten leer, und die Zusammenfassung sagt warum.
  [ -n "$hersteller$modell_dmi$serie" ] \
    || notiere_luecke "dmidecode" "nicht vorhanden oder nichts gelesen"

  { kopf_hosts
    csv_zeile "$node" "$hersteller" "$modell_dmi" \
              "$ip" "$os" "$rollen" "$cpu" "$ram" "$hdd" "$raid" \
              "$serie" "" "" "$notizen" "" ""
  } > "$ziel"
  fortschritt_ende
}

# --- Guest-Agent (Spec 4, R4) ----------------------------------------------
AGENT_TOT=0

# agent_frage <node> <vmid> <kommando>
# Genau ein Versuch, nur lesend. Scheitert er, bleibt das Feld leer - es gibt
# keinen Rueckfall auf eine andere Methode (R4). Nach einer Zeitschranke wird
# derselbe Gast nicht noch einmal gefragt: ein toter Agent kostet einmal die
# Schranke, nicht dreimal.
agent_frage() {
  [ "$AGENT_TOT" -eq 1 ] && return 1
  local pfad="/nodes/$1/qemu/$2/agent/$3"
  if [ "$SHOW_ONLY" -eq 1 ]; then
    zeige_befehl "$PVESH get $pfad --output-format json"
    return 1
  fi
  run_limited "$AGENT_TIMEOUT" "$PVESH" get "$pfad" --output-format json
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    AGENT_TOT=1
    hinweis "  Agent von $2 antwortet nicht (Zeitschranke), weitere Fragen entfallen"
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1
  [ -s "$TMP_DIR/out" ] || return 1
  return 0
}

# agent_an <wert> - ist der Guest-Agent eingeschaltet?
# `agent` ist ein Property-String mit `enabled` als default_key. Der Wert kann
# darum "1", "0", "enabled=1,fstrim_cloned_disks=1" oder "1,freeze-fs=0" sein.
# Ein Vergleich auf "1" allein uebersaehe jede VM mit Zusatzoptionen.
agent_an() {
  case ",${1:-},"  in
    *",enabled=0,"*) return 1 ;;
    *",enabled=1,"*) return 0 ;;
  esac
  case ${1:-} in
    1|1,*) return 0 ;;
  esac
  return 1
}

# Schnittstellen, die nichts ueber die Erreichbarkeit im Netz sagen: Docker-
# Bruecken, veth-Paare, VPN-Tunnel. Auf einem Container mit Docker stehen sonst
# fuenf Adressen in der Spalte und die brauchbare geht darin unter.
# Ein Muster, von awk und von perl benutzt, damit es nicht auseinanderlaeuft.
export NIC_AUS
NIC_AUS='^(lo|docker|br-|veth|virbr|vmbr|tun|tap|wg|tailscale|zt|cni|flannel|kube|nomad|podman|cali|nerdctl)'

# --- Gaeste: VMs und LXC (Spec 8) ------------------------------------------

# ostype_lesbar <ostype> - grob, und genau deshalb gekennzeichnet
ostype_lesbar() {
  case $1 in
    win11)  printf 'Windows 11 / Server 2022' ;;
    wvista) printf 'Windows Vista / Server 2008' ;;
    w2k8)   printf 'Windows Server 2008' ;;
    w2k3)   printf 'Windows Server 2003' ;;
    w2k)    printf 'Windows 2000' ;;
    wxp)    printf 'Windows XP' ;;
    solaris) printf 'Solaris / OpenIndiana' ;;
    win10)  printf 'Windows 10 / Server 2016-2019' ;;
    win8)   printf 'Windows 8 / Server 2012' ;;
    win7)   printf 'Windows 7 / Server 2008 R2' ;;
    l26)    printf 'Linux (Kernel 2.6+)' ;;
    l24)    printf 'Linux (Kernel 2.4)' ;;
    "")     printf '' ;;
    other)  printf 'Unbekannt' ;;
    # LXC traegt den Namen der Vorlage, etwa debian oder alpine
    *)      printf 'Linux (%s)' "$1" ;;
  esac
}

# disk_summe <config-datei> - GB ueber alle Plattenzeilen, CD-Laufwerke aus
disk_summe() {
  "$PERL" -MJSON::PP -e '
    local $/; my $roh = <STDIN>;
    my $d = eval { decode_json($roh) }; exit 0 unless ref $d eq "HASH";
    my $g = 0;
    for my $k (keys %$d) {
      next unless $k =~ /^(scsi|virtio|sata|ide|rootfs|mp)\d*$/;
      next if ref $d->{$k};
      next if $d->{$k} =~ /media=cdrom/;
      if ($d->{$k} =~ /(?:^|,)size=(\d+(?:\.\d+)?)([KMGT])/) {
        my ($n, $e) = ($1, $2);
        my %f = (K => 1/1048576, M => 1/1024, G => 1, T => 1024);
        $g += $n * $f{$e};
      }
    }
    printf("%d", $g + 0.5) if $g > 0;
  ' < "$1" 2>/dev/null
}

schreibe_vms() {
  local ziel=$1 liste TAB
  if [ "$SHOW_ONLY" -eq 1 ]; then
    # Die Gaesteliste ist ohne Abfrage unbekannt. Also die Schleife einmal
    # mit Platzhaltern zeigen, statt 43 gleiche Zeilen zu drucken.
    api "/cluster/resources" --type vm
    zeige_befehl "$PVESH get /nodes/<node>/<qemu|lxc>/<vmid>/config --output-format json     [je Gast]"
    zeige_befehl "$PVESH get /nodes/<node>/lxc/<vmid>/interfaces --output-format json        [je laufendem LXC]"
    if [ "$OHNE_AGENT" -eq 0 ]; then
      zeige_befehl "$PVESH get /nodes/<node>/qemu/<vmid>/agent/network-get-interfaces --output-format json   [je laufender VM mit Agent]"
      zeige_befehl "$PVESH get /nodes/<node>/qemu/<vmid>/agent/get-osinfo --output-format json"
      zeige_befehl "$PVESH get /nodes/<node>/qemu/<vmid>/agent/get-host-name --output-format json"
    fi
    return 0
  fi
  TAB=$(printf '\t')
  liste="$TMP_DIR/gaeste.tsv"

  api "/cluster/resources" --type vm
  jrows vmid type node name status < "$TMP_DIR/out" | sort -t"$TAB" -k1,1n > "$liste"

  kopf_vms > "$ziel"

  local gesamt nr=0
  gesamt=$(wc -l < "$liste" | tr -d ' ')
  abschnitt "Gaeste ($gesamt)"

  # Aus einer Datei lesen, nicht aus einer Pipe: hinter einer Pipe laeuft
  # `while` in Bash 3.2 in einer Subshell und verliert nr.
  # Zeile als Ganzes lesen und mit `cut -f` zerlegen. NICHT ueber IFS
  # trennen: Bash zaehlt Tab zu den IFS-Whitespace-Zeichen, zwei davon
  # hintereinander gelten als ein Trenner - ein leerer Name wuerde jede
  # folgende Spalte verschieben.
  local z vmid typ node name status
  while IFS= read -r z; do
    [ -n "$z" ] || continue
    vmid=$(printf '%s' "$z" | cut -f1)
    typ=$(printf '%s' "$z" | cut -f2)
    node=$(printf '%s' "$z" | cut -f3)
    name=$(printf '%s' "$z" | cut -f4)
    status=$(printf '%s' "$z" | cut -f5)
    [ -n "$vmid" ] || continue
    nr=$((nr + 1))
    ANZ_GAST=$((ANZ_GAST + 1))
    if [ "$typ" = "lxc" ]; then ANZ_LXC=$((ANZ_LXC + 1)); else ANZ_VM=$((ANZ_VM + 1)); fi
    [ -n "$name" ] || name="VM$vmid"
    fortschritt "$nr" "$gesamt" "$typ $vmid $name"

    api "/nodes/$node/$typ/$vmid/config"
    cp "$TMP_DIR/out" "$TMP_DIR/config.json" 2>/dev/null || : > "$TMP_DIR/config.json"

    local c cores sockets mem ostype agent tags desc
    c=$(jrows cores sockets memory ostype agent tags description \
        < "$TMP_DIR/config.json" | head -1)
    cores=$(printf '%s' "$c" | cut -f1)
    sockets=$(printf '%s' "$c" | cut -f2)
    mem=$(printf '%s' "$c" | cut -f3)
    ostype=$(printf '%s' "$c" | cut -f4)
    agent=$(printf '%s' "$c" | cut -f5)
    tags=$(printf '%s' "$c" | cut -f6)
    desc=$(printf '%s' "$c" | cut -f7)

    local cpu="" ram="" hdd
    [ -n "$cores" ] && cpu=$(( cores * ${sockets:-1} ))
    # aufrunden: 512 MB sind nicht 0 GB
    [ -n "$mem" ] && ram=$(( (mem + 1023) / 1024 ))
    hdd=$(disk_summe "$TMP_DIR/config.json")

    # Rollen: Tags und erste Zeile der Beschreibung. Mehr weiss Proxmox nicht.
    local erste_zeile rollen
    # Nur an einem ECHTEN Umbruch schneiden: in der maskierten Fassung steckt in
    # "C:\\new" ebenfalls ein "\\n". Eine gerade Zahl Backslashes davor heisst
    # "das n gehoert zum Text". \\r faellt mit weg, sonst bliebe bei CRLF ein
    # nacktes Wagenruecklauf-Zeichen im Feld stehen.
    erste_zeile=$(printf '%s' "$desc" | "$PERL" -pe 's/^((?:[^\\]|\\\\)*)\\[nr].*/$1/s')
    rollen=$(printf '%s' "$tags" | tr ';' ',')
    if [ -n "$rollen" ] && [ -n "$erste_zeile" ]; then
      rollen="$rollen - $erste_zeile"
    elif [ -z "$rollen" ]; then
      rollen="$erste_zeile"
    fi

    local ip="" os
    os=$(ostype_lesbar "$ostype")
    [ -n "$os" ] && os="$os (aus Config)"

    if [ "$typ" = "lxc" ] && [ "$status" = "running" ]; then
      api "/nodes/$node/lxc/$vmid/interfaces"
      ip=$(jrows name inet < "$TMP_DIR/out" \
           | awk -F'\t' -v aus="$NIC_AUS" \
               '$2!="" && $1 !~ aus {sub(/\/.*/,"",$2); printf "%s%s", (n++?", ":""), $2}')
    fi

    # Der Agent, wenn es ihn gibt. AGENT_TOT steht hier und nicht ausserhalb
    # der Schleife: die Sperre gilt je Gast, ein toter Agent in einer VM darf
    # der naechsten die Abfrage nicht nehmen.
    AGENT_TOT=0
    local notiz_extra=""
    if [ "$OHNE_AGENT" -eq 0 ] && [ "$typ" = "qemu" ] \
       && [ "$status" = "running" ] && agent_an "$agent"; then

      if agent_frage "$node" "$vmid" "network-get-interfaces"; then
        ip=$("$PERL" -MJSON::PP -e '
          binmode(STDOUT, ":utf8");
          local $/; my $d = eval { decode_json(<STDIN>) } or exit 0;
          my @a;
          my $aus = $ENV{NIC_AUS};
          for my $i (@{ $d->{result} || [] }) {
            my $n = $i->{name} || "";
            next if $aus && $n =~ /$aus/;
            for my $x (@{ $i->{"ip-addresses"} || [] }) {
              next unless ($x->{"ip-address-type"} || "") eq "ipv4";
              my $ip = $x->{"ip-address"};
              next if $ip =~ /^127\./;
              push @a, $ip;
            }
          }
          print join(", ", @a);
        ' < "$TMP_DIR/out" 2>/dev/null)
      fi

      if agent_frage "$node" "$vmid" "get-osinfo"; then
        local pn; pn=$(jrows result.pretty-name < "$TMP_DIR/out" | head -1)
        [ -n "$pn" ] && os="$pn"
      fi

      if agent_frage "$node" "$vmid" "get-host-name"; then
        local hn; hn=$(jrows result.host-name < "$TMP_DIR/out" | head -1)
        if [ -n "$hn" ] && [ "$hn" != "$name" ]; then
          notiz_extra="Gast-Hostname $hn"
        fi
      fi
    fi

    # Jede VM landet in genau einem Topf, damit die Summe stimmt.
    if [ "$typ" = "qemu" ]; then
      if [ "$status" != "running" ]; then
        ANZ_NICHT_LAUFEND=$((ANZ_NICHT_LAUFEND + 1))
      elif ! agent_an "$agent"; then
        ANZ_OHNE_AGENT=$((ANZ_OHNE_AGENT + 1))
      elif [ "$OHNE_AGENT" -eq 1 ]; then
        ANZ_UEBERSPRUNGEN=$((ANZ_UEBERSPRUNGEN + 1))
      else
        ANZ_AGENT=$((ANZ_AGENT + 1))
      fi
    fi

    local art notiz speicher
    if [ "$typ" = "lxc" ]; then art="LXC-Container"; else art="KVM-VM"; fi
    notiz="$art, VMID $vmid, $status"
    if [ "$typ" = "qemu" ]; then
      if agent_an "$agent"; then notiz="$notiz, Agent ja"
      else notiz="$notiz, Agent nein"; fi
    fi
    # Eine VM kann an virtio0, sata0 oder ide0 haengen statt an scsi0 - ohne die
    # bekaeme sie gar keine Speicher-Notiz.
    speicher=$(jrows scsi0 virtio0 sata0 ide0 rootfs < "$TMP_DIR/config.json" | head -1 \
               | tr '\t' '\n' | grep -v '^$' | head -1 | cut -d: -f1)
    [ -n "$speicher" ] && notiz="$notiz, Speicher $speicher"
    [ -n "$notiz_extra" ] && notiz="$notiz, $notiz_extra"

    csv_zeile "$name" "$ip" "$os" "$(entmaskiere "$rollen")" \
              "$cpu" "$ram" "$hdd" "$node" "$notiz" >> "$ziel"
  done < "$liste"
  fortschritt_ende
}

# lege_ab <quelle> <ziel> - die Datei entsteht im Temp-Verzeichnis und wird
# erst am Ende an ihren Platz verschoben (R11). Ein Abbruch mittendrin laesst
# darum nie eine halbe CSV zurueck.
lege_ab() {
  [ -e "$2" ] && die "$2 gibt es schon. Das Werkzeug ueberschreibt nichts - erst wegraeumen."
  # Liegt das Ziel auf einem anderen Dateisystem (--ziel /mnt/pve/...), ist mv
  # Kopieren plus Loeschen. Ein Strg-C genau in diesem Fenster laesst eine halbe
  # CSV liegen, waehrend abbruch() "Es wurde nichts geschrieben" meldet.
  trap '' INT TERM
  mv "$1" "$2" || die "konnte $2 nicht ablegen"
  trap abbruch INT TERM
  printf 'geschrieben: %s\n' "$2"
}

# --- Vorflug-Kontrolle (Spec 5.2) ------------------------------------------
# Jeden Pfad einmal, hoechstens ein Gast, nichts geschrieben. Beantwortet die
# drei Annahmen aus Spec 12, bevor eine Datei entsteht.
pruefbericht() {
  local node; node=$(node_name)

  melde() { printf '%-50s %-6s %s\n' "$1" "$2" "$3"; }

  pruefe_pfad() {
    # Erstes Wort ist der Pfad, der Rest sind Zusatzargumente fuer pvesh.
    # $zusatz bleibt absichtlich ungequotet - es soll in Worte zerfallen.
    local roh=$1; shift
    local pfad=${roh%% *} zusatz=""
    [ "$pfad" != "$roh" ] && zusatz=${roh#* }
    if ! api "$pfad" $zusatz; then melde "$roh" "FEHLT" "keine Antwort"; return; fi
    # Eine gueltige, aber leere Antwort ist kein Fehler: ein Node ohne
    # ZFS-Pool liefert hier zu Recht nichts.
    local zeilen; zeilen=$(jrows "$1" < "$TMP_DIR/out" | wc -l | tr -d ' ')
    if [ "$zeilen" -eq 0 ]; then
      # Leer und unlesbar sind zweierlei: das eine ist in Ordnung, das andere
      # nicht. Ohne die Unterscheidung verschwaende eine kaputte Antwort als
      # harmloses "leer".
      if "$PERL" -MJSON::PP -e 'local $/; decode_json(<STDIN>)' \
         < "$TMP_DIR/out" 2>/dev/null; then
        melde "$roh" "leer" "keine Eintraege - kein Fehler, nur nichts vorhanden"
      else
        melde "$roh" "FEHLT" "Antwort nicht lesbar"
      fi
      return
    fi
    local fehlend="" f
    for f in "$@"; do
      # nicht nur die erste Zeile: das erste Element von /network ist lo
      # und traegt keine Adresse - das waere ein Fehlalarm
      [ -n "$(jrows "$f" < "$TMP_DIR/out" | grep -v '^$' | head -1)" ] \
        || fehlend="$fehlend $f"
    done
    if [ -n "$fehlend" ]; then melde "$roh" "FEHLT" "Felder:$fehlend"
    else melde "$roh" "ok" "$*"; fi
  }

  printf 'Vorflug-Kontrolle. Es wird nichts geschrieben.\n\n'
  pruefe_pfad "/cluster/status" name type
  pruefe_pfad "/cluster/resources" vmid type node name status
  pruefe_pfad "/nodes/$node/status" cpuinfo.model cpuinfo.cpus memory.total kversion pveversion
  pruefe_pfad "/nodes/$node/network" iface address active
  pruefe_pfad "/nodes/$node/disks/list --skipsmart 1" size model serial
  pruefe_pfad "/nodes/$node/disks/zfs" name

  # genau ein Gast: der erste laufende qemu mit Agent
  local erst vid nod
  api "/cluster/resources" --type vm
  erst=$(jrows vmid type node status < "$TMP_DIR/out" \
         | awk -F'\t' '$2=="qemu" && $4=="running" {print $1"\t"$3; exit}')
  if [ -n "$erst" ]; then
    vid=$(printf '%s' "$erst" | cut -f1)
    nod=$(printf '%s' "$erst" | cut -f2)
    pruefe_pfad "/nodes/$nod/qemu/$vid/config" cores memory ostype
    if agent_frage "$nod" "$vid" "get-osinfo"; then
      melde "/nodes/$nod/qemu/$vid/agent/get-osinfo" "ok" "lesend erlaubt, Agent antwortet"
    else
      melde "/nodes/$nod/qemu/$vid/agent/get-osinfo" "FEHLT" "nicht lesbar oder Agent stumm"
    fi
  fi

  printf '\nNichts geschrieben. Naechster Schritt: --nur-hosts --ohne-agent\n'
}

hilfe() {
  cat <<'ENDE'
Export-ProxmoxInventar.sh - liest den Proxmox-Cluster aus, schreibt zwei CSVs.

  --zeige-befehle    zeigt jeden Befehl, fuehrt keinen aus, schreibt nichts
  --pruefen          fragt jeden Pfad einmal ab, berichtet, schreibt nichts
  --ziel <verz>      Ausgabeverzeichnis, Vorgabe .
  --nur-hosts        nur die Host-Datei
  --nur-vms          nur die Gaeste-Datei
  --ohne-agent       den Guest-Agent gar nicht fragen
  --fortschritt <w>  auto (Vorgabe), immer oder nie - Balken am Terminal
  --timeout <n>      Zeitschranke je Aufruf in Sekunden, Vorgabe 5
  --version          Versionsnummer
  --hilfe            diese Uebersicht

Das Skript liest ausschliesslich. Es setzt nur zwei Befehle ab - die
Proxmox-API lesend und die DMI-Abfrage - und schreibt nur in das
Zielverzeichnis.
ENDE
}

main() {
  selftest_source "$0" || exit 1

  while [ $# -gt 0 ]; do
    case $1 in
      --zeige-befehle) SHOW_ONLY=1 ;;
      --pruefen)       CHECK_ONLY=1 ;;
      --ziel)          shift; OUT_DIR=${1:-} ;;
      --nur-hosts)     NUR_HOSTS=1 ;;
      --nur-vms)       NUR_VMS=1 ;;
      --ohne-agent)    OHNE_AGENT=1 ;;
      --fortschritt)   shift; FORTSCHRITT=${1:-auto} ;;
      --timeout)
        shift
        # Ungeprueft scheitert erst sleep im Waechter: dann laeuft jede Abfrage in
        # die Zeitschranke und es entstuenden zwei CSVs voller leerer Felder.
        case ${1:-} in
          ''|*[!0-9]*|0) die "--timeout braucht eine ganze Zahl groesser 0, bekommen: '${1:-}'" ;;
        esac
        API_TIMEOUT=$1; AGENT_TIMEOUT=$API_TIMEOUT
        ;;
      --hilfe|-h)      hilfe; exit 0 ;;
      # vor der PVE-Pruefung: die Version muss auch auf dem Mac abfragbar sein
      --version)       printf 'Export-ProxmoxInventar.sh %s\n' "$VERSION"; exit 0 ;;
      --selbsttest-zeitwaechter)
        # nur fuer den Test: ein Befehl, der laenger laeuft als die Schranke
        TMP_DIR=$(mktemp -d) || die "kein Temp-Verzeichnis"
        trap aufraeumen EXIT
        run_limited 1 sleep 5
        exit $?
        ;;
      *) die "Unbekannter Schalter: $1" ;;
    esac
    shift
  done

  # Zusammen schliessen sich die beiden aus: es entstuende keine Datei, ohne
  # dass jemand einen Grund zu sehen bekaeme.
  if [ "$NUR_HOSTS" -eq 1 ] && [ "$NUR_VMS" -eq 1 ]; then
    die "--nur-hosts und --nur-vms zusammen ergeben keine Datei. Eines von beiden waehlen oder keines."
  fi

  [ -d "$PVE_DIR" ] || die "kein Proxmox-Node - $PVE_DIR fehlt. Das Skript gehoert auf einen PVE-Node."

  # pvesh und dmidecode lesen nur mit root-Rechten. Ohne sie entstuenden zwei
  # fast leere CSV-Dateien statt einer klaren Ansage. --zeige-befehle braucht
  # nichts davon und laeuft weiter als normaler Benutzer.
  if [ "$SHOW_ONLY" -eq 0 ] && [ "$PVE_DIR" = "/etc/pve" ] && [ "$(id -u)" -ne 0 ]; then
    die "root-Rechte noetig: pvesh und dmidecode lesen sonst nichts. Mit sudo aufrufen, etwa: sudo $0 --pruefen"
  fi
  [ -d "$OUT_DIR" ] || die "Zielverzeichnis gibt es nicht: $OUT_DIR"

  TMP_DIR=$(mktemp -d) || die "kein Temp-Verzeichnis"
  trap aufraeumen EXIT
  trap abbruch INT TERM
  # Im Trockenlauf setzt api() keinen Befehl ab und legt darum auch keine
  # Antwortdatei an. Ohne diese hier liefe jedes jrows in einen Lesefehler.
  : > "$TMP_DIR/out"
  : > "$TMP_DIR/err"

  # Vorhandene Zieldateien VOR dem Lauf pruefen: vierzig Gaeste lesen und
  # dann abbrechen waere unhoeflich (R10).
  ZIEL_HOST="$OUT_DIR/proxmox-host-$(node_name).csv"
  ZIEL_VMS="$OUT_DIR/proxmox-vms.csv"
  if [ "$SHOW_ONLY" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
    if [ "$NUR_VMS" -eq 0 ] && [ -e "$ZIEL_HOST" ]; then
      die "$ZIEL_HOST gibt es schon. Das Werkzeug ueberschreibt nichts - erst wegraeumen."
    fi
    if [ "$NUR_HOSTS" -eq 0 ] && [ -e "$ZIEL_VMS" ]; then
      die "$ZIEL_VMS gibt es schon. Das Werkzeug ueberschreibt nichts - erst wegraeumen."
    fi
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then pruefbericht; exit 0; fi

  if [ "$SHOW_ONLY" -eq 1 ]; then
    # Dieselben Wege gehen, aber ins Leere schreiben - eine Stelle statt zehn.
    [ "$NUR_VMS" -eq 1 ]   || schreibe_host /dev/null
    [ "$NUR_HOSTS" -eq 1 ] || schreibe_vms  /dev/null
    exit 0
  fi

  if [ "$NUR_VMS" -eq 0 ]; then
    schreibe_host "$TMP_DIR/host.csv"
    lege_ab "$TMP_DIR/host.csv" "$ZIEL_HOST"
  fi
  if [ "$NUR_HOSTS" -eq 0 ]; then
    schreibe_vms "$TMP_DIR/vms.csv"
    lege_ab "$TMP_DIR/vms.csv" "$ZIEL_VMS"
  fi

  zusammenfassung
}

# Nur ausfuehren, wenn direkt aufgerufen - der Test laedt die Funktionen
# einzeln per `source` und darf dabei nicht den ganzen Lauf ausloesen.
# NICHT am Dateinamen festmachen: wer die Datei umbenennt, bekaeme sonst ein
# Skript, das stillschweigend nichts tut. Beim Sourcen zeigt BASH_SOURCE auf
# die geladene Datei, $0 auf den Aufrufer.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
