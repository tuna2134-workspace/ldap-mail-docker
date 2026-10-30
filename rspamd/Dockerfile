FROM rspamd/rspamd:4.2.3

# The upstream image runs as _rspamd.  The entrypoint must be able to create
# and chown the DKIM key volume, so it starts as root and lets rspamd drop
# privileges via -u/-g.
USER root

COPY local.d/ /etc/rspamd/local.d/
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

# 11332 = milter (used by Postfix); 11333 = normal/HTTP; 11334 = controller
# (disabled by local.d/worker-controller.inc).
EXPOSE 11332 11333

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/rspamd", "-f", "-u", "_rspamd", "-g", "_rspamd"]
