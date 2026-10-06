#!/usr/bin/env bash
# =============================================================================
#  harden-debian.sh — Durcissement de base d'un serveur Debian (VPS ou local)
#
#  - Création d'un utilisateur sudo
#  - SSH : port personnalisé, root interdit, clés uniquement, TrustedUserCAKeys
#  - UFW : deny incoming par défaut, allow SSH uniquement
#  - Fail2ban : jail sshd (backend systemd) + ban progressif + alerte Telegram
#  - Bonus : unattended-upgrades, durcissement sysctl
#
#  Usage : éditer les variables ci-dessous, puis  sudo bash harden-debian.sh
#  Script idempotent : il peut être relancé sans casse.
# =============================================================================
set -euo pipefail

# ------------------------------- CONFIGURATION -------------------------------
NEW_USER=""                 # utilisateur à créer
SSH_PORT=""                  # nouveau port SSH (1024-65535 conseillé)

# Au moins UNE des deux méthodes d'authentification ci-dessous est obligatoire.
# Clé publique classique (secours ou usage sans CA) — laisser vide si inutile
USER_PUBKEY=""
# Clé publique de ta CA SSH (contenu de ca.pub) — laisser vide si pas de CA
CA_PUBKEY=""

SUDO_NOPASSWD="false"            # "true" = sudo sans mot de passe

# Discord (laisser vide pour désactiver l'alerte)
DISCORD_WEBHOOK_URL=""           # ex: https://discord.com/api/webhooks/123/abc...

# Garder le port 22 ouvert temporairement pendant la transition (recommandé)
KEEP_PORT_22_TEMP="true"

# Paramètres fail2ban
F2B_MAXRETRY="5"
F2B_FINDTIME="10m"
F2B_BANTIME="1h"
# -----------------------------------------------------------------------------

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

# ------------------------------ VÉRIFICATIONS --------------------------------
[[ $EUID -eq 0 ]] || die "Lance ce script en root (sudo)."
grep -qi '^ID=debian' /etc/os-release || die "Script prévu pour Debian uniquement."
[[ -n "$USER_PUBKEY" || -n "$CA_PUBKEY" ]] \
  || die "Renseigne USER_PUBKEY et/ou CA_PUBKEY, sinon tu seras bloqué dehors."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
  || die "SSH_PORT invalide."
if [[ -n "$DISCORD_WEBHOOK_URL" && ! "$DISCORD_WEBHOOK_URL" =~ ^https://(discord|discordapp)\.com/api/webhooks/ ]]; then
  die "DISCORD_WEBHOOK_URL ne ressemble pas à une URL de webhook Discord."
fi

# ------------------------------- PAQUETS -------------------------------------
log "Installation des paquets..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo ufw fail2ban python3-systemd curl \
  unattended-upgrades apt-listchanges >/dev/null

# ---------------------------- UTILISATEUR ------------------------------------
if id "$NEW_USER" &>/dev/null; then
  log "Utilisateur $NEW_USER déjà existant."
else
  log "Création de l'utilisateur $NEW_USER..."
  adduser --disabled-password --gecos "" "$NEW_USER" >/dev/null
fi
usermod -aG sudo "$NEW_USER"

if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
  chmod 440 "/etc/sudoers.d/90-$NEW_USER"
  visudo -cf "/etc/sudoers.d/90-$NEW_USER" >/dev/null || die "Fichier sudoers invalide."
elif passwd -S "$NEW_USER" | awk '{print $2}' | grep -qv '^P$'; then
  warn "Définis un mot de passe pour $NEW_USER (utilisé uniquement par sudo) :"
  passwd "$NEW_USER"
fi

if [[ -n "$USER_PUBKEY" ]]; then
  log "Ajout de la clé publique..."
  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
  AK="/home/$NEW_USER/.ssh/authorized_keys"
  touch "$AK"
  grep -qxF "$USER_PUBKEY" "$AK" || echo "$USER_PUBKEY" >> "$AK"
  chown "$NEW_USER:$NEW_USER" "$AK"; chmod 600 "$AK"
fi

# --------------------------------- SSH ---------------------------------------
log "Configuration SSH..."
if [[ -n "$CA_PUBKEY" ]]; then
  echo "$CA_PUBKEY" > /etc/ssh/trusted_user_ca_keys.pub
  chmod 644 /etc/ssh/trusted_user_ca_keys.pub
fi

# Debian lit sshd_config.d en premier et la 1re valeur gagne → préfixe 00-
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# Généré par harden-debian.sh
Port $SSH_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
AllowUsers $NEW_USER
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
$( [[ -n "$CA_PUBKEY" ]] && echo "TrustedUserCAKeys /etc/ssh/trusted_user_ca_keys.pub" )
EOF

mkdir -p /run/sshd
sshd -t || die "Configuration sshd invalide, rien n'a été redémarré."

# Cas où l'activation par socket est utilisée
if systemctl is-enabled ssh.socket &>/dev/null; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" \
    > /etc/systemd/system/ssh.socket.d/override.conf
  systemctl daemon-reload
fi

# --------------------------------- UFW ---------------------------------------
log "Configuration UFW..."
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp" comment 'SSH' >/dev/null
if [[ "$KEEP_PORT_22_TEMP" == "true" && "$SSH_PORT" != "22" ]]; then
  ufw allow 22/tcp comment 'SSH temporaire - a supprimer' >/dev/null
fi
ufw --force enable >/dev/null

# ------------------------------- DISCORD -------------------------------------
# Nettoyage d'une éventuelle ancienne config Telegram
rm -f /etc/fail2ban/telegram.env /usr/local/bin/f2b-telegram.sh /etc/fail2ban/action.d/telegram.conf

DISCORD_ENABLED="false"
if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
  DISCORD_ENABLED="true"
  log "Configuration de l'alerte Discord..."
  install -m 600 /dev/null /etc/fail2ban/discord.env
  echo "DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK_URL\"" > /etc/fail2ban/discord.env

  cat > /usr/local/bin/f2b-discord.sh <<'EOF'
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
  chmod 700 /usr/local/bin/f2b-discord.sh

  cat > /etc/fail2ban/action.d/discord.conf <<'EOF'
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
cat > /etc/fail2ban/jail.local <<EOF
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
$( [[ "$DISCORD_ENABLED" == "true" ]] && printf 'action = %%(action_)s\n         discord[name=%%(__name__)s]' )
EOF

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# ------------------------- MISES À JOUR AUTO ---------------------------------
log "Activation des mises à jour de sécurité automatiques..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# -------------------------------- SYSCTL -------------------------------------
log "Durcissement réseau (sysctl)..."
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
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
sysctl --system >/dev/null

# --------------------------- REDÉMARRAGE SSH ---------------------------------
log "Redémarrage de SSH..."
if systemctl is-enabled ssh.socket &>/dev/null; then
  systemctl restart ssh.socket
fi
systemctl restart ssh

[[ "$DISCORD_ENABLED" == "true" ]] && \
  /usr/local/bin/f2b-discord.sh test "Durcissement terminé (SSH port $SSH_PORT)"

# -------------------------------- RÉSUMÉ -------------------------------------
echo
log "Terminé."
warn "NE FERME PAS cette session. Dans un autre terminal, teste :"
echo "      ssh -p $SSH_PORT $NEW_USER@<ip_du_serveur>"
if [[ "$KEEP_PORT_22_TEMP" == "true" && "$SSH_PORT" != "22" ]]; then
  warn "Une fois la connexion validée, ferme le port 22 :"
  echo "      sudo ufw delete allow 22/tcp"
fi
echo "  Vérifications utiles :"
echo "      sudo ufw status verbose"
echo "      sudo fail2ban-client status sshd"
echo "      sudo sshd -T | grep -Ei 'port|permitroot|password|trustedusercakeys'"
