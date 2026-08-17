# Changelog

Toutes les évolutions notables de ce projet sont documentées ici. Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/).

## [1.3.0] - 2026-08-17

### Corrigé (sécurité / RHEL-family)

- **SELinux** : sur RHEL/CentOS/Rocky/AlmaLinux/Fedora avec SELinux en mode `Enforcing` (le défaut sur ces distributions), sshd est confiné au domaine `sshd_t` et ne peut se binder QUE sur les ports étiquetés `ssh_port_t`. Le script changeait le port SSH sans jamais étiqueter le nouveau port, ce qui empêchait sshd de démarrer dessus sur un vrai VPS RHEL-like (`Bind to port ... failed: Permission denied`) — allant à l'encontre du but même du script. Nouvelle fonction `configure_selinux_ssh_port()` : détecte SELinux (`getenforce`), installe `policycoreutils-python-utils` si `semanage` est absent, étiquette le nouveau port (`semanage port -a/-m -t ssh_port_t`) en évitant d'écraser un port déjà réservé par un autre service, et défait l'étiquetage au rollback. No-op silencieux sur les distributions sans SELinux (Debian/Ubuntu, Arch) ou avec SELinux désactivé.

### Corrigé (idempotence)

- Relancer `harden.sh` une seconde fois avec le même `--ssh-port` sur un serveur déjà durci échouait systématiquement : `validate_port()` rejetait ce port comme "déjà utilisé", alors qu'il l'était... par le sshd que le script lui-même avait configuré au tour précédent. Le port SSH actuellement configuré (`sshd -T`) est maintenant lu avant validation et exempté de ce contrôle.

### Corrigé (affichage)

- La bannière et `--help` affichaient parfois un numéro de version incohérent (ex: "v24.04.4 LTS (Noble Numbat)" au lieu de "v1.3.0") : le script utilisait une variable `VERSION`, or `/etc/os-release` définit LUI-MÊME une variable `VERSION` (le nom de version de la distribution), et le `. /etc/os-release` fait plus loin pour détecter la distribution écrasait silencieusement la nôtre. Renommée en `TOOLKIT_VERSION`. Bug repéré via un test manuel du script pendant cette session, pas par la CI (couvre un cas que shellcheck ne peut pas détecter : une collision de nom avec une variable définie dans un fichier externe sourcé).

### Ajouté

- Job CI `integration-test` étendu : simule désormais un vrai drop-in `50-cloud-init.conf` avant l'exécution (jamais testé en conditions réelles jusqu'ici, seulement relu) et vérifie qu'il est bien corrigé ; ajoute une seconde exécution du script avec les mêmes paramètres pour vérifier l'idempotence (pas de doublon dans `authorized_keys`, SSH toujours fonctionnel après).

### Recherché, considéré, et volontairement non modifié

- **fail2ban + firewalld sur RHEL-family** : la configuration par défaut du paquet fail2ban gère déjà correctement la coexistence avec firewalld sur les distributions supportées ; forcer un `banaction` spécifique (ex: nftables natif) dans `jail.local` risquerait de casser ce qui fonctionne déjà sur certaines distributions pour un bénéfice incertain. Non modifié après recherche.
- **AppArmor sur Ubuntu/Debian** : contrairement à SELinux sur RHEL, `openssh-server` n'installe pas de profil AppArmor confinant sshd par défaut sur Ubuntu/Debian — pas de restriction de port équivalente à corriger.

## [1.2.0] - 2026-08-17

### Ajouté

- Job CI `rollback-test` : simule un échec constaté par l'utilisateur (réponse "non" à la confirmation finale de `harden.sh`) et vérifie que `rollback()` restaure réellement `sshd_config` à l'identique, désactive le firewall, retire l'entrée sudoers créée, les drop-ins sysctl IPv6/ICMP et la configuration fail2ban. Ce mécanisme anti-lockout, jusqu'ici seulement relu, est maintenant exécuté pour de vrai à chaque push/PR.
- Jobs CI `dry-run-rhel` (Rocky Linux 9, conteneur `rockylinux:9`) et `dry-run-arch` (`archlinux:latest`) : exécutent réellement le script en `--dry-run --non-interactive` dans un conteneur de chaque distribution, exerçant pour de vrai la détection de distribution, la sélection `dnf`/`pacman` et `firewalld`/`ufw`, et la détection du service SSH sur ces deux familles (jusqu'ici jamais exécutées par la CI, seulement par Ubuntu). Limite assumée et documentée : pas de vrai `systemd` en PID 1 dans ces conteneurs, donc pas de test du redémarrage réel des services comme sur Ubuntu.

### Modifié

- Tous les appels à `systemctl` (détection du service SSH, `manage_service()`) sont désormais protégés par un `timeout` (10s pour la détection, 30s pour les actions), pour ne jamais bloquer indéfiniment le script sur un bus systemd injoignable (environnement conteneurisé sans init réel, notamment).

## [1.1.0] - 2026-08-17

### Ajouté

- Mode non-interactif scriptable : `--user`, `--ssh-port`, `--allowed-ips`, `--pubkey`, `--disable-ipv6`, `--limit-icmp`, `--sudo-nopasswd`, `--non-interactive`. Permet d'exécuter le script sans aucune question, utilisable en CI ou depuis un outil d'infra-as-code.
- Mode `--dry-run` : prévisualise toutes les actions (utilisateur, SSH, IPv6/ICMP, firewall, fail2ban) sans modifier le système.
- `-h` / `--help` : aide complète, utilisable sans droits root.
- Journalisation automatique de toute l'exécution dans `/var/log/vps-hardening-toolkit.log` (best-effort, ne bloque pas le script si le fichier n'est pas accessible en écriture).
- Pipeline GitHub Actions (`.github/workflows/ci.yml`) : lint shellcheck sur chaque push/PR, plus un test d'intégration qui exécute réellement le script en mode non-interactif sur un runner Ubuntu et vérifie le résultat (SSH par clé fonctionnel, mot de passe/root désactivés, firewall actif, fail2ban actif).
- `CHANGELOG.md` (ce fichier).

### Modifié

- La détection des fichiers `sshd_config.d/*.conf` concernés par le durcissement (ex: `50-cloud-init.conf`) est maintenant effectuée même en mode `--dry-run`, pour prévisualiser correctement ce qui serait modifié.

## [1.0.0] - 2026-08-17

Première version publique, entièrement réécrite à partir d'un script de MozzyPC.

### Corrigé (fiabilité / anti-lockout)

- Validation `sshd -t` avant tout redémarrage de sshd (évite de restart une config cassée).
- `set_sshd_option()` remplace les `sed` fragiles qui ne matchaient que les lignes commentées : applique désormais la valeur que la ligne soit commentée, déjà définie, ou absente.
- Détection et correction des drop-ins `/etc/ssh/sshd_config.d/*.conf` (ex: `50-cloud-init.conf` sur Ubuntu cloud, qui force `PasswordAuthentication yes` après le fichier principal).
- `register_action()` appelé avant chaque action risquée (et non après), pour que le rollback fonctionne même si l'action échoue en cours de route.
- `rollback()` parcourt les actions dans l'ordre inverse (on rouvre le firewall avant de remettre l'ancien port SSH), pour éviter une fenêtre de blocage pendant l'annulation.
- `trap ERR` désarmé au début de `rollback()` pour éviter une boucle de rollback récursif.
- `manage_service()` propage désormais le vrai code de retour (avant : toujours "succès").

### Corrigé (portabilité multi-distro)

- Création d'utilisateur adaptée (`adduser` Debian-only vs `useradd`+`passwd -l` ailleurs).
- Groupe `sudo`/`wheel` détecté selon la distribution (`usermod -aG sudo` cassait sur RHEL-like).
- Regex de distribution corrigée pour matcher `almalinux` (et pas seulement `alma`).
- Fail2ban : `logpath` adapté (`auth.log` vs `secure`) ou passage en `backend = systemd` si aucun fichier de log classique n'existe (image cloud minimaliste).
- Vérification/installation de `sudo` s'il est absent.

### Corrigé (sécurité)

- Plus d'affichage systématique de la clé privée en clair : option de fournir sa propre clé publique (recommandé), sinon affichage seulement sur confirmation explicite, avec commande `scp` fournie pour récupérer la clé proprement.
- `sudo NOPASSWD` n'est plus la valeur imposée par défaut ; demandé explicitement, avec validation du fichier sudoers via `visudo -cf` et permissions `0440`.
- `UsePAM` n'est plus désactivé (cassait 2FA/PAM sans bénéfice de sécurité réel).
- IPv6/ICMP gérés via des fichiers de dépôt `/etc/sysctl.d/` dédiés (idempotents, rollback = suppression du fichier) plutôt que des `echo >>` cumulatifs dans `sysctl.conf`.
- Sauvegarde des règles UFW existantes avant `reset` si un firewall était déjà actif.
- Pas de doublons dans `authorized_keys` en cas de ré-exécution du script.

### Corrigé (validation)

- `validate_port`/`is_port_in_use` corrigés (ancrage regex : `":$port"` évite les faux positifs du type port 22 matchant aussi 2222).
- `validate_yes_no` unifié et insensible à la casse (`oui`/`non`/`o`/`y`/`yes`/`no` acceptés partout).
- `validate_ip` vérifie désormais que chaque octet est bien entre 0 et 255.
