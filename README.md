# harden-debian

Script de durcissement de base pour Debian (VPS neuf **ou** machine déjà en service) :
utilisateur sudo, SSH (port dédié, root interdit, clés publiques ou CA uniquement),
UFW, fail2ban (jail `sshd` + alerte Discord facultative), mises à jour de sécurité
automatiques, durcissement réseau via sysctl.

## Principes

- **Réutilisable** : un compte qui existe déjà n'est jamais recréé, les paquets déjà
  installés ne sont pas réinstallés, et tout fichier de configuration qu'il n'a pas
  écrit est sauvegardé (`.bak.<date>`) avant écrasement.
- **Mode guidé** : « soit tu as tout et hop, soit on te demande ». Si tout est fourni
  (options ou variables d'environnement), le script s'exécute sans rien demander. S'il
  manque une valeur et qu'un terminal est disponible, il la demande (défaut entre
  crochets, `Entrée` l'accepte), puis affiche un récapitulatif avant d'appliquer. Sans
  terminal, il auto-détecte ce qui peut l'être et s'arrête sinon : aucune valeur
  n'est inventée.
- **`--dry-run`** : affiche tout ce qui serait fait, sans écrire ni redémarrer (les
  questions du mode guidé sont quand même posées).
- **Secrets hors du dépôt** : l'URL du webhook Discord se passe par option, variable
  d'environnement ou saisie masquée en mode guidé. Elle n'est jamais recopiée dans la
  sortie (ni dans le récapitulatif, ni en `--dry-run`), elle est écrite uniquement dans
  `/etc/fail2ban/discord.env` (0600) et ne doit jamais être committée.

## Utilisation

```bash
sudo bash harden-debian.sh                       # mode guidé : pose les questions manquantes
sudo bash harden-debian.sh --dry-run             # idem, en simulation
sudo bash harden-debian.sh --user admin --port 50050 --ca-pubkey "$(cat ca.pub)"
sudo ADMIN_USER=admin SSH_PORT=50050 bash harden-debian.sh
sudo bash harden-debian.sh --user admin --yes    # aucune question, défauts acceptés
```

### Mode guidé

Seules les valeurs manquantes sont demandées, dans cet ordre :

1. **Compte administrateur** : la valeur proposée est `$SUDO_USER`, sinon l'unique compte humain.
2. **Création du compte** s'il n'existe pas (`[o/N]`, refus = arrêt) ; `--create-user` et
   `--no-create-user` restent prioritaires.
3. **Port SSH** : la valeur proposée est le port actuel (`sshd -T`).
4. **Accès SSH** : `1) clé publique utilisateur  2) clé de CA  3) les deux`. La méthode proposée
   est celle déjà en place, sinon `3`. Chaque clé se colle (même coupée sur plusieurs lignes)
   ou s'indique par le chemin d'un fichier `.pub`. Elle est validée et redemandée si elle est
   invalide. Une clé déjà en place peut être conservée avec `Entrée`. Choisir `1` alors
   qu'une CA est déployée retire `TrustedUserCAKeys`.
5. **sudo sans mot de passe** (`[o/N]`).
6. **Webhook Discord** : saisie masquée, vide = pas d'alerte.
7. **Port 22 gardé pendant la transition** (`[O/n]`), seulement si le port SSH n'est pas 22.

Un récapitulatif s'affiche ensuite, suivi de « Appliquer ? [O/n] ». Une clé fournie en
option ou en variable n'est jamais redemandée.

`--yes` (`-y`) ne pose aucune question et n'affiche pas de confirmation. Le compte peut
alors être déduit (`$SUDO_USER` ou compte humain unique). Le reste suit le comportement
non interactif : port et CA auto-détectés, création automatique d'un compte absent sauf
avec `--no-create-user`.

Variables d'environnement : `ADMIN_USER`, `SSH_PORT`, `CA_PUBKEY`, `USER_PUBKEY`,
`DISCORD_WEBHOOK_URL`, `SUDO_NOPASSWD`, `KEEP_PORT_22_TEMP`, `CREATE_USER`,
`ALLOW_EXTRA_USERS`, `ALLOW_GROUP`.

## Options

| Option | Effet |
|---|---|
| `--user <nom>` | compte administrateur (demandé s'il manque) |
| `--port <n>` | port SSH (défaut : port actuel de `sshd`) |
| `--ca-pubkey <clé>` | clé publique de la CA SSH (défaut : CA déjà déployée) |
| `--pubkey <clé>` | clé publique classique dans `authorized_keys` |
| `--allow-user <nom>` | compte supplémentaire autorisé (répétable) |
| `--allow-group <grp>` | autoriser un groupe entier au lieu de `AllowUsers` |
| `--no-create-user` / `--create-user` (alias `--force-create-user`) | forcer le mode de création du compte |
| `--keep-22` / `--no-keep-22` | garder (ou non) le port 22 pendant la transition |
| `--discord-webhook <url>` | alerte fail2ban Discord |
| `--sudo-nopasswd` | sudo sans mot de passe pour l'administrateur |
| `--yes`, `-y` | aucune question, défauts acceptés, pas de confirmation |
| `--dry-run`, `-n` | simulation |

## Historique

1. **Version initiale** — variables en dur en tête de script, pensée pour un VPS neuf.
2. **Version actuelle** — options CLI et variables d'environnement, auto-détection du
   port et de la CA, mode de création du compte, liste `AllowUsers`, sauvegardes des
   fichiers non gérés, `--dry-run`, installation des seuls paquets manquants.
3. **Mode guidé** : questions pour les seules valeurs manquantes, saisie et validation
   des clés, webhook masqué, récapitulatif et confirmation, `--yes`.

## Limites connues

- Garde une session ouverte pendant l'exécution : le changement de port et de
  `AllowUsers` peut couper l'accès SSH. Le port 22 est conservé par défaut pendant
  la transition (`--no-keep-22` pour le fermer).
- `AllowUsers` restreint l'accès à la liste fournie ; le script avertit des comptes à
  shell qui ne seraient pas listés, mais ne les ajoute pas tout seul.
- Prévoir Debian uniquement (le script refuse les autres distributions).
