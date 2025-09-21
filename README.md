# docker-nuclos-installer
Automatische dockerbasierte nuclos Installation

# !!! A C H T U N G !!! für einen produktiven Betrieb ausschließlich hinter einem Reverseproxyserver wie z.B. nginx

Zur Installation im Installationsverzeichnis z.B. /opt/<mein nuclos installationsverzeichnis>
ist nur dieses Script und das Installationspackage von Nuclos  erforderlich. Download auf der Herstellerseite.
https://www.nuclos.de/downloads/

- Das Restorescript benötigt für eine vollständige Wiederherstellung weitere Anpassungen.
- Es werden 2 Container erzeugt und ein Docker Netzwerk (PostgreSQL und Nuclos basiert auf temurin Java Image)


<img width="869" height="131" alt="image" src="https://github.com/user-attachments/assets/23a36369-8838-4b21-a55f-e9df59709a01" />

Erzeugung der Dockercontainer entsprechend den eingegebenen Parameter
<img width="795" height="776" alt="image" src="https://github.com/user-attachments/assets/51877ccb-1e2e-4cd1-8400-63429c38def8" />


Im Installationsordner werden automatisch folgende Scripts und Konfigurationsdateien erzeugt.
<img width="910" height="264" alt="image" src="https://github.com/user-attachments/assets/34b499d5-859f-43a3-ad08-ec922c55adc3" />




Dieses Script wird ohne jegliche Gewährleistung zur Verfügung gestellt unter MIT.
Kein Backup? Kein Mitleid!
