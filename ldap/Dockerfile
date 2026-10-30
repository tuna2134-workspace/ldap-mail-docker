FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        slapd \
        ldap-utils \
        gettext-base \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* /etc/ldap/slapd.d

COPY schema/mailaccount.schema /etc/ldap/schema/mailaccount.schema
COPY slapd.conf.template /etc/ldap/slapd.conf.template
COPY bootstrap/ /bootstrap/
COPY entrypoint.sh healthcheck.sh /usr/local/bin/

RUN chmod 0644 /etc/ldap/schema/mailaccount.schema /etc/ldap/slapd.conf.template \
 && chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

EXPOSE 389

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
