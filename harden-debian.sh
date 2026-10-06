#!/usr/bin/env bash
# =============================================================================
#  harden-debian.sh — Durcissement de base d'un serveur Debian (VPS ou local)
#
#  Réutilisable : machine vierge (VPS) comme machine déjà en service.
#  Rien n'est recréé ni écrasé en aveugle :
#    - un utilisateur qui existe déjà n'est jamais recréé (mode auto) ;
#    - tout fichier de config absent de ce script est sauvegardé avant écrasement ;
#    - les paquets déjà installés ne sont pas réinstallés ;
#    - --dry-run montre tout ce qui serait fait, sans rien modifier.
#
#  Mode guidé : soit tout est fourni (options / environnement) et le script
#  s'exécute directement, soit il manque une valeur et, si un terminal est
#  disponible, le script la demande (défaut entre crochets, Entrée l'accepte),
#  puis affiche un récapitulatif avant d'appliquer. Sans terminal : auto-
#  détection quand elle existe, arrêt sinon. --yes : aucune question.
#
#  Exemples :
#    sudo bash harden-debian.sh                      # mode guidé
#    sudo bash harden-debian.sh --user admin --port 50050 \
#         --ca-pubkey "$(cat ca.pub)"
#    sudo bash harden-debian.sh --dry-run --user admin --port 50050
#    sudo ADMIN_USER=admin SSH_PORT=50050 bash harden-debian.sh
#    sudo bash harden-debian.sh --user admin --yes   # port & CA auto-détectés
#
#  Options :
#    --user <nom>            compte administrateur (demandé s'il manque)
#    --port <n>              port SSH (défaut : port actuel de sshd)
#    --ca-pubkey <clé>       clé publique de la CA SSH (défaut : CA déjà en place)
#    --pubkey <clé>          clé publique classique dans authorized_keys
#    --allow-user <nom>      compte supplémentaire à autoriser (répétable)
#    --allow-group <grp>     autoriser un groupe entier au lieu de AllowUsers
#    --no-create-user        ne jamais créer l'utilisateur (il doit exister)
#    --create-user, --force-create-user  le créer s'il est absent, sans question
#    --keep-22 / --no-keep-22  garder le port 22 ouvert pendant la transition
#    --discord-webhook <url> alerte fail2ban Discord (vide = désactivé)
#    --sudo-nopasswd         sudo sans mot de passe pour l'admin
#    --yes, -y               aucune question : défauts acceptés, pas de confirmation
#    --dry-run, -n           simulation : rien n'est écrit ni redémarré
#    --help, -h
#
#  Script idempotent : relançable sans casse.
# =============================================================================
set -euo pipefail

# ------------------------------- CONFIGURATION -------------------------------
# Valeurs de départ, surchargeables par variable d'environnement puis par option.
# Ce qui est fourni explicitement n'est jamais redemandé par le mode guidé.
GIVEN_SUDO="${SUDO_NOPASSWD+1}"
GIVEN_WEBHOOK="${DISCORD_WEBHOOK_URL+1}"
GIVEN_KEEP22="${KEEP_PORT_22_TEMP+1}"

ADMIN_USER="${ADMIN_USER:-}"                 # ex: admin
SSH_PORT="${SSH_PORT:-}"                     # vide = port actuel de sshd
USER_PUBKEY="${USER_PUBKEY:-}"               # clé publique de secours (optionnelle)
CA_PUBKEY="${CA_PUBKEY:-}"                   # clé publique de la CA (optionnelle)
SUDO_NOPASSWD="${SUDO_NOPASSWD:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
KEEP_PORT_22_TEMP="${KEEP_PORT_22_TEMP:-true}"
CREATE_USER="${CREATE_USER:-auto}"           # auto | always | never
ALLOW_EXTRA_USERS="${ALLOW_EXTRA_USERS:-}"   # noms séparés par des espaces
ALLOW_GROUP="${ALLOW_GROUP:-}"               # ex: sudo (alternative à AllowUsers)

F2B_MAXRETRY="5"
F2B_FINDTIME="10m"
F2B_BANTIME="1h"

DRY_RUN=false
ASSUME_YES=false
# -----------------------------------------------------------------------------

TAG="# Généré par harden-debian.sh"
BACKUPS=()

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

# Exécute une commande, ou l'affiche seulement en simulation.
run() {
  if $DRY_RUN; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

# Écrit un fichier depuis stdin ; en simulation, affiche son contenu.
put() {
  local p="$1"
  if $DRY_RUN; then
    printf '    [dry-run] écrirait %s :\n' "$p"
    sed 's/^/        | /'
  else
    mkdir -p "$(dirname "$p")"
    cat > "$p"
  fi
}

# Sauvegarde un fichier existant qui n'est pas géré par ce script.
backup_foreign() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  grep -qF "$TAG" "$p" 2>/dev/null && return 0
  local b="$p.bak.$(date +%Y%m%d-%H%M%S)"
  warn "Fichier existant géré hors de ce script, sauvegarde : $b"
  run cp -a "$p" "$b"
  BACKUPS+=("$b")
}

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

WEBHOOK_RE='^https://(discord|discordapp)\.com/api/webhooks/'
KEY_RE='^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-[a-z0-9@.-]+|sk-ecdsa-sha2-[a-z0-9@.-]+)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$'

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# Port réellement utilisé par sshd (puis lecture directe des fichiers de
# configuration si sshd -T n'est pas utilisable). Vide si introuvable.
detect_port() {
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')" || true
  if [[ -z "$p" ]]; then
    p="$(grep -rhiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
      | awk '{print $2; exit}')" || true
  fi
  echo "$p"
}

# Compte administrateur probable : $SUDO_USER, sinon l'unique compte humain.
guess_admin_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo "$SUDO_USER"; return 0
  fi
  local humans
  humans="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd)" || true
  if [[ -n "$humans" && "$(wc -l <<<"$humans")" -eq 1 ]]; then echo "$humans"; fi
}

# ------------------------------ MODE GUIDÉ -----------------------------------
# Les questions partent sur stderr (read -p), les réponses viennent du terminal.
ASKED=false

# ask <question> <variable> [secret] : lit une ligne, sans espaces aux bords.
ask() {
  local __v
  ASKED=true
  if [[ "${3:-}" == "secret" ]]; then
    IFS= read -rs -p "$1" __v || { echo >&2; die "Saisie interrompue."; }
    echo >&2
  else
    IFS= read -r -p "$1" __v || { echo >&2; die "Saisie interrompue."; }
  fi
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$2" '%s' "$__v"
}

# ask_yn <question> <o|n> : succès si oui ; le défaut est en majuscule.
ask_yn() {
  local r hint="[o/N]"
  if [[ "$2" == "o" ]]; then hint="[O/n]"; fi
  while :; do
    ask "$1 $hint " r
    r="${r,,}"
    case "${r:-$2}" in
      o|oui|y|yes) return 0 ;;
      n|non|no)    return 1 ;;
      *)           warn "Réponds o ou n." ;;
    esac
  done
}

# valid_keys <texte> <multi> : une clé publique par ligne, plusieurs si multi=true.
valid_keys() {
  local l n=0
  while IFS= read -r l; do
    if [[ -z "${l//[[:space:]]/}" ]]; then continue; fi
    [[ "$l" =~ $KEY_RE ]] || return 1
    if command -v ssh-keygen &>/dev/null; then
      ssh-keygen -lf - <<<"$l" &>/dev/null || return 1
    fi
    n=$((n+1))
  done <<<"$1"
  (( n == 1 )) || { [[ "$2" == "true" ]] && (( n > 1 )); }
}

# Résumé lisible d'une ou plusieurs clés (empreinte, commentaire, type).
key_summary() {
  local l
  while IFS= read -r l; do
    if [[ -z "${l//[[:space:]]/}" ]]; then continue; fi
    ssh-keygen -lf - <<<"$l" 2>/dev/null || awk '{print $1, $3}' <<<"$l"
  done <<<"$1"
}

# read_pubkey <libellé> <Entrée conserve l'existant : true|false> <multi>
# Accepte un collage (y compris coupé sur plusieurs lignes) ou le chemin d'un
# fichier .pub. Résultat dans REPLY_KEY (vide = conserver l'existant).
read_pubkey() {
  local label="$1" keep="$2" multi="$3" line text path more hint="" from_file
  if [[ "$keep" == "true" ]]; then hint=" [Entrée = conserver l'existant]"; fi
  while :; do
    ask "Collez la clé publique $label (ssh-ed25519 AAAA…), ou le chemin d'un fichier .pub$hint : " line
    if [[ -z "$line" ]]; then
      if [[ "$keep" == "true" ]]; then REPLY_KEY=""; return 0; fi
      warn "Clé obligatoire."; continue
    fi
    path="${line/#\~/$HOME}"
    from_file=false
    if [[ ! "$line" =~ ^(ssh-|ecdsa-|sk-) && -f "$path" ]]; then
      text="$(grep -vE '^[[:space:]]*(#|$)' "$path")" || text=""
      from_file=true
    else
      text="$line"
      # Collage coupé par le terminal : tant que la clé est incomplète (type
      # reconnu, base64 sans commentaire), on recolle les lignes suivantes.
      # Une ligne vide arrête la saisie.
      while ! valid_keys "$text" "$multi" \
            && [[ "$text" =~ ^(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+[A-Za-z0-9+/]*$ ]]; do
        IFS= read -r -p "> " more || break
        more="${more#"${more%%[![:space:]]*}"}"
        more="${more%"${more##*[![:space:]]}"}"
        if [[ -z "$more" ]]; then break; fi
        text+="$more"
      done
    fi
    if valid_keys "$text" "$multi"; then REPLY_KEY="$text"; return 0; fi
    if valid_keys "$text" true; then
      warn "Une seule clé attendue ici."
    elif $from_file; then
      warn "$path ne contient pas de clé publique valide (fichier .pub attendu, pas la clé privée)."
    else
      warn "Clé invalide (attendu : ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-* suivi du base64)."
    fi
  done
}

# ----------------------------- OPTIONS CLI -----------------------------------
while (( $# )); do
  case "$1" in
    --user)            ADMIN_USER="${2:?}"; shift 2 ;;
    --port)            SSH_PORT="${2:?}"; shift 2 ;;
    --ca-pubkey)       CA_PUBKEY="${2:?}"; shift 2 ;;
    --pubkey)          USER_PUBKEY="${2:?}"; shift 2 ;;
    --allow-user)      ALLOW_EXTRA_USERS="$ALLOW_EXTRA_USERS ${2:?}"; shift 2 ;;
    --allow-group)     ALLOW_GROUP="${2:?}"; shift 2 ;;
    --discord-webhook) DISCORD_WEBHOOK_URL="${2:?}"; GIVEN_WEBHOOK=1; shift 2 ;;
    --no-create-user)  CREATE_USER="never"; shift ;;
    --create-user|--force-create-user) CREATE_USER="always"; shift ;;
    --keep-22)         KEEP_PORT_22_TEMP="true"; GIVEN_KEEP22=1; shift ;;
    --no-keep-22)      KEEP_PORT_22_TEMP="false"; GIVEN_KEEP22=1; shift ;;
    --sudo-nopasswd)   SUDO_NOPASSWD="true"; GIVEN_SUDO=1; shift ;;
    --yes|-y)          ASSUME_YES=true; shift ;;
    --dry-run|-n)      DRY_RUN=true; shift ;;
    --help|-h)         usage; exit 0 ;;
    *)                 die "Option inconnue : $1 (--help)" ;;
  esac
done

# ------------------------------ VÉRIFICATIONS --------------------------------
[[ $EUID -eq 0 ]] || die "Lance ce script en root (sudo)."
grep -qi '^ID=debian' /etc/os-release || die "Script prévu pour Debian uniquement."

# Questions seulement avec un terminal et sans --yes ; sinon comportement
# non interactif : auto-détection quand elle existe, arrêt net sinon.
INTERACTIVE=false
if ! $ASSUME_YES && [[ -t 0 ]]; then INTERACTIVE=true; fi

# 1. Compte administrateur
if [[ -z "$ADMIN_USER" ]]; then
  guess="$(guess_admin_user)"
  if $INTERACTIVE; then
    while :; do
      ask "Compte administrateur${guess:+ [$guess]} : " ADMIN_USER
      ADMIN_USER="${ADMIN_USER:-$guess}"
      if [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then break; fi
      warn "Nom requis : minuscules, chiffres, _ et - (ne commence pas par un chiffre)."
    done
  elif $ASSUME_YES && [[ -n "$guess" ]]; then
    ADMIN_USER="$guess"
    log "Compte administrateur déduit : $ADMIN_USER"
  fi
fi
[[ -n "$ADMIN_USER" ]] || die "Renseigne le compte administrateur : --user <nom>."
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nom d'utilisateur invalide : $ADMIN_USER"
[[ "$CREATE_USER" =~ ^(auto|always|never)$ ]] || die "CREATE_USER invalide (auto|always|never)."

# 2. Création du compte (--create-user / --no-create-user restent prioritaires)
if $INTERACTIVE && [[ "$CREATE_USER" == "auto" ]] && ! id "$ADMIN_USER" &>/dev/null; then
  if ask_yn "Le compte $ADMIN_USER n'existe pas. Le créer (adduser --disabled-password) ?" n; then
    CREATE_USER="always"
  else
    die "L'utilisateur $ADMIN_USER est absent et sa création a été refusée."
  fi
fi

# 3. Port : celui fourni, sinon celui actuellement utilisé par sshd.
if [[ -z "$SSH_PORT" ]]; then
  detected_port="$(detect_port)"
  if $INTERACTIVE; then
    while :; do
      ask "Port SSH${detected_port:+ [$detected_port]} : " SSH_PORT
      SSH_PORT="${SSH_PORT:-$detected_port}"
      if valid_port "$SSH_PORT"; then break; fi
      warn "Port invalide (1-65535)."
    done
  else
    SSH_PORT="$detected_port"
    [[ -n "$SSH_PORT" ]] || die "SSH_PORT vide et impossible à détecter : passe --port <n>."
    log "Port SSH détecté : $SSH_PORT"
  fi
fi
valid_port "$SSH_PORT" || die "SSH_PORT invalide."

# 4. Accès SSH : clés fournies, sinon CA déjà déployée sur la machine.
CA_FOUND=""
if [[ -s /etc/ssh/trusted_user_ca_keys.pub ]]; then
  CA_FOUND="$(cat /etc/ssh/trusted_user_ca_keys.pub)"
fi
admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)" || admin_home=""
AK_EXISTING=false
if [[ -n "$admin_home" && -s "$admin_home/.ssh/authorized_keys" ]]; then AK_EXISTING=true; fi
KEEP_AK=false        # mode guidé : on garde les clés déjà dans authorized_keys
CA_DROPPED=false     # mode guidé : CA en place mais méthode « clé utilisateur » seule

if $INTERACTIVE && [[ -z "$USER_PUBKEY" && -z "$CA_PUBKEY" ]]; then
  if [[ -n "$CA_FOUND" ]] && $AK_EXISTING; then access_def=3
  elif [[ -n "$CA_FOUND" ]]; then access_def=2
  elif $AK_EXISTING; then access_def=1
  else access_def=3
  fi
  echo "Accès SSH :  1) clé publique utilisateur  2) clé de CA (ca.pub)  3) les deux" >&2
  while :; do
    ask "Méthode [$access_def] : " access
    access="${access:-$access_def}"
    if [[ "$access" =~ ^[123]$ ]]; then break; fi
    warn "Choisis 1, 2 ou 3."
  done
  if [[ "$access" != 2 ]]; then
    read_pubkey "de l'utilisateur" "$AK_EXISTING" false
    USER_PUBKEY="$REPLY_KEY"
    if [[ -z "$USER_PUBKEY" ]]; then KEEP_AK=true; fi
  fi
  if [[ "$access" != 1 ]]; then
    ca_keep=false
    if [[ -n "$CA_FOUND" ]]; then ca_keep=true; fi
    read_pubkey "de la CA" "$ca_keep" true
    CA_PUBKEY="${REPLY_KEY:-$CA_FOUND}"
  elif [[ -n "$CA_FOUND" ]]; then
    CA_DROPPED=true
    warn "La CA déjà en place ne sera plus acceptée (TrustedUserCAKeys retiré)."
  fi
elif [[ -z "$CA_PUBKEY" && -n "$CA_FOUND" ]]; then
  CA_PUBKEY="$CA_FOUND"
  log "CA SSH déjà présente, réutilisée."
fi
[[ -n "$USER_PUBKEY" || -n "$CA_PUBKEY" ]] || $KEEP_AK \
  || die "Fournis --ca-pubkey ou --pubkey (sinon tu seras bloqué dehors)."

# 5. sudo sans mot de passe
if $INTERACTIVE && [[ -z "$GIVEN_SUDO" ]]; then
  if ask_yn "sudo sans mot de passe pour $ADMIN_USER ?" n; then
    SUDO_NOPASSWD="true"
  else
    SUDO_NOPASSWD="false"
  fi
fi

# 6. Webhook Discord : saisie masquée, jamais réaffichée.
if $INTERACTIVE && [[ -z "$GIVEN_WEBHOOK" ]]; then
  while :; do
    ask "URL du webhook Discord (vide = pas d'alerte, saisie masquée) : " DISCORD_WEBHOOK_URL secret
    if [[ -z "$DISCORD_WEBHOOK_URL" || "$DISCORD_WEBHOOK_URL" =~ $WEBHOOK_RE ]]; then break; fi
    warn "Ce n'est pas une URL de webhook Discord (https://discord.com/api/webhooks/…)."
  done
fi
if [[ -n "$DISCORD_WEBHOOK_URL" && ! "$DISCORD_WEBHOOK_URL" =~ $WEBHOOK_RE ]]; then
  die "DISCORD_WEBHOOK_URL ne ressemble pas à une URL de webhook Discord."
fi

# 7. Port 22 pendant la transition
if $INTERACTIVE && [[ -z "$GIVEN_KEEP22" && "$SSH_PORT" != "22" ]]; then
  if ask_yn "Garder le port 22 ouvert pendant la transition ?" o; then
    KEEP_PORT_22_TEMP="true"
  else
    KEEP_PORT_22_TEMP="false"
  fi
fi

# Récapitulatif et confirmation, seulement si une question a été posée.
if $ASKED; then
  if id "$ADMIN_USER" &>/dev/null; then acct="existant"
  elif [[ "$CREATE_USER" == "never" ]]; then acct="absent, création désactivée"
  else acct="à créer, adduser --disabled-password"
  fi
  # Alignement en caractères (printf compte les octets, pas les accents).
  recap() { printf '      %s%*s %s\n' "$1" $((20 - ${#1})) '' "$2"; }
  methods=()
  if [[ -n "$USER_PUBKEY" ]] || $KEEP_AK; then methods+=("clé utilisateur"); fi
  if [[ -n "$CA_PUBKEY" ]]; then methods+=("CA"); fi
  echo
  log "Récapitulatif :"
  recap "Compte" "$ADMIN_USER — $acct"
  recap "Port SSH" "$SSH_PORT"
  recap "Accès SSH" "$(IFS=,; echo "${methods[*]}" | sed 's/,/ + /g')"
  if [[ -n "$USER_PUBKEY" ]]; then
    recap "Clé utilisateur" "$(key_summary "$USER_PUBKEY")"
  elif $KEEP_AK; then
    recap "Clé utilisateur" "clés existantes d'authorized_keys conservées"
  fi
  if [[ -n "$CA_PUBKEY" ]]; then
    while IFS= read -r l; do
      recap "Clé de CA" "$l"
    done < <(key_summary "$CA_PUBKEY")
  elif $CA_DROPPED; then
    recap "Clé de CA" "CA en place désactivée"
  fi
  if [[ "$SUDO_NOPASSWD" == "true" ]]; then sudo_txt="sans mot de passe"; else sudo_txt="avec mot de passe"; fi
  recap "sudo" "$sudo_txt"
  if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then discord_txt="activée"; else discord_txt="désactivée"; fi
  recap "Alerte Discord" "$discord_txt"
  if [[ "$SSH_PORT" == "22" ]]; then p22_txt="c'est le port SSH"
  elif [[ "$KEEP_PORT_22_TEMP" == "true" ]]; then p22_txt="gardé ouvert pendant la transition"
  else p22_txt="fermé"
  fi
  recap "Port 22" "$p22_txt"
  if $DRY_RUN; then recap "Mode" "simulation (--dry-run)"; fi
  echo
  if ! $ASSUME_YES && ! ask_yn "Appliquer ?" o; then
    warn "Abandon : rien n'a été modifié."
    exit 0
  fi
fi

# Comptes déjà présents qui perdront l'accès SSH si on ne les autorise pas.
if [[ -z "$ALLOW_GROUP" ]]; then
  others="$(awk -F: -v me="$ADMIN_USER" -v extra=" $ALLOW_EXTRA_USERS " \
    '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ && $1 != me && index(extra, " " $1 " ") == 0 {print $1}' \
    /etc/passwd | paste -sd' ' -)" || true
  if [[ -n "$others" ]]; then
    warn "Ces comptes ne seront PAS autorisés (AllowUsers) : $others"
    warn "Ajoute-les avec --allow-user <nom> si tu en as besoin."
  fi
fi

# ------------------------------- PAQUETS -------------------------------------
PKGS=(sudo ufw fail2ban python3-systemd curl unattended-upgrades apt-listchanges)
missing=()
for p in "${PKGS[@]}"; do
  dpkg -s "$p" &>/dev/null || missing+=("$p")
done
if (( ${#missing[@]} )); then
  log "Paquets manquants : ${missing[*]}"
  if $DRY_RUN; then
    printf '    [dry-run] apt-get update && apt-get install -y %s\n' "${missing[*]}"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
else
  log "Tous les paquets requis sont déjà installés."
fi

# ---------------------------- UTILISATEUR ------------------------------------
case "$CREATE_USER" in
  always) want_create=1 ;;
  never)  want_create=0 ;;
  auto)   if id "$ADMIN_USER" &>/dev/null; then want_create=0; else want_create=1; fi ;;
esac

if id "$ADMIN_USER" &>/dev/null; then
  log "Utilisateur $ADMIN_USER déjà existant : création ignorée."
elif (( want_create )); then
  log "Création de l'utilisateur $ADMIN_USER..."
  if $DRY_RUN; then
    printf '    [dry-run] adduser --disabled-password --gecos '\'''\'' %s\n' "$ADMIN_USER"
  else
    adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
else
  die "L'utilisateur $ADMIN_USER est absent et la création est désactivée (--no-create-user)."
fi

if id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  log "$ADMIN_USER est déjà dans le groupe sudo."
else
  log "Ajout de $ADMIN_USER au groupe sudo..."
  run usermod -aG sudo "$ADMIN_USER"
fi

if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  log "sudo sans mot de passe pour $ADMIN_USER."
  put "/etc/sudoers.d/90-$ADMIN_USER" <<EOF
$TAG
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL
EOF
  run chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
  if ! $DRY_RUN; then
    visudo -cf "/etc/sudoers.d/90-$ADMIN_USER" >/dev/null || die "Fichier sudoers invalide."
  fi
else
  # État du mot de passe : P = défini, L/NP = verrouillé ou absent.
  state="$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')" || state="?"
  case "$state" in
    P)  : ;;
    L|NP|"")
        warn "Aucun mot de passe utilisable pour $ADMIN_USER (état : ${state:-inconnu})."
        warn "Il servira uniquement à sudo, pas à SSH."
        if $DRY_RUN; then
          printf '    [dry-run] passwd %s\n' "$ADMIN_USER"
        else
          passwd "$ADMIN_USER"
        fi ;;
    *)  warn "État du mot de passe inconnu ($state) : rien changé." ;;
  esac
fi

if [[ -n "$USER_PUBKEY" ]]; then
  log "Ajout de la clé publique dans authorized_keys..."
  run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  AK="/home/$ADMIN_USER/.ssh/authorized_keys"
  if $DRY_RUN; then
    printf '    [dry-run] ajouterait la clé dans %s\n' "$AK"
  else
    touch "$AK"
    grep -qxF "$USER_PUBKEY" "$AK" || echo "$USER_PUBKEY" >> "$AK"
    chown "$ADMIN_USER:$ADMIN_USER" "$AK"
    chmod 600 "$AK"
  fi
fi

# --------------------------------- SSH ---------------------------------------
log "Configuration SSH..."
if [[ -n "$CA_PUBKEY" ]]; then
  put /etc/ssh/trusted_user_ca_keys.pub <<EOF
$CA_PUBKEY
EOF
  run chmod 644 /etc/ssh/trusted_user_ca_keys.pub
fi

# Liste des comptes autorisés (le compte admin, plus les --allow-user).
allow_users=("$ADMIN_USER")
for u in $ALLOW_EXTRA_USERS; do
  for seen in "${allow_users[@]}"; do
    [[ "$u" == "$seen" ]] && continue 2
  done
  allow_users+=("$u")
done

ADMISSION_LINE="AllowUsers ${allow_users[*]}"
if [[ -n "$ALLOW_GROUP" ]]; then
  ADMISSION_LINE="AllowGroups $ALLOW_GROUP"
  warn "AllowGroups $ALLOW_GROUP : tout compte absent de ce groupe perdra SSH."
fi

CA_LINE=""
if [[ -n "$CA_PUBKEY" ]]; then
  CA_LINE="TrustedUserCAKeys /etc/ssh/trusted_user_ca_keys.pub"
fi

# Debian lit sshd_config.d en premier et la 1re valeur gagne → préfixe 00-
SSHD_CONF=/etc/ssh/sshd_config.d/00-hardening.conf
backup_foreign "$SSHD_CONF"
put "$SSHD_CONF" <<EOF
$TAG
Port $SSH_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
$ADMISSION_LINE
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
$CA_LINE
EOF

if $DRY_RUN; then
  log "[dry-run] sshd -t non exécuté (configuration non écrite)."
else
  mkdir -p /run/sshd
  sshd -t || die "Configuration sshd invalide : rien n'a été redémarré."
fi

# Cas où l'activation par socket est utilisée
if systemctl is-enabled ssh.socket &>/dev/null; then
  log "Activation par socket détectée (ssh.socket)."
  run mkdir -p /etc/systemd/system/ssh.socket.d
  put /etc/systemd/system/ssh.socket.d/override.conf <<EOF
$TAG
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
  run systemctl daemon-reload
fi

# --------------------------------- UFW ---------------------------------------
log "Configuration UFW..."
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow "$SSH_PORT/tcp" comment 'SSH'
if [[ "$KEEP_PORT_22_TEMP" == "true" && "$SSH_PORT" != "22" ]]; then
  warn "Port 22 laissé ouvert temporairement (transition)."
  run ufw allow 22/tcp comment 'SSH temporaire - a supprimer'
fi
run ufw --force enable

# ------------------------------- DISCORD -------------------------------------
# Nettoyage d'une éventuelle ancienne config Telegram
run rm -f /etc/fail2ban/telegram.env /usr/local/bin/f2b-telegram.sh /etc/fail2ban/action.d/telegram.conf

DISCORD_ENABLED="false"
if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
  DISCORD_ENABLED="true"
  log "Configuration de l'alerte Discord..."
  if $DRY_RUN; then
    # L'URL de webhook est un secret : jamais recopiée en clair dans la sortie.
    printf '    [dry-run] écrirait /etc/fail2ban/discord.env :\n'
    printf '        | DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/<id>/<masqué>"\n'
  else
    printf 'DISCORD_WEBHOOK_URL="%s"\n' "$DISCORD_WEBHOOK_URL" > /etc/fail2ban/discord.env
    chmod 600 /etc/fail2ban/discord.env
  fi

  put /usr/local/bin/f2b-discord.sh <<'EOF'
#!/usr/bin/env bash
# Usage : f2b-discord.sh <ban|unban|start|stop|test> <jail|message> [ip] [failures] [bantime]
source /etc/fail2ban/discord.env
ACTION="$1"; JAIL="${2:-}"; IP="${3:-}"; FAIL="${4:-}"; BT="${5:-}"
HOST="$(hostname -f 2>/dev/null || hostname)"
case "$ACTION" in
  ban)   MSG="🚫 **[$HOST]** Ban \`$IP\` (jail: $JAIL, échecs: $FAIL, durée: ${BT}s)" ;;
  unban) MSG="✅ **[$HOST]** Unban \`$IP\` (jail: $JAIL)" ;;
  start) MSG="▶️ **[$HOST]** Jail $JAIL démarrée" ;;
  stop)  MSG="⏹️ **[$HOST]** Jail $JAIL arrêtée" ;;
  test)  MSG="🔐 **[$HOST]** $JAIL" ;;
  *)     MSG="**[$HOST]** $*" ;;
esac
# Encodage JSON propre via python3 (déjà présent, dépendance de fail2ban)
PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"username":"Fail2ban","content":sys.argv[1]}))' "$MSG")"
curl -s -m 10 -o /dev/null -H "Content-Type: application/json" \
  -X POST -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL" || true
EOF
  run chmod 700 /usr/local/bin/f2b-discord.sh

  put /etc/fail2ban/action.d/discord.conf <<'EOF'
# Généré par harden-debian.sh
[Definition]
actionstart =
actionstop  =
actioncheck =
actionban   = /usr/local/bin/f2b-discord.sh ban <name> <ip> <failures> <bantime>
actionunban =

[Init]
name = default
EOF
fi

# ------------------------------- FAIL2BAN ------------------------------------
log "Configuration Fail2ban..."
F2B_ACTION_LINE=""
if [[ "$DISCORD_ENABLED" == "true" ]]; then
  F2B_ACTION_LINE="action = %(action_)s
         discord[name=%(__name__)s]"
fi

put /etc/fail2ban/jail.local <<EOF
$TAG
[DEFAULT]
backend = systemd
banaction = ufw
bantime = $F2B_BANTIME
findtime = $F2B_FINDTIME
maxretry = $F2B_MAXRETRY
# Ban progressif pour les récidivistes (x2 à chaque fois, max 1 semaine)
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
mode = aggressive
$F2B_ACTION_LINE
EOF

run systemctl enable fail2ban
run systemctl restart fail2ban

# ------------------------- MISES À JOUR AUTO ---------------------------------
log "Activation des mises à jour de sécurité automatiques..."
# APT n'accepte qu'un commentaire en « // » — pas de « # » dans ce fichier.
put /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Généré par harden-debian.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# -------------------------------- SYSCTL -------------------------------------
log "Durcissement réseau (sysctl)..."
put /etc/sysctl.d/99-hardening.conf <<'EOF'
# Généré par harden-debian.sh
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
EOF
run sysctl --system

# --------------------------- REDÉMARRAGE SSH ---------------------------------
log "Redémarrage de SSH..."
if systemctl is-enabled ssh.socket &>/dev/null; then
  run systemctl restart ssh.socket
fi
run systemctl restart ssh

if [[ "$DISCORD_ENABLED" == "true" ]]; then
  run /usr/local/bin/f2b-discord.sh test "Durcissement terminé (SSH port $SSH_PORT)"
fi

# -------------------------------- RÉSUMÉ -------------------------------------
echo
if $DRY_RUN; then
  warn "Simulation terminée : rien n'a été modifié. Relance sans --dry-run."
  exit 0
fi

log "Terminé."
echo "      Mode utilisateur : $CREATE_USER → compte $ADMIN_USER"
echo "      Port SSH         : $SSH_PORT"
echo "      Comptes autorisés: ${allow_users[*]}${ALLOW_GROUP:+ (via le groupe $ALLOW_GROUP)}"
if (( ${#BACKUPS[@]} )); then
  echo "      Sauvegardes      :"
  printf '        %s\n' "${BACKUPS[@]}"
fi
echo
warn "NE FERME PAS cette session. Dans un autre terminal, teste :"
echo "      ssh -p $SSH_PORT $ADMIN_USER@<ip_du_serveur>"
if [[ "$KEEP_PORT_22_TEMP" == "true" && "$SSH_PORT" != "22" ]]; then
  warn "Une fois la connexion validée, ferme le port 22 :"
  echo "      sudo ufw delete allow 22/tcp"
fi
echo "  Vérifications utiles :"
echo "      sudo ufw status verbose"
echo "      sudo fail2ban-client status sshd"
echo "      sudo sshd -T | grep -Ei 'port|permitroot|password|trustedusercakeys|allowusers'"
