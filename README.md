# harden-debian

Script de durcissement de base pour Debian (VPS neuf **ou** machine déjà en service) :
utilisateur sudo, SSH (port dédié, root interdit, clés publiques ou CA uniquement),
UFW, fail2ban (jail `sshd` + alerte Discord facultative), mises à jour de sécurité
automatiques, durcissement réseau via sysctl.

## Principes

- **Réutilisable** : un compte qui existe déjà n'est jamais recréé, les paquets déjà
  installés ne sont pas réinstallés, et tout fichier de configuration qu'il n'a pas
  écrit est sauvegardé (`.bak.<date>`) avant écrasement.
- **`--dry-run`** : affiche tout ce qui serait fait, sans écrire ni redémarrer.
- **Secrets hors du dépôt** : l'URL du webhook Discord se passe par option ou variable
  d'environnement, n'est jamais recopiée dans la sortie (masquée en `--dry-run`) et ne
  doit jamais être committée.

## Utilisation

```bash
sudo bash harden-debian.sh --user admin --port 50050 --ca-pubkey "$(cat ca.pub)"
sudo bash harden-debian.sh --dry-run --user admin --port 50050
sudo ADMIN_USER=admin SSH_PORT=50050 bash harden-debian.sh
```

Variables d'environnement : `ADMIN_USER`, `SSH_PORT`, `CA_PUBKEY`, `USER_PUBKEY`,
`DISCORD_WEBHOOK_URL`, `SUDO_NOPASSWD`, `KEEP_PORT_22_TEMP`, `CREATE_USER`,
`ALLOW_EXTRA_USERS`, `ALLOW_GROUP`.

## Options

| Option | Effet |
|---|---|
| `--user <nom>` | compte administrateur (obligatoire) |
| `--port <n>` | port SSH (défaut : port actuel de `sshd`) |
| `--ca-pubkey <clé>` | clé publique de la CA SSH (défaut : CA déjà déployée) |
| `--pubkey <clé>` | clé publique classique dans `authorized_keys` |
| `--allow-user <nom>` | compte supplémentaire autorisé (répétable) |
| `--allow-group <grp>` | autoriser un groupe entier au lieu de `AllowUsers` |
| `--no-create-user` / `--force-create-user` | forcer le mode de création du compte |
| `--keep-22` / `--no-keep-22` | garder (ou non) le port 22 pendant la transition |
| `--discord-webhook <url>` | alerte fail2ban Discord |
| `--sudo-nopasswd` | sudo sans mot de passe pour l'administrateur |
| `--dry-run`, `-n` | simulation |

## Historique

1. **Version initiale** — variables en dur en tête de script, pensée pour un VPS neuf.
2. **Version actuelle** — options CLI et variables d'environnement, auto-détection du
   port et de la CA, mode de création du compte, liste `AllowUsers`, sauvegardes des
   fichiers non gérés, `--dry-run`, installation des seuls paquets manquants.

## Limites connues

- Garde une session ouverte pendant l'exécution : le changement de port et de
  `AllowUsers` peut couper l'accès SSH. Le port 22 est conservé par défaut pendant
  la transition (`--no-keep-22` pour le fermer).
- `AllowUsers` restreint l'accès à la liste fournie ; le script avertit des comptes à
  shell qui ne seraient pas listés, mais ne les ajoute pas tout seul.
- Prévoir Debian uniquement (le script refuse les autres distributions).
