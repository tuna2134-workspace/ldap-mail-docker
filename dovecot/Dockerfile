FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        dovecot-core \
        dovecot-imapd \
        dovecot-lmtpd \
        dovecot-ldap \
        dovecot-sieve \
        gettext-base \
        ca-certificates \
        openssl \
        util-linux \
 && rm -rf /var/lib/apt/lists/*

# 5000 = vmail, the single UID/GID that owns all Maildirs.
# 5002 = shared TLS certificate group (same GID as in the Postfix image).
RUN groupadd -g 5000 vmail \
 && useradd -u 5000 -g 5000 -d /data/maildir -s /usr/sbin/nologin vmail \
 && groupadd -g 5002 mailcert \
 && usermod -aG mailcert dovecot

COPY dovecot/dovecot.conf /etc/dovecot/dovecot.conf
COPY dovecot/dovecot-ldap.conf.ext.template /etc/dovecot/dovecot-ldap.conf.ext.template
COPY dovecot/sieve/ /etc/dovecot/sieve/
COPY shared/ensure-cert.sh shared/cert-watch.sh dovecot/entrypoint.sh /usr/local/bin/

RUN sievec /etc/dovecot/sieve/spam.sieve \
 && chmod 0644 /etc/dovecot/sieve/spam.sieve /etc/dovecot/sieve/spam.svbin \
 && chmod 0755 /usr/local/bin/ensure-cert.sh \
              /usr/local/bin/cert-watch.sh \
              /usr/local/bin/entrypoint.sh

EXPOSE 143 993

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
