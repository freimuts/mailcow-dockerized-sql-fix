#!/bin/bash
set -e

# Wait for MySQL to warm-up
while ! mysqladmin status --socket=/var/run/mysqld/mysqld.sock -u${DBUSER} -p${DBPASS} --silent; do
  echo "Waiting for database to come up..."
  sleep 2
done

until dig +short mailcow.email > /dev/null; do
  echo "Waiting for DNS..."
  sleep 1
done

# Do not attempt to write to slave
if [[ ! -z ${REDIS_SLAVEOF_IP} ]]; then
  REDIS_CMDLINE="redis-cli -h ${REDIS_SLAVEOF_IP} -p ${REDIS_SLAVEOF_PORT}"
else
  REDIS_CMDLINE="redis-cli -h redis -p 6379"
fi

until [[ $(${REDIS_CMDLINE} PING) == "PONG" ]]; do
  echo "Waiting for Redis..."
  sleep 2
done

${REDIS_CMDLINE} SET DOVECOT_REPL_HEALTH 1 > /dev/null

# Create missing directories
[[ ! -d /etc/dovecot/sql/ ]] && mkdir -p /etc/dovecot/sql/
[[ ! -d /etc/dovecot/auth/ ]] && mkdir -p /etc/dovecot/auth/
[[ ! -d /var/vmail/_garbage ]] && mkdir -p /var/vmail/_garbage
[[ ! -d /var/vmail/sieve ]] && mkdir -p /var/vmail/sieve
[[ ! -d /etc/sogo ]] && mkdir -p /etc/sogo
[[ ! -d /var/volatile ]] && mkdir -p /var/volatile

# Set Dovecot sql config parameters, escape " in db password
DBPASS=$(echo ${DBPASS} | sed 's/"/\\"/g')

# Create quota dict for Dovecot
if [[ "${MASTER}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  QUOTA_TABLE=quota2
else
  QUOTA_TABLE=quota2replica
fi
cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-quota.conf
# Autogenerated by mailcow
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
map {
  pattern = priv/quota/storage
  table = ${QUOTA_TABLE}
  username_field = username
  value_field = bytes
}
map {
  pattern = priv/quota/messages
  table = ${QUOTA_TABLE}
  username_field = username
  value_field = messages
}
EOF

# Create dict used for sieve pre and postfilters
cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-sieve_before.conf
# Autogenerated by mailcow
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
map {
  pattern = priv/sieve/name/\$script_name
  table = sieve_before
  username_field = username
  value_field = id
  fields {
    script_name = \$script_name
  }
}
map {
  pattern = priv/sieve/data/\$id
  table = sieve_before
  username_field = username
  value_field = script_data
  fields {
    id = \$id
  }
}
EOF

cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-sieve_after.conf
# Autogenerated by mailcow
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
map {
  pattern = priv/sieve/name/\$script_name
  table = sieve_after
  username_field = username
  value_field = id
  fields {
    script_name = \$script_name
  }
}
map {
  pattern = priv/sieve/data/\$id
  table = sieve_after
  username_field = username
  value_field = script_data
  fields {
    id = \$id
  }
}
EOF

echo -n ${ACL_ANYONE} > /etc/dovecot/acl_anyone

if [[ "${SKIP_SOLR}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
echo -n 'quota acl zlib mail_crypt mail_crypt_acl mail_log notify listescape replication' > /etc/dovecot/mail_plugins
echo -n 'quota imap_quota imap_acl acl zlib imap_zlib imap_sieve mail_crypt mail_crypt_acl notify listescape replication mail_log' > /etc/dovecot/mail_plugins_imap
echo -n 'quota sieve acl zlib mail_crypt mail_crypt_acl notify listescape replication' > /etc/dovecot/mail_plugins_lmtp
else
echo -n 'quota acl zlib mail_crypt mail_crypt_acl mail_log notify fts fts_solr listescape replication' > /etc/dovecot/mail_plugins
echo -n 'quota imap_quota imap_acl acl zlib imap_zlib imap_sieve mail_crypt mail_crypt_acl notify mail_log fts fts_solr listescape replication' > /etc/dovecot/mail_plugins_imap
echo -n 'quota sieve acl zlib mail_crypt mail_crypt_acl fts fts_solr notify listescape replication' > /etc/dovecot/mail_plugins_lmtp
fi
chmod 644 /etc/dovecot/mail_plugins /etc/dovecot/mail_plugins_imap /etc/dovecot/mail_plugins_lmtp /templates/quarantine.tpl

cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-userdb.conf
# Autogenerated by mailcow
driver = mysql
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
user_query = SELECT CONCAT(JSON_UNQUOTE(JSON_VALUE(attributes, '$.mailbox_format')), mailbox_path_prefix, '%d/%n/${MAILDIR_SUB}:VOLATILEDIR=/var/volatile/%u:INDEX=/var/vmail_index/%u') AS mail, '%s' AS protocol, 5000 AS uid, 5000 AS gid, concat('*:bytes=', quota) AS quota_rule FROM mailbox WHERE username = '%u' AND (active = '1' OR active = '2')
iterate_query = SELECT username FROM mailbox WHERE active = '1' OR active = '2';
EOF

cat <<EOF > /etc/dovecot/auth/passwd-verify.lua
function auth_password_verify(request, password)
  if request.domain == nil then
    return dovecot.auth.PASSDB_RESULT_USER_UNKNOWN, "No such user"
  end

  json = require "json"
  ltn12 = require "ltn12"
  https = require "ssl.https"
  https.TIMEOUT = 5
  mysql = require "luasql.mysql"
  env  = mysql.mysql()
  con = env:connect("__DBNAME__","__DBUSER__","__DBPASS__","localhost")

  local req = {
    username = request.user,
    password = password
  }
  local req_json = json.encode(req)
  local res = {} 
  
  -- check against mailbox passwds
  local b, c = https.request {
    method = "POST",
    url = "https://nginx:9082",
    source = ltn12.source.string(req_json),
    headers = {
      ["content-type"] = "application/json",
      ["content-length"] = tostring(#req_json)
    },
    sink = ltn12.sink.table(res),
    insecure = true
  }
  local api_response = json.decode(table.concat(res))
  if api_response.role == 'user' then
    con:execute(string.format([[REPLACE INTO sasl_log (service, app_password, username, real_rip)
      VALUES ("%s", 0, "%s", "%s")]], con:escape(request.service), con:escape(request.user), con:escape(request.real_rip)))
    con:close()
    return dovecot.auth.PASSDB_RESULT_OK, "password=" .. password
  end

  
  -- check against app passwds for imap and smtp
  -- app passwords are only available for imap, smtp, sieve and pop3 when using sasl
  if request.service == "smtp" or request.service == "imap" or request.service == "sieve" or request.service == "pop3" then
    skip_sasl_log = false
    req.protocol = {}
    if tostring(req.real_rip) ~= "__IPV4_SOGO__" then
      skip_sasl_log = true
      req.protocol[request.service] = true
    end
    req_json = json.encode(req)

    local b, c = https.request {
      method = "POST",
      url = "https://nginx:9082",
      source = ltn12.source.string(req_json),
      headers = {
        ["content-type"] = "application/json",
        ["content-length"] = tostring(#req_json)
      },
      sink = ltn12.sink.table(res),
      insecure = true
    }
    local api_response = json.decode(table.concat(res))
    if api_response.role == 'user' then
      if skip_sasl_log == false then
        con:execute(string.format([[REPLACE INTO sasl_log (service, app_password, username, real_rip)
          VALUES ("%s", %d, "%s", "%s")]], con:escape(req.service), row.id, con:escape(req.user), con:escape(req.real_rip)))
      end
      con:close()
      return dovecot.auth.PASSDB_RESULT_OK, "password=" .. password
    end
  end
  
  con:close()
  return dovecot.auth.PASSDB_RESULT_PASSWORD_MISMATCH, "Failed to authenticate"
end

function auth_passdb_lookup(req)
   return dovecot.auth.PASSDB_RESULT_USER_UNKNOWN, ""
end
EOF

# Replace patterns in app-passdb.lua
sed -i "s/__DBUSER__/${DBUSER}/g" /etc/dovecot/auth/passwd-verify.lua
sed -i "s/__DBPASS__/${DBPASS}/g" /etc/dovecot/auth/passwd-verify.lua
sed -i "s/__DBNAME__/${DBNAME}/g" /etc/dovecot/auth/passwd-verify.lua
sed -i "s/__IPV4_SOGO__/${IPV4_NETWORK}.248/g" /etc/dovecot/auth/passwd-verify.lua


# Migrate old sieve_after file
[[ -f /etc/dovecot/sieve_after ]] && mv /etc/dovecot/sieve_after /etc/dovecot/global_sieve_after
# Create global sieve scripts
cat /etc/dovecot/global_sieve_after > /var/vmail/sieve/global_sieve_after.sieve
cat /etc/dovecot/global_sieve_before > /var/vmail/sieve/global_sieve_before.sieve

# Check permissions of vmail/index/garbage directories.
# Do not do this every start-up, it may take a very long time. So we use a stat check here.
if [[ $(stat -c %U /var/vmail/) != "vmail" ]] ; then chown -R vmail:vmail /var/vmail ; fi
if [[ $(stat -c %U /var/vmail/_garbage) != "vmail" ]] ; then chown -R vmail:vmail /var/vmail/_garbage ; fi
if [[ $(stat -c %U /var/vmail_index) != "vmail" ]] ; then chown -R vmail:vmail /var/vmail_index ; fi

# Cleanup random user maildirs
rm -rf /var/vmail/mailcow.local/*
# Cleanup PIDs
[[ -f /tmp/quarantine_notify.pid ]] && rm /tmp/quarantine_notify.pid

# create sni configuration
echo "" > /etc/dovecot/sni.conf
for cert_dir in /etc/ssl/mail/*/ ; do
  if [[ ! -f ${cert_dir}domains ]] || [[ ! -f ${cert_dir}cert.pem ]] || [[ ! -f ${cert_dir}key.pem ]]; then
    continue
  fi
  domains=($(cat ${cert_dir}domains))
  for domain in ${domains[@]}; do
    echo 'local_name '${domain}' {' >> /etc/dovecot/sni.conf;
    echo '  ssl_cert = <'${cert_dir}'cert.pem' >> /etc/dovecot/sni.conf;
    echo '  ssl_key = <'${cert_dir}'key.pem' >> /etc/dovecot/sni.conf;
    echo '}' >> /etc/dovecot/sni.conf;
  done
done

# Create random master for SOGo sieve features
RAND_USER=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 16 | head -n 1)
RAND_PASS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 24 | head -n 1)

if [[ ! -z ${DOVECOT_MASTER_USER} ]] && [[ ! -z ${DOVECOT_MASTER_PASS} ]]; then
  RAND_USER=${DOVECOT_MASTER_USER}
  RAND_PASS=${DOVECOT_MASTER_PASS}
fi
echo ${RAND_USER}@mailcow.local:{SHA1}$(echo -n ${RAND_PASS} | sha1sum | awk '{print $1}'):::::: > /etc/dovecot/dovecot-master.passwd
echo ${RAND_USER}@mailcow.local::5000:5000:::: > /etc/dovecot/dovecot-master.userdb
echo ${RAND_USER}@mailcow.local:${RAND_PASS} > /etc/sogo/sieve.creds

if [[ -z ${MAILDIR_SUB} ]]; then
  MAILDIR_SUB_SHARED=
else
  MAILDIR_SUB_SHARED=/${MAILDIR_SUB}
fi
cat <<EOF > /etc/dovecot/shared_namespace.conf
# Autogenerated by mailcow
namespace {
    type = shared
    separator = /
    prefix = Shared/%%u/
    location = maildir:%%h${MAILDIR_SUB_SHARED}:INDEX=~${MAILDIR_SUB_SHARED}/Shared/%%u
    subscriptions = no
    list = children
}
EOF


cat <<EOF > /etc/dovecot/sogo_trusted_ip.conf
# Autogenerated by mailcow
remote ${IPV4_NETWORK}.248 {
  disable_plaintext_auth = no
}
EOF

# Create random master Password for SOGo SSO
RAND_PASS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 32 | head -n 1)
echo -n ${RAND_PASS} > /etc/phpfpm/sogo-sso.pass
cat <<EOF > /etc/dovecot/sogo-sso.conf
# Autogenerated by mailcow
passdb {
  driver = static
  args = allow_real_nets=${IPV4_NETWORK}.248/32 password={plain}${RAND_PASS}
}
EOF

if [[ "${MASTER}" =~ ^([nN][oO]|[nN])+$ ]]; then
  # Toggling MASTER will result in a rebuild of containers, so the quota script will be recreated
  cat <<'EOF' > /usr/local/bin/quota_notify.py
#!/usr/bin/python3
import sys
sys.exit()
EOF
fi

# 401 is user dovecot
if [[ ! -s /mail_crypt/ecprivkey.pem || ! -s /mail_crypt/ecpubkey.pem ]]; then
	openssl ecparam -name prime256v1 -genkey | openssl pkey -out /mail_crypt/ecprivkey.pem
	openssl pkey -in /mail_crypt/ecprivkey.pem -pubout -out /mail_crypt/ecpubkey.pem
	chown 401 /mail_crypt/ecprivkey.pem /mail_crypt/ecpubkey.pem
else
	chown 401 /mail_crypt/ecprivkey.pem /mail_crypt/ecpubkey.pem
fi

# Compile sieve scripts
sievec /var/vmail/sieve/global_sieve_before.sieve
sievec /var/vmail/sieve/global_sieve_after.sieve
sievec /usr/lib/dovecot/sieve/report-spam.sieve
sievec /usr/lib/dovecot/sieve/report-ham.sieve

for file in /var/vmail/*/*/sieve/*.sieve ; do
  if [[ "$file" == "/var/vmail/*/*/sieve/*.sieve" ]]; then
    continue
  fi
  sievec "$file" "$(dirname "$file")/../.dovecot.svbin"
  chown vmail:vmail "$(dirname "$file")/../.dovecot.svbin"
done

# Fix permissions
chown root:root /etc/dovecot/sql/*.conf
chown root:dovecot /etc/dovecot/sql/dovecot-dict-sql-sieve* /etc/dovecot/sql/dovecot-dict-sql-quota* /etc/dovecot/auth/passwd-verify.lua
chmod 640 /etc/dovecot/sql/*.conf /etc/dovecot/auth/passwd-verify.lua
chown -R vmail:vmail /var/vmail/sieve
chown -R vmail:vmail /var/volatile
chown -R vmail:vmail /var/vmail_index
adduser vmail tty
chmod g+rw /dev/console
chown root:tty /dev/console
chmod +x /usr/lib/dovecot/sieve/rspamd-pipe-ham \
  /usr/lib/dovecot/sieve/rspamd-pipe-spam \
  /usr/local/bin/imapsync_runner.pl \
  /usr/local/bin/imapsync \
  /usr/local/bin/trim_logs.sh \
  /usr/local/bin/sa-rules.sh \
  /usr/local/bin/clean_q_aged.sh \
  /usr/local/bin/maildir_gc.sh \
  /usr/local/sbin/stop-supervisor.sh \
  /usr/local/bin/quota_notify.py \
  /usr/local/bin/repl_health.sh

# Prepare environment file for cronjobs
printenv | sed 's/^\(.*\)$/export \1/g' > /source_env.sh

# Clean old PID if any
[[ -f /var/run/dovecot/master.pid ]] && rm /var/run/dovecot/master.pid

# Clean stopped imapsync jobs
rm -f /tmp/imapsync_busy.lock
IMAPSYNC_TABLE=$(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SHOW TABLES LIKE 'imapsync'" -Bs)
[[ ! -z ${IMAPSYNC_TABLE} ]] && mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "UPDATE imapsync SET is_running='0'"

# Envsubst maildir_gc
echo "$(envsubst < /usr/local/bin/maildir_gc.sh)" > /usr/local/bin/maildir_gc.sh

# GUID generation
while [[ ${VERSIONS_OK} != 'OK' ]]; do
  if [[ ! -z $(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -B -e "SELECT 'OK' FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = \"${DBNAME}\" AND TABLE_NAME = 'versions'") ]]; then
    VERSIONS_OK=OK
  else
    echo "Waiting for versions table to be created..."
    sleep 3
  fi
done
PUBKEY_MCRYPT=$(doveconf -P 2> /dev/null | grep -i mail_crypt_global_public_key | cut -d '<' -f2)
if [ -f ${PUBKEY_MCRYPT} ]; then
  GUID=$(cat <(echo ${MAILCOW_HOSTNAME}) /mail_crypt/ecpubkey.pem | sha256sum | cut -d ' ' -f1 | tr -cd "[a-fA-F0-9.:/] ")
  if [ ${#GUID} -eq 64 ]; then
    mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} << EOF
REPLACE INTO versions (application, version) VALUES ("GUID", "${GUID}");
EOF
  else
    mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} << EOF
REPLACE INTO versions (application, version) VALUES ("GUID", "INVALID");
EOF
  fi
fi

# Collect SA rules once now
/usr/local/bin/sa-rules.sh

# Run hooks
for file in /hooks/*; do
  if [ -x "${file}" ]; then
    echo "Running hook ${file}"
    "${file}"
  fi
done

# For some strange, unknown and stupid reason, Dovecot may run into a race condition, when this file is not touched before it is read by dovecot/auth
# May be related to something inside Docker, I seriously don't know
touch /etc/dovecot/auth/passwd-verify.lua

exec "$@"
