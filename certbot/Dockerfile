FROM certbot/certbot:v5.0.0

COPY --chmod=0755 entrypoint.sh deploy-hook.sh /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
