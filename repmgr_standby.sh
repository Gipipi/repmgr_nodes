#!/bin/bash


HOSTNAME=$(hostname -f)
PRIMARYHOST="postgresql1"
STANDBYHOST="postgresql2"
WITNESSHOST="postgresql3"

: "${POSTGRES_PASSWORD_FILE:?POSTGRES_PASSWORD_FILE non défini}"

PG_PORT="5432"

REPMGRPASS=$(cat "$POSTGRES_PASSWORD_FILE")
PGDATA="/var/lib/postgresql/18/main"
REPMGRCONF="/etc/postgresql/18/main/repmgr.conf"
PGPASS="/var/lib/postgresql/.pgpass"
PGBINDDIR="/usr/lib/postgresql/18/bin"

# Récupérer le nodeid du noeud
if [[ "$HOSTNAME" == "$PRIMARYHOST" ]]; then
  NODEID=1
elif [[ "$HOSTNAME" == "$STANDBYHOST" ]]; then
  NODEID=2
elif [[ "$HOSTNAME" == "$WITNESSHOST" ]]; then
  NODEID=3
fi

echo "== STANDBY ${HOSTNAME} (node ${NODEID}) =="

if [ ! -f "$PGPASS" ]; then
  echo "ERREUR: $PGPASS doit exister"
  exit 1
fi

# ------------------------------------------------------------------
# Fonctions de MAJ
# ------------------------------------------------------------------

# Fonction pour mettre à jour un paramètre dans postgresql.conf
update_postgres_conf() {
    local param_name="$1"
    local param_value="$2"
    local config_file="$3"

    if grep -Eq "^[#[:space:]]*${param_name}[[:space:]]*=" "$config_file"; then
        current_value=$(grep -E "^[[:space:]]*${param_name}[[:space:]]*=" "$config_file" \
            | grep -v "^[[:space:]]*#" \
            | tail -1 \
            | sed -E "s/.*=[[:space:]]*//;s/[[:space:]]*#.*//")

        if [ "${current_value:-}" = "${param_value}" ]; then
            echo "  ✓ ${param_name} déjà configuré"
        else
            sed -i -E "s|^[[:space:]]*${param_name}[[:space:]]*=.*|#&|" "$config_file"
            echo "${param_name} = ${param_value}" >> "$config_file"
            echo "  ✓ ${param_name} mis à jour"
        fi
    else
        echo "${param_name} = ${param_value}" >> "$config_file"
        echo "  ✓ ${param_name} ajouté"
    fi
}

# Fonction pour ajouter une règle dans pg_hba.conf
ensure_pg_hba_rule() {
    local rule="$1"
    local file="$2"

    # Correction: enlever le -x et corriger le -v
    if grep -v "^#" "$file" | grep -Fq "$rule"; then
        echo "  ✓ règle HBA déjà présente"
    else
        echo "$rule" >> "$file"
        echo "  ✓ règle HBA ajoutée"
    fi
}

# Fonction pour ajouter une entrée dans .pgpass
ensure_pgpass_entry() {
    local host="$1"
    local port="$2"
    local db="$3"
    local user="$4"
    local pass="$5"

    local entry="${host}:${port}:${db}:${user}:${pass}"

    # Correction: enlever le -x
    if grep -v "^#" "$PGPASS" | grep -Fq "$entry"; then
        echo "  ✓ entrée .pgpass déjà présente"
    else
        echo "$entry" >> "$PGPASS"
        echo "  ✓ entrée .pgpass ajoutée"
    fi
}

PG_CONFIG=$(su postgres -c "psql -d postgres -Atqc 'SHOW config_file;'")
PG_HBA=$(su postgres -c "psql -d postgres -Atqc 'SHOW hba_file;'")

echo "Configuration de PostgreSQL pour la réplication :"
update_postgres_conf "wal_level" "replica" "$PG_CONFIG"
update_postgres_conf "max_wal_senders" "10" "$PG_CONFIG"
update_postgres_conf "max_replication_slots" "10" "$PG_CONFIG"
update_postgres_conf "hot_standby" "on" "$PG_CONFIG"
update_postgres_conf "archive_mode" "on" "$PG_CONFIG"
update_postgres_conf "archive_command" "'/bin/true'" "$PG_CONFIG"
update_postgres_conf "wal_log_hints" "on" "$PG_CONFIG"
update_postgres_conf "listen_addresses" "'*'" "$PG_CONFIG"
update_postgres_conf "shared_preload_libraries" "'repmgr'" "$PG_CONFIG"

echo "Configuration de pg_hba.conf pour la réplication :"
ensure_pg_hba_rule "host replication repmgr 172.0.0.0/8 scram-sha-256" "$PG_HBA"

echo "Redémarrage de PostgreSQL pour appliquer les modifications :"
service postgresql restart

echo "Ajout des entrées dans pgpass pour repmgr :"
ensure_pgpass_entry "$PRIMARYHOST" "$PG_PORT" "replication" "repmgr" "$REPMGRPASS"
ensure_pgpass_entry "$STANDBYHOST" "$PG_PORT" "replication" "repmgr" "$REPMGRPASS"
ensure_pgpass_entry "$WITNESSHOST" "$PG_PORT" "replication" "repmgr" "$REPMGRPASS"

SHARED_DIR="/shared-keys"

# Vider le fichier pour éviter les doublons
su - postgres -c "> ~/.ssh/authorized_keys"

# Collecter toutes les clés
for pub_key in "$SHARED_DIR"/*.pub; do
    if [ -f "$pub_key" ]; then
        hostname_from_key=$(basename "$pub_key" .pub)
        echo "  ✓ Ajout de la clé de $hostname_from_key"
        cat "$pub_key" >> /var/lib/postgresql/.ssh/authorized_keys
    fi
done

# Dédupliquer
su - postgres -c "sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"

echo "Nombre de clés autorisées: $(wc -l < /var/lib/postgresql/.ssh/authorized_keys)"


# ------------------------------------------------------------------
# repmgr.conf
# ------------------------------------------------------------------

echo "Création du fichier de configuration repmgr.conf :"
#si le noeud n'est pas le witness alors on passe cette conf
if [ -n "${WITNESSHOST}" ]; then
    cat > "$REPMGRCONF" <<EOF
node_id=${NODEID}
node_name=${HOSTNAME}
conninfo='host=${HOSTNAME} port=${PG_PORT} user=repmgr dbname=replication passfile=${PGPASS}'
data_directory='${PGDATA}'
pg_bindir='${PGBINDDIR}'
use_replication_slots=yes
failover=automatic
log_file='/var/log/repmgr/repmgr.log'
#Switchover
promote_command='repmgr standby promote -f ${REPMGRCONF} --log-to-file --verbose'
follow_command='repmgr standby follow -f ${REPMGRCONF} --upstream-node-id=%n --wait-upto=%t --log-to-file --verbose'
service_start_command='/usr/bin/pg_ctlcluster 18 main start'
service_stop_command='/usr/bin/pg_ctlcluster 18 main stop'
service_restart_command='/usr/bin/pg_ctlcluster 18 main restart'
service_reload_command='/usr/bin/pg_ctlcluster 18 main reload'
EOF
else
    cat > "$REPMGRCONF" <<EOF    
node_id=${NODEID}
node_name=${HOSTNAME}
conninfo='host=${HOSTNAME} port=${PG_PORT} user=repmgr dbname=replication passfile=${PGPASS}'
data_directory='${PGDATA}'
pg_bindir='${PGBINDDIR}'
failover=automatic
priority=0
log_file='/var/log/repmgr/repmgr.log'
#Switchover
promote_command='repmgr standby promote -f ${REPMGRCONF} --log-to-file --verbose'
follow_command='repmgr standby follow -f ${REPMGRCONF} --upstream-node-id=%n --wait-upto=%t --log-to-file --verbose'
service_start_command='/usr/bin/pg_ctlcluster 18 main start'
service_stop_command='/usr/bin/pg_ctlcluster 18 main stop'
service_restart_command='/usr/bin/pg_ctlcluster 18 main restart'
service_reload_command='/usr/bin/pg_ctlcluster 18 main reload'
#Monitoring
monitoring_history=yes
monitor_interval_secs=2
reconnect_attempts=6
reconnect_interval=10
EOF
fi

chown postgres:postgres "$REPMGRCONF"

# Création du répertoire et du fichier de log
mkdir /var/log/repmgr
chown postgres:postgres /var/log/repmgr
chmod 755 /var/log/repmgr
touch /var/log/repmgr/repmgr.log
chown postgres:postgres /var/log/repmgr/repmgr.log
chmod 664 /var/log/repmgr/repmgr.log

# configuration & activation du daemon repmgrd sur tous les noeuds

cat > /etc/default/repmgrd <<EOF
# default settings for repmgrd. This file is source by /bin/sh from
# /etc/init.d/repmgrd

# disable repmgrd by default so it won't get started upon installation
# valid values: yes/no
REPMGRD_ENABLED=yes

# configuration file (required)
REPMGRD_CONF=${REPMGRCONF} 

# additional options
#REPMGRD_OPTS="--daemonize=false"

# user to run repmgrd as
REPMGRD_USER=postgres

# repmgrd binary
#REPMGRD_BIN=/usr/bin/repmgrd

# pid file
#REPMGRD_PIDFILE=/var/run/repmgrd.pid
EOF


# Création du user repmgr et de la base de données replication pour le primary et le witness
if [ "$HOSTNAME" = "$PRIMARYHOST" ] || [ "$HOSTNAME" = "$WITNESSHOST" ]; then
    echo "Création du rôle repmgr et de la base de données replication :"
    
    # Création du rôle repmgr
    # HINT: grant pg_checkpoint role to repmgr user
    su - postgres -c "psql -v ON_ERROR_STOP=1" <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='repmgr') THEN
        CREATE ROLE repmgr LOGIN REPLICATION PASSWORD '${REPMGRPASS}';
        GRANT pg_monitor TO repmgr;
    END IF;
END
\$\$;
SQL

    # Création de la base de données replication (si elle n'existe pas)
    echo "Création de la base de données replication :"
    su - postgres -c "psql -v ON_ERROR_STOP=1" <<'SQL'
SELECT 'CREATE DATABASE replication OWNER repmgr'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'replication')\gexec
SQL
fi

# ------------------------------------------------------------------
# register du primary 
# ------------------------------------------------------------------

if [ "$HOSTNAME" = "$PRIMARYHOST" ]; then
    echo "Enregistrement du primary..."
    su - postgres -c "repmgr -f ${REPMGRCONF} primary register -S postgres"
    su - postgres -c "repmgr -f ${REPMGRCONF} cluster show"
    echo "Le primary est prêt!"


elif [ "$HOSTNAME" = "$STANDBYHOST" ]; then
    # ------------------------------------------------------------------
    # Clone & register du standby
    # ------------------------------------------------------------------

    echo "Clone du standby depuis le primary :"
    echo "Arrêt de PostgreSQL pour le clone..."
    service postgresql stop

    echo "Suppression de l'ancien PGDATA..."
    rm -rf "${PGDATA}"

    echo "Clonage depuis ${PRIMARYHOST}..."
    su - postgres -c "repmgr -h ${PRIMARYHOST} -p ${PG_PORT} -U repmgr -d replication -f ${REPMGRCONF} standby clone --fast-checkpoint"

    if [ $? -ne 0 ]; then
        echo ""
        echo "ERREUR: Le clonage a échoué!"
        echo "Vérifiez que:"
        echo "  1. Le primary ${PRIMARYHOST} est accessible"
        echo "  2. L'utilisateur repmgr existe sur le primary"
        echo "  3. La base replication existe sur le primary"
        echo "  4. Le fichier .pgpass contient les bonnes informations"
        exit 1
    fi

    echo "Démarrage de PostgreSQL..."
    service postgresql start

    # Attendre que PostgreSQL soit prêt
    echo "Attente du démarrage de PostgreSQL..."
    for i in {1..30}; do
        if su - postgres -c "pg_isready -q"; then
            echo "  ✓ PostgreSQL est prêt"
            break
        fi
        sleep 1
    done

    echo "Enregistrement du standby dans le cluster :"
    su - postgres -c "repmgr -f ${REPMGRCONF} standby register" || {
        echo "ERREUR lors de l'enregistrement du standby"
        echo "Vérifiez que le primary est accessible et que l'utilisateur repmgr existe"
    }

    echo "Affichage du cluster :"
    su - postgres -c "repmgr -f ${REPMGRCONF} cluster show"

    echo "STANDBY configuré."

elif [ "$HOSTNAME" = "$WITNESSHOST" ]; then
    echo "Configuration du witness"
    su - postgres -c 'repmgr -f /etc/postgresql/18/main/repmgr.conf witness register -h postgresql1  -S postgres'
    su - postgres -c 'repmgr -f /etc/postgresql/18/main/repmgr.conf cluster show'
fi

echo "Start du daemon repmgrd"
service repmgrd start
echo "repmgr configuré."