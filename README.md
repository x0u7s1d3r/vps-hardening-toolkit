# vps-hardening-toolkit

[![CI](https://github.com/x0u7s1d3r/vps-hardening-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/x0u7s1d3r/vps-hardening-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Script bash pour durcir rapidement et correctement un serveur VPS fraîchement installé : utilisateur non-root, SSH par clé uniquement, firewall, fail2ban, et quelques réglages réseau. Pensé pour être le **premier script qu'on lance** sur un VPS tout neuf, avant d'y déployer quoi que ce soit.

Compatible **Debian/Ubuntu**, **RHEL/CentOS/Rocky/AlmaLinux/Fedora** et **Arch Linux**. Utilisable en mode interactif classique ou entièrement scriptable (`--non-interactive`), avec un mode `--dry-run` pour prévisualiser les changements.

> Un tutoriel pas-à-pas très détaillé (durcissement + hébergement d'un vrai site web dynamique en HTTPS) est disponible dans [`docs/TUTORIEL.md`](docs/TUTORIEL.md). L'historique des versions est dans [`CHANGELOG.md`](CHANGELOG.md).

## Pourquoi ce script

La plupart des scripts de "hardening VPS" qu'on trouve sur GitHub ou YouTube ont un défaut commun : ils appliquent des `sed` fragiles sur `sshd_config`, ne testent jamais la config avant de redémarrer SSH, et peuvent vous verrouiller hors de votre propre serveur. Celui-ci a été spécifiquement corrigé pour éviter ça :

- Validation `sshd -t` avant tout redémarrage de SSH (jamais de restart sur une config cassée).
- Détection et correction des fichiers `/etc/ssh/sshd_config.d/*.conf` (notamment `50-cloud-init.conf` sur les images cloud Ubuntu, qui réactive silencieusement l'authentification par mot de passe après votre configuration).
- Rollback automatique fiable en cas de problème (config sauvegardée, restaurée dans le bon ordre pour ne jamais rester bloqué dehors).
- Compatible plusieurs distributions sans supposer que `adduser`/`usermod -aG sudo` se comportent pareil partout.
- Étiquetage automatique du port SSH personnalisé sous SELinux (`semanage port`) sur RHEL/CentOS/Rocky/AlmaLinux/Fedora : sans ça, sshd refuse de démarrer sur un port non-standard dès que SELinux est en mode `Enforcing` (le réglage par défaut sur ces distributions) — un piège très fréquent, absent de la plupart des scripts équivalents.
- Idempotent : relancer le script sur un serveur déjà durci (même port SSH, etc.) ne casse rien et ne duplique rien.

## Ce que fait le script

1. Crée un utilisateur non-root, ajouté à `sudo`/`wheel`, avec (au choix) mot de passe requis pour sudo ou non.
2. Installe votre clé publique SSH existante, ou en génère une nouvelle sur le serveur (sans jamais l'afficher en clair sans confirmation explicite).
3. Durcit `sshd_config` : port personnalisé, `PermitRootLogin no`, `PasswordAuthentication no`, authentification par clé uniquement.
4. Désactive IPv6 et limite les réponses ICMP (optionnel, demandé à l'exécution).
5. Configure le firewall (`ufw` ou `firewalld` selon la distro) : tout bloqué par défaut, seuls 80/443/SSH (port custom, IP restreintes si vous le souhaitez) sont ouverts.
6. Installe et configure Fail2ban sur le service SSH.
7. Vérifie que SSH répond bien sur le nouveau port avant de terminer, et propose un rollback complet si quelque chose ne va pas.

## Utilisation

```bash
git clone https://github.com/x0u7s1d3r/vps-hardening-toolkit.git
cd vps-hardening-toolkit
chmod +x harden.sh
sudo ./harden.sh
```

Le script pose des questions à chaque étape (nom d'utilisateur, port SSH, IPs autorisées, etc.) avec des valeurs par défaut raisonnables. **Gardez votre session SSH actuelle ouverte** pendant toute l'exécution : à la fin, le script vous demande de valider la nouvelle connexion depuis une autre fenêtre avant de considérer que tout est bon. Si vous répondez "non", tout est annulé automatiquement.

## Mode avancé : dry-run et non-interactif

```bash
sudo ./harden.sh --help
```

- `--dry-run` : affiche tout ce que le script ferait (utilisateur, SSH, firewall, fail2ban) sans toucher au système. Aucune question interactive n'empêche l'aperçu, seules les actions réelles sont sautées.
- `--non-interactive` avec `--user`, `--ssh-port`, `--allowed-ips`, `--pubkey`, `--disable-ipv6`, `--limit-icmp`, `--sudo-nopasswd` : exécution 100% automatisée, sans aucune question, utilisable en CI ou appelée depuis un autre script/outil d'infra.

Exemple :

```bash
sudo ./harden.sh --non-interactive \
  --user deploy \
  --ssh-port 2222 \
  --pubkey "$(cat ~/.ssh/id_ed25519.pub)" \
  --allowed-ips "203.0.113.42" \
  --disable-ipv6 oui \
  --limit-icmp oui \
  --sudo-nopasswd non
```

Chaque exécution est journalisée dans `/var/log/vps-hardening-toolkit.log`.

Le pipeline CI (`.github/workflows/ci.yml`) tourne sur chaque push/PR et comprend 5 jobs indépendants :

- **lint** : shellcheck + vérification syntaxique.
- **integration-test** : exécution réelle et complète du script en mode non-interactif sur un runner Ubuntu jetable, y compris : un faux drop-in `50-cloud-init.conf` créé avant l'exécution pour vérifier pour de vrai qu'il est corrigé (pas seulement `sshd_config`), et une seconde exécution du script avec les mêmes paramètres pour vérifier l'idempotence (pas de doublon dans `authorized_keys`, pas d'erreur).
- **rollback-test** : simule un échec constaté par l'utilisateur (réponse "non" à la confirmation finale) et vérifie que `rollback()` restaure bien `sshd_config`, désactive le firewall, retire l'entrée sudoers, les drop-ins sysctl et la config fail2ban — le mécanisme anti-lockout le plus critique du script est donc lui-même testé, pas seulement relu.
- **dry-run-rhel** / **dry-run-arch** : exécutent réellement (pas en théorie) la détection de distribution, la sélection dnf/pacman et firewalld/ufw, et surtout la détection du service SSH sur Rocky Linux et Arch Linux, en mode `--dry-run`. Ces deux jobs tournent dans un conteneur Docker simple (pas de vrai `systemd` en PID 1, pas de SELinux enforcing non plus), donc ils ne couvrent pas le redémarrage réel des services ni l'étiquetage SELinux comme le ferait un vrai VPS RHEL — c'est une limite assumée, pas cachée. L'étiquetage SELinux (`configure_selinux_ssh_port` dans `harden.sh`) est donc revu par shellcheck et exercé en dry-run, mais pas vérifié en conditions réelles par la CI.

## Avertissements

- Ce script modifie la configuration réseau et SSH d'un serveur en production. Testez-le d'abord sur un VPS jetable si vous n'êtes pas sûr.
- Il n'installe **aucun** serveur web ni n'ouvre que les ports 80/443/SSH : pour héberger un site derrière, suivez [`docs/TUTORIEL.md`](docs/TUTORIEL.md).
- Fourni "tel quel", sans garantie (voir [LICENSE](LICENSE)).

## Licence

MIT, voir [LICENSE](LICENSE).

Basé à l'origine sur un script de [MozzyPC](https://www.youtube.com/@mozzypc), largement réécrit depuis (fiabilité, portabilité multi-distro, sécurité).
