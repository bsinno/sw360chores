#!/usr/bin/env bash

# Copyright Bosch Software Innovations GmbH, 2016.
# Part of the SW360 Portal Project.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# which accompanies this distribution, and is available at
# http://www.eclipse.org/legal/epl-v10.html

# the used / parsed environmental variables are:
#
# for liferay
#    $PORTAL_EXT_PROPERTIES (dafaults to: "")
#    $PROTOCOL (defaults to: "https")
#    $PORT (defaults to: "8443")
#
# for postgres configuration
#    $POSTGRES_HOST (defaults to: "localhost")
#    $POSTGRES_USER (optional)
#    $POSTGRES_PASSWORD (optional)
#
# for couchdb configuration
#    $COUCHDB_HOST (defaults to: "localhost")
#    $COUCHDB_USER (optional)
#    $COUCHDB_PASSWORD (optional)
#
# for trusting SSL certificates
#    $HTTPS_HOSTS (optional)
#    $JAVA_HOME (defaults to: path where java lies)
#
# for setting up cve-search connection
#    $CVE_SEARCH_HOST (optional)
#
# for LDAP configuration
#    $LDAP_HOST (e.g. ldap://10.1.2.100:389)
#    $LDAP_BASE_DN (e.g. ou=Users,o=Example)
#    $LDAP_PRINCIPAL (e.g. cn=LDAP1,ou=Users,o=Example)
#    $LDAP_CREDENTIALS (e.g. Password)

set -e

################################################################################
# Setup JAVA_OPTS
if [ "$JAVA_OPTS_EXT" ]; then
    cat <<EOF > /opt/sw360/bin/setenv.sh
#!/usr/bin/env bash
JAVA_OPTS="\$JAVA_OPTS $JAVA_OPTS_EXT"
EOF
fi

################################################################################
# Setup liferay
mkdir -p /etc/sw360/
EXT_PROPERTIES_FILE=/etc/sw360/portal-ext.properties
echo > $EXT_PROPERTIES_FILE
if [[ $PORTAL_EXT_PROPERTIES ]]; then
    echo -e "$PORTAL_EXT_PROPERTIES" >> $EXT_PROPERTIES_FILE
fi
if [[ $PORT ]]; then
    echo "web.server.https.port=$PORT" >> $EXT_PROPERTIES_FILE
fi

# Setup postgres for liferay
if [ ! "$POSTGRES_HOST" ] || [ ! "$POSTGRES_USER" ] || [ ! "$POSTGRES_PASSWORD" ]; then
    echo "postgres configuration incomplete"
    exit 1
fi
cat <<EOF >> $EXT_PROPERTIES_FILE
jdbc.default.driverClassName=org.postgresql.Driver
jdbc.default.url=jdbc:postgresql://${POSTGRES_HOST:-localhost}:5432/sw360pgdb
jdbc.default.username=$POSTGRES_USER
jdbc.default.password=$POSTGRES_PASSWORD
EOF
export DB_TYPE=POSTGRESQL

################################################################################
# Setup sw360
mkdir -p /etc/sw360
if [ "$SW360_PROPERTIES" ]; then
    echo -e "$SW360_PROPERTIES" > /etc/sw360/sw360.properties
fi

################################################################################
# Setup couchdb
echo "couchdb.url = http://${COUCHDB_HOST:-localhost}:5984" > /etc/sw360/couchdb.properties
if [ "$COUCHDB_USER" ]; then
    echo "couchdb.user = $COUCHDB_USER" >> /etc/sw360/couchdb.properties
fi
if [ "$COUCHDB_PASSWORD" ]; then
    echo "couchdb.password = $COUCHDB_PASSWORD" >> /etc/sw360/couchdb.properties
fi
echo >> /etc/sw360/couchdb.properties

################################################################################
# Setup for HTTPS hosts
#
# $HTTPS_HOSTS should be a comma seperated list if `host:port` pairs, e.g.
#    "some.bdp_host.org:443,an.ldaps.host:636"
[[ "$JAVA_HOME" ]] || JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")
if [ "$HTTPS_HOSTS" ]; then
    for HOST in $(echo $HTTPS_HOSTS | sed "s/,/ /g"); do
        echo "Trust certificate of host $HOST ..."
        openssl s_client -connect "${HOST}" < /dev/null \
            | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > public.crt

        keytool -keystore "$JAVA_HOME/lib/security/cacerts" \
                -alias "$HOST" \
                -storepass changeit \
                -noprompt \
                -import -file public.crt || continue
    done
fi

################################################################################
# Setup for trusted Certificate Authorities
#
# $TRUSTED_CACERTS should be a comma separated list of environment variable
# names, e.g.:
# "TRUSTED_CA1,TRUSTED_CA2"
# Mentioned variables ($TRUSTED_CA1 and $TRUSTED_CA2 in this example) should
# contain the certificates, e.g.:
# -----BEGIN CERTIFICATE-----
# AAAAAAAAAAAAAAAAAAAAAAAAAAAA
# -----END CERTIFICATE-----
if [ "$TRUSTED_CACERTS" ]; then
    for CERT_NAME in $(echo $TRUSTED_CACERTS | sed "s/,/ /g"); do
        if [ "${!CERT_NAME}" ]; then
          echo "Trust certificate $CERT_NAME ..."
          OUT="$(mktemp).crt"
          echo -e "${!CERT_NAME}" > $OUT
          keytool -keystore "$JAVA_HOME/lib/security/cacerts" \
                  -alias "$CERT_NAME" \
                  -storepass changeit \
                  -noprompt \
                  -import -file $OUT
        fi
    done
fi

################################################################################
# Setup for cve-search
if [ "$CVE_SEARCH_HOST" ]; then
    echo "cvesearch.host = $CVE_SEARCH_HOST" > /etc/sw360/cvesearch.properties
fi

################################################################################
# Setup for FOSSology
if [ "$FOSSOLOGY_HOST" ] && [ "$FOSSOLOGY_PORT" ]; then
    echo "fossology.host = $FOSSOLOGY_HOST" > /etc/sw360/fossology.properties
    echo "fossology.port = $FOSSOLOGY_PORT" >> /etc/sw360/fossology.properties
    if [ "$FOSSOLOGY_USER" ]; then
        echo "fossology.user = $FOSSOLOGY_USER" >> /etc/sw360/fossology.properties
    fi
    if [ "$FOSSOLOGY_KEY_PRIV" ]; then
        echo "$FOSSOLOGY_KEY_PRIV" > /etc/sw360/fossology.id_rsa
        chmod 600 /etc/sw360/fossology.id_rsa
    fi
    if [ "$FOSSOLOGY_KEY_PUB" ]; then
        echo "$FOSSOLOGY_KEY_PUB" > /etc/sw360/fossology.id_rsa.pub
        chmod 600 /etc/sw360/fossology.id_rsa.pub
    fi
fi

################################################################################
# Setup for ldap importer
mkdir -p /etc/ldap-importer
if [[ $LDAP_IMPORTER_CONFIGURATION ]]; then
    echo -e "$LDAP_IMPORTER_CONFIGURATION" >> /etc/ldap-importer/ldapimporter.properties
fi

################################################################################
# Startup apache
CATALINA_OPTS=""
if [ "$TOMCAT_DEBUG_PORT" ] && [[ "$TOMCAT_DEBUG_PORT" =~ ^[0-9]+$ ]]; then
    CATALINA_OPTS+="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=${TOMCAT_DEBUG_PORT} "
    CATALINA_OPTS+="-Dorg.ektorp.support.AutoUpdateViewOnChange=true "
fi
DB_TYPE="$DB_TYPE" CATALINA_OPTS="$CATALINA_OPTS" /opt/sw360/bin/startup.sh

################################################################################
exec "$@"