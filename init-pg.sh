#!/bin/bash
set -e

echo "========================================="
echo "Installation de PostgreSQL 18 sur Debian 13"
echo "========================================="

echo "1. Mise à jour du système..."
apt-get update
apt-get install -y \
    curl \
    gnupg \
    lsb-release \
    ca-certificates \
    nano \
    gosu \
    openssh-server \
    rsync \
    sudo \
    locales

# Générer les locales nécessaires
echo "Génération des locales..."

# S'assurer que locales est installé
apt-get update && apt-get install -y locales

# Décommenter les locales dans /etc/locale.gen
sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^# fr_FR.UTF-8/fr_FR.UTF-8/' /etc/locale.gen

# Générer les locales
locale-gen

# Définir la locale par défaut
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# rendre executable le script repmgr_standby.sh copier depuis le docker compose
chmod +x /scripts/repmgr_standby.sh
echo "Locales configurées"

chmod +x /scripts/repmgr_standby.sh

echo "2. Ajout du dépôt PostgreSQL (PGDG)..."

install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor \
  > /etc/apt/keyrings/postgresql.gpg

chmod 0644 /etc/apt/keyrings/postgresql.gpg

echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] \
http://apt.postgresql.org/pub/repos/apt \
$(lsb_release -cs)-pgdg main" \
> /etc/apt/sources.list.d/pgdg.list

echo "3. Installation de PostgreSQL 18..."
apt-get update
apt-get install -y \
    postgresql-18 \
    postgresql-client-18 \
    postgresql-contrib-18 \
    repmgr \

echo "3b. Vérification du cluster PostgreSQL..."

if pg_lsclusters | grep -q "^18[[:space:]]\+main"; then
    echo "✓ Cluster 18/main déjà existant"
else
    echo "Création du cluster principal..."
    pg_createcluster 18 main --start
    echo "✓ Cluster créé"
fi

echo "4. Démarrage du service PostgreSQL..."
service postgresql start

echo "5. Attente de la disponibilité du serveur..."
for i in {1..30}; do
    if pg_isready -q; then
        echo "✓ PostgreSQL est prêt"
        break
    fi
    sleep 1
done

echo "6. Récupération du mot de passe PostgreSQL..."
if [ -f "$POSTGRES_PASSWORD_FILE" ]; then
    POSTGRES_PASSWORD=$(cat "$POSTGRES_PASSWORD_FILE")
    echo "✓ Mot de passe chargé depuis $POSTGRES_PASSWORD_FILE"
else
    echo "⚠ Aucun fichier de mot de passe fourni"
    POSTGRES_PASSWORD="postgres"
fi

echo "7. Configuration de .pgpass..."
cat > /var/lib/postgresql/.pgpass <<EOF
*:5432:*:repuser:${POSTGRES_PASSWORD}
*:5432:*:postgres:${POSTGRES_PASSWORD}
EOF

chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

echo "✓ .pgpass configuré"

echo "Configuration des variables PostgreSQL..."
export PGUSER=postgres
export PGDATABASE=postgres

#ajout user postgres en sudoers si le user n'y est pas déjà
echo "ajout user postgres en sudoers"
echo "postgres ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

echo "8. Initialisation logique (rôles / bases)..."

# Définir le mot de passe postgres
gosu postgres psql -v ON_ERROR_STOP=1 <<-EOSQL
ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';
EOSQL

# Création de la base si demandée
if [ -n "${POSTGRES_DB}" ] && [ "${POSTGRES_DB}" != "postgres" ]; then
    gosu postgres psql -v ON_ERROR_STOP=1 <<-EOSQL
        SELECT 'CREATE DATABASE ${POSTGRES_DB}'
        WHERE NOT EXISTS (
            SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}'
        )\gexec
EOSQL
    echo "✓ Base ${POSTGRES_DB} vérifiée"
fi

# Configuration du service SSH
echo "9. Configuration du serveur SSH"
POSTGRES_HOME="/var/lib/postgresql"
SSH_CONFIG="${POSTGRES_HOME}/.ssh/config"

# Création du répertoire .ssh pour postgres s'il n'existe pas déja
if [ ! -d "${POSTGRES_HOME}/.ssh" ]; then
    mkdir -p "${POSTGRES_HOME}/.ssh"
    chown postgres:postgres "${POSTGRES_HOME}/.ssh"
    chmod 700 "${POSTGRES_HOME}/.ssh"
fi

# Génération de la clé SSH
if [ ! -f /var/lib/postgresql/.ssh/id_rsa ]; then
    gosu postgres mkdir -p "${POSTGRES_HOME}/.ssh"
    gosu postgres ssh-keygen -t rsa -b 4096 -f ${POSTGRES_HOME}/.ssh/id_rsa -N ""
    gosu postgres chmod 700 ${POSTGRES_HOME}/.ssh
    gosu postgres chmod 600 ${POSTGRES_HOME}/.ssh/id_rsa
fi

# Configuration SSH permissive pour dev
gosu postgres cat > "$SSH_CONFIG" <<EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    LogLevel ERROR
EOF
chown postgres:postgres "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# copie de la clef sur un répertoire partagé
SHARED_DIR="/shared-keys"
CURRENT_HOSTNAME=$(hostname -f)
if [ ! -d "$SHARED_DIR" ]; then
    mkdir -p "$SHARED_DIR" && chmod 777 "$SHARED_DIR"
fi

cp /var/lib/postgresql/.ssh/id_rsa.pub "$SHARED_DIR/${CURRENT_HOSTNAME}.pub"

# Redémarrer le service SSH (si nécessaire)
if ! service ssh status &> /dev/null; then
    service ssh restart
    echo "Service SSH redémarré."
else
    echo "Service SSH déjà en cours d'exécution."
fi


echo "10. Mise à jour des settings par défaut dans postgresql.conf"
#PG_CONFIG="/etc/postgresql/18/main/postgresql.conf"
PG_CONFIG=$(gosu postgres psql -d postgres -Atqc "SHOW config_file;")

# Fonction pour mettre à jour ou ajouter un paramètre
update_postgres_conf() {
    local param_name="$1"
    local param_value="$2"
    local config_file="$3"
    
    # Vérifier si le paramètre existe déjà (commenté ou non)
    if grep -q "^[#]*[[:space:]]*${param_name}[[:space:]]*=" "$config_file"; then
        # Le paramètre existe, vérifier s'il est déjà configuré avec la bonne valeur
        current_value=$(grep "^[[:space:]]*${param_name}[[:space:]]*=" "$config_file" | grep -v "^#" | tail -1 | sed "s/.*=[[:space:]]*//;s/[[:space:]]*#.*//")
        
        if [ "$current_value" = "$param_value" ]; then
            echo "  ✓ $param_name déjà configuré à $param_value"
        else
            # Commenter l'ancienne valeur et ajouter la nouvelle
            sed -i "s/^[[:space:]]*${param_name}[[:space:]]*=.*/#&/" "$config_file"
            echo "${param_name} = ${param_value}" >> "$config_file"
            echo "  ✓ $param_name mis à jour: $param_value (ancienne valeur: ${current_value:-par défaut})"
        fi
    else
        # Le paramètre n'existe pas, l'ajouter
        echo "${param_name} = ${param_value}" >> "$config_file"
        echo "  ✓ $param_name ajouté: $param_value"
    fi
}

# Appliquer les configurations
update_postgres_conf "shared_buffers" "128MB" "$PG_CONFIG"
update_postgres_conf "max_wal_size" "1GB" "$PG_CONFIG"
update_postgres_conf "min_wal_size" "100MB" "$PG_CONFIG"
update_postgres_conf "wal_log_hints" "on" "$PG_CONFIG"
update_postgres_conf "listen_addresses" "'*'" "$PG_CONFIG"

echo "✓ Configuration postgresql.conf mise à jour"

# ajout au pg_hba.conf des entrées pour le réseau local et le réseau docker
echo "Mise à jour de pg_hba.conf"
PG_HBA=$(gosu postgres psql -d postgres -Atqc "SHOW hba_file;")
echo "# Allow connection for all docker containers" >> $PG_HBA
echo "host    all             all             172.0.0.0/8            scram-sha-256" >> $PG_HBA


echo "11. redémarrage du service PostgreSQL..."
service postgresql restart

# Ajout de la variable d'environnement PATH pour l'utilisateur postgres
echo -e '\n# PostgreSQL 18\nexport PATH=/usr/lib/postgresql/18/bin:$PATH\nexport PS1="[\u@\h \W]$ "' >> /var/lib/postgresql/.profile
chown postgres:postgres /var/lib/postgresql/.profile

echo "========================================="
echo "PostgreSQL 18 prêt"
echo "Cluster : /var/lib/postgresql/18/main"
echo "Config  : /etc/postgresql/18/main"
echo "========================================="

# Laisser le service tourner (container-friendly)
exec tail -f /var/log/postgresql/postgresql-18-main.log

