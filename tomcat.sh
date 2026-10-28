#!/bin/bash

# ============================================================
# Tomcat Installation Script (RHEL 10)
# ============================================================
# Purpose:
#   Install Java JDK and the latest stable Apache Tomcat
#   of the selected major version.
#   Safe to re-run: steps already done are SKIPPED (yellow).
#
# Optional overrides (environment variables):
#   TOMCAT_MAJOR=10 TOMCAT_ADMIN_PASSWORD='MyPass' ./tomcat-install.sh
# ============================================================


# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

JAVA_VERSION="21"

TOMCAT_MAJOR="${TOMCAT_MAJOR:-9}"          # 9, 10 or 11
TOMCAT_BASE_DIR="/opt"
TOMCAT_SYMLINK="${TOMCAT_BASE_DIR}/tomcat"
TOMCAT_USER="tomcat"

TOMCAT_ADMIN_USER="${TOMCAT_ADMIN_USER:-admin}"
TOMCAT_ADMIN_PASSWORD="${TOMCAT_ADMIN_PASSWORD:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"
ALLOW_REMOTE_MANAGER="${ALLOW_REMOTE_MANAGER:-true}"   # false = keep localhost-only

TOMCAT_INDEX_URL="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR}/"

LOGFILE="/tmp/tomcat-install-$(date +%F-%H-%M-%S).log"

PROFILE_FILE="/etc/profile.d/tomcat.sh"
SERVICE_FILE="/etc/systemd/system/tomcat.service"

NEED_RESTART="false"     # set to true when something changed


# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

R="\e[31m"
G="\e[32m"
Y="\e[33m"
N="\e[0m"


# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

VALIDATE() {

    if [ "$1" -ne 0 ]
    then
        echo -e "$2...$R FAILURE $N"
        echo "Check log file: $LOGFILE"
        exit 1
    else
        echo -e "$2...$G SUCCESS $N"
    fi
}

SKIP() {
    echo -e "$1...$Y SKIPPING (already done) $N"
}


# ------------------------------------------------------------
# Root User Check
# ------------------------------------------------------------

USERID=$(id -u)

if [ "$USERID" -ne 0 ]
then
    echo -e "$R Please run this script with root access $N"
    exit 1
else
    echo -e "$G You are running as root $N"
fi


# ------------------------------------------------------------
# Start
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Java + Latest Tomcat ${TOMCAT_MAJOR}.x Installation"
echo "============================================================"
echo
echo "Java Version   : $JAVA_VERSION"
echo "Tomcat Home    : $TOMCAT_SYMLINK"
echo "Log File       : $LOGFILE"
echo


# ------------------------------------------------------------
# Required Packages (install only the missing ones)
# ------------------------------------------------------------

MISSING_PKGS=""

for PKG in wget curl tar gzip unzip tree net-tools
do
    rpm -q "$PKG" &>/dev/null || MISSING_PKGS="$MISSING_PKGS $PKG"
done

if [ -z "$MISSING_PKGS" ]
then
    SKIP "Installing required packages"
else
    dnf install -y $MISSING_PKGS &>> "$LOGFILE"
    VALIDATE $? "Installing required packages:${MISSING_PKGS}"
fi


# ------------------------------------------------------------
# Java JDK
# ------------------------------------------------------------

if rpm -q "java-${JAVA_VERSION}-openjdk-devel" &>/dev/null
then
    SKIP "Installing Java ${JAVA_VERSION} JDK"
else
    dnf install -y "java-${JAVA_VERSION}-openjdk-devel" &>> "$LOGFILE"
    VALIDATE $? "Installing Java ${JAVA_VERSION} JDK"
fi

java -version &>> "$LOGFILE"
VALIDATE $? "Checking Java installation"

javac -version &>> "$LOGFILE"
VALIDATE $? "Checking Java compiler"


# ------------------------------------------------------------
# Detect Latest Tomcat Version
# ------------------------------------------------------------

echo
echo "Detecting latest Tomcat ${TOMCAT_MAJOR}.x version..."

TOMCAT_VERSION=$(curl -fsSL "$TOMCAT_INDEX_URL" \
    | grep -oP 'href="v\K[0-9]+\.[0-9]+\.[0-9]+(?=/")' \
    | sort -V \
    | tail -1)

if [ -z "$TOMCAT_VERSION" ]
then
    echo -e "$R Unable to determine latest Tomcat ${TOMCAT_MAJOR}.x version $N"
    echo "Checked URL: $TOMCAT_INDEX_URL"
    exit 1
fi

echo -e "Latest Tomcat Version : $G $TOMCAT_VERSION $N"

# Show what is currently installed (if anything)
if [ -L "$TOMCAT_SYMLINK" ]
then
    CURRENT_HOME=$(readlink -f "$TOMCAT_SYMLINK")
    echo -e "Currently installed   : $Y ${CURRENT_HOME##*/apache-tomcat-} $N"
fi
echo


# ------------------------------------------------------------
# Tomcat Variables
# ------------------------------------------------------------

TOMCAT_HOME="${TOMCAT_BASE_DIR}/apache-tomcat-${TOMCAT_VERSION}"
TOMCAT_ARCHIVE="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
TOMCAT_URL="${TOMCAT_INDEX_URL}v${TOMCAT_VERSION}/bin/${TOMCAT_ARCHIVE}"

echo "Tomcat URL  : $TOMCAT_URL"
echo "Tomcat Home : $TOMCAT_HOME"
echo

cd "$TOMCAT_BASE_DIR" &>> "$LOGFILE"
VALIDATE $? "Changing directory to ${TOMCAT_BASE_DIR}"


# ------------------------------------------------------------
# Download + Extract + Configure (skip if this version exists)
# ------------------------------------------------------------

if [ -d "$TOMCAT_HOME" ]
then

    SKIP "Tomcat ${TOMCAT_VERSION} download/extract/config (found at ${TOMCAT_HOME})"

else

    NEED_RESTART="true"

    wget -q "$TOMCAT_URL" -O "$TOMCAT_ARCHIVE" &>> "$LOGFILE"
    VALIDATE $? "Downloading Tomcat ${TOMCAT_VERSION}"

    wget -q "${TOMCAT_URL}.sha512" -O "${TOMCAT_ARCHIVE}.sha512" &>> "$LOGFILE"
    VALIDATE $? "Downloading checksum file"

    sha512sum -c "${TOMCAT_ARCHIVE}.sha512" &>> "$LOGFILE"
    VALIDATE $? "Verifying SHA512 checksum"

    tar -xzf "$TOMCAT_ARCHIVE" &>> "$LOGFILE"
    VALIDATE $? "Extracting Tomcat ${TOMCAT_VERSION}"

    rm -f "$TOMCAT_ARCHIVE" "${TOMCAT_ARCHIVE}.sha512" &>> "$LOGFILE"
    VALIDATE $? "Removing Tomcat archive"

    # Admin user
    sed -i '/<\/tomcat-users>/i \
  <user username="'"$TOMCAT_ADMIN_USER"'" password="'"$TOMCAT_ADMIN_PASSWORD"'" roles="manager-gui,admin-gui"/>' \
        "$TOMCAT_HOME/conf/tomcat-users.xml"

    VALIDATE $? "Configuring Tomcat admin user"

    # Remote access to Manager / Host-Manager
    if [ "$ALLOW_REMOTE_MANAGER" = "true" ]
    then
        for APP in manager host-manager
        do
            CTX="$TOMCAT_HOME/webapps/$APP/META-INF/context.xml"

            if ! grep -q '<!-- *<Valve' "$CTX"
            then
                sed -i '/<Valve className="org.apache.catalina.valves.RemoteCIDRValve"/,/\/>/ {
                    s/<Valve/<!-- <Valve/
                    s/\/>/\/> -->/
                }' "$CTX"
            fi
        done

        VALIDATE $? "Enabling remote access for Manager / Host-Manager"
    else
        SKIP "Enabling remote access for Manager / Host-Manager (ALLOW_REMOTE_MANAGER=false)"
    fi

fi


# ------------------------------------------------------------
# Tomcat System User
# ------------------------------------------------------------

if id "$TOMCAT_USER" &>/dev/null
then
    SKIP "Creating ${TOMCAT_USER} system user"
else
    useradd -r -s /sbin/nologin -d "$TOMCAT_SYMLINK" "$TOMCAT_USER" &>> "$LOGFILE"
    VALIDATE $? "Creating ${TOMCAT_USER} system user"
fi

chown -R "$TOMCAT_USER":"$TOMCAT_USER" "$TOMCAT_HOME" &>> "$LOGFILE"
VALIDATE $? "Setting ownership on ${TOMCAT_HOME}"

chmod +x "$TOMCAT_HOME"/bin/*.sh &>> "$LOGFILE"
VALIDATE $? "Making Tomcat scripts executable"


# ------------------------------------------------------------
# Symlink  /opt/tomcat -> /opt/apache-tomcat-<version>
# ------------------------------------------------------------

if [ "$(readlink -f "$TOMCAT_SYMLINK" 2>/dev/null)" = "$TOMCAT_HOME" ]
then
    SKIP "Creating Tomcat symbolic link (already points to ${TOMCAT_HOME})"
else
    ln -sfn "$TOMCAT_HOME" "$TOMCAT_SYMLINK" &>> "$LOGFILE"
    VALIDATE $? "Creating Tomcat symbolic link"
    NEED_RESTART="true"
fi


# ------------------------------------------------------------
# Environment Variables
# ------------------------------------------------------------

if [ -f "$PROFILE_FILE" ] && grep -q "CATALINA_HOME=\"$TOMCAT_SYMLINK\"" "$PROFILE_FILE"
then
    SKIP "Configuring Tomcat environment variables"
else
    cat > "$PROFILE_FILE" <<EOF

# Apache Tomcat
export CATALINA_HOME="$TOMCAT_SYMLINK"
export CATALINA_BASE="$TOMCAT_SYMLINK"
export PATH="\$CATALINA_HOME/bin:\$PATH"

EOF
    VALIDATE $? "Configuring Tomcat environment variables"
fi

source "$PROFILE_FILE" &>> "$LOGFILE"
VALIDATE $? "Loading Tomcat environment variables"


# ------------------------------------------------------------
# Systemd Service
# ------------------------------------------------------------

JAVA_HOME_PATH=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")

if [ -f "$SERVICE_FILE" ]
then
    SKIP "Creating systemd service"
else
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
User=$TOMCAT_USER
Group=$TOMCAT_USER

Environment="JAVA_HOME=$JAVA_HOME_PATH"
Environment="CATALINA_HOME=$TOMCAT_SYMLINK"
Environment="CATALINA_BASE=$TOMCAT_SYMLINK"
Environment="CATALINA_PID=$TOMCAT_SYMLINK/temp/tomcat.pid"

ExecStart=$TOMCAT_SYMLINK/bin/startup.sh
ExecStop=$TOMCAT_SYMLINK/bin/shutdown.sh
PIDFile=$TOMCAT_SYMLINK/temp/tomcat.pid

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    VALIDATE $? "Creating systemd service"

    systemctl daemon-reload &>> "$LOGFILE"
    VALIDATE $? "Reloading systemd"

    NEED_RESTART="true"
fi

if systemctl is-enabled tomcat &>/dev/null
then
    SKIP "Enabling Tomcat on boot"
else
    systemctl enable tomcat &>> "$LOGFILE"
    VALIDATE $? "Enabling Tomcat on boot"
fi


# ------------------------------------------------------------
# Start / Restart Tomcat
# ------------------------------------------------------------

if systemctl is-active tomcat &>/dev/null && [ "$NEED_RESTART" = "false" ]
then
    SKIP "Starting Tomcat (already running, nothing changed)"
else
    systemctl restart tomcat &>> "$LOGFILE"
    VALIDATE $? "Starting Tomcat"
fi


# ------------------------------------------------------------
# Verify Tomcat
# ------------------------------------------------------------

echo
echo "Waiting for Tomcat to listen on port 8080..."

for i in {1..30}
do
    if netstat -lnt | grep -q ':8080 '
    then
        break
    fi
    sleep 2
done

netstat -lnt | grep -q ':8080 '
VALIDATE $? "Checking Tomcat is listening on port 8080"

"$TOMCAT_SYMLINK"/bin/version.sh &>> "$LOGFILE"
VALIDATE $? "Checking Tomcat version"


# ------------------------------------------------------------
# Completed
# ------------------------------------------------------------

echo
echo "============================================================"
echo -e "$G Tomcat Installation Completed Successfully $N"
echo "============================================================"
echo

echo "Java Version:"
java -version

echo
echo "Tomcat Version:"
"$TOMCAT_SYMLINK"/bin/version.sh 2>/dev/null | grep -E 'Server (version|number)'

echo
echo "Tomcat Home    : $TOMCAT_SYMLINK  ->  $TOMCAT_HOME"
echo "Java Home      : $JAVA_HOME_PATH"
echo "URL            : http://<server-ip>:8080"
echo "Manager GUI    : http://<server-ip>:8080/manager/html"
echo "Admin User     : $TOMCAT_ADMIN_USER"

if [ -d "$TOMCAT_HOME/conf" ] && grep -q "$TOMCAT_ADMIN_PASSWORD" "$TOMCAT_HOME/conf/tomcat-users.xml"
then
    echo "Admin Password : $TOMCAT_ADMIN_PASSWORD"
else
    echo -e "Admin Password : $Y unchanged (already configured on first install) $N"
fi

echo "Log File       : $LOGFILE"
echo
echo "Manage service : systemctl status|stop|start|restart tomcat"