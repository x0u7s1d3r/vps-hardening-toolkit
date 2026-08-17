# vps-hardening-toolkit

Script bash pour durcir rapidement et correctement un serveur VPS fraîchement installé : utilisateur non-root, SSH par clé uniquement, firewall, fail2ban, et quelques réglages réseau. Pensé pour être le **premier script qu'on lance** sur un VPS tout neuf, avant d'y déployer quoi que ce soit.

Compatible **Debian/Ubuntu**, **RHEL/CentOS/Rocky/AlmaLinux/Fedora** et **Arch Linux**.

> Un tutoriel pas-à-pas très détaillé (durcissement + hébergement d'un vrai site web dynamique en HTTPS) est disponible dans [`docs/TUTORIEL.md`](docs/TUTORIEL.md).

## Pourquoi ce script

La plupart des scripts de "hardening VPS" qu'on trouve sur GitHub ou YouTube ont un défaut commun : ils appliquent des `sed` fragiles sur `sshd_config`, ne testent jamais la config avant de redémarrer SSH, et peuvent vous verrouiller hors de votre propre serveur. Celui-ci a été spécifiquement corrigé pour éviter ça :

- Validation `sshd -t` avant tout redémarrage de SSH (jamais de restart sur une config cassée).
- Détection et correction des fichiers `/etc/ssh/sshd_config.d/*.conf` (notamment `50-cloud-init.conf` sur les images cloud Ubuntu, qui réactive silencieusement l'authentification par mot de passe après votre configuration).
- Rollback automatique fiable en cas de problème (config sauvegardée, restaurée dans le bon ordre pour ne jamais rester bloqué dehors).
- Compatible plusieurs distributions sans supposer que `adduser`/`usermod -aG sudo` se comportent pareil partout.

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

## Avertissements

- Ce script modifie la configuration réseau et SSH d'un serveur en production. Testez-le d'abord sur un VPS jetable si vous n'êtes pas sûr.
- Il n'installe **aucun** serveur web ni n'ouvre que les ports 80/443/SSH : pour héberger un site derrière, suivez [`docs/TUTORIEL.md`](docs/TUTORIEL.md).
- Fourni "tel quel", sans garantie (voir [LICENSE](LICENSE)).

## Licence

MIT, voir [LICENSE](LICENSE).

Basé à l'origine sur un script de [MozzyPC](https://www.youtube.com/@mozzypc), largement réécrit depuis (fiabilité, portabilité multi-distro, sécurité).
