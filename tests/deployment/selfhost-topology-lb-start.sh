#!/bin/sh
# HAProxy for the topology fixture. In the transparent variant, replies addressed to client addresses
# arrive on the pool interface and belong to HAProxy's transparent sockets; a separate table keeps the
# main table's connected route, which carries HAProxy's own replies to clients. A restart or recreate
# gives the container a new network namespace, so the routes are set here on every start.
set -eu
if [ -n "${TOPOLOGY_TRANSPARENT_CLIENTS:-}" ]; then
  pool_dev=$(ip -o -4 addr show | awk -v a="$TOPOLOGY_POOL_ADDRESS/" 'index($4, a) == 1 { print $2 }')
  ip -4 rule add iif "$pool_dev" lookup 100
  ip -4 route add local "$TOPOLOGY_TRANSPARENT_CLIENTS" dev lo table 100
fi
exec haproxy -W -db -f /fixture/lb.cfg
