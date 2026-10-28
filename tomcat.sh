#!/bin/bash

# ============================================================
# Java 21 + Latest Stable Apache Tomcat
# Operating System: RHEL 10
# Default Tomcat  : Latest 9.x  (override: TOMCAT_MAJOR=10 or 11)
# Install path    : /opt/tomcat
# Service user    : tomcat
# Service name    : tomcat
#
# Usage:
#   sudo bash tomcat.sh
#   sudo env TOMCAT_MAJOR=10 bash tomcat.sh
# ============================================================

set -o pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

JAVA_VERSION="21"

TOMCAT_MAJOR="${TOMCAT_MAJOR:-9}"
TOMCAT_BASE_DIR="/opt"
TOMCAT_SYMLINK="/opt/tomcat"
TOMCAT_USER="tomcat"
TOMCAT_INDEX_URL="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR}/"

PROFILE_FILE="/etc/profile.d/tomcat.sh"
SERVICE_FILE="/etc/systemd/system/tomcat.service"
RUN_SYSTEM_UPDATE="${RUN_SYSTEM_UPDATE:-false}"

LOGFILE="/tmp/tomcat-install-$(date +%F-%H-%M-%S).log"

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

VALIDATE() {
    local STATUS="$1"
    local MESSAGE="$2"

    if [ "$STATUS" -eq 0 ]; then
        echo "$MESSAGE... SUCCESS"
    else
        echo "$MESSAGE... FAILURE"
        echo "Check log file: $LOGFILE"
        exit 1
    fi
}

SKIP() {
    echo "$1... SKIPPING (already done)"
}

# ------------------------------------------------------------
# Root Check
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this script with root access."
    echo "Command: sudo bash tomcat.sh"
    exit 1
fi

touch "$LOGFILE" || {
    echo "ERROR: Cannot create log file."
    exit 1
}

case "$TOMCAT_MAJOR" in
    9|10|11) ;;
    *)
        echo "ERROR: TOMCAT_MAJOR must be 9, 10, or 11."
        exit 1
        ;;
esac

echo
echo "============================================================"
echo " Java + Latest Tomcat ${TOMCAT_MAJOR}.x Installation"
echo "============================================================"
echo
echo "Java Version : $JAVA_VERSION"
echo "Tomcat Major : $TOMCAT_MAJOR"
echo "Tomcat Home  : $TOMCAT_SYMLINK"
echo "Service User : $TOMCAT_USER"
echo "Log File     : $LOGFILE"
echo

# ------------------------------------------------------------
# Optional System Update
# ------------------------------------------------------------

if [ "$RUN_SYSTEM_UPDATE" = "true" ]; then
    dnf update -y --allowerasing >> "$LOGFILE" 2>&1
    VALIDATE $? "System package update"
else
    SKIP "System package update"
fi

# ------------------------------------------------------------
# Required Packages
# ------------------------------------------------------------

MISSING_PKGS=""

for PKG in wget curl tar gzip
do
    if ! rpm -q "$PKG" >/dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS $PKG"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    dnf install -y $MISSING_PKGS >> "$LOGFILE" 2>&1
    VALIDATE $? "Installing required packages"
else
    SKIP "Required packages"
fi

# ------------------------------------------------------------
# Install Java 21 JDK
# ------------------------------------------------------------

if rpm -q "java-${JAVA_VERSION}-openjdk-devel" >/dev/null 2>&1; then
    SKIP "Java ${JAVA_VERSION} JDK"
else
    dnf install -y "java-${JAVA_VERSION}-openjdk-devel" \
        >> "$LOGFILE" 2>&1
    VALIDATE $? "Installing Java ${JAVA_VERSION} JDK"
fi

JAVAC_PATH=$(command -v javac)

if [ -z "$JAVAC_PATH" ]; then
    echo "ERROR: javac was not found."
    exit 1
fi

JAVA_HOME_PATH=$(dirname "$(dirname "$(readlink -f "$JAVAC_PATH")")")

if [ ! -x "$JAVA_HOME_PATH/bin/java" ]; then
    echo "ERROR: Java executable not found under $JAVA_HOME_PATH"
    exit 1
fi

export JAVA_HOME="$JAVA_HOME_PATH"
export PATH="$JAVA_HOME/bin:$PATH"

"$JAVA_HOME/bin/java" -version >> "$LOGFILE" 2>&1
VALIDATE $? "Checking Java installation"

"$JAVA_HOME/bin/javac" -version >> "$LOGFILE" 2>&1
VALIDATE $? "Checking Java compiler"

# ------------------------------------------------------------
# Detect Latest Stable Tomcat Version
# ------------------------------------------------------------

echo
echo "Detecting latest stable Tomcat ${TOMCAT_MAJOR}.x version..."

TOMCAT_VERSION=$(
    curl -fsSL "$TOMCAT_INDEX_URL" 2>> "$LOGFILE" |
        grep -oP "href=\"v\K${TOMCAT_MAJOR}\.[0-9]+\.[0-9]+(?=/\")" |
        sort -Vu |
        tail -n 1
)

if [ -z "$TOMCAT_VERSION" ]; then
    echo "ERROR: Could not detect the latest Tomcat ${TOMCAT_MAJOR}.x version."
    echo "URL: $TOMCAT_INDEX_URL"
    echo "Check log: $LOGFILE"
    exit 1
fi

echo "Latest Tomcat ${TOMCAT_MAJOR}.x Version: $TOMCAT_VERSION"

# ------------------------------------------------------------
# Tomcat Paths
# ------------------------------------------------------------

TOMCAT_HOME="${TOMCAT_BASE_DIR}/apache-tomcat-${TOMCAT_VERSION}"
TOMCAT_ARCHIVE="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
TOMCAT_URL="${TOMCAT_INDEX_URL}v${TOMCAT_VERSION}/bin/${TOMCAT_ARCHIVE}"
TOMCAT_USERS_FILE="${TOMCAT_HOME}/conf/tomcat-users.xml"

echo "Tomcat URL  : $TOMCAT_URL"
echo "Tomcat Home : $TOMCAT_HOME"
echo

cd "$TOMCAT_BASE_DIR" >> "$LOGFILE" 2>&1
VALIDATE $? "Changing to $TOMCAT_BASE_DIR"

# ------------------------------------------------------------
# Download, Verify and Extract Tomcat
# ------------------------------------------------------------

if [ -d "$TOMCAT_HOME" ]; then
    SKIP "Tomcat $TOMCAT_VERSION download and extraction"
else
    wget -q "$TOMCAT_URL" -O "$TOMCAT_ARCHIVE" \
        >> "$LOGFILE" 2>&1
    VALIDATE $? "Downloading Tomcat"

    EXPECTED_SHA=$(
        curl -fsSL "${TOMCAT_URL}.sha512" 2>> "$LOGFILE" |
            awk '{print $1}'
    )

    if [ -z "$EXPECTED_SHA" ]; then
        echo "ERROR: Could not retrieve the Tomcat SHA512 checksum."
        exit 1
    fi

    echo "${EXPECTED_SHA}  ${TOMCAT_ARCHIVE}" |
        sha512sum -c - >> "$LOGFILE" 2>&1
    VALIDATE $? "Verifying Tomcat SHA512 checksum"

    tar -xzf "$TOMCAT_ARCHIVE" >> "$LOGFILE" 2>&1
    VALIDATE $? "Extracting Tomcat"

    rm -f "$TOMCAT_ARCHIVE"
    VALIDATE $? "Removing Tomcat archive"
fi

if [ ! -x "$TOMCAT_HOME/bin/catalina.sh" ]; then
    echo "ERROR: Tomcat executable not found:"
    echo "$TOMCAT_HOME/bin/catalina.sh"
    exit 1
fi

# ------------------------------------------------------------
# Create Dedicated Service Account
# ------------------------------------------------------------

if id "$TOMCAT_USER" >/dev/null 2>&1; then
    SKIP "Service account $TOMCAT_USER"
else
    useradd --system \
        --home-dir "$TOMCAT_SYMLINK" \
        --shell /sbin/nologin \
        "$TOMCAT_USER" >> "$LOGFILE" 2>&1
    VALIDATE $? "Creating Tomcat service account"
fi

# ------------------------------------------------------------
# Configure tomcat-users.xml (content written exactly as provided)
# ------------------------------------------------------------

if [ ! -f "${TOMCAT_USERS_FILE}.orig" ]; then
    cp -p "$TOMCAT_USERS_FILE" "${TOMCAT_USERS_FILE}.orig" \
        >> "$LOGFILE" 2>&1
    VALIDATE $? "Backing up original tomcat-users.xml"
else
    SKIP "tomcat-users.xml backup"
fi

cat > "$TOMCAT_USERS_FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Licensed to the Apache Software Foundation (ASF) under one or more
  contributor license agreements.  See the NOTICE file distributed with
  this work for additional information regarding copyright ownership.
  The ASF licenses this file to You under the Apache License, Version 2.0
  (the "License"); you may not use this file except in compliance with
  the License.  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-->
<tomcat-users xmlns="http://tomcat.apache.org/xml"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://tomcat.apache.org/xml tomcat-users.xsd"
              version="1.0">
<!--
  By default, no user is included in the "manager-gui" role required
  to operate the "/manager/html" web application.  If you wish to use this app,
  you must define such a user - the username and password are arbitrary.

  Built-in Tomcat manager roles:
    - manager-gui    - allows access to the HTML GUI and the status pages
    - manager-script - allows access to the HTTP API and the status pages
    - manager-jmx    - allows access to the JMX proxy and the status pages
    - manager-status - allows access to the status pages only

  The users below are wrapped in a comment and are therefore ignored. If you
  wish to configure one or more of these users for use with the manager web
  application, do not forget to remove the <!.. ..> that surrounds them. You
  will also need to set the passwords to something appropriate.
-->
<!--
  <user username="admin" password="<must-be-changed>" roles="manager-gui"/>
  <user username="robot" password="<must-be-changed>" roles="manager-script"/>
-->
  <user username="admin" password="Bangalore@2026" roles="manager-gui,admin-gui"/>
  <user username="admin" password="Bangalore@20256" roles="manager-gui,admin-gui"/>
<!--
  The sample user and role entries below are intended for use with the
  examples web application. They are wrapped in a comment and thus are ignored
  when reading this file. If you wish to configure these users for use with the
  examples web application, do not forget to remove the <!.. ..> that surrounds
  them. You will also need to set the passwords to something appropriate.
-->
<!--
  <role rolename="tomcat"/>
  <role rolename="role1"/>
  <user username="tomcat" password="<must-be-changed>" roles="tomcat"/>
  <user username="both" password="<must-be-changed>" roles="tomcat,role1"/>
  <user username="role1" password="<must-be-changed>" roles="role1"/>
-->
</tomcat-users>
EOF

VALIDATE $? "Writing tomcat-users.xml"

# ------------------------------------------------------------
# Ownership and Permissions
# ------------------------------------------------------------

chown -R root:"$TOMCAT_USER" "$TOMCAT_HOME" >> "$LOGFILE" 2>&1
VALIDATE $? "Setting Tomcat ownership"

chmod -R u=rwX,g=rX,o= "$TOMCAT_HOME" >> "$LOGFILE" 2>&1
VALIDATE $? "Setting Tomcat permissions"

# Directories Tomcat must write to at runtime
mkdir -p "$TOMCAT_HOME/conf/Catalina"

for DIR in logs temp work webapps conf/Catalina
do
    mkdir -p "$TOMCAT_HOME/$DIR"
    chown -R "$TOMCAT_USER":"$TOMCAT_USER" "$TOMCAT_HOME/$DIR"
    chmod -R u=rwX,g=rX,o= "$TOMCAT_HOME/$DIR"
done
VALIDATE $? "Setting runtime directory permissions"

chown root:"$TOMCAT_USER" "$TOMCAT_USERS_FILE"
chmod 640 "$TOMCAT_USERS_FILE"
VALIDATE $? "Securing tomcat-users.xml"

chmod 750 "$TOMCAT_HOME"/bin/*.sh
VALIDATE $? "Setting script permissions"

# ------------------------------------------------------------
# Create Stable Tomcat Symlink
# /opt/tomcat -> /opt/apache-tomcat-<version>
# ------------------------------------------------------------

if [ -e "$TOMCAT_SYMLINK" ] && [ ! -L "$TOMCAT_SYMLINK" ]; then
    echo "ERROR: $TOMCAT_SYMLINK exists and is not a symbolic link."
    echo "Inspect it before replacing anything."
    exit 1
fi

if [ "$(readlink -f "$TOMCAT_SYMLINK" 2>/dev/null)" = "$TOMCAT_HOME" ]; then
    SKIP "Tomcat symbolic link"
else
    ln -sfn "$TOMCAT_HOME" "$TOMCAT_SYMLINK" \
        >> "$LOGFILE" 2>&1
    VALIDATE $? "Creating Tomcat symbolic link"
fi

# ------------------------------------------------------------
# Configure Permanent Environment Variables
# ------------------------------------------------------------

cat > "$PROFILE_FILE" <<EOF
# Apache Tomcat and Java
export JAVA_HOME="$JAVA_HOME_PATH"
export CATALINA_HOME="$TOMCAT_SYMLINK"
export CATALINA_BASE="$TOMCAT_SYMLINK"
export PATH="\$CATALINA_HOME/bin:\$JAVA_HOME/bin:\$PATH"
EOF

VALIDATE $? "Configuring environment variables"

chmod 644 "$PROFILE_FILE"
VALIDATE $? "Setting profile permissions"

# ------------------------------------------------------------
# Configure systemd Service
# ------------------------------------------------------------

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=simple
User=$TOMCAT_USER
Group=$TOMCAT_USER
UMask=0027

Environment="JAVA_HOME=$JAVA_HOME_PATH"
Environment="CATALINA_HOME=$TOMCAT_SYMLINK"
Environment="CATALINA_BASE=$TOMCAT_SYMLINK"
Environment="CATALINA_TMPDIR=$TOMCAT_SYMLINK/temp"
Environment="JAVA_OPTS=-Djava.awt.headless=true"

ExecStart=$TOMCAT_SYMLINK/bin/catalina.sh run
ExecStop=$TOMCAT_SYMLINK/bin/catalina.sh stop

Restart=on-failure
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30
SuccessExitStatus=143
LimitNOFILE=65536

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

VALIDATE $? "Creating systemd service file"

chmod 644 "$SERVICE_FILE"
VALIDATE $? "Setting service file permissions"

systemctl daemon-reload >> "$LOGFILE" 2>&1
VALIDATE $? "Reloading systemd"

systemctl enable tomcat >> "$LOGFILE" 2>&1
VALIDATE $? "Enabling Tomcat at boot"

systemctl restart tomcat >> "$LOGFILE" 2>&1
VALIDATE $? "Starting Tomcat service"

# ------------------------------------------------------------
# Verify Service and HTTP Connector
# ------------------------------------------------------------

echo
echo "Waiting for Tomcat on port 8080..."

HTTP_STATUS="000"

for ATTEMPT in {1..30}
do
    HTTP_STATUS=$(
        curl -sS --connect-timeout 2 --max-time 3 \
            -o /dev/null -w '%{http_code}' \
            http://127.0.0.1:8080/ 2>/dev/null
    )

    if [ "$HTTP_STATUS" != "000" ]; then
        break
    fi

    sleep 2
done

if [ "$HTTP_STATUS" = "000" ]; then
    systemctl status tomcat --no-pager >> "$LOGFILE" 2>&1
    journalctl -u tomcat -n 50 --no-pager >> "$LOGFILE" 2>&1
    echo "ERROR: Tomcat did not respond on port 8080."
    echo "Check log file: $LOGFILE"
    exit 1
fi

systemctl is-active --quiet tomcat
VALIDATE $? "Checking Tomcat service status"

# ------------------------------------------------------------
# Installation Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Tomcat Installation Completed Successfully"
echo "============================================================"
echo

echo "Java Version:"
"$JAVA_HOME/bin/java" -version

echo
echo "Tomcat Version:"
"$TOMCAT_SYMLINK/bin/version.sh" 2>&1 |
    grep -E 'Server version|Server number|JVM Version'

echo
echo "Tomcat Home     : $TOMCAT_SYMLINK"
echo "Tomcat Real Path: $TOMCAT_HOME"
echo "Java Home       : $JAVA_HOME_PATH"
echo "Service         : $(systemctl is-active tomcat)"
echo "HTTP Status     : $HTTP_STATUS"
echo "Application URL : http://<server-ip>:8080"
echo "Manager URL     : http://<server-ip>:8080/manager/html"
echo "Log File        : $LOGFILE"
echo
echo "Check service: systemctl status tomcat"
echo "View logs    : journalctl -u tomcat -f"
echo "============================================================"