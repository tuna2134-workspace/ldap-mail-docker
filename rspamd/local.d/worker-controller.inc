# The controller/Web UI is not needed for mail delivery.  It is disabled so
# that no unauthenticated management endpoint exists on the Compose network.
# To enable it for rspamc/Web UI, remove this file and configure:
#   bind_socket = "*:11334";
#   password = "$2$...";   # generate with: rspamadm pw
enabled = false;
