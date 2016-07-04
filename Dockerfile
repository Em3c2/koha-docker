#######
# Debian Jessie build of Koha - Provisioned by Salt
#######

FROM debian:jessie

MAINTAINER Oslo Public Library "digitalutvikling@gmail.com"

ENV REFRESHED_AT 2015-01-06

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get upgrade --yes && \
    apt-get install -y wget less curl git nmap socat netcat tree htop \ 
                       unzip python-software-properties libswitch-perl \
                       libnet-ssleay-perl libcrypt-ssleay-perl apache2 && \
    apt-get clean

ARG KOHA_VERSION

ENV KOHA_ADMINUSER admin
ENV KOHA_ADMINPASS secret
ENV KOHA_INSTANCE  name
ENV KOHA_ZEBRAUSER zebrauser
ENV KOHA_ZEBRAPASS lkjasdpoiqrr
ENV KOHA_DBHOST    koha_mysql

#######
# Mysql config for initial db
#######
RUN echo "mysql-server mysql-server/root_password password $KOHA_ADMINPASS" | debconf-set-selections && \
    echo "mysql-server mysql-server/root_password_again password $KOHA_ADMINPASS" | debconf-set-selections && \
    apt-get install -y mysql-server && \
    sed "/max_allowed_packet/c\*/max_allowed_packet = 64M" /etc/mysql/my.cnf && \
    sed "/wait_timeout/c\*/wait_timeout = 6000" /etc/mysql/my.cnf

########
# Files and templates
########

# Global files
COPY ./files/local-apt-repo.tmpl /etc/apt/preferences.d/local-apt-repo

# Install Koha Common
RUN echo "deb http://datatest.deichman.no/repositories/koha/public/ wheezy main" > /etc/apt/sources.list.d/deichman.list && \
    echo "deb http://debian.koha-community.org/koha stable main" > /etc/apt/sources.list.d/koha.list && \
    wget -q -O- http://debian.koha-community.org/koha/gpg.asc | apt-key add - && \
    apt-get update && apt-get install -y --force-yes koha-common=$KOHA_VERSION && apt-get clean

# Installer files
COPY ./files/installer /installer

# Templates
ADD ./files/templates /templates

# Apache settings
COPY ./files/apache-shared-intranet-plack.conf.tmpl /etc/koha/apache-shared-intranet-plack.conf
COPY ./files/plack.psgi /etc/koha/plack.psgi
RUN echo "\nListen 8080\nListen 8081" | tee /etc/apache2/ports.conf && \
    a2dissite 000-default && \
    a2enmod rewrite headers proxy_http cgi

# Koha SIP2 server
ENV SIP_PORT      6001
ENV SIP_WORKERS   3
ENV SIP_AUTOUSER1 autouser
ENV SIP_AUTOPASS1 autopass


#############
# WORKAROUNDS
#############

# CAS bug workaround
ADD ./files/Authen_CAS_Client_Response_Failure.pm /usr/share/perl5/Authen/CAS/Client/Response/Failure.pm
ADD ./files/Authen_CAS_Client_Response_Success.pm /usr/share/perl5/Authen/CAS/Client/Response/Success.pm

# Symlink api folder - TODO: Remove when unneccesary
RUN ln -s /usr/share/koha/api/api/v1 /usr/share/koha/api/v1

# Overwrite swagger definition file
COPY ./files/swagger.json /usr/share/koha/api/v1/swagger.json

ENV HOME /root
WORKDIR /root

# Setup cron job to sync holdingbranches to services
COPY holdingbranches.sh /root/holdingbranches.sh
COPY update_holdingbranches.sh /root/update_holdingbranches.sh
COPY branch-sync /etc/cron.d/branch-sync
RUN chmod 0644 /etc/cron.d/branch-sync

COPY docker-entrypoint.sh /root/entrypoint.sh
ENTRYPOINT ["/root/entrypoint.sh"]

EXPOSE 6001 8080 8081

# Script and deps for checking if koha is up & ready (to be executed using docker exec)
RUN apt-get install -y python-requests && apt-get clean
COPY docker-wait_until_ready.py /root/wait_until_ready.py
