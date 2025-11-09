#!/bin/bash

# Installationsscript für Nuclos Docker Instanz
# Erstellt: Jörg Staub - 15.09.2025
#
# install.sh

# Funktion zur Suche nach einem freien Port ab 8080 ################################################

# Check RAM ##########################################################################
REQUIRED_MEMORY=4000  # 4GB in MB
AVAILABLE_MEMORY=$(free -m | awk '/^Mem:/{print $2}')
if (( AVAILABLE_MEMORY < REQUIRED_MEMORY )); then
    echo "⚠️ Warning: System has less than 4GB RAM"
fi

# Check Docker installation ##########################################################################
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon is not running"
    exit 1
fi

default_javaversion=11
default_pgversion=17
default_nuclosinstanz=snnuc
default_prefix=nuc
default_database=nuclosdb
default_dbuser=nuclos
default_dbpassword=nuclos

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
# Setup logging
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/nuclos_install_${TIMESTAMP}.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

echo "=== Nuclos Installation Log ===" 
echo "Date: ${TIMESTAMP}"
echo "System: $(uname -a)"
echo "==========================="

find_free_port() {
  local port=8080
  while lsof -iTCP -sTCP:LISTEN -Pn | grep ":$port" > /dev/null; do
    ((port++))
  done
  echo $port
}

clear
set -e
echo "-----------------------------------------------------------"
echo "Nuclos Docker-Instanz Setup"
echo "Dieses Script erzeugt automatische .env, Dockerfile, "
echo "docker-compose.yml und die Nuclos Konfigurationsdatei "
echo "sowie einige Backup- und Restorescripte"
echo "-----------------------------------------------------------"
echo "Folgende Container werden erzeugt:"
echo "Postgresql, Nuclos "
echo "-----------------------------------------------------------"

echo "> Docker Parameter ---------------------------------------------------"
read -p "Image-Tag für Docker Build (z.B. dev, test, prod) (default=-dev): " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-dev}
read -p "Docker Container-Präfix [Enter für $default_prefix]: " PREFIX
PREFIX=${PREFIX:-$default_prefix}




# Parameter abfragen ##############################################################################
echo "> Datenbank Parameter -----------------------------------------------------"
read -p "PostgreSQL Version (z.B. 17) [Enter für $default_pgversion]: " PG_VERSION
PG_VERSION=${PG_VERSION:-$default_pgversion}

read -p "Datenbankname [Enter für $default_database]: " POSTGRES_DB
POSTGRES_DB=${POSTGRES_DB:-$default_database}
read -p "Datenbank Benutzername [Enter für $default_dbuser]: " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-$default_dbuser}
read -p "Datenbank Passwort [Enter für $default_dbpassword]: " POSTGRES_PASSWORD
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$default_dbpassword}


# Add after database parameter collection
if [[ "$POSTGRES_USER" == "nuclos" && "$POSTGRES_PASSWORD" == "nuclos" ]]; then
    echo "⚠️ Warning: Using default credentials is not recommended for production"
    read -p "Continue anyway? (y/N): " confirm
    [[ $confirm != "y" ]] && exit 1
fi




echo "> JAVA Parameter ----------------------------------------------------------"
read -p "Java Version (zurzeit 11 empfohlen) [Enter für $default_javaversion]: " JAVA_VERSION
JAVA_VERSION=${JAVA_VERSION:-$default_javaversion}

echo "> Nuclos Parameter --------------------------------------------------------"
read -p "Nuclos Instanzname [Enter für $default_nuclosinstanz]: " NUCLOS_INSTANZ
NUCLOS_INSTANZ=${NUCLOS_INSTANZ:-$default_nuclosinstanz}


# Port automatisch vorschlagen ####################################################################
default_port=$(find_free_port)
echo "Vorgeschlagener freier Port: $default_port"

while true; do
  read -p "Freier HTTP-Port für Nuclos [Enter für $default_port]: " NUCLOS_PORT
  NUCLOS_PORT=${NUCLOS_PORT:-$default_port}

  if lsof -iTCP -sTCP:LISTEN -Pn | grep ":$NUCLOS_PORT" > /dev/null; then
    echo "❌ Port $NUCLOS_PORT ist bereits belegt. Bitte einen anderen wählen."
  else
    echo "✅ Port $NUCLOS_PORT ist frei."
    break
  fi
done



# .env erzeugen ##################################################################################

cat > .env <<EOF
# Generated .env 
# Installation: ${TIMESTAMP}
#
# Versionen
PG_VERSION=${PG_VERSION}
JAVA_VERSION=${JAVA_VERSION}
# Docker Container Namen
DOCKER_CONTAINER_PG=${PREFIX}-postgres
DOCKER_CONTAINER_NUCLOS=${PREFIX}-server
# Nuclos
NUCLOS_INSTANZ=${NUCLOS_INSTANZ}
NUCLOS_PORT=${NUCLOS_PORT}
# Datenbank
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF


# Dockerfile erzeugen #############################################################################

cat > Dockerfile <<EOF
FROM eclipse-temurin:${JAVA_VERSION}-jdk
WORKDIR /opt/nuclos-install

RUN apt-get update && apt-get install -y postgresql-client
RUN apt-get update && apt-get install -y ncat nano
RUN apt-get update && apt-get install -y locales && locale-gen de_DE.UTF-8
ENV LANG = "de_DE.UTF-8"
ENV POSTGRES_INITDB_ARGS="--locale=de_DE.UTF-8"


COPY nuclos-*.jar ./nuclos-installer.jar
COPY nuclos-install-config.xml ./install-config.xml

RUN java -jar nuclos-installer.jar -s install-config.xml
EOF


# docker-compose.yml erzeugen #####################################################################

cat > docker-compose.yml <<EOF
networks:
  ${PREFIX}-nuclos-net:
    driver: bridge
services:
  ${PREFIX}-postgres:
    image: postgres:\${PG_VERSION}
    container_name: ${PREFIX}-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=\${POSTGRES_DB}
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./nuclos-pgdata:/var/lib/postgresql/data
    ports:
      - "5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - ${PREFIX}-nuclos-net

  ${PREFIX}-server:
    # build: .
    image: snnuclos:${IMAGE_TAG}
    container_name: ${PREFIX}-server
    ports:
      - "\${NUCLOS_PORT}:80"
    restart: unless-stopped
    depends_on:
      ${PREFIX}-postgres:
        condition: service_healthy
    environment:
      - DB_HOST=${PREFIX}-postgres
      - DB_PORT=5432
      - DB_NAME=\${POSTGRES_DB}
      - DB_USER=\${POSTGRES_USER}
      - DB_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./nuclos-data/documents-upload:/opt/nuclos/data/documents-upload
      - ./nuclos-data/documents:/opt/nuclos/data/documents
      - ./nuclos-data/index:/opt/nuclos/data/index
    entrypoint: /opt/nuclos/bin/launchd.sh
    networks:
      - ${PREFIX}-nuclos-net
EOF

# nuclos-install-config.xml erzeugen #############################################################

cat > nuclos-install-config.xml <<EOF
<?xml version="1.0"?>
<nuclos>
  <server>
    <home>/opt/nuclos</home>
    <name>${NUCLOS_INSTANZ}</name>
    <http>
      <enabled>true</enabled>
      <port>80</port>
    </http>
    <shutdown-port>8005</shutdown-port>
    <heap-size>2048</heap-size>
    <java-home></java-home>
    <launch-on-startup>true</launch-on-startup>
  </server>
  <database>
    <adapter>postgresql</adapter>
    <driver>org.postgresql.Driver</driver>
    <driverjar>/opt/nuclos/lib/postgresql.jar</driverjar>
    <connection-url>jdbc:postgresql://${PREFIX}-postgres:5432/${POSTGRES_DB}</connection-url>
    <username>${POSTGRES_USER}</username>
    <password>${POSTGRES_PASSWORD}</password>
    <schema>${POSTGRES_DB}</schema>
    <tablespace></tablespace>
  </database>
</nuclos>
EOF

# nuclos uninstallscript ##############################################################################

cat > uninstall.sh <<EOF
#!/bin/bash
set -e
# Uninstall-Skript für Nuclos Docker Instanz
# Erstellt: Jörg Staub - 08.11.2025
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")
echo "⚠️  Achtung: Diese Aktion entfernt alle Nuclos-Docker-Komponenten und Daten!"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "\${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

# Container-Präfix aus .env laden
if [[ -f .env ]]; then
  export \$(grep -v '^#' .env | xargs)
else
  echo "❌ .env-Datei nicht gefunden. Abbruch."
  exit 1
fi

echo "🧨 Stoppe und entferne Container..."
docker compose down --volumes --remove-orphans


echo "🧨 Packe Datenverzeichnis..."
tar -czvf backup-nuclos-data\$TIMESTAMP.tar.gz ./nuclos-data
echo "🧨 Packe Datenbankverzeichnis..."
tar -czvf backup-nuclos-pgdata\$TIMESTAMP.tar.gz ./nuclos-pgdata
echo "🧨 Packe .env"
tar -czvf backup-nuclos-environment\$TIMESTAMP.tar.gz ".env"
echo "🧨 Packe nuclos-config"
tar -czvf backup-nuclos-config\$TIMESTAMP.tar.gz "nuclos-install-config.xml"


echo "🧹 Entferne lokale Datenverzeichnisse..."
rm -rf nuclos-pgdata nuclos-data

echo "🗑️ Entferne Konfigurationsdateien..."
rm -f .env docker-compose.yml Dockerfile nuclos-install-config.xml uninstall.sh backup-db.sh

echo "✅ Nuclos-Docker-Instanz wurde vollständig entfernt."
EOF

# ###################################################################################################
# ###################################################################################################
# BACKUP SCRIPTS ####################################################################################
# nuclos db backupscript ############################################################################

cat > backup-db.sh <<EOF
#!/bin/bash
set -e
# Konfiguration
CONTAINER_NAME=${PREFIX}-postgres
DB_USER=${POSTGRES_USER}
BACKUP_DIR="./nuclos-backups"
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")

# Backup-Verzeichnis sicherstellen
mkdir -p "\$BACKUP_DIR"

# Backup ausführen
echo "Sichere Datenabnk..."
docker exec "\$CONTAINER_NAME" pg_dumpall -U "\$DB_USER" | gzip > "\$BACKUP_DIR/postgres-backup-\$TIMESTAMP.sql.gz"

# Alte Backups nach 30 Tagen löschen
echo "Lösche alte Datenbankbackups älter >30 Tage..."
find "\$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +30 -delete
EOF

# ###################################################################################################
# ###################################################################################################
# nuclos backup-instanz.sh ########################################################################
cat > backup-instanz.sh <<EOF
#!/bin/bash
set -e
# Konfiguration
# itsm-nuc-postgres
CONTAINER_NAME=${PREFIX}-postgres
DB_USER=${POSTGRES_USER}
BACKUP_DIR="./nuclos-instanzbackup"
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")

echo "⚠️  Instanzbackup / Vollbackup"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "\${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi



# Backup-Verzeichnis sicherstellen
mkdir -p "\$BACKUP_DIR"

# Backup ausführen
echo "Backup Database only..."
docker exec "\$CONTAINER_NAME" pg_dumpall -U "\$DB_USER" | gzip > "\$BACKUP_DIR/postgres-backup-\$TIMESTAMP.sql.gz"

echo "Lösche alte Backup >30 Tage..."
# Alte Backups nach 30 Tagen löschen
find "\$BACKUP_DIR" -type f -name "*.gz" -mtime +30 -delete



# Container-Präfix aus .env laden
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env-Datei nicht gefunden. Abbruch."
  exit 1
fi

echo "🧨 Stoppe Container..."
docker compose down


echo "🧨 Packe Datenverzeichnis..."
tar -czvf \$BACKUP_DIR/backup-nuclos-data\$TIMESTAMP.tar.gz ./nuclos-data
echo "🧨 Packe Datenbankverzeichnis..."
tar -czvf \$BACKUP_DIR/backup-nuclos-pgdata\$TIMESTAMP.tar.gz ./nuclos-pgdata

echo "🧨 Packe .env"
tar -czvf \$BACKUP_DIR/backup-nuclos-environment\$TIMESTAMP.tar.gz ".env"
echo "🧨 Packe nuclos-config"
tar -czvf \$BACKUP_DIR/backup-nuclos-config\$TIMESTAMP.tar.gz "nuclos-install-config.xml"


echo "✅ Nuclos-Docker-Instanz wurde vollständig gesichert."

echo "🧨 Starte Container neu..."
docker compose up -d

EOF
# ###################################################################################################
# Upgradscript ######################################################################################
# ###################################################################################################
cat > upgrade.sh <<EOF
#!/bin/bash
set -e
# Konfiguration
# itsm-nuc-postgres
CONTAINER_NAME=${PREFIX}-postgres
DB_USER=${POSTGRES_USER}
BACKUP_DIR="./nuclos-instanzbackup"
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")

echo "⚠️  Nuclos Upgrade ausführen"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "\${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

# Backup-Verzeichnis sicherstellen
mkdir -p "\$BACKUP_DIR"

# Backup ausführen
echo "Backup Database only..."
docker exec "\$CONTAINER_NAME" pg_dumpall -U "\$DB_USER" | gzip > "\$BACKUP_DIR/postgres-backup-\$TIMESTAMP.sql.gz"

echo "Lösche alte Backup >30 Tage..."
# Alte Backups nach 30 Tagen löschen
find "\$BACKUP_DIR" -type f -name "*.gz" -mtime +30 -delete


# Container-Präfix aus .env laden
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env-Datei nicht gefunden. Abbruch."
  exit 1
fi

echo "🧨 Stoppe Container..."
docker compose down


echo "🧨 Packe Datenverzeichnis..."
tar -czvf \$BACKUP_DIR/backup-nuclos-data\$TIMESTAMP.tar.gz ./nuclos-data
echo "🧨 Packe Datenbankverzeichnis..."
tar -czvf \$BACKUP_DIR/backup-nuclos-pgdata\$TIMESTAMP.tar.gz ./nuclos-pgdata

echo "🧨 Packe .env"
tar -czvf \$BACKUP_DIR/backup-nuclos-environment\$TIMESTAMP.tar.gz ".env"
echo "🧨 Packe nuclos-config"
tar -czvf \$BACKUP_DIR/backup-nuclos-config\$TIMESTAMP.tar.gz "nuclos-install-config.xml"


echo "✅ Nuclos-Docker-Instanz wurde vollständig gesichert."


echo "Baue neues Docker Image mit Tag: snnuclos:${IMAGE_TAG} ..."

if ! docker build -t snnuclos:${IMAGE_TAG} .; then
    echo "❌ Docker build failed"
    exit 1
fi

echo "🧨 Starte Container neu..."
docker compose up -d

EOF

# ###################################################################################################
# ###################################################################################################
# ###################################################################################################


# Restore ##########################################################################################
# nuclos restore-instanz-script ####################################################################

cat > restore-instanz.sh <<EOF
#!/bin/bash
set -e
# Konfiguration
# itsm-nuc-postgres
BACKUP_DIR="./nuclos-instanzbackup"
ARCHIVE_DIR="./nuclos-archiv"
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")

echo "⚠️  Instanz zurückspielen / Möglicher Datenverlust ⚠️"
echo "Dadurch wird die aktuelle Instanz überschrieben"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "\${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

# Archiv-Verzeichnis sicherstellen
mkdir -p "\$ARCHIVE_DIR"

echo "🧨 Verschiebe Backup-Dateien aus $BACKUP_DIR..."
mv "\$BACKUP_DIR"/* ./


echo "🧨 Stoppe Container..."
docker compose down

echo "🧨 Entpacke Datenverzeichnisse..."
tar -xzvf backup-nuclos-pgdata*.tar.gz
tar -xzvf backup-nuclos-data*.tar.gz
echo "🧨 Entpacke .env"
tar -xzvf backup-nuclos-environment*.tar.gz
echo "🧨 Entpacke nuclos-config"
tar -xzvf backup-nuclos-config*.tar.gz


echo "🧨 Starte Container..."
docker compose up -d


echo "Aufräumen..."
mv  *.gz "\$ARCHIVE_DIR"/

EOF



# ###################################################################################################
# ###################################################################################################
# ###################################################################################################
# ###################################################################################################
# Ausführbar machen #################################################################################

chmod +x backup-db.sh
chmod +x backup-instanz.sh
chmod +x uninstall.sh
chmod +x restore-instanz.sh
chmod +x upgrade.sh

echo "Alle Konfigurationsdateien wurden erfolgreich erzeugt:"
echo "- .env"
echo "- Dockerfile"
echo "- docker-compose.yml"
echo "- nuclos-install-config.xml"
echo "- uninstall.sh"
echo "- backup-db.sh"
echo "- backup-instanz.sh"
echo "- restore-instanz.sh"



echo "Baue Docker Image mit Tag: snnuclos:${IMAGE_TAG} ..."


# docker build -t snnuclos:${IMAGE_TAG} .
# Modify Docker build section
if ! docker build -t snnuclos:${IMAGE_TAG} .; then
    echo "❌ Docker build failed"
    exit 1
fi

echo "Starte Docker-Container..."
docker compose up -d 

echo "------------------------------------------------------------"
echo "✅ Installation abgeschlossen."
echo
echo "------------------------------------------------------------"
echo "               ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️               "
echo "Produktivbetrieb im Internet nur hinter einem Reverse-Proxy!"
echo "------------------------------------------------------------"



