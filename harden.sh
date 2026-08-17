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
#   (Debian/Ubuntu, RHEL/CentOS/Rocky/AlmaLinux/Fedora, Arch), mode
#   non-interactif scriptable et mode --dry-run. Historique des versions
#   dans CHANGELOG.md, guide complet dans docs/TUTORIEL.md.
#
#   Usage : sudo ./harden.sh [options]   (voir --help)
# ============================================================================

# Nom volontairement distinct de "VERSION" : /etc/os-release définit LUI-MÊME une
# variable VERSION (ex: "24.04.4 LTS (Noble Numbat)" sur Ubuntu), et ce script fait
# ". /etc/os-release" plus loin pour lire $ID -- ce qui écraserait silencieusement notre
# propre numéro de version si on utilisait le même nom (bug réel constaté : la bannière et
# --help affichaient la version d'Ubuntu au lieu de celle du script).
TOOLKIT_VERSION="1.3.1"

set -e  # Arrête le script en cas d'erreur (voir gestion du trap ERR plus bas)
set -u  # Erreur si variable non définie utilisée
set -o pipefail
set -o errtrace  # CRITIQUE : sans ça, le trap ERR (rollback) ne se déclenche PAS pour une
                 # erreur survenant à l'intérieur d'une fonction (ex: manage_service) - le
                 # script mourrait alors brutalement avec le code d'erreur brut, sans jamais
                 # passer par le rollback censé éviter de rester bloqué dehors.

# === Déclaration des variables ===
ACTIONS_DONE=()  # Liste des actions effectuées, dans l'ORDRE d'exécution (le rollback les rejoue à l'envers)
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S") # Timestamp unique pour les fichiers de backup
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
SYSCTL_DROPIN_DIR="/etc/sysctl.d"
IPV6_DROPIN="$SYSCTL_DROPIN_DIR/90-vps-hardening-ipv6.conf"
ICMP_DROPIN="$SYSCTL_DROPIN_DIR/90-vps-hardening-icmp.conf"
SSHD_TOUCHED_FILES=()  # Tous les fichiers sshd_config* concernés (pour backup/rollback)
LOG_FILE="/var/log/vps-hardening-toolkit.log"

# CLI / modes d'exécution (voir usage() plus bas)
DRY_RUN=false
NON_INTERACTIVE=false
ARG_USER=""
ARG_SSH_PORT=""
ARG_ALLOWED_IPS=""
ARG_PUBKEY=""
ARG_DISABLE_IPV6=""
ARG_LIMIT_ICMP=""
ARG_SUDO_NOPASSWD=""

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

dry_log() {
    echo -e "${CYAN}[DRY-RUN]${NC} $1"
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

# En mode --non-interactive : utilise la valeur passée en argument (ou le défaut) sans
# jamais lire sur stdin, et échoue proprement si la validation ne passe pas.
# En mode interactif normal : une valeur passée en argument devient simplement la valeur
# par défaut proposée dans le prompt (qu'on peut toujours changer en répondant).
resolve_value() {
    local arg_value="$1" prompt_text="$2" default_value="$3" validate_func="$4" val
    if $NON_INTERACTIVE; then
        val="${arg_value:-$default_value}"
        if [[ -n "$validate_func" ]]; then
            "$validate_func" "$val" || exit 1
        fi
        echo "$val"
    else
        prompt_user "$prompt_text" "${arg_value:-$default_value}" "$validate_func"
    fi
}

usage() {
    cat <<USAGE
vps-hardening-toolkit v${TOOLKIT_VERSION} - harden.sh
https://github.com/x0u7s1d3r/vps-hardening-toolkit

Usage : sudo ./harden.sh [options]

Options :
  --user NOM                   Nom de l'utilisateur à créer (défaut : secureuser)
  --ssh-port PORT               Port SSH à utiliser (défaut : port aléatoire libre >= 10000)
  --allowed-ips "IP1 IP2"       IPs/CIDR autorisées pour SSH, séparées par des espaces (défaut : aucune restriction)
  --pubkey "ssh-ed25519 ..."    Clé publique SSH à installer (défaut : en génère une sur le serveur)
  --disable-ipv6 oui|non        Désactiver IPv6 (défaut : oui)
  --limit-icmp oui|non          Limiter les réponses ICMP (défaut : oui)
  --sudo-nopasswd oui|non       Sudo sans mot de passe pour le nouvel utilisateur (défaut : non)
  --non-interactive              Ne pose aucune question, utilise les valeurs ci-dessus ou les défauts
  --dry-run                      N'applique aucun changement, affiche ce qui serait fait
  -h, --help                     Affiche cette aide

Exemples :
  sudo ./harden.sh
      Mode interactif classique (questions à chaque étape).

  sudo ./harden.sh --dry-run
      Prévisualise les changements sans rien appliquer.

  sudo ./harden.sh --non-interactive --user deploy --ssh-port 2222 --pubkey "\$(cat ~/.ssh/id_ed25519.pub)"
      Exécution entièrement automatisée, utilisable en CI ou dans un script d'infra.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) ARG_USER="${2:-}"; shift 2 ;;
        --ssh-port) ARG_SSH_PORT="${2:-}"; shift 2 ;;
        --allowed-ips) ARG_ALLOWED_IPS="${2:-}"; shift 2 ;;
        --pubkey) ARG_PUBKEY="${2:-}"; shift 2 ;;
        --disable-ipv6) ARG_DISABLE_IPV6="${2:-}"; shift 2 ;;
        --limit-icmp) ARG_LIMIT_ICMP="${2:-}"; shift 2 ;;
        --sudo-nopasswd) ARG_SUDO_NOPASSWD="${2:-}"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) show_error "Option inconnue : $1"; usage; exit 1 ;;
    esac
done

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
        # Exception : si ce port est déjà le port SSH actuellement configuré (relance du
        # script sur un serveur déjà durci, avec le même port), ce n'est pas un conflit.
        if is_port_in_use "$port" && [[ "$port" != "${CURRENT_SSH_PORT:-}" ]]; then
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

    if command -v systemctl &>/dev/null && timeout 10 systemctl list-units --full -all 2>/dev/null | grep -q "${service_name}\.service"; then
        # "timeout 30" : filet de sécurité si systemctl reste bloqué (bus systemd
        # injoignable, environnement conteneurisé sans init réel...) plutôt que de
        # bloquer le script indéfiniment sur un simple restart/enable de service.
        timeout 30 systemctl "$action" "$service_name" &>/dev/null
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

# Sur RHEL/CentOS/Rocky/AlmaLinux/Fedora, SELinux est actif (Enforcing) par défaut, et sshd
# tourne confiné dans le domaine sshd_t, qui ne peut se binder QUE sur les ports étiquetés
# ssh_port_t (22 par défaut). Changer le port dans sshd_config sans étiqueter le nouveau
# port empêche sshd de démarrer dessus ("Bind to port ... failed: Permission denied"), ce
# qui va à l'encontre même du but du script sur ces distributions. No-op silencieux si
# SELinux est absent/désactivé (Debian/Ubuntu, Arch, ou RHEL avec SELinux désactivé).
configure_selinux_ssh_port() {
    if ! command -v getenforce &>/dev/null; then
        return 0
    fi
    local se_status
    se_status=$(getenforce 2>/dev/null || echo "Disabled")
    if [[ "$se_status" == "Disabled" ]]; then
        return 0
    fi

    if ! command -v semanage &>/dev/null; then
        show_info "📦 Installation de policycoreutils-python-utils (nécessaire pour étiqueter le port SSH sous SELinux)..."
        INSTALL_CMD policycoreutils-python-utils
    fi
    if ! command -v semanage &>/dev/null; then
        show_warn "semanage indisponible même après installation : le port $SSH_PORT n'a pas pu être étiqueté pour SELinux. Si SELinux est en mode 'Enforcing', sshd risque de ne pas démarrer sur ce port (voir : semanage port -a -t ssh_port_t -p tcp $SSH_PORT)."
        return 0
    fi

    if semanage port -l 2>/dev/null | grep -qE "^ssh_port_t[[:space:]]+tcp[[:space:]].*(,|[[:space:]])${SSH_PORT}(,|\$)"; then
        show_info "Port $SSH_PORT déjà étiqueté ssh_port_t (SELinux) : rien à faire."
        return 0
    fi

    if semanage port -l 2>/dev/null | grep -qE "tcp[[:space:]].*(,|[[:space:]])${SSH_PORT}(,|\$)"; then
        show_warn "Le port $SSH_PORT est déjà étiqueté SELinux pour un AUTRE service : sshd risque de ne pas pouvoir y écouter. Choisissez un autre port SSH si possible."
        return 0
    fi

    register_action "selinux_port"
    if semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null; then
        show_success "✅ Port $SSH_PORT étiqueté ssh_port_t pour SELinux ($se_status)."
    else
        show_warn "Échec de l'étiquetage SELinux du port $SSH_PORT (semanage port -a). sshd risque de ne pas démarrer si SELinux est en mode 'Enforcing'."
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
            "selinux_port")
                command -v semanage &>/dev/null && semanage port -d -t ssh_port_t -p tcp "$SSH_PORT" &>/dev/null
                show_success "✅ Étiquette SELinux du port SSH retirée."
                ;;
            "sudoers")
                rm -f "/etc/sudoers.d/$NEW_USER"
                show_success "✅ Entrée sudoers retirée."
                ;;
        esac
    done
    # "${NEW_USER:-}" (et non "$NEW_USER") : rollback() peut être déclenché par une
    # erreur survenue AVANT que NEW_USER ne soit défini (ex: précheck, détection de
    # distribution/service). rollback() est le filet de sécurité du script : il ne doit
    # jamais planter lui-même, quelle que soit la précocité de l'erreur d'origine -- avec
    # "set -u" actif, référencer une variable non définie ici ferait planter le rollback
    # au moment même où on en a le plus besoin (bug réel constaté sur ce projet).
    if [[ -n "${NEW_USER:-}" ]]; then
        show_success "✅ Rollback terminé. L'utilisateur '$NEW_USER' et sa clé SSH ne sont pas supprimés automatiquement (au cas où) : supprimez-les manuellement avec 'deluser $NEW_USER' si besoin."
    else
        show_success "✅ Rollback terminé (l'erreur est survenue avant la création de l'utilisateur : rien à nettoyer de ce côté)."
    fi
    exit 1
}

# Active le rollback en cas d'échec
trap 'rollback' ERR


# === Precheck ===

if [[ $EUID -ne 0 ]]; then
   show_error "Ce script doit être exécuté en tant que root ou avec sudo."
   exit 1
fi

# Journalisation complète de la sortie dans un fichier, en plus de l'affichage à l'écran
# (best-effort : si /var/log n'est pas inscriptible, on continue sans logguer dans un fichier).
if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    show_info "Journal complet de cette exécution : $LOG_FILE"
else
    show_warn "Impossible d'écrire dans $LOG_FILE : pas de journalisation fichier pour cette exécution."
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
        # DEBIAN_FRONTEND=noninteractive + NEEDRESTART_MODE=a : sur Ubuntu 22.04+/24.04, le
        # paquet needrestart peut afficher une invite interactive ("quels services
        # redémarrer ?") qui bloque indéfiniment un script non-interactif (CI, VPS distant
        # sans TTY). Ces deux variables la neutralisent.
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt update -qq && \
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y "$@" &>/dev/null
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
    if $DRY_RUN; then
        dry_log "aurait installé le paquet 'sudo' (absent)."
    else
        show_warn "sudo n'est pas installé, installation en cours..."
        INSTALL_CMD sudo
    fi
fi

# Un fichier d'unité systemd peut se trouver à plusieurs emplacements standards selon la
# distribution (paquet système vs unité locale). On vérifie les trois pour éviter un faux
# négatif.
unit_file_exists() {
    local unit="$1"
    [[ -f "/lib/systemd/system/$unit" || -f "/usr/lib/systemd/system/$unit" || -f "/etc/systemd/system/$unit" ]]
}

if command -v systemctl &>/dev/null; then
    # "systemctl list-unit-files" liste tous les fichiers d'unité connus de systemd,
    # indépendamment de leur état d'exécution au moment précis de l'appel. C'est plus
    # fiable que de parser "list-units" (dont le format de sortie et le "LOAD state"
    # peuvent varier juste après une installation/activation selon le système). En
    # complément, on vérifie aussi directement la présence du fichier d'unité sur le
    # disque, au cas où systemctl se comporterait différemment sur une distribution donnée.
    # "timeout 10" : sur un système sans bus systemd joignable (conteneur sans init réel,
    # par exemple les jobs CI RHEL/Arch qui tournent dans un simple conteneur Docker),
    # systemctl échoue normalement très vite ("Failed to connect to bus"), mais on se
    # protège quand même d'un blocage éventuel plutôt que de dépendre uniquement de ce
    # comportement. Le fallback unit_file_exists() (lecture directe sur disque) ne dépend
    # lui d'aucun bus et fonctionne dans tous les cas.
    if timeout 10 systemctl list-unit-files --type=service 2>/dev/null | grep -qE '^ssh\.service\b' || unit_file_exists "ssh.service"; then
        SSH_SERVICE="ssh"
    elif timeout 10 systemctl list-unit-files --type=service 2>/dev/null | grep -qE '^sshd\.service\b' || unit_file_exists "sshd.service"; then
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

# Port SSH actuellement configuré (si le script a déjà tourné une fois, ou si sshd est
# déjà configuré par ailleurs). Sert uniquement à ne pas rejeter à tort, dans
# validate_port(), le port qu'on s'apprête à reconfigurer : sans ça, relancer le script
# une seconde fois avec le même --ssh-port échoue toujours, car ce port est déjà "in use"
# par... le sshd que le script lui-même a configuré au tour précédent.
# "|| true" : "sshd -T" échoue (code 1, "no hostkeys available") tant qu'aucune clé
# d'hôte SSH n'a encore été générée -- le cas sur une image/conteneur tout juste
# installé où le générateur de clés n'a jamais tourné (pas de service init réel). Sans
# ce garde-fou, "set -e"/pipefail feraient échouer le script ici même, AVANT que
# NEW_USER ne soit défini -- ce qui ferait planter rollback() lui-même (cf. plus bas).
# Un échec ici signifie simplement "aucun port SSH actuel connu", ce qui est le
# comportement de repli correct.
CURRENT_SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}') || true

# === Collecte des informations ===
if [[ -t 1 ]]; then
    clear
fi
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
show_info "  vps-hardening-toolkit v${TOOLKIT_VERSION}, par x0u7s1d3r"
show_info "  https://github.com/x0u7s1d3r/vps-hardening-toolkit"
echo
echo -e "${GREEN}🌟 Configuration du serveur 🌟${NC}"
if $DRY_RUN; then
    show_warn "MODE DRY-RUN : aucune modification ne sera appliquée au système."
fi
if $NON_INTERACTIVE; then
    show_info "Mode non-interactif : valeurs fournies en argument (ou défauts) utilisées sans confirmation."
fi

NEW_USER=$(resolve_value "$ARG_USER" "Quel nom souhaitez-vous pour l'utilisateur sécurisé SSH ?" "secureuser" "validate_username")
RANDOM_SSH_PORT=$(generate_random_port)
SSH_PORT=$(resolve_value "$ARG_SSH_PORT" "Quel port souhaitez-vous pour SSH ?" "$RANDOM_SSH_PORT" "validate_port")
if ! $NON_INTERACTIVE; then
    show_secondary "(Laissez vide pour autoriser SSH depuis n'importe quelle IP - déconseillé)"
fi
ALLOWED_SSH_IPS=$(resolve_value "$ARG_ALLOWED_IPS" "Entrez les IPs ou CIDR autorisés pour SSH (séparées par des espaces)" "" "validate_ips_list")
DISABLE_IPV6=$(resolve_value "$ARG_DISABLE_IPV6" "Voulez-vous désactiver IPv6 ?" "oui" "validate_yes_no")
LIMIT_ICMP=$(resolve_value "$ARG_LIMIT_ICMP" "Voulez-vous limiter les réponses ICMP (Ping) ?" "oui" "validate_yes_no")
SUDO_NOPASSWD=$(resolve_value "$ARG_SUDO_NOPASSWD" "Autoriser $NEW_USER à utiliser sudo SANS mot de passe ? (déconseillé)" "non" "validate_yes_no")

if [[ -n "$ARG_PUBKEY" ]]; then
    validate_pubkey "$ARG_PUBKEY" || exit 1
    USER_PUBKEY="$ARG_PUBKEY"
elif $NON_INTERACTIVE; then
    USER_PUBKEY=""
    show_warn "Mode non-interactif sans --pubkey : une paire de clés sera générée sur le serveur."
else
    show_secondary "Avez-vous déjà une paire de clés SSH et voulez-vous fournir votre clé PUBLIQUE (recommandé, plus sûr que de générer la clé sur le serveur) ?"
    HAS_OWN_KEY=$(prompt_user "Fournir ma propre clé publique ?" "oui" "validate_yes_no")
    if is_yes "$HAS_OWN_KEY"; then
        USER_PUBKEY=$(prompt_user "Collez votre clé publique (ssh-ed25519 AAAA...)" "" "validate_pubkey")
    else
        USER_PUBKEY=""
        show_warn "Une paire de clés sera générée sur le serveur. La clé privée ne sera PAS affichée à l'écran par défaut : le script vous donnera la commande scp pour la récupérer."
    fi
fi

show_success "🔒 Début de la sécurisation du serveur VPS..."
if $DRY_RUN; then
    show_warn "(dry-run : les étapes ci-dessous décrivent ce qui SERAIT fait, rien n'est modifié)"
fi

# === 1. Création du nouvel utilisateur ===
show_info "👤 Utilisateur SSH : $NEW_USER"
if $DRY_RUN; then
    dry_log "aurait créé l'utilisateur '$NEW_USER' (groupe $SUDO_GROUP) si absent, mot de passe désactivé."
    dry_log "aurait ajouté /etc/sudoers.d/$NEW_USER, sudo $(is_yes "$SUDO_NOPASSWD" && echo 'SANS' || echo 'AVEC') mot de passe."
else
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
    show_success "✅ Ajout de $NEW_USER aux sudoers ($(is_yes "$SUDO_NOPASSWD" && echo 'sans' || echo 'avec') mot de passe)."
fi

# === 2. Configuration des clés SSH ===
show_info "🔑 Configuration des clés SSH..."
SSH_DIR="/home/$NEW_USER/.ssh"

if $DRY_RUN; then
    if [[ -n "$USER_PUBKEY" ]]; then
        dry_log "aurait installé votre clé publique fournie dans $SSH_DIR/authorized_keys."
    else
        dry_log "aurait généré une nouvelle paire de clés ed25519 dans $SSH_DIR/ et installé la clé publique dans authorized_keys."
    fi
else
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
fi

# === 3. Sécurisation du service SSH ===
show_info "🔧 Sécurisation du service SSH..."

# Détection des fichiers concernés (lecture seule, effectuée même en dry-run) : le fichier
# principal, PLUS tout drop-in dans sshd_config.d (ex: 50-cloud-init.conf sur les images
# Ubuntu cloud force souvent "PasswordAuthentication yes" et écraserait silencieusement notre
# changement, car ces fichiers sont inclus AVANT la suite du fichier principal).
SSHD_TOUCHED_FILES=("$SSHD_CONFIG")
if [[ -d "$SSHD_CONFIG_D" ]]; then
    while IFS= read -r -d '' dropin; do
        if grep -qE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|Port|ChallengeResponseAuthentication|KbdInteractiveAuthentication)\b' "$dropin"; then
            SSHD_TOUCHED_FILES+=("$dropin")
        fi
    done < <(find "$SSHD_CONFIG_D" -maxdepth 1 -name '*.conf' -print0 2>/dev/null)
fi

if $DRY_RUN; then
    dry_log "aurait appliqué Port $SSH_PORT, PermitRootLogin no, PasswordAuthentication no, PubkeyAuthentication yes dans :"
    for f in "${SSHD_TOUCHED_FILES[@]}"; do
        dry_log "  - $f"
    done
    dry_log "aurait étiqueté le port $SSH_PORT pour SELinux si la distribution l'utilise (RHEL-like en mode Enforcing/Permissive)."
    dry_log "aurait validé avec 'sshd -t' puis redémarré $SSH_SERVICE."
else
    register_action "ssh"
    for f in "${SSHD_TOUCHED_FILES[@]}"; do
        cp "$f" "${f}.bak_${TIMESTAMP}"
    done

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

    # Étiquetage SELinux du port (no-op si SELinux absent/désactivé) : DOIT être fait avant
    # le redémarrage de sshd ci-dessous, sinon sshd refuse de se binder sur le nouveau port
    # tant que SELinux est en mode Enforcing (RHEL/CentOS/Rocky/AlmaLinux/Fedora).
    configure_selinux_ssh_port

    # Validation de la config AVANT de redémarrer, pour ne jamais restart un sshd cassé.
    if ! sshd -t; then
        show_error "La configuration SSH générée est invalide (sshd -t a échoué). Annulation avant redémarrage."
        rollback
    fi

    manage_service "$SSH_SERVICE" restart
    show_success "✅ SSH sécurisé et redémarré."
fi

# === 4. Désactivation de l'IPv6 si demandé ===
if is_yes "$DISABLE_IPV6"; then
    show_info "🌍 IPv6"
    if $DRY_RUN; then
        dry_log "aurait désactivé IPv6 via $IPV6_DROPIN"
    else
        register_action "ipv6"
        cat > "$IPV6_DROPIN" <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl --system &>/dev/null
        show_success "✅ IPv6 désactivé."
    fi
else
    show_warn "IPv6 reste activé."
fi

# === 5. Limitation du Ping (ICMP Echo Reply) si demandé ===
if is_yes "$LIMIT_ICMP"; then
    show_info "📡 ICMP"
    if $DRY_RUN; then
        dry_log "aurait limité les réponses ICMP via $ICMP_DROPIN"
    else
        register_action "icmp"
        cat > "$ICMP_DROPIN" <<EOF
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089
EOF
        sysctl --system &>/dev/null
        show_success "✅ ICMP Echo limité."
    fi
else
    show_warn "Réponses ICMP non limitées."
fi

# === 6. Configuration du firewall ===
show_info "🌐 Firewall ($FIREWALL_SERVICE)"

if $DRY_RUN; then
    if [[ -n "$ALLOWED_SSH_IPS" ]]; then
        dry_log "aurait configuré $FIREWALL_SERVICE : tout bloqué en entrée par défaut, 80/443 ouverts, SSH sur $SSH_PORT restreint à : $ALLOWED_SSH_IPS, port 22 bloqué."
    else
        dry_log "aurait configuré $FIREWALL_SERVICE : tout bloqué en entrée par défaut, 80/443 ouverts, SSH sur $SSH_PORT ouvert à toutes les IPs, port 22 bloqué."
    fi
else
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
fi

# === 7. Installation et configuration de Fail2Ban ===
show_info "🛡️ Fail2Ban"

if $DRY_RUN; then
    dry_log "aurait installé/configuré fail2ban pour surveiller SSH sur le port $SSH_PORT (ban 1h après 5 échecs en 10 min)."
else
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

    # Non bloquant volontairement : fail2ban est une couche de protection supplémentaire,
    # pas le mécanisme SSH lui-même. Un souci ici ne doit pas annuler tout le durcissement
    # SSH/firewall déjà appliqué et fonctionnel (le "||" empêche que ça déclenche le rollback).
    manage_service fail2ban restart || show_warn "Le redémarrage de fail2ban a échoué, vérifiez manuellement : systemctl status fail2ban"
    manage_service fail2ban enable || show_warn "L'activation au démarrage de fail2ban a échoué, vérifiez manuellement : systemctl status fail2ban"

    show_success "✅ Fail2Ban configuré pour SSH."
fi

# === Fin de la simulation en mode dry-run : rien n'a été modifié, pas de vérification à faire ===
if $DRY_RUN; then
    echo
    show_info "----------------------------------------"
    show_success "🔎 Dry-run terminé : aucun changement n'a été appliqué au système."
    show_info "Relancez sans --dry-run (avec --non-interactive si besoin) pour appliquer ces changements pour de vrai."
    exit 0
fi

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
    if $NON_INTERACTIVE; then
        show_info "Mode non-interactif : la clé privée n'est pas affichée automatiquement (récupérez-la via scp ci-dessus)."
    else
        show_warn "Ne partagez jamais cette clé. Si vous préférez l'afficher directement ici (déconseillé, reste dans le scrollback/logs du terminal) :"
        SHOW_KEY=$(prompt_user "Afficher la clé privée à l'écran maintenant ?" "non" "validate_yes_no")
        if is_yes "$SHOW_KEY"; then
            show_info "----------------------------------------"
            cat "$SSH_DIR/id_ed25519"
            show_info "----------------------------------------"
        fi
    fi
fi

show_success "🎉 Sécurisation terminée !"
show_warn "NE FERMEZ PAS CETTE SESSION SSH avant d'avoir vérifié la nouvelle connexion depuis une AUTRE machine/fenêtre :"
show_secondary "➡ ssh -p $SSH_PORT $NEW_USER@<VOTRE_IP>"
show_info "Si la connexion fonctionne, vous pouvez fermer cette session."

# === Vérification finale ===
if $NON_INTERACTIVE; then
    show_success "✅ Mode non-interactif : sécurisation appliquée et vérifiée automatiquement (SSH répond sur le port $SSH_PORT)."
else
    show_info "\n----------------------------------------"
    CONFIRM=$(prompt_user "Tout fonctionne bien depuis une autre connexion ? (oui/non)" "non" "validate_yes_no")

    if ! is_yes "$CONFIRM"; then
        trap 'rollback' ERR
        rollback
    else
        show_success "✅ Sécurisation validée !"
    fi
fi

# ==============================================================================
# Historique détaillé des versions : voir CHANGELOG.md
# Guide d'utilisation complet (durcissement + hébergement d'un site) : docs/TUTORIEL.md
# ==============================================================================
