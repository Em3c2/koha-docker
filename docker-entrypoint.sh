#!/bin/bash
set -e

echo "Koha Sites global config ..."
envsubst < /templates/global/koha-sites.conf.tmpl > /etc/koha/koha-sites.conf
envsubst < /templates/global/passwd.tmpl > /etc/koha/passwd

echo "Mysql server setup ..."
if ping -c 1 -W 1 $KOHA_DBHOST ; then
  printf "Using linked mysql container $KOHA_DBHOST\n"
else
  printf "Unable to connect to linked mysql container $KOHA_DBHOST\n-- initializing local mysql ...\n"
  /etc/init.d/mysql start
  sleep 3 # waiting for mysql to spin up
  echo "127.0.0.1  $KOHA_DBHOST" >> /etc/hosts
  echo "CREATE USER '$KOHA_ADMINUSER'@'%' IDENTIFIED BY '$KOHA_ADMINPASS' ; \
        CREATE USER '$KOHA_ADMINUSER'@'localhost' IDENTIFIED BY '$KOHA_ADMINPASS' ; \
        CREATE DATABASE IF NOT EXISTS koha_$KOHA_INSTANCE ; \
        GRANT ALL ON koha_$KOHA_INSTANCE.* TO '$KOHA_ADMINUSER'@'%' WITH GRANT OPTION ; \
        GRANT ALL ON koha_$KOHA_INSTANCE.* TO '$KOHA_ADMINUSER'@'localhost' WITH GRANT OPTION ; \
        FLUSH PRIVILEGES ;" | mysql -u root -p$KOHA_ADMINPASS
fi

echo "Initializing local instance ..."
envsubst < /templates/instance/koha-common.cnf.tmpl > /etc/mysql/koha-common.cnf
koha-create --request-db $KOHA_INSTANCE || true
koha-create --populate-db $KOHA_INSTANCE

echo "Configuring local instance ..."
envsubst < /templates/instance/koha-conf.xml.tmpl > /etc/koha/sites/$KOHA_INSTANCE/koha-conf.xml
envsubst < /templates/instance/log4perl.conf.tmpl > /etc/koha/sites/$KOHA_INSTANCE/log4perl.conf
envsubst < /templates/instance/zebra.passwd.tmpl > /etc/koha/sites/$KOHA_INSTANCE/zebra.passwd

envsubst < /templates/instance/apache.tmpl > /etc/apache2/sites-available/$KOHA_INSTANCE.conf
envsubst < /templates/instance/SIPconfig.xml.tmpl > /etc/koha/sites/$KOHA_INSTANCE/SIPconfig.xml

echo "Configuring languages ..."
# Install languages in Koha
for language in $INSTALL_LANGUAGES
do
    koha-translate --install $language
done

echo "Running webinstaller - please be patient ..."
service apache2 restart
sleep 1 # waiting for apache to respond
cd /usr/share/koha/lib && /installer/updatekohadbversion.sh

echo "Installing the default language if not already installed ..."
if [ -n "$DEFAULT_LANGUAGE" ]; then
    if [ -z `koha-translate --list | grep -Fx $DEFAULT_LANGUAGE` ] ; then
        koha-translate --install $DEFAULT_LANGUAGE
    fi

    echo -n "UPDATE systempreferences SET value = '$DEFAULT_LANGUAGE' WHERE variable = 'language';
        UPDATE systempreferences SET value = '$DEFAULT_LANGUAGE' WHERE variable = 'opaclanguages';" | \
        koha-mysql $KOHA_INSTANCE
fi

echo "Configuring messaging settings ..."
if [ -n "$MESSAGE_QUEUE_FREQUENCY" ]; then
  sed -i "/process_message_queue/c\*/${MESSAGE_QUEUE_FREQUENCY} * * * * root koha-foreach --enabled --email \
  /usr/share/koha/bin/cronjobs/process_message_queue.pl" /etc/cron.d/koha-common
fi

echo "Configuring email settings ..."
if [ -n "$EMAIL_ENABLED" ]; then
  # Koha uses default sendmail localhost, so need to override perl Sendmail config
  if [ -n "$SMTP_SERVER_HOST" ]; then
    sub="%mailcfg = (
      'smtp'    => [ '$SMTP_SERVER_HOST' ],
      'from'    => '', # default sender e-mail, used when no From header in mail
      'mime'    => 1, # use MIME encoding by default
      'retries' => 1, # number of retries on smtp connect failure
      'delay'   => 1, # delay in seconds between retries
      'tz'      => '', # only to override automatic detection
      'port'    => $SMTP_SERVER_PORT,
      'debug'   => 0,
    );"
    sendmail=/usr/share/perl5/Mail/Sendmail.pm
    awk -v sb="$sub" '/^%mailcfg/,/;/ { if ( $0 ~ /\);/ ) print sb; next } 1' $sendmail > tmp && \
      mv tmp $sendmail
  fi
  koha-email-enable $KOHA_INSTANCE
fi

echo "Configuring SMS settings ..."
if [ -n "$SMS_SERVER_HOST" ]; then
  # SMS modules need to be in shared perl libs
  mkdir -p /usr/share/perl5/SMS/Send/NO
  sed -e "s|__REPLACE_WITH_SMS_URL__|${SMS_SERVER_HOST}|g" /usr/share/koha/lib/Koha/SMS_HTTP.pm > /usr/share/perl5/SMS/Send/NO/HTTP.pm
  echo -n "UPDATE systempreferences SET value = 'NO::HTTP' WHERE variable = 'SMSSendDriver';" | \
      koha-mysql $KOHA_INSTANCE
fi

echo "Configuring National Library Card settings ..."
if [ -n "$NLVENDORURL" ]; then
  echo -n "UPDATE systempreferences SET value = \"$NLVENDORURL\" WHERE variable = 'NorwegianPatronDBEndpoint';" | koha-mysql $KOHA_INSTANCE
  echo -n "UPDATE systempreferences SET value = \"$NLBASEUSER\" WHERE variable = 'NorwegianPatronDBUsername';" | koha-mysql $KOHA_INSTANCE
  echo -n "UPDATE systempreferences SET value = \"$NLBASEPASS\" WHERE variable = 'NorwegianPatronDBPassword';" | koha-mysql $KOHA_INSTANCE
fi

echo "Starting SIP2 Server ..."
/usr/sbin/koha-start-sip $KOHA_INSTANCE

echo "Starting cron ..."
/etc/init.d/cron start

echo "Starting plack ..."
koha-plack --enable "$KOHA_INSTANCE"
koha-plack --start "$KOHA_INSTANCE"

echo "Restarting apache ..."
service apache2 restart

# Make sure log files exist before tailing them
touch /var/log/koha/${KOHA_INSTANCE}/intranet-error.log; chmod ugo+rw /var/log/koha/${KOHA_INSTANCE}/intranet-error.log
touch /var/log/koha/${KOHA_INSTANCE}/sip-error.log; chmod ugo+rw /var/log/koha/${KOHA_INSTANCE}/sip-error.log
touch /var/log/koha/${KOHA_INSTANCE}/sip-output.log; chmod ugo+rw /var/log/koha/${KOHA_INSTANCE}/sip-output.log
touch /var/log/koha/${KOHA_INSTANCE}/sip-output.log; chmod ugo+rw /var/log/koha/${KOHA_INSTANCE}/plack-error.log

/usr/bin/tail -f /var/log/apache2/access.log \
  /var/log/koha/${KOHA_INSTANCE}/intranet*.log \
  /var/log/koha/${KOHA_INSTANCE}/opac*.log \
  /var/log/koha/${KOHA_INSTANCE}/zebra*.log \
  /var/log/apache2/other_vhosts_access.log \
  /var/log/koha/${KOHA_INSTANCE}/sip*.log \
  /var/log/koha/${KOHA_INSTANCE}/plack*.log
