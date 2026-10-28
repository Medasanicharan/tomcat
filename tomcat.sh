#!/bin/bash

# ============================================================
# Apache Tomcat Installation Script
# OS             : RHEL 10
# Java           : OpenJDK 21
# Default Tomcat : Latest stable Tomcat 9.x
# Install path   : /opt/tomcat
# Service user   : tomcat
# Service name   : tomcat
#
# Usage:
#   sudo bash tomcat.sh
#
# Optional:
#   sudo env TOMCAT_MAJOR=10 bash tomcat.sh
#   sudo env TOMCAT_MAJOR=11 bash tomcat.sh
#
# Admin password:
#   Enter interactively when prompted, or supply
#   TOMCAT_ADMIN_PASSWORD through a secure environment.
# ============================================================

set -Eeuo pipefail
umask 027

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

JAVA_VERSION="21"

TOMCAT_MAJOR="${TOMCAT_MAJOR:-9}"
TOMCAT_BASE_DIR="/opt"
TOMCAT_SYMLINK="/opt/tomcat"
TOMCAT_USER="tomcat"

TOMCAT_ADMIN_USER="${TOMCAT_ADMIN_USER:-admin}"
TOMCAT_ADMIN_PASSWORD="${TOMCAT_ADMIN_PASSWORD:-}"

TOMCAT_INDEX_URL="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR}/"

PROFILE_FILE="/etc/profile.d/tomcat.sh"
SERVICE_FILE="/etc/systemd/system/tomcat.service"

LOGFILE="/var/log/tomcat-install-$(date +%F-%H-%M-%S).log"

# ------------------------------------------------------------
# Root Check
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script with root privileges."
    echo "Example: sudo bash tomcat.sh"
    exit 1
fi

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

touch "$LOGFILE"
chmod 600 "$LOGFILE"

exec > >(tee -a "$LOGFILE") 2>&1

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

log() {
    printf '[INFO] %s\n' "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    printf 'Log file: %s\n' "$LOGFILE" >&2
    exit 1
}

validate() {
    local status="$1"
    local message="$2"

    if [[ "$status" -eq 0 ]]; then
        log "$message: SUCCESS"
    else
        die "$message: FAILED"
    fi
}

# ------------------------------------------------------------
# Validate Configuration
# ------------------------------------------------------------

case "$TOMCAT_MAJOR" in
    9|10|11)
        ;;
    *)
        die "TOMCAT_MAJOR must be 9, 10, or 11."
        ;;
esac

if [[ ! "$TOMCAT_ADMIN_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Invalid admin username."
fi

if [[ -z "$TOMCAT_ADMIN_PASSWORD" ]]; then
    if [[ ! -t 0 ]]; then
        die "Set TOMCAT_ADMIN_PASSWORD securely when running non-interactively."
    fi

    read -r -s -p "Enter Tomcat admin password: " TOMCAT_ADMIN_PASSWORD
    echo

    read -r -s -p "Confirm Tomcat admin password: " CONFIRM_PASSWORD
    echo

    if [[ "$TOMCAT_ADMIN_PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
        die "Passwords do not match."
    fi

    unset CONFIRM_PASSWORD
fi

if (( ${#TOMCAT_ADMIN_PASSWORD} < 15 )); then
    die "Use an admin password of at least 15 characters."
fi

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Apache Tomcat Installation"
echo "============================================================"
echo "Java version : $JAVA_VERSION"
echo "Tomcat major : $TOMCAT_MAJOR"
echo "Install path : $TOMCAT_SYMLINK"
echo "Service user : $TOMCAT_USER"
echo "Log file     : $LOGFILE"
echo

# ------------------------------------------------------------
# Install Required Packages
# ------------------------------------------------------------

log "Installing required packages"

dnf install -y \
    curl \
    wget \
    tar \
    gzip \
    python3 \
    "java-${JAVA_VERSION}-openjdk-devel"

validate $? "Installing packages"

# ------------------------------------------------------------
# Detect Java
# ------------------------------------------------------------

JAVA_BIN="$(command -v javac || true)"

[[ -n "$JAVA_BIN" ]] || die "javac not found."

JAVA_HOME_PATH="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")"

[[ -x "$JAVA_HOME_PATH/bin/java" ]] || die "Java executable not found."

export JAVA_HOME="$JAVA_HOME_PATH"
export PATH="$JAVA_HOME/bin:$PATH"

log "Java installation:"
"$JAVA_HOME/bin/java" -version
"$JAVA_HOME/bin/javac" -version

# # ------------------------------------------------------------
# # Detect Latest Stable Tomcat Version
# # ------------------------------------------------------------

# log "Detecting latest Tomcat ${TOMCAT_MAJOR}.x release"

# TOMCAT_LISTING="$(
#     curl -fsSL --retry 3 "$TOMCAT_INDEX_URL"
# )" || die "Unable to access Apache Tomcat release index."

# TOMCAT_VERSION="$(
#     printf '%s\n' "$TOMCAT_LISTING" |
#         grep -oP 'href="\Kv[0-9]+\.[0-9]+\.[0-9]+(?=/")' |
#         sed 's/^v//' |
#         awk -v major="$TOMCAT_MAJOR" \
#             'BEGIN { FS="." }
#              $1 == major && (major != 10 || $2 == 1) { print }' |
#         sort -Vu |
#         tail -n 1
# )"

# [[ -n "$TOMCAT_VERSION" ]] ||
#     die "Unable to detect a supported Tomcat release."

# log "Selected Tomcat version: $TOMCAT_VERSION"

# # ------------------------------------------------------------
# # Download and Verify Tomcat
# # ------------------------------------------------------------

# TOMCAT_HOME="${TOMCAT_BASE_DIR}/apache-tomcat-${TOMCAT_VERSION}"
# TOMCAT_ARCHIVE="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
# TOMCAT_URL="${TOMCAT_INDEX_URL}v${TOMCAT_VERSION}/bin/${TOMCAT_ARCHIVE}"

# if [[ ! -d "$TOMCAT_HOME" ]]; then

#     TEMP_DIR="$(mktemp -d /tmp/tomcat-install.XXXXXX)"
#     trap 'rm -rf "${TEMP_DIR:-}"' EXIT

#     log "Downloading Tomcat $TOMCAT_VERSION"

#     curl -fL --retry 3 \
#         "$TOMCAT_URL" \
#         -o "$TEMP_DIR/$TOMCAT_ARCHIVE"

#     validate $? "Downloading Tomcat"

#     log "Downloading SHA512 checksum"

#     curl -fsSL --retry 3 \
#         "${TOMCAT_URL}.sha512" \
#         -o "$TEMP_DIR/checksum.txt"

#     validate $? "Downloading checksum"

#     EXPECTED_SHA="$(
#         grep -oE '[[:xdigit:]]{128}' "$TEMP_DIR/checksum.txt" |
#             head -n 1
#     )"

#     [[ -n "$EXPECTED_SHA" ]] ||
#         die "Invalid or missing SHA512 checksum."

#     ACTUAL_SHA="$(
#         sha512sum "$TEMP_DIR/$TOMCAT_ARCHIVE" |
#             awk '{print $1}'
#     )"

#     [[ "${ACTUAL_SHA,,}" == "${EXPECTED_SHA,,}" ]] ||
#         die "Tomcat SHA512 verification failed."

#     log "SHA512 verification: SUCCESS"

#     # Extract into a staging directory first.
#     mkdir "$TEMP_DIR/extracted"

#     tar -xzf "$TEMP_DIR/$TOMCAT_ARCHIVE" \
#         -C "$TEMP_DIR/extracted"

#     validate $? "Extracting Tomcat"

#     [[ -d "$TEMP_DIR/extracted/apache-tomcat-${TOMCAT_VERSION}" ]] ||
#         die "Unexpected Tomcat archive layout."

#     mv "$TEMP_DIR/extracted/apache-tomcat-${TOMCAT_VERSION}" \
#         "$TOMCAT_HOME"

#     validate $? "Installing Tomcat files"

# else
#     log "Tomcat $TOMCAT_VERSION already exists; skipping download."
# fi

# # ------------------------------------------------------------
# # Create Dedicated Service Account
# # ------------------------------------------------------------

# if id "$TOMCAT_USER" >/dev/null 2>&1; then
#     log "Service account $TOMCAT_USER already exists."
# else
#     useradd \
#         --system \
#         --home-dir "$TOMCAT_SYMLINK" \
#         --shell /sbin/nologin \
#         "$TOMCAT_USER"

#     validate $? "Creating Tomcat service account"
# fi

# # ------------------------------------------------------------
# # Configure Tomcat Admin User
# # ------------------------------------------------------------
# # Remove XML comments before changing active entries.
# # Preserve other active users and insert exactly one admin user.

# TOMCAT_USERS_FILE="$TOMCAT_HOME/conf/tomcat-users.xml"

# [[ -f "$TOMCAT_USERS_FILE" ]] ||
#     die "Missing file: $TOMCAT_USERS_FILE"

# export TOMCAT_ADMIN_USER TOMCAT_ADMIN_PASSWORD

# python3 - "$TOMCAT_USERS_FILE" <<'PYTHON'
# import os
# import re
# import sys
# import tempfile
# import xml.etree.ElementTree as ET
# from pathlib import Path
# from xml.sax.saxutils import escape, quoteattr

# path = Path(sys.argv[1])
# content = path.read_text(encoding="utf-8")

# # Remove XML comments so example users in comments are not
# # accidentally treated as active user entries.
# content = re.sub(r"<!--.*?-->", "", content, flags=re.S)

# username = os.environ["TOMCAT_ADMIN_USER"]
# password = os.environ["TOMCAT_ADMIN_PASSWORD"]

# # Remove any active entry for this admin username.
# user_pattern = re.compile(
#     r"<user\b(?=[^>]*\busername\s*=\s*"
#     + quoteattr(username)
#     + r")(?=[^>]*?/?>)[^>]*/\s*>",
#     flags=re.S,
# )
# content = user_pattern.sub("", content)

# # XML-escape the password to keep the XML valid.
# escaped_password = escape(password, {'"': "&quot;", "'": "&apos;"})

# admin_entry = (
#     f'  <user username="{username}" '
#     f'password="{escaped_password}" '
#     'roles="manager-gui,admin-gui"/>'
# )

# if not re.search(r"</tomcat-users\s*>", content, flags=re.I):
#     raise SystemExit("ERROR: Missing closing tomcat-users element.")

# content = re.sub(
#     r"</tomcat-users\s*>",
#     admin_entry + "\n</tomcat-users>",
#     content,
#     count=1,
#     flags=re.I,
# )

# # Validate the generated XML before replacing the original.
# ET.fromstring(content)

# fd, temp_name = tempfile.mkstemp(
#     prefix="tomcat-users.",
#     dir=str(path.parent),
#     text=True,
# )

# try:
#     with os.fdopen(fd, "w", encoding="utf-8") as stream:
#         stream.write(content)
#         stream.flush()
#         os.fsync(stream.fileno())

#     os.chmod(temp_name, 0o640)
#     os.replace(temp_name, path)
# except Exception:
#     try:
#         os.unlink(temp_name)
#     except FileNotFoundError:
#         pass
#     raise

# print("Tomcat admin user configured and XML validated.")
# PYTHON

# validate $? "Configuring Tomcat admin user"

# unset TOMCAT_ADMIN_PASSWORD

# ------------------------------------------------------------
# Secure File Ownership and Permissions
# ------------------------------------------------------------

chown -R root:"$TOMCAT_USER" "$TOMCAT_HOME"
validate $? "Setting Tomcat installation ownership"

# Root can modify files; Tomcat group can read and execute.
chmod -R u=rwX,g=rX,o= "$TOMCAT_HOME"
validate $? "Setting Tomcat installation permissions"

# Tomcat needs write access to runtime directories only.
for DIR in logs temp work
do
    mkdir -p "$TOMCAT_HOME/$DIR"
    chown -R "$TOMCAT_USER":"$TOMCAT_USER" "$TOMCAT_HOME/$DIR"
    chmod 750 "$TOMCAT_HOME/$DIR"
done

chown root:"$TOMCAT_USER" "$TOMCAT_USERS_FILE"
chmod 640 "$TOMCAT_USERS_FILE"

chmod 750 "$TOMCAT_HOME"/bin/*.sh

# ------------------------------------------------------------
# Create Stable Symlink
# /opt/tomcat -> /opt/apache-tomcat-<version>
# ------------------------------------------------------------

if [[ -e "$TOMCAT_SYMLINK" && ! -L "$TOMCAT_SYMLINK" ]]; then
    die "$TOMCAT_SYMLINK exists and is not a symlink. Inspect it first."
fi

ln -sfn "$TOMCAT_HOME" "$TOMCAT_SYMLINK"
validate $? "Creating Tomcat symbolic link"

# ------------------------------------------------------------
# Configure Environment Variables
# ------------------------------------------------------------

cat > "$PROFILE_FILE" <<EOF
# Apache Tomcat
export JAVA_HOME="$JAVA_HOME_PATH"
export CATALINA_HOME="$TOMCAT_SYMLINK"
export CATALINA_BASE="$TOMCAT_SYMLINK"
export PATH="\$CATALINA_HOME/bin:\$JAVA_HOME/bin:\$PATH"
EOF

chmod 644 "$PROFILE_FILE"
validate $? "Configuring Tomcat environment variables"

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

chmod 644 "$SERVICE_FILE"

systemctl daemon-reload
validate $? "Reloading systemd"

systemctl enable tomcat
validate $? "Enabling Tomcat at boot"

# ------------------------------------------------------------
# Start / Restart Tomcat
# ------------------------------------------------------------

log "Restarting Tomcat"

systemctl restart tomcat
validate $? "Starting Tomcat service"

# ------------------------------------------------------------
# Verify Service and HTTP Connector
# ------------------------------------------------------------

log "Waiting for Tomcat on port 8080"

HTTP_STATUS="000"

for ATTEMPT in {1..30}
do
    HTTP_STATUS="$(
        curl -sS \
            --connect-timeout 2 \
            --max-time 3 \
            -o /dev/null \
            -w '%{http_code}' \
            http://127.0.0.1:8080/ 2>/dev/null || true
    )"

    if [[ "$HTTP_STATUS" != "000" ]]; then
        break
    fi

    sleep 2
done

[[ "$HTTP_STATUS" != "000" ]] ||
    {
        systemctl status tomcat --no-pager || true
        journalctl -u tomcat -n 50 --no-pager || true
        die "Tomcat did not respond on port 8080."
    }

systemctl is-active --quiet tomcat ||
    die "Tomcat systemd service is not active."

# ------------------------------------------------------------
# Installation Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Tomcat Installation Completed Successfully"
echo "============================================================"
echo

echo "Java Version:"
"$JAVA_HOME_PATH/bin/java" -version

echo
echo "Tomcat Version:"
"$TOMCAT_SYMLINK/bin/version.sh" 2>&1 |
    grep -E 'Server version|Server number|JVM Version' || true

echo
echo "Tomcat Home     : $TOMCAT_SYMLINK"
echo "Tomcat Real Path: $TOMCAT_HOME"
echo "Java Home       : $JAVA_HOME_PATH"
echo "Service         : $(systemctl is-active tomcat)"
echo "HTTP Status     : $HTTP_STATUS"
echo "Application URL : http://<server-ip>:8080"
echo "Manager URL     : http://<server-ip>:8080/manager/html"
echo "Admin Username  : $TOMCAT_ADMIN_USER"
echo "Log File        : $LOGFILE"
echo
echo "Check service: systemctl status tomcat"
echo "View logs    : journalctl -u tomcat -f"
echo
echo "Security: Tomcat Manager remote access remains restricted"
echo "by the default application context configuration."
echo "Restrict port 8080 using your AWS Security Group."
echo "============================================================"