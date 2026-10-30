FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'postfix postfix/main_mailer_type select No configuration' \
        | debconf-set-selections \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        postfix \
        postfix-ldap \
        gettext-base \
        ca-certificates \
        openssl \
        util-linux \
 && rm -rf /var/lib/apt/lists/*

# Fixed GID shared with certbot's deploy hook: the TLS private key is installed
# as root:5002 mode 0640 and the postfix user belongs to this group.
RUN groupadd -g 5002 mailcert \
 && usermod -aG mailcert postfix

COPY postfix/main.cf.template /etc/postfix/main.cf.template
COPY postfix/master.cf /etc/postfix/master.cf
COPY postfix/ldap-virtual-mailbox-maps.cf.template \
     postfix/ldap-virtual-alias-maps.cf.template \
     postfix/ldap-sender-login-maps.cf.template \
     postfix/ldap-sender-canonical-maps.cf.template \
     /etc/postfix/
COPY shared/ensure-cert.sh shared/cert-watch.sh postfix/entrypoint.sh /usr/local/bin/

RUN chmod 0644 /etc/postfix/main.cf.template /etc/postfix/master.cf \
 && chmod 0644 /etc/postfix/ldap-*.cf.template \
 && chmod 0755 /usr/local/bin/entrypoint.sh \
              /usr/local/bin/ensure-cert.sh \
              /usr/local/bin/cert-watch.sh

EXPOSE 25 587

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
