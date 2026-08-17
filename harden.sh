#!/bin/bash
#
# ============================================================================
#   vps-hardening-toolkit - harden.sh
#   Durcissement automatisé d'un serveur VPS fraîchement installé
#
#   Auteur   : x0u7s1d3r (Amiir)
#   Repo     : https://github.com/x0u7s1d3r/vps-hardening-toolkit
#   Licence  : MIT (voir LICENSE)
#   Inspiré du script original de MozzyPC (https://www.youtube.com/@mozzypc),
#   entièrement revu : idempotence, rollback fiable, compatibilité multi-distro
#   (Debian/Ubuntu, RHEL/CentOS/Rocky/AlmaLinux/Fedora, Arch), et durcissement
#   SSH/firewall/fail2ban plus strict. Détail complet des correctifs en bas
#   de ce fichier et dans docs/TUTORIEL.md.
#
#   Usage : sudo ./harden.sh
# ============================================================================

VERSION="1.0.0"

set -e  # Arrête le script en cas d'erreur (voir gestion du trap ERR plus bas)
set -u  # Erreur si variable non définie utilisée
set -o pipefail

# === Déclaration des variables ===
ACTIONS_DONE=()  # Liste des actions effectuées, dans l'ORDRE d'exécution (le rollback les rejoue à l'envers)
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S") # Timestamp unique pour les fichiers de backup
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
SYSCTL_DROPIN_DIR="/etc/sysctl.d"
IPV6_DROPIN="$SYSCTL_DROPIN_DIR/90-vps-hardening-ipv6.conf"
ICMP_DROPIN="$SYSCTL_DROPIN_DIR/90-vps-hardening-icmp.conf"
SSHD_TOUCHED_FILES=()  # Tous les fichiers sshd_config* réellement modifiés (pour backup/rollback)

# === Ajout de couleurs pour améliorer l'affichage ===
RED="\033[1;31m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
NC="\033[0m"  # No Color


# === Fonction d'affichage de message ===
show_info() {
    echo -e "${BLUE}$1${NC}"
}

show_secondary() {
    echo -e "${CYAN}$1${NC}" >&2
}

show_success() {
    echo -e "${GREEN}$1${NC}"
}

show_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

show_error() {
    echo -e "${RED}❌ $1${NC}" >&2  # On force l'affichage sur stderr
}

# Fonction générique pour demander une entrée utilisateur avec validation
prompt_user() {
    local prompt_text="$1"
    local default_value="$2"
    local validate_func="$3"
    local user_input

    while true; do
        show_secondary "$prompt_text [${default_value}]: "
        read -r user_input
        user_input="${user_input:-$default_value}"  # Si entrée vide, prendre la valeur par défaut

        if [[ -n "$validate_func" ]]; then
            if "$validate_func" "$user_input"; then
                echo "$user_input"
                return 0
            fi
        else
            echo "$user_input"
            return 0
        fi
    done
}

# === Fonctions de validation ===

validate_username() {
    local username="$1"
    if [[ ${#username} -gt 32 ]]; then
        show_error "Le nom d'utilisateur ne peut pas dépasser 32 caractères."
        return 1
    fi
    if [[ "$username" =~ ^[a-z][-a-z0-9_]*\$?$ ]]; then
        return 0
    else
        show_error "Le nom d'utilisateur '$username' est invalide."
        return 1
    fi
}

# Valide un octet d'IPv4 (0-255)
validate_octet() {
    [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( 10#$1 >= 0 && 10#$1 <= 255 ))
}

validate_ip() {
    local ip_cidr="$1" ip="${1%%/*}" cidr="${1#*/}"
    local a b c d

    if [[ "$ip_cidr" == "$ip" ]]; then
        cidr=""
    fi
    IFS='.' read -r a b c d <<< "$ip"
    if [[ -z "${a:-}" || -z "${b:-}" || -z "${c:-}" || -z "${d:-}" ]] \
        || ! validate_octet "$a" || ! validate_octet "$b" || ! validate_octet "$c" || ! validate_octet "$d"; then
        show_error "L'adresse IP '$ip_cidr' est invalide."
        return 1
    fi
    if [[ -n "$cidr" ]] && ! [[ "$cidr" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        show_error "Le masque CIDR de '$ip_cidr' est invalide."
        return 1
    fi
    return 0
}

validate_ips_list() {
    local ips="$1"
    for ip in $ips; do
        if ! validate_ip "$ip"; then
            return 1
        fi
    done
    return 0
}

# Vérifie si un port TCP/UDP local est déjà utilisé (avec ancrage correct pour éviter
# les faux positifs de type "22" qui matcherait aussi "2222")
is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -Htuln | awk '{print $5}' | grep -qE "[.:]${port}\$"
    elif command -v netstat &>/dev/null; then
        netstat -tuln | awk '{print $4}' | grep -qE "[.:]${port}\$"
    else
        show_warn "Impossible de vérifier les ports utilisés (ni ss ni netstat)."
        return 1
    fi
}

validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )); then
        if is_port_in_use "$port"; then
            show_error "Le port $port est déjà utilisé."
            return 1
        fi
        return 0
    else
        show_error "Le port doit être un nombre entre 1024 et 65535."
        return 1
    fi
}

# Réponse oui/non insensible à la casse, formes courtes ou longues acceptées
validate_yes_no() {
    local input="$1"
    shopt -s nocasematch
    if [[ "$input" =~ ^(oui|o|y|yes|non|n|no)$ ]]; then
        shopt -u nocasematch
        return 0
    else
        shopt -u nocasematch
        show_error "Réponse invalide. Veuillez répondre par 'oui' ou 'non'."
        return 1
    fi
}

is_yes() {
    local res
    shopt -s nocasematch
    [[ "$1" =~ ^(oui|o|y|yes)$ ]]
    res=$?
    shopt -u nocasematch
    return $res
}

validate_pubkey() {
    local key="$1"
    if [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]] ]]; then
        return 0
    else
        show_error "Cette clé ne ressemble pas à une clé publique SSH valide (elle doit commencer par ssh-ed25519, ssh-rsa, etc.)."
        return 1
    fi
}

# Génère un port SSH aléatoire entre 10000 et 65535 non utilisé
generate_random_port() {
    local port
    while true; do
        port=$((RANDOM % 55535 + 10000))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

check_ssh_port() {
    is_port_in_use "$1"
}

# Wrapper pour gérer les services, avec fallback systemd -> service, et propagation réelle
# du code de retour (contrairement à l'original, un échec de "restart" est maintenant détecté).
manage_service() {
    local service_name="$1" action="$2" rc

    if command -v systemctl &>/dev/null && systemctl list-units --full -all 2>/dev/null | grep -q "${service_name}\.service"; then
        systemctl "$action" "$service_name" &>/dev/null
        rc=$?
    elif command -v service &>/dev/null && service --status-all 2>/dev/null | grep -q "$service_name"; then
        service "$service_name" "$action" &>/dev/null
        rc=$?
    else
        show_warn "Impossible de $action $service_name (service non détecté)."
        return 1
    fi

    if [[ $rc -eq 0 ]]; then
        show_info "Service $service_name : '$action' effectué."
    else
        show_error "Échec de '$action' sur le service $service_name (code $rc)."
    fi
    return $rc
}

# Enregistre une action AVANT de la tenter, pour que le rollback sache la défaire
# même si l'action elle-même échoue en cours de route.
register_action() {
    ACTIONS_DONE+=("$1")
}

# Applique (ou ajoute si absente) une directive dans un fichier sshd_config donné,
# qu'elle soit commentée ou déjà décommentée avec une autre valeur.
set_sshd_option() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}([[:space:]]|\$)" "$file" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}([[:space:]].*)?\$|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

# Fonction de rollback
rollback() {
    # On désarme le trap ERR pour éviter qu'une erreur PENDANT le rollback ne se relance
    # elle-même en boucle.
    trap - ERR
    set +e

    show_error "Un problème est survenu. Annulation des changements..."

    # On rejoue les actions dans l'ordre INVERSE de leur exécution : on rouvre l'accès
    # (firewall, fail2ban) avant de remettre SSH dans son état d'origine, pour éviter
    # une fenêtre où le nouveau port est fermé et l'ancien pas encore rouvert.
    local i action
    for (( i=${#ACTIONS_DONE[@]}-1 ; i>=0 ; i-- )); do
        action="${ACTIONS_DONE[$i]}"
        case "$action" in
            "fail2ban")
                rm -f /etc/fail2ban/jail.local
                manage_service fail2ban restart
                show_success "✅ Fail2ban désactivé."
                ;;
            "firewall")
                if [[ "$FIREWALL_SERVICE" == "ufw" ]]; then
                    ufw --force reset &>/dev/null
                    ufw disable &>/dev/null
                elif [[ "$FIREWALL_SERVICE" == "firewalld" ]]; then
                    manage_service firewalld stop
                    manage_service firewalld disable
                fi
                show_success "✅ Firewall désactivé."
                ;;
            "icmp")
                rm -f "$ICMP_DROPIN"
                sysctl --system &>/dev/null
                show_success "✅ Paramètres ICMP restaurés."
                ;;
            "ipv6")
                rm -f "$IPV6_DROPIN"
                sysctl --system &>/dev/null
                show_success "✅ IPv6 restauré."
                ;;
            "ssh")
                local f
                for f in "${SSHD_TOUCHED_FILES[@]}"; do
                    if [[ -f "${f}.bak_${TIMESTAMP}" ]]; then
                        mv "${f}.bak_${TIMESTAMP}" "$f"
                    fi
                done
                manage_service "$SSH_SERVICE" restart
                show_success "✅ Configuration SSH restaurée."
                ;;
            "sudoers")
                rm -f "/etc/sudoers.d/$NEW_USER"
                show_success "✅ Entrée sudoers retirée."
                ;;
        esac
    done
    show_success "✅ Rollback terminé. L'utilisateur '$NEW_USER' et sa clé SSH ne sont pas supprimés automatiquement (au cas où) : supprimez-les manuellement avec 'deluser $NEW_USER' si besoin."
    exit 1
}

# Active le rollback en cas d'échec
trap 'rollback' ERR


# === Precheck ===

if [[ $EUID -ne 0 ]]; then
   show_error "Ce script doit être exécuté en tant que root ou avec sudo."
   exit 1
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO="$ID"
else
    show_error "Impossible de détecter la distribution. Script interrompu."
    exit 1
fi

if [[ "$DISTRO" =~ ^(ubuntu|debian)$ ]]; then
    PKG_MANAGER="apt"
    FIREWALL_SERVICE="ufw"
    SUDO_GROUP="sudo"

    INSTALL_CMD() {
        apt update -qq && apt install -y "$@" &>/dev/null
    }

elif [[ "$DISTRO" =~ ^(centos|rhel|rocky|almalinux|fedora)$ ]]; then
    PKG_MANAGER="dnf"
    FIREWALL_SERVICE="firewalld"
    SUDO_GROUP="wheel"

    INSTALL_CMD() {
        dnf install -y "$@" &>/dev/null
    }

elif [[ "$DISTRO" == "arch" ]]; then
    PKG_MANAGER="pacman"
    FIREWALL_SERVICE="ufw"
    SUDO_GROUP="wheel"

    show_warn "Sur Arch, l'installation d'un paquet via pacman -Sy déclenche une mise à jour complète du système (recommandation Arch pour éviter les 'partial upgrades')."
    INSTALL_CMD() {
        pacman -Syu --noconfirm --needed "$@" &>/dev/null
    }
else
    show_error "Distribution '$DISTRO' non supportée. Script interrompu."
    exit 1
fi

if ! command -v sudo &>/dev/null; then
    show_warn "sudo n'est pas installé, installation en cours..."
    INSTALL_CMD sudo
fi

if command -v systemctl &>/dev/null; then
    if systemctl list-units --type=service --all 2>/dev/null | awk '$2 == "loaded"' | grep -E -q '\bssh\.service\b'; then
        SSH_SERVICE="ssh"
    elif systemctl list-units --type=service --all 2>/dev/null | awk '$2 == "loaded"' | grep -E -q '\bsshd\.service\b'; then
        SSH_SERVICE="sshd"
    else
        show_error "Impossible de détecter le service SSH. Script interrompu."
        exit 1
    fi
elif command -v service &>/dev/null; then
    if service --status-all 2>/dev/null | grep -E -q '\bssh\b'; then
        SSH_SERVICE="ssh"
    elif service --status-all 2>/dev/null | grep -E -q '\bsshd\b'; then
        SSH_SERVICE="sshd"
    else
        show_error "Impossible de détecter le service SSH. Script interrompu."
        exit 1
    fi
else
    show_error "Ni systemctl ni service ne sont disponibles. Script interrompu."
    exit 1
fi

# === Collecte des informations ===
clear
echo -e "${GREEN}"
cat <<'BANNER'
 __     __             ___    _  _              _              _
 \ \   / /            / _ \  | || |            | |            (_)
  \ \_/ / __  ___     | | | | | || |__   __ _ __| | ___ _ __    _ _ __   __ _
   \   / '_ \/ __|    | | | | | || '_ \ / _` |/ _` |/ _ \ '_ \ | | '_ \ / _` |
    | || |_) \__ \    | |_| | | || | | | (_| | (_| |  __/ | | || | | | | (_| |
    |_|| .__/|___/     \___/  |_||_| |_|\__,_|\__,_|\___|_| |_||_|_| |_|\__, |
        | |                                                              __/ |
        |_|                                                             |___/
BANNER
echo -e "${NC}"
show_info "  vps-hardening-toolkit v${VERSION}, par x0u7s1d3r"
show_info "  https://github.com/x0u7s1d3r/vps-hardening-toolkit"
echo
echo -e "${GREEN}🌟 Configuration du serveur 🌟${NC}"

NEW_USER=$(prompt_user "Quel nom souhaitez-vous pour l'utilisateur sécurisé SSH ?" "secureuser" "validate_username")
RANDOM_SSH_PORT=$(generate_random_port)
SSH_PORT=$(prompt_user "Quel port souhaitez-vous pour SSH ?" "$RANDOM_SSH_PORT" "validate_port")
show_secondary "(Laissez vide pour autoriser SSH depuis n'importe quelle IP - déconseillé)"
ALLOWED_SSH_IPS=$(prompt_user "Entrez les IPs ou CIDR autorisés pour SSH (séparées par des espaces)" "" "validate_ips_list")
DISABLE_IPV6=$(prompt_user "Voulez-vous désactiver IPv6 ?" "oui" "validate_yes_no")
LIMIT_ICMP=$(prompt_user "Voulez-vous limiter les réponses ICMP (Ping) ?" "oui" "validate_yes_no")
SUDO_NOPASSWD=$(prompt_user "Autoriser $NEW_USER à utiliser sudo SANS mot de passe ? (déconseillé)" "non" "validate_yes_no")

show_secondary "Avez-vous déjà une paire de clés SSH et voulez-vous fournir votre clé PUBLIQUE (recommandé, plus sûr que de générer la clé sur le serveur) ?"
HAS_OWN_KEY=$(prompt_user "Fournir ma propre clé publique ?" "oui" "validate_yes_no")
if is_yes "$HAS_OWN_KEY"; then
    USER_PUBKEY=$(prompt_user "Collez votre clé publique (ssh-ed25519 AAAA...)" "" "validate_pubkey")
else
    USER_PUBKEY=""
    show_warn "Une paire de clés sera générée sur le serveur. La clé privée ne sera PAS affichée à l'écran par défaut : le script vous donnera la commande scp pour la récupérer."
fi

show_success "🔒 Début de la sécurisation du serveur VPS..."

# === 1. Création du nouvel utilisateur ===
show_info "👤 Création de l'utilisateur SSH : $NEW_USER"
if ! id "$NEW_USER" &>/dev/null; then
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        adduser --disabled-password --gecos "" "$NEW_USER"
    else
        useradd -m -s /bin/bash "$NEW_USER"
        passwd -l "$NEW_USER" &>/dev/null   # verrouille le mot de passe (équivalent de --disabled-password)
    fi
    show_success "✅ Utilisateur $NEW_USER créé."
else
    show_warn "L'utilisateur $NEW_USER existe déjà."
fi

# Ajouter au groupe sudo/wheel selon la distribution
usermod -aG "$SUDO_GROUP" "$NEW_USER"

register_action "sudoers"
if is_yes "$SUDO_NOPASSWD"; then
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
else
    echo "$NEW_USER ALL=(ALL) ALL" > "/etc/sudoers.d/$NEW_USER"
fi
chmod 0440 "/etc/sudoers.d/$NEW_USER"
if ! visudo -cf "/etc/sudoers.d/$NEW_USER" &>/dev/null; then
    show_error "Fichier sudoers généré invalide, suppression par sécurité."
    rm -f "/etc/sudoers.d/$NEW_USER"
    exit 1
fi
show_success "✅ Ajout de $NEW_USER aux sudoers ($([[ $(is_yes "$SUDO_NOPASSWD"; echo $?) -eq 0 ]] && echo 'sans' || echo 'avec') mot de passe)."

# === 2. Configuration des clés SSH ===
show_info "🔑 Configuration des clés SSH..."

SSH_DIR="/home/$NEW_USER/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

if [[ -n "$USER_PUBKEY" ]]; then
    if ! grep -qF "$USER_PUBKEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "$USER_PUBKEY" >> "$SSH_DIR/authorized_keys"
    fi
    show_success "✅ Votre clé publique a été installée pour $NEW_USER."
else
    if [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$TIMESTAMP" &>/dev/null
        show_success "✅ Clé SSH ED25519 générée sur le serveur."
    fi
    if ! grep -qF "$(cat "$SSH_DIR/id_ed25519.pub")" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        cat "$SSH_DIR/id_ed25519.pub" >> "$SSH_DIR/authorized_keys"
    fi
fi

chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"
show_success "✅ authorized_keys configuré pour $NEW_USER."

# === 3. Sécurisation du service SSH ===
show_info "🔧 Sécurisation du service SSH..."
register_action "ssh"

# On sauvegarde et corrige le fichier principal...
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_${TIMESTAMP}"
SSHD_TOUCHED_FILES+=("$SSHD_CONFIG")

# ...ET tout drop-in dans sshd_config.d (ex: 50-cloud-init.conf sur les images Ubuntu cloud
# force souvent "PasswordAuthentication yes" et écraserait silencieusement notre changement,
# car ces fichiers sont inclus AVANT la suite du fichier principal).
if [[ -d "$SSHD_CONFIG_D" ]]; then
    while IFS= read -r -d '' dropin; do
        if grep -qE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|Port|ChallengeResponseAuthentication|KbdInteractiveAuthentication)\b' "$dropin"; then
            cp "$dropin" "${dropin}.bak_${TIMESTAMP}"
            SSHD_TOUCHED_FILES+=("$dropin")
        fi
    done < <(find "$SSHD_CONFIG_D" -maxdepth 1 -name '*.conf' -print0 2>/dev/null)
fi

for f in "${SSHD_TOUCHED_FILES[@]}"; do
    set_sshd_option "Port" "$SSH_PORT" "$f"
    set_sshd_option "PermitRootLogin" "no" "$f"
    set_sshd_option "PasswordAuthentication" "no" "$f"
    set_sshd_option "PubkeyAuthentication" "yes" "$f"
    # ChallengeResponseAuthentication est l'ancien nom ; KbdInteractiveAuthentication (>= OpenSSH 8.7)
    # n'est ajusté que s'il est déjà présent dans ce fichier, pour ne pas casser un sshd trop ancien
    # qui ne connaît pas cette directive.
    set_sshd_option "ChallengeResponseAuthentication" "no" "$f"
    if grep -qE '^[[:space:]]*#?[[:space:]]*KbdInteractiveAuthentication\b' "$f"; then
        set_sshd_option "KbdInteractiveAuthentication" "no" "$f"
    fi
done
# NB: on laisse volontairement UsePAM à sa valeur par défaut (yes). Le désactiver casse
# des fonctionnalités PAM utiles (verrouillage de compte, future 2FA, quotas...) sans
# bénéfice de sécurité réel ici.

# Validation de la config AVANT de redémarrer, pour ne jamais restart un sshd cassé.
if ! sshd -t; then
    show_error "La configuration SSH générée est invalide (sshd -t a échoué). Annulation avant redémarrage."
    rollback
fi

manage_service "$SSH_SERVICE" restart
show_success "✅ SSH sécurisé et redémarré."

# === 4. Désactivation de l'IPv6 si demandé ===
if is_yes "$DISABLE_IPV6"; then
    show_info "🌍 Désactivation de IPv6..."
    register_action "ipv6"
    cat > "$IPV6_DROPIN" <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system &>/dev/null
    show_success "✅ IPv6 désactivé."
else
    show_warn "IPv6 reste activé."
fi

# === 5. Limitation du Ping (ICMP Echo Reply) si demandé ===
if is_yes "$LIMIT_ICMP"; then
    show_info "📡 Limitation des réponses aux pings..."
    register_action "icmp"
    cat > "$ICMP_DROPIN" <<EOF
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089
EOF
    sysctl --system &>/dev/null
    show_success "✅ ICMP Echo limité."
else
    show_warn "Réponses ICMP non limitées."
fi

# === 6. Configuration du firewall ===
show_info "🌐 Configuration du firewall $FIREWALL_SERVICE..."
register_action "firewall"

if [[ "$FIREWALL_SERVICE" == "ufw" ]]; then
    if ! command -v ufw &>/dev/null; then
        show_warn "📦 Installation de UFW..."
        INSTALL_CMD ufw
    fi

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        show_warn "Un firewall UFW actif a été détecté. Ses règles vont être écrasées."
        ufw status verbose > "/root/ufw_status_backup_${TIMESTAMP}.txt" 2>/dev/null || true
        show_info "Un instantané des règles actuelles a été sauvegardé dans /root/ufw_status_backup_${TIMESTAMP}.txt (à titre de référence, restauration manuelle si besoin)."
    fi

    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow in on lo &>/dev/null
    ufw allow 80/tcp &>/dev/null
    ufw allow 443/tcp &>/dev/null

    if [[ -n "$ALLOWED_SSH_IPS" ]]; then
        show_info "🔒 Restriction SSH : Seules les IPs/réseaux suivants sont autorisés : $ALLOWED_SSH_IPS"
        for IP in $ALLOWED_SSH_IPS; do
            ufw allow from "$IP" to any port "$SSH_PORT" proto tcp &>/dev/null
        done
    else
        show_warn "SSH ouvert à tous sur le port $SSH_PORT (aucune IP de restriction fournie)."
        ufw allow "$SSH_PORT"/tcp &>/dev/null
    fi

    ufw deny 22/tcp &>/dev/null
    ufw --force enable &>/dev/null

elif [[ "$FIREWALL_SERVICE" == "firewalld" ]]; then
    if ! command -v firewall-cmd &>/dev/null; then
        show_warn "📦 Installation de firewalld..."
        INSTALL_CMD firewalld
    fi
    manage_service firewalld enable
    manage_service firewalld start

    firewall-cmd --set-default-zone=drop &>/dev/null
    firewall-cmd --permanent --zone=trusted --add-interface=lo &>/dev/null

    firewall-cmd --permanent --zone=public --add-service=http &>/dev/null
    firewall-cmd --permanent --zone=public --add-service=https &>/dev/null

    if [[ -n "$ALLOWED_SSH_IPS" ]]; then
        show_info "🔒 Restriction SSH : Seules les IPs/réseaux suivants sont autorisés : $ALLOWED_SSH_IPS"
        for IP in $ALLOWED_SSH_IPS; do
            firewall-cmd --permanent --zone=trusted --add-rich-rule="rule family='ipv4' source address='$IP' port protocol='tcp' port='$SSH_PORT' accept" &>/dev/null
        done
    else
        show_warn "SSH ouvert à tous sur le port $SSH_PORT (aucune IP de restriction fournie)."
        firewall-cmd --permanent --zone=public --add-port="$SSH_PORT"/tcp &>/dev/null
    fi

    firewall-cmd --permanent --zone=public --remove-service=ssh &>/dev/null || true
    firewall-cmd --permanent --zone=public --remove-port=22/tcp &>/dev/null || true

    firewall-cmd --reload &>/dev/null
fi

show_success "✅ Firewall activé avec règles sécurisées."

# === 7. Installation et configuration de Fail2Ban ===
show_info "🛡️ Installation et configuration de Fail2Ban..."
register_action "fail2ban"

if ! command -v fail2ban-client &>/dev/null; then
    INSTALL_CMD fail2ban
fi

# Le chemin de log SSH diffère selon la distribution ; si aucun des deux fichiers connus
# n'existe (cas fréquent sur les images cloud minimalistes journald-only), on utilise le
# backend systemd de fail2ban plutôt qu'un logpath qui ferait tourner fail2ban sans jamais
# bannir personne.
F2B_BACKEND_LINE=""
if [[ -f /var/log/auth.log ]]; then
    F2B_LOGPATH_LINE="logpath = /var/log/auth.log"
elif [[ -f /var/log/secure ]]; then
    F2B_LOGPATH_LINE="logpath = /var/log/secure"
else
    F2B_LOGPATH_LINE=""
    F2B_BACKEND_LINE="backend = systemd"
fi

cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
${F2B_LOGPATH_LINE}
${F2B_BACKEND_LINE}
maxretry = 5
bantime = 1h
findtime = 10m
EOF

manage_service fail2ban restart
manage_service fail2ban enable

show_success "✅ Fail2Ban configuré pour SSH."

# Vérifier si le service SSH écoute bien sur le bon port
sleep 2

if check_ssh_port "$SSH_PORT"; then
    show_success "✅ SSH fonctionne sur le port $SSH_PORT"
else
    show_warn "Le service SSH ne semble pas actif sur le bon port. Redémarrage forcé..."
    manage_service "$SSH_SERVICE" restart
    sleep 2
    if check_ssh_port "$SSH_PORT"; then
        show_success "✅ SSH est maintenant actif sur le port $SSH_PORT"
    else
        show_error "SSH ne répond toujours pas ! Vérifiez $SSHD_CONFIG et les logs avec journalctl -xe."
        rollback
    fi
fi

# Désactive le trap ERR pour la suite : on gère nous-mêmes la confirmation finale.
trap - ERR

echo
show_info "----------------------------------------"
if [[ -z "$USER_PUBKEY" ]]; then
    show_warn "Une clé privée a été générée sur le serveur : $SSH_DIR/id_ed25519"
    show_warn "Récupérez-la IMMÉDIATEMENT depuis votre machine locale, puis supprimez-la du serveur :"
    show_secondary "  scp -P $SSH_PORT $NEW_USER@<VOTRE_IP>:$SSH_DIR/id_ed25519 ~/.ssh/vps_key"
    show_secondary "  ssh -p $SSH_PORT -i ~/.ssh/vps_key $NEW_USER@<VOTRE_IP> 'shred -u ~/.ssh/id_ed25519'"
    show_warn "Ne partagez jamais cette clé. Si vous préférez l'afficher directement ici (déconseillé, reste dans le scrollback/logs du terminal) :"
    SHOW_KEY=$(prompt_user "Afficher la clé privée à l'écran maintenant ?" "non" "validate_yes_no")
    if is_yes "$SHOW_KEY"; then
        show_info "----------------------------------------"
        cat "$SSH_DIR/id_ed25519"
        show_info "----------------------------------------"
    fi
fi

show_success "🎉 Sécurisation terminée !"
show_warn "NE FERMEZ PAS CETTE SESSION SSH avant d'avoir vérifié la nouvelle connexion depuis une AUTRE machine/fenêtre :"
show_secondary "➡ ssh -p $SSH_PORT $NEW_USER@<VOTRE_IP>"
show_info "Si la connexion fonctionne, vous pouvez fermer cette session."

# === Vérification finale ===
show_info "\n----------------------------------------"
CONFIRM=$(prompt_user "Tout fonctionne bien depuis une autre connexion ? (oui/non)" "non" "validate_yes_no")

if ! is_yes "$CONFIRM"; then
    trap 'rollback' ERR
    rollback
else
    show_success "✅ Sécurisation validée !"
fi

# ==============================================================================
# Résumé des correctifs apportés par rapport au script original :
#
# Fiabilité / anti-lockout :
#   - Validation "sshd -t" avant tout redémarrage de sshd (évite de restart une config cassée).
#   - set_sshd_option() remplace les sed fragiles qui ne matchaient que les lignes commentées :
#     applique désormais la valeur que la ligne soit commentée, déjà définie, ou absente.
#   - Détection et correction des drop-ins /etc/ssh/sshd_config.d/*.conf (ex: 50-cloud-init.conf
#     sur Ubuntu cloud, qui force PasswordAuthentication yes après le fichier principal).
#   - register_action() appelé AVANT chaque action risquée (et non après), pour que le rollback
#     fonctionne même si l'action échoue en cours de route.
#   - rollback() parcourt les actions dans l'ordre INVERSE (on rouvre le firewall avant de remettre
#     l'ancien port SSH), pour éviter une fenêtre de blocage pendant l'annulation.
#   - trap ERR désarmé au début de rollback() pour éviter une boucle de rollback récursif.
#   - manage_service() propage désormais le vrai code de retour (avant : toujours "succès").
#
# Portabilité multi-distro :
#   - Création d'utilisateur adaptée (adduser Debian-only vs useradd+passwd -l ailleurs).
#   - Groupe sudo/wheel détecté selon la distribution (usermod -aG sudo cassait sur RHEL-like).
#   - Regex de distribution corrigée pour matcher "almalinux" (et pas seulement "alma").
#   - fail2ban : logpath adapté (auth.log vs secure) ou passage en backend systemd si aucun
#     fichier de log classique n'existe (image cloud minimaliste).
#   - Vérification/installation de "sudo" s'il est absent.
#
# Sécurité :
#   - Plus d'affichage systématique de la clé privée en clair : option de fournir sa propre
#     clé publique (recommandé), sinon affichage seulement sur confirmation explicite, avec
#     commande scp fournie pour récupérer la clé proprement.
#   - sudo NOPASSWD n'est plus la valeur imposée par défaut ; demandé explicitement, avec
#     validation du fichier sudoers via "visudo -cf" et permissions 0440.
#   - UsePAM n'est plus désactivé (cassait 2FA/PAM sans bénéfice de sécurité réel).
#   - IPv6/ICMP gérés via des fichiers de dépôt /etc/sysctl.d/ dédiés (idempotents, rollback =
#     suppression du fichier) plutôt que des "echo >>" cumulatifs dans sysctl.conf.
#   - Sauvegarde des règles UFW existantes avant "reset" si un firewall était déjà actif.
#   - Pas de doublons dans authorized_keys en cas de ré-exécution du script.
#
# Validation :
#   - validate_port/is_port_in_use corrigés (ancrage regex ":$port" -> évite les faux positifs
#     du type port 22 matchant aussi 2222).
#   - validate_yes_no unifié et insensible à la casse (oui/non/o/y/yes/no acceptés partout).
#   - validate_ip vérifie désormais que chaque octet est bien entre 0 et 255.
# ==============================================================================
