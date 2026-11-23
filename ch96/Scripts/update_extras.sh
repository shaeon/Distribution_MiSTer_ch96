#!/bin/bash
# update_extras.sh — BIOS y ROMs de arcade SOLO para los cores instalados.
#
# Chameleon96 (Distribution_MiSTer_ch96). No usa update_all (instalaría la
# distribución de la DE10 y dejaría la placa sin arrancar): reutiliza el
# Downloader oficial (Scripts/update.sh) con las mismas bases de datos que
# usa update_all en "Extra Content":
#
#   bios_db        https://github.com/ajgowans/BiosDB_MiSTer
#   arcade_roms_db https://github.com/zakk4223/ArcadeROMsDB_MiSTer
#
# 1. Mira los .rbf de _Computer/_Console/_Other/_Utility y _Arcade/cores.
# 2. Saca el nombre de cada core (sin fecha), normalizado como los tags del
#    Downloader (minúsculas, sin guiones ni barras bajas).
# 3. Escribe un ini propio con un "filter =" por base de datos y lanza el
#    Downloader con DOWNLOADER_INI_PATH. El filtro hace que solo se bajen los
#    ficheros etiquetados con esos cores: nada de cores, Linux ni DE10.
# 4. Al final comprueba los .mra instalados y avisa de las ROM que falten.
#
# Uso: Scripts -> update_extras  (o por SSH: bash /media/fat/Scripts/update_extras.sh)

set -u

BASE="/media/fat"
CONF="$BASE/Scripts/.config/update_extras"
INI="$CONF/downloader.ini"
LOG="$CONF/update_extras.log"

BIOS_DB_URL='https://raw.githubusercontent.com/ajgowans/BiosDB_MiSTer/db/bios_db.json'
ARCADE_DB_URL='https://raw.githubusercontent.com/zakk4223/ArcadeROMsDB_MiSTer/db/arcade_roms_db.json.zip'

if [ ! -f "$BASE/Scripts/update.sh" ]; then
    echo "ERROR: no está Scripts/update.sh; ejecuta antes la actualización normal."
    exit 1
fi

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

# Nombre del core a partir del .rbf: fuera la fecha (y el _ch96 si lo hubiera).
core_name() {
    local n
    n=$(basename "$1"); n=${n%.*}
    n=$(printf '%s' "$n" | sed -E 's/_[0-9]{8}(_ch96)?$//; s/_ch96_[0-9]{8}$//; s/_ch96$//')
    norm "$n"
}

# Alias: nombre del core en la ch96 -> etiqueta(s) en bios_db.
# Añadir aquí los que hagan falta al publicar cores nuevos.
# Ojo: "Lynx" en la ch96 es el Camputers Lynx, no el Atari Lynx (el core de
# Atari se llama AtariLynx y ya coincide con la etiqueta atarilynx sin alias).
aliases() {
    case "$1" in
        turbografx16|pcengine) echo turbografx16cd pcenginecd ;;
        neogeo)                echo neogeocd ;;
        msx)                   echo msx1 ;;
        wonderswan)            echo wonderswancolor pocketchallengev2 ;;
    esac
}

bios_terms="" arcade_terms=""

for dir in _Computer _Console _Other _Utility; do
    [ -d "$BASE/$dir" ] || continue
    while IFS= read -r -d '' rbf; do
        c=$(core_name "$rbf"); [ -n "$c" ] || continue
        bios_terms="$bios_terms $c $(aliases "$c")"
    done < <(find "$BASE/$dir" -maxdepth 1 -iname '*.rbf' -print0)
done

if [ -d "$BASE/_Arcade/cores" ]; then
    while IFS= read -r -d '' rbf; do
        c=$(core_name "$rbf"); [ -n "$c" ] || continue
        arcade_terms="$arcade_terms arcade$c"
    done < <(find "$BASE/_Arcade/cores" -maxdepth 1 -iname '*.rbf' -print0)
fi

bios_terms=$(printf '%s\n' $bios_terms | sort -u | grep -v '^$' | tr '\n' ' ')
arcade_terms=$(printf '%s\n' $arcade_terms | sort -u | grep -v '^$' | tr '\n' ' ')

if [ -z "${bios_terms// /}" ] && [ -z "${arcade_terms// /}" ]; then
    echo "No hay cores instalados; ejecuta antes Scripts/update."
    exit 0
fi

mkdir -p "$CONF"
{
    echo '; Generado por update_extras.sh — no editar a mano.'
    if [ -n "${bios_terms// /}" ]; then
        echo '[bios_db]'
        echo "db_url = $BIOS_DB_URL"
        echo "filter = $bios_terms"
        echo
    fi
    if [ -n "${arcade_terms// /}" ]; then
        echo '[arcade_roms_db]'
        echo "db_url = $ARCADE_DB_URL"
        echo "filter = $arcade_terms"
    fi
} > "$INI"

echo "Cores detectados:"
echo "  BIOS:   $bios_terms"
echo "  Arcade: $arcade_terms"
echo "Ini: $INI   Log: $LOG"
echo

DOWNLOADER_INI_PATH="$INI" ALLOW_REBOOT=0 UPDATE_LINUX=false LOGFILE="$LOG" \
    bash "$BASE/Scripts/update.sh"
rc=$?

# --- Comprobación de las ROM que piden los .mra instalados (solo aviso) ---
have_rom() {
    local rel="$1" root
    for root in "$BASE" /media/usb0 /media/usb1 /media/usb2 /media/usb3 /media/usb4 /media/usb5 "$BASE/cifs"; do
        [ -f "$root/games/$rel" ] && return 0
    done
    return 1
}

missing=0
if [ -d "$BASE/_Arcade" ]; then
    while IFS= read -r -d '' mra; do
        while IFS= read -r zline; do
            [ -n "$zline" ] || continue
            found=0
            IFS='|' read -r -a alts <<< "$zline"
            for z in "${alts[@]}"; do
                z=$(printf '%s' "$z" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
                [ -n "$z" ] || continue
                case "$z" in
                    hbmame/*) have_rom "hbmame/${z#hbmame/}" && found=1 && break ;;
                    *)        have_rom "mame/$z"             && found=1 && break ;;
                esac
            done
            if [ "$found" -eq 0 ]; then
                echo "AVISO: falta la ROM '$zline' para $(basename "$mra")"
                missing=$((missing+1))
            fi
        done < <(grep -oiE 'zip="[^"]+"' "$mra" | sed -E 's/^[^"]*"//; s/"$//')
    done < <(find "$BASE/_Arcade" -maxdepth 1 -iname '*.mra' -print0)
fi
[ "$missing" -eq 0 ] && echo "ROMs de los .mra instalados: OK"

exit $rc
