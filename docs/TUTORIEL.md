# Sécuriser un VPS et y héberger un vrai site web dynamique en HTTPS

Tutoriel pas à pas, commande par commande, pour partir d'un VPS tout neuf et arriver à un serveur durci qui héberge un vrai site dynamique (base de données + backend Python + reverse proxy) en HTTPS.

Ce tutoriel accompagne le script [`harden.sh`](../harden.sh) de ce dépôt. Vous pouvez soit lancer le script directement (partie 2, option A), soit refaire chaque commande à la main pour bien comprendre ce qui se passe (partie 2, option B, recommandé au moins une fois).

## Ce qu'on va construire

```
Internet
   |
   |  HTTPS (443) / HTTP (80, redirigé vers 443)
   v
[ Nginx ou Apache ]  <-- reverse proxy + certificat Let's Encrypt
   |
   |  HTTP en local uniquement (127.0.0.1:8000)
   v
[ Gunicorn + Flask ]  <-- l'application, gérée par systemd, tourne sous un utilisateur dédié
   |
   v
[ PostgreSQL ]  <-- écoute en local uniquement, utilisateur dédié à la base
```

Le tout derrière un firewall qui ne laisse passer que le SSH (sur un port personnalisé, éventuellement restreint à vos IPs), le port 80 et le port 443.

Prérequis : un VPS tout neuf (Ubuntu 22.04 ou 24.04 LTS recommandé pour ce tutoriel, les commandes RHEL/Arch équivalentes sont données en encart quand elles diffèrent), l'accès root ou sudo initial fourni par votre hébergeur, et idéalement un nom de domaine que vous pouvez pointer vers l'IP du VPS (pour la partie HTTPS).

---

## Partie 1 : préparer le terrain

### 1.1 Première connexion

Depuis votre machine, connectez-vous en root (ou l'utilisateur fourni par l'hébergeur) :

```bash
ssh root@VOTRE_IP_VPS
```

Remplacez `VOTRE_IP_VPS` par l'IP réelle. Si c'est la toute première connexion, SSH vous demande de confirmer l'empreinte du serveur : vérifiez-la si possible dans le panneau de votre hébergeur, puis tapez `yes`.

### 1.2 Mise à jour du système

Sur Debian/Ubuntu :

```bash
apt update && apt upgrade -y
```

Sur RHEL/CentOS/Rocky/AlmaLinux/Fedora :

```bash
dnf upgrade -y
```

Sur Arch :

```bash
pacman -Syu --noconfirm
```

Redémarrez si un nouveau noyau a été installé (l'invite vous le signale en général) :

```bash
reboot
```

Reconnectez-vous ensuite en SSH avant de continuer.

---

## Partie 2 : durcir le serveur

### Option A : lancer le script du dépôt

```bash
apt install -y git   # ou dnf install -y git / pacman -S --noconfirm git
git clone https://github.com/x0u7s1d3r/vps-hardening-toolkit.git
cd vps-hardening-toolkit
chmod +x harden.sh
sudo ./harden.sh
```

Répondez aux questions (nom d'utilisateur, port SSH, IPs autorisées, IPv6, ICMP, sudo avec ou sans mot de passe, clé publique ou génération sur place). **Gardez cette session SSH ouverte** jusqu'à la toute fin : le script vous demandera de confirmer que la nouvelle connexion fonctionne depuis une autre fenêtre avant de terminer. Si quelque chose cloche, répondez "non" à la question finale et le script annule tout automatiquement.

Si vous choisissez cette option, vous pouvez passer directement à la Partie 3. La suite de cette section (Option B) explique ce que le script fait, commande par commande, pour ceux qui veulent comprendre ou dérouler la procédure à la main.

### Option B : le faire à la main, étape par étape

#### 2.1 Créer un utilisateur non-root

Ne jamais laisser root accessible en SSH. On crée un utilisateur dédié :

```bash
adduser deploy
```

(Sur RHEL/CentOS/Arch : `useradd -m -s /bin/bash deploy && passwd -l deploy` puis donnez-lui un mot de passe local avec `passwd deploy` si vous comptez l'utiliser en console, sinon laissez verrouillé si l'accès se fait uniquement par clé SSH.)

Ajoutez-le au groupe sudo (`sudo` sur Debian/Ubuntu, `wheel` sur RHEL/Arch) :

```bash
usermod -aG sudo deploy        # Debian/Ubuntu
usermod -aG wheel deploy       # RHEL/CentOS/Rocky/AlmaLinux/Fedora/Arch
```

#### 2.2 Installer votre clé SSH

**Sur votre machine locale** (pas sur le VPS), si vous n'avez pas déjà une paire de clés :

```bash
ssh-keygen -t ed25519 -C "deploy@vps"
```

Copiez la clé publique sur le VPS pour le nouvel utilisateur :

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@VOTRE_IP_VPS
```

Si `ssh-copy-id` n'est pas disponible (Windows sans WSL par exemple), faites-le à la main sur le VPS, connecté en root :

```bash
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
echo "VOTRE_CLE_PUBLIQUE_ICI" >> /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

Testez la connexion **dans une nouvelle fenêtre de terminal, sans fermer la session root actuelle** :

```bash
ssh deploy@VOTRE_IP_VPS
```

Ne continuez que si ça fonctionne.

#### 2.3 Durcir la configuration SSH

Retour dans une session root ou avec `sudo`. On sauvegarde d'abord la config :

```bash
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
```

Choisissez un port SSH personnalisé (entre 1024 et 65535, ici on prend 2222 en exemple, changez-le pour un port de votre choix) et éditez `/etc/ssh/sshd_config` :

```bash
sudo nano /etc/ssh/sshd_config
```

Vérifiez/modifiez ces lignes (décommentez-les si besoin, `Ctrl+O` puis `Entrée` pour sauvegarder, `Ctrl+X` pour quitter) :

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

**Piège classique sur les images cloud Ubuntu/Debian** : le fichier `/etc/ssh/sshd_config` contient en général une ligne `Include /etc/ssh/sshd_config.d/*.conf` tout en haut, et ces fichiers sont lus **avant** le reste de la config. Sur beaucoup d'images Ubuntu, `/etc/ssh/sshd_config.d/50-cloud-init.conf` force `PasswordAuthentication yes`, ce qui annule silencieusement le réglage qu'on vient de faire. Vérifiez :

```bash
grep -r "PasswordAuthentication\|PermitRootLogin\|Port" /etc/ssh/sshd_config.d/ 2>/dev/null
```

Si une ligne apparaît, corrigez-la dans ce fichier aussi (même méthode, `sudo nano /etc/ssh/sshd_config.d/50-cloud-init.conf`).

**Ne redémarrez jamais SSH sans tester la config d'abord** :

```bash
sudo sshd -t
```

Si la commande ne renvoie rien, la config est valide. Redémarrez :

```bash
sudo systemctl restart ssh      # Debian/Ubuntu
sudo systemctl restart sshd     # RHEL/CentOS/Rocky/AlmaLinux/Fedora/Arch
```

**Règle d'or : gardez votre session actuelle ouverte** et testez la nouvelle connexion depuis un tout nouveau terminal avant de fermer quoi que ce soit :

```bash
ssh -p 2222 deploy@VOTRE_IP_VPS
```

Si ça ne fonctionne pas, vous avez toujours votre session root ouverte pour corriger le tir. C'est exactement ce que le script `harden.sh` automatise avec un rollback si le test échoue.

#### 2.4 Configurer le firewall

**Sur Debian/Ubuntu/Arch (ufw)** :

```bash
sudo apt install -y ufw   # déjà présent sur la plupart des images Ubuntu
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on lo
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2222/tcp
sudo ufw deny 22/tcp
sudo ufw enable
```

Vérifiez :

```bash
sudo ufw status verbose
```

**Sur RHEL/CentOS/Rocky/AlmaLinux/Fedora (firewalld)** :

```bash
sudo dnf install -y firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=2222/tcp
sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --reload
```

Vérifiez :

```bash
sudo firewall-cmd --list-all
```

Si vous voulez restreindre SSH à des IPs précises (recommandé si vous avez une IP fixe) :

```bash
# ufw
sudo ufw allow from VOTRE_IP to any port 2222 proto tcp

# firewalld
sudo firewall-cmd --permanent --zone=trusted --add-rich-rule="rule family='ipv4' source address='VOTRE_IP' port protocol='tcp' port='2222' accept"
sudo firewall-cmd --reload
```

#### 2.5 Installer Fail2ban

```bash
sudo apt install -y fail2ban    # ou dnf install -y fail2ban
```

Créez une jail dédiée à SSH plutôt que de modifier les fichiers fournis par le paquet :

```bash
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[sshd]
enabled = true
port = 2222
filter = sshd
maxretry = 5
bantime = 1h
findtime = 10m
EOF
```

(Ne précisez pas `logpath` si vous n'êtes pas certain du chemin des logs : fail2ban détecte automatiquement le bon backend sur les systèmes systemd récents. Si besoin, forcez `backend = systemd`.)

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

#### 2.6 IPv6 et ICMP (optionnel mais recommandé si vous n'utilisez pas IPv6)

```bash
sudo tee /etc/sysctl.d/90-hardening-ipv6.conf > /dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sudo tee /etc/sysctl.d/90-hardening-icmp.conf > /dev/null <<'EOF'
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089
EOF

sudo sysctl --system
```

#### 2.7 Mises à jour de sécurité automatiques

Sur Debian/Ubuntu :

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

Sur RHEL/CentOS/Rocky/AlmaLinux/Fedora :

```bash
sudo dnf install -y dnf-automatic
sudo sed -i 's/^apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic.timer
```

#### 2.8 Vérifications de fin de partie

```bash
sudo ss -tuln                 # quels ports écoutent réellement
sudo fail2ban-client status   # jails actives
sudo ufw status                # (ou firewall-cmd --list-all)
last -a                        # derniers logins
```

---

## Partie 3 : déployer un vrai site dynamique

On construit un vrai backend : une petite application Flask connectée à PostgreSQL, servie par Gunicorn, gérée comme un service système. Rien d'ici n'est un jouet : c'est le schéma standard utilisé en production pour un site Python.

### 3.1 Installer PostgreSQL

```bash
sudo apt install -y postgresql postgresql-contrib   # ou dnf install -y postgresql-server postgresql-contrib
```

Sur RHEL-like, initialisez et démarrez le service si ce n'est pas déjà fait :

```bash
sudo postgresql-setup --initdb   # RHEL/CentOS/Rocky/AlmaLinux uniquement
sudo systemctl enable --now postgresql
```

Créez une base et un utilisateur dédiés à l'application (jamais l'utilisateur `postgres` par défaut pour une appli) :

```bash
sudo -u postgres psql <<'SQL'
CREATE DATABASE monsite;
CREATE USER monsite_app WITH PASSWORD 'CHANGEZ_MOI_MOT_DE_PASSE_FORT';
GRANT ALL PRIVILEGES ON DATABASE monsite TO monsite_app;
SQL
```

Générez un mot de passe fort plutôt que d'en inventer un :

```bash
openssl rand -base64 24
```

Vérifiez que PostgreSQL n'écoute qu'en local (comportement par défaut, mais on le confirme) :

```bash
sudo grep -E "^listen_addresses" /etc/postgresql/*/main/postgresql.conf 2>/dev/null || sudo grep -E "^listen_addresses" /var/lib/pgsql/data/postgresql.conf
```

La valeur doit être `localhost` (ou absente, ce qui revient à `localhost` par défaut). Ne l'ouvrez jamais sur `*` sans VPN ni règle firewall stricte.

### 3.2 Créer un utilisateur système dédié à l'application

L'application ne doit jamais tourner sous root ni sous votre utilisateur d'administration :

```bash
sudo adduser --system --group --home /opt/monsite --shell /usr/sbin/nologin monsite
```

### 3.3 Le code de l'application

Créez le dossier et basculez sur l'utilisateur `deploy` pour préparer les fichiers (on ajustera les permissions à la fin) :

```bash
sudo mkdir -p /opt/monsite
sudo chown deploy:deploy /opt/monsite
cd /opt/monsite
python3 -m venv venv
source venv/bin/activate
pip install flask gunicorn psycopg2-binary flask-wtf python-dotenv
pip freeze > requirements.txt
```

Fichier `/opt/monsite/.env` (les vrais secrets, jamais commités dans git) :

```bash
cat > /opt/monsite/.env <<'EOF'
DATABASE_URL=postgresql://monsite_app:CHANGEZ_MOI_MOT_DE_PASSE_FORT@localhost/monsite
SECRET_KEY=CHANGEZ_MOI_AUSSI
FLASK_ENV=production
EOF
chmod 600 /opt/monsite/.env
```

Générez une vraie clé secrète pour `SECRET_KEY` :

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

Fichier `/opt/monsite/app.py`, un vrai site dynamique (livre d'or public avec écriture en base, protégé contre l'injection SQL grâce aux requêtes préparées, contre le XSS grâce à l'échappement automatique de Jinja2, et contre le CSRF grâce à Flask-WTF) :

```python
import os
from datetime import datetime

from dotenv import load_dotenv
from flask import Flask, render_template, redirect, url_for, flash
from flask_wtf import FlaskForm, CSRFProtect
from wtforms import StringField, TextAreaField
from wtforms.validators import DataRequired, Length
import psycopg2
import psycopg2.extras

load_dotenv()

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ["SECRET_KEY"]
csrf = CSRFProtect(app)

DATABASE_URL = os.environ["DATABASE_URL"]


def get_db():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.DictCursor)


def init_db():
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    id SERIAL PRIMARY KEY,
                    author VARCHAR(80) NOT NULL,
                    content TEXT NOT NULL,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW()
                )
                """
            )


class MessageForm(FlaskForm):
    author = StringField("Nom", validators=[DataRequired(), Length(max=80)])
    content = TextAreaField("Message", validators=[DataRequired(), Length(max=500)])


@app.route("/", methods=["GET", "POST"])
def index():
    form = MessageForm()
    if form.validate_on_submit():
        # Requête préparée : aucune concaténation de chaînes, donc pas d'injection SQL possible
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO messages (author, content) VALUES (%s, %s)",
                    (form.author.data, form.content.data),
                )
        flash("Message ajouté.")
        return redirect(url_for("index"))

    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT author, content, created_at FROM messages ORDER BY created_at DESC LIMIT 50")
            messages = cur.fetchall()

    return render_template("index.html", form=form, messages=messages)


@app.route("/healthz")
def healthz():
    # Endpoint de vérification pour le monitoring (pas de données sensibles)
    return {"status": "ok", "time": datetime.utcnow().isoformat()}


if __name__ == "__main__":
    init_db()
    app.run(debug=False)
```

Fichier `/opt/monsite/templates/index.html` (Jinja2 échappe automatiquement `author` et `content`, donc pas de faille XSS même si quelqu'un poste du HTML/JS dans le formulaire) :

```html
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <title>Mon Site</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body>
  <h1>Livre d'or</h1>

  {% with msgs = get_flashed_messages() %}
    {% if msgs %}
      <ul>{% for m in msgs %}<li>{{ m }}</li>{% endfor %}</ul>
    {% endif %}
  {% endwith %}

  <form method="post">
    {{ form.hidden_tag() }}
    <p>{{ form.author.label }} {{ form.author() }}</p>
    <p>{{ form.content.label }} {{ form.content() }}</p>
    <button type="submit">Envoyer</button>
  </form>

  <hr>

  {% for msg in messages %}
    <p><strong>{{ msg.author }}</strong> ({{ msg.created_at }})<br>{{ msg.content }}</p>
  {% endfor %}
</body>
</html>
```

Initialisez la table et testez en local avant d'aller plus loin :

```bash
cd /opt/monsite
source venv/bin/activate
python3 -c "from app import init_db; init_db()"
gunicorn --bind 127.0.0.1:8000 app:app
```

Dans un autre terminal, sur le VPS :

```bash
curl -I http://127.0.0.1:8000/healthz
```

Vous devez voir un `HTTP/1.1 200 OK`. Arrêtez le test avec `Ctrl+C`.

### 3.4 Gunicorn en service systemd

Ajustez les permissions pour l'utilisateur système `monsite` :

```bash
sudo chown -R monsite:monsite /opt/monsite
```

Créez `/etc/systemd/system/monsite.service` :

```bash
sudo tee /etc/systemd/system/monsite.service > /dev/null <<'EOF'
[Unit]
Description=Gunicorn - monsite
After=network.target postgresql.service

[Service]
User=monsite
Group=monsite
WorkingDirectory=/opt/monsite
EnvironmentFile=/opt/monsite/.env
ExecStart=/opt/monsite/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:8000 app:app
Restart=on-failure
RestartSec=5

# Durcissement systemd du service
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now monsite
sudo systemctl status monsite
```

Consultez les logs si quelque chose ne démarre pas :

```bash
sudo journalctl -u monsite -f
```

---

## Partie 4 : reverse proxy et HTTPS

Choisissez **Nginx** ou **Apache** selon vos habitudes ou vos besoins (Apache reste pertinent si vous prévoyez d'héberger aussi du PHP classique en `.htaccess` à côté). Les deux font ici exactement le même travail : recevoir le trafic HTTPS public, terminer le TLS, et relayer vers Gunicorn en local sur le port 8000.

### 4.1 Pointer votre nom de domaine

Chez votre registrar/fournisseur DNS, créez un enregistrement `A` pointant `monsite.exemple.com` vers l'IP de votre VPS. Vérifiez la propagation avant de continuer :

```bash
dig +short monsite.exemple.com
```

La commande doit renvoyer l'IP de votre VPS (la propagation DNS peut prendre de quelques minutes à quelques heures).

### 4.2a Reverse proxy avec Nginx

```bash
sudo apt install -y nginx    # ou dnf install -y nginx
```

Créez `/etc/nginx/sites-available/monsite` (Debian/Ubuntu) ou `/etc/nginx/conf.d/monsite.conf` (RHEL-like) :

```nginx
server {
    listen 80;
    server_name monsite.exemple.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Sur Debian/Ubuntu, activez le site :

```bash
sudo ln -s /etc/nginx/sites-available/monsite /etc/nginx/sites-enabled/monsite
sudo rm -f /etc/nginx/sites-enabled/default
```

Testez la config puis rechargez :

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 4.2b Reverse proxy avec Apache

```bash
sudo apt install -y apache2   # ou dnf install -y httpd
sudo a2enmod proxy proxy_http headers ssl   # Debian/Ubuntu
```

Créez `/etc/apache2/sites-available/monsite.conf` (Debian/Ubuntu) ou `/etc/httpd/conf.d/monsite.conf` (RHEL-like) :

```apache
<VirtualHost *:80>
    ServerName monsite.exemple.com

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8000/
    ProxyPassReverse / http://127.0.0.1:8000/

    RequestHeader set X-Forwarded-Proto "http"
</VirtualHost>
```

Sur Debian/Ubuntu, activez le site :

```bash
sudo a2ensite monsite.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

Sur RHEL-like :

```bash
sudo apachectl configtest
sudo systemctl reload httpd
```

### 4.3 HTTPS avec Let's Encrypt (Certbot)

**Pour Nginx** :

```bash
sudo apt install -y certbot python3-certbot-nginx   # ou dnf install -y certbot python3-certbot-nginx
sudo certbot --nginx -d monsite.exemple.com
```

**Pour Apache** :

```bash
sudo apt install -y certbot python3-certbot-apache   # ou dnf install -y certbot python3-certbot-apache
sudo certbot --apache -d monsite.exemple.com
```

Certbot modifie automatiquement la config pour rediriger le HTTP vers HTTPS et ajoute la bonne section `listen 443 ssl` / `<VirtualHost *:443>`. Répondez `yes` si on vous demande d'activer la redirection automatique.

Vérifiez le renouvellement automatique (le certificat expire tous les 90 jours, un timer systemd le renouvelle normalement tout seul) :

```bash
sudo systemctl status certbot.timer
sudo certbot renew --dry-run
```

Testez ensuite votre site :

```bash
curl -I https://monsite.exemple.com
```

---

## Partie 5 : sécurisation avancée de l'hébergement

### 5.1 Headers de sécurité HTTP

**Nginx**, à ajouter dans le bloc `server { }` du fichier `443` (généré par Certbot) :

```nginx
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

**Apache**, dans le `<VirtualHost *:443>` :

```apache
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
```

Rechargez le service concerné après modification (`nginx -t && systemctl reload nginx`, ou `apachectl configtest && systemctl reload apache2`/`httpd`).

### 5.2 Durcir les protocoles et suites TLS

Utilisez le générateur officiel Mozilla pour obtenir une config TLS à jour et adaptée à votre serveur : https://ssl-config.mozilla.org (choisissez le profil "Intermediate" pour un bon équilibre compatibilité/sécurité, collez le résultat dans votre config Nginx ou Apache).

### 5.3 Limiter le débit des requêtes (anti brute-force applicatif)

**Nginx**, dans le bloc `http { }` de `/etc/nginx/nginx.conf` :

```nginx
limit_req_zone $binary_remote_addr zone=monsite:10m rate=10r/s;
```

Puis dans le `location / { }` du site :

```nginx
limit_req zone=monsite burst=20 nodelay;
```

**Apache** : activez `mod_ratelimit` ou, plus simple à configurer, ajoutez une jail Fail2ban dédiée au log d'accès (voir 5.6).

### 5.4 Vérifier les permissions et l'absence de secrets exposés

```bash
sudo find /opt/monsite -name "*.env" -exec ls -la {} \;
```

Le fichier `.env` doit appartenir à `monsite:monsite` avec les permissions `600`. Si vous publiez le code sur GitHub, ajoutez un `.gitignore` :

```bash
cat > /opt/monsite/.gitignore <<'EOF'
.env
venv/
__pycache__/
*.pyc
EOF
```

### 5.5 Sauvegardes automatiques de la base

Script de sauvegarde `/opt/monsite/backup.sh` :

```bash
sudo tee /opt/monsite/backup.sh > /dev/null <<'EOF'
#!/bin/bash
set -e
BACKUP_DIR="/var/backups/monsite"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
sudo -u postgres pg_dump monsite | gzip > "$BACKUP_DIR/monsite_$TIMESTAMP.sql.gz"
# On garde les 14 dernières sauvegardes
ls -1t "$BACKUP_DIR"/monsite_*.sql.gz | tail -n +15 | xargs -r rm --
EOF
sudo chmod +x /opt/monsite/backup.sh
```

Ajoutez une tâche cron quotidienne :

```bash
( sudo crontab -l 2>/dev/null; echo "0 3 * * * /opt/monsite/backup.sh" ) | sudo crontab -
```

Pensez à copier régulièrement ces sauvegardes **hors du VPS** (stockage objet, autre serveur), une sauvegarde qui reste uniquement sur la machine qu'on protège ne sert à rien en cas de compromission ou de perte du VPS.

### 5.6 Logs et supervision

Consultez les logs applicatifs et web :

```bash
sudo journalctl -u monsite -n 100 --no-pager
sudo tail -n 100 /var/log/nginx/access.log     # ou /var/log/httpd/access_log
sudo tail -n 100 /var/log/nginx/error.log      # ou /var/log/httpd/error_log
```

Ajoutez une jail Fail2ban pour bannir les IPs qui scannent agressivement votre site (404 en rafale, tentatives d'exploitation connues) :

```bash
sudo tee -a /etc/fail2ban/jail.local > /dev/null <<'EOF'

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 10
bantime = 1h
EOF
sudo systemctl restart fail2ban
```

Pour une supervision externe simple de la disponibilité du site (indépendante du VPS lui-même), un service comme UptimeRobot ou un ping HTTP planifié ailleurs reste la solution la plus fiable : si le VPS tombe entièrement, un check lancé depuis le VPS lui-même ne peut évidemment rien remonter.

---

## Partie 6 : checklist finale de vérification

À faire systématiquement avant de considérer le serveur "prêt production" :

```bash
# SSH : uniquement par clé, sur le bon port, root désactivé
ssh -p VOTRE_PORT deploy@VOTRE_IP_VPS "echo OK"
ssh -p VOTRE_PORT root@VOTRE_IP_VPS "echo test"    # doit être refusé

# Firewall : seuls 80/443/SSH ouverts
sudo ufw status verbose                             # ou sudo firewall-cmd --list-all

# Fail2ban actif
sudo fail2ban-client status

# SSH : config validée
sudo sshd -t && echo "config sshd OK"

# Services applicatifs actifs et démarrent bien au boot
sudo systemctl is-enabled monsite nginx fail2ban postgresql

# Le site répond bien en HTTPS avec un certificat valide
curl -Iv https://monsite.exemple.com 2>&1 | grep -E "HTTP|subject|expire"

# Aucun port inattendu n'écoute
sudo ss -tuln

# Scan externe depuis une autre machine, pour voir ce qu'un attaquant verrait réellement
nmap -Pn VOTRE_IP_VPS
```

Testez aussi la note SSL de votre site avec l'outil en ligne SSL Labs (https://www.ssllabs.com/ssltest/), viser au minimum une note "A".

---

## Annexe : je me suis retrouvé bloqué dehors, que faire

La quasi-totalité des hébergeurs VPS (OVH, Hetzner, DigitalOcean, Scaleway, etc.) fournissent une **console web** accessible depuis leur panneau de gestion, indépendante du réseau. Si un mauvais réglage SSH ou firewall vous coupe l'accès :

1. Ouvrez la console web du fournisseur (souvent appelée "Console", "VNC" ou "Recovery").
2. Connectez-vous localement avec les identifiants root/console.
3. Corrigez le fichier fautif (`/etc/ssh/sshd_config`, règles firewall, etc.), ou restaurez la sauvegarde faite par `harden.sh` (`/etc/ssh/sshd_config.bak_AAAA-MM-JJ_HHMMSS`).
4. Redémarrez le service concerné et retestez depuis une vraie session SSH avant de fermer la console.

C'est exactement pour éviter d'en arriver là que `harden.sh` teste systématiquement la config avant de redémarrer SSH, et propose un rollback automatique si la nouvelle connexion échoue.

## Ressources

- Documentation officielle OpenSSH : https://www.openssh.com/manual.html
- Générateur de config TLS Mozilla : https://ssl-config.mozilla.org
- Documentation Certbot : https://certbot.eff.org
- Documentation Fail2ban : https://github.com/fail2ban/fail2ban/wiki
- Test SSL Labs : https://www.ssllabs.com/ssltest/
