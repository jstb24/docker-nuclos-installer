#!/bin/bash

# Installationsscript für Nuclos Docker Instanz
# Erstellt: Jörg Staub - 15.09.2025
#
# install-nuc-all.sh

# Funktion zur Suche nach einem freien Port ab 8080
default_javaversion=11
default_pgversion=17
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

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
echo "docker-compose.yml und die Nuclos Konfigurationsdatei"
echo "-----------------------------------------------------------"
echo "Folgende Container werden erzeugt:"
echo "Postgresql, Nuclos "
echo "-----------------------------------------------------------"


read -p "Image-Tag für Docker Build (z.B. dev, test, prod): " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-dev}

# Parameter abfragen
echo "Datenbank Parameter..."
read -p "PostgreSQL Version (z.B. 17) [Enter für $default_pgversion]: " PG_VERSION
PG_VERSION=${PG_VERSION:-$default_pgversion}

read -p "Datenbankname: " POSTGRES_DB
read -p "Datenbank Benutzername: " POSTGRES_USER
read -p "Datenbank Passwort: " POSTGRES_PASSWORD

echo "JAVA Parameter..."
read -p "Java Version (zurzeit 11 empfohlen) [Enter für $default_javaversion]: " JAVA_VERSION
JAVA_VERSION=${JAVA_VERSION:-$default_javaversion}

echo "Nuclos Parameter..."
read -p "Nuclos Instanzname: " NUCLOS_INSTANZ
# Port automatisch vorschlagen
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


read -p "Container-Präfix (z.B. nuclos): " PREFIX

# .env erzeugen

cat > .env <<EOF
# Generated .env 
# Installation: ${TIMESTAMP}
#
# Versionen
PG_VERSION=${PG_VERSION}
JAVA_VERSION=${JAVA_VERSION}
# Nuclos
NUCLOS_INSTANZ=${NUCLOS_INSTANZ}
NUCLOS_PORT=${NUCLOS_PORT}
# Datenbank
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF


# Dockerfile erzeugen
cat > Dockerfile <<EOF
FROM eclipse-temurin:${JAVA_VERSION}-jdk
WORKDIR /opt/nuclos-install

RUN apt-get update && apt-get install -y postgresql-client
RUN apt-get update && apt-get install -y ncat nano
RUN apt-get update && apt-get install -y locales \
  && locale-gen de_DE.UTF-8
ENV LANG de_DE.UTF-8
ENV POSTGRES_INITDB_ARGS="--locale=de_DE.UTF-8"


COPY nuclos-*.jar ./nuclos-installer.jar
COPY nuclos-install-config.xml ./install-config.xml

RUN java -jar nuclos-installer.jar -s install-config.xml
EOF


# docker-compose.yml erzeugen
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

# nuclos-install-config.xml erzeugen
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

# nuclos uninstallscript
cat > uninstall.sh <<EOF
#!/bin/bash
# Uninstall-Skript für Nuclos Docker Instanz
# Erstellt: Jörg Staub - 15.09.2025
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")
echo "⚠️  Achtung: Diese Aktion entfernt alle Nuclos-Docker-Komponenten und Daten!"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "\${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi


# Backup ausführen
echo "Erstelle Datenbank Backup..."
docker exec "${PREFIX}-postgres" pg_dumpall -U "${POSTGRES_USER}" | gzip > "./postgres-final-backup-\$TIMESTAMP.sql.gz"



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

echo "🧹 Entferne lokale Datenverzeichnisse..."
rm -rf nuclos-pgdata nuclos-data

echo "🗑️ Entferne Konfigurationsdateien..."
rm -f .env docker-compose.yml Dockerfile nuclos-install-config.xml uninstall.sh backup-db.sh

echo "✅ Nuclos-Docker-Instanz wurde vollständig entfernt."
EOF

# nuclos backupscript
cat > backup-db.sh <<EOF
#!/bin/bash

# Konfiguration
CONTAINER_NAME=${PREFIX}-postgres
DB_USER=${POSTGRES_USER}
BACKUP_DIR="./nuclos-backups"
TIMESTAMP=\$(date +"%Y-%m-%d_%H-%M-%S")

# Backup-Verzeichnis sicherstellen
mkdir -p "\$BACKUP_DIR"

# Backup ausführen
echo "Backup Database only..."
docker exec "\$CONTAINER_NAME" pg_dumpall -U "\$DB_USER" | gzip > "\$BACKUP_DIR/postgres-backup-\$TIMESTAMP.sql.gz"

echo "Lösche alte Backup >30 Tage..."
# Alte Backups nach 30 Tagen löschen
find "\$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +30 -delete
EOF

# nuclos backupscriptrestore-data-script
cat > restore-data.sh <<EOF
#!/bin/bash

echo "🧨 Entpacke Datenverzeichnisse..."
tar -xzvf backup-nuclos-pgdata*.tar.gz
tar -xzvf backup-nuclos-data*.tar.gz

EOF




chmod +x backup-db.sh
chmod +x uninstall.sh
chmod +x restore-data.sh

echo "Alle Konfigurationsdateien wurden erfolgreich erzeugt:"
echo "- .env"
echo "- Dockerfile"
echo "- docker-compose.yml"
echo "- nuclos-install-config.xml"
echo "- uninstall.sh"
echo "- backup-db.sh"
echo "- restore-data.sh"



echo "Starte Docker-Container..."
docker build -t snnuclos:${IMAGE_TAG} .
docker compose up -d 

echo "---------------------------------------------------"
echo "Installation abgeschlossen."
echo "---------------------------------------------------"
echo "A C H T U N G !!!"
echo "Betrieb im Internet nur hinter einem Reverse-Proxy!"
echo "---------------------------------------------------"


