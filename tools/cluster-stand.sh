#!/usr/bin/env bash
# A two-node cluster stand of the Chicago application on one machine.
#
#   tools/cluster-stand.sh start    set up on first use, sync src/ and the lock, start both nodes
#   tools/cluster-stand.sh stop     stop both nodes (pids taken from the gateway ports)
#   tools/cluster-stand.sh status   listeners and the cluster lines of each log
#   tools/cluster-stand.sh reset    stop, then forget the raft state (keys and data stay)
#
# Node a: gateway 127.0.0.1:8097, SSH 127.0.0.1:2224, gossip 7946, internode 7950.
# Node b: gateway 127.0.0.1:8098, SSH 127.0.0.1:2223, gossip 7947, internode 7951.
# Neither takes 8099/2222: those are the person's own desktop (`make run`),
# and a stand node there would be logged on to by mistake and killed by a test.
#
# Each node runs from its own copy of the application under $STAND/<node>:
# .wippy/app.db, registry.db and the raft store must not be shared. The first
# start copies .wippy/ with the data (accounts included); later starts sync
# src/, wippy.lock, .wippy.yaml and .wippy/vendor/, so a node keeps its own data.
#
# PRECONDITION: relay.node_name == cluster.name on every node. PIDs carry the
# relay node id, members() and the voter list carry cluster.name; anything
# that picks a node from members() and sends to it by node id (the remote
# desktop does exactly that) addresses a node that does not exist when the
# two differ, and nothing reports it. Raft breaks the same way ("node is not
# a voter"). The overlay below sets both from one value; never set one alone.
#
# What a clustered node needs, and why each line of the overlay is there, is
# in the runtime fork's boot/components/system/cluster.example.yaml.
#
# Stand-only entries: put an app.* namespace under $STAND/extra/src/ and it
# is laid over each node's src/ on start (it never reaches the repository).
set -u
APP="$(cd "$(dirname "$0")/.." && pwd)"
STAND="${STAND:-$APP/.wippy/cluster-stand}"
WIPPY="${WIPPY:-$APP/bin/wippy}"

# node:gossip:internode:gateway:ssh
NODES="a:7946:7950:8097:2224 b:7947:7951:8098:2223"

field() { echo "$1" | cut -d: -f"$2"; }
pid_of() { ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1; }

keys() {
  mkdir -p "$STAND/keys"
  [ -s "$STAND/keys/gossip.key" ] || openssl rand -base64 32 > "$STAND/keys/gossip.key"
  for spec in $NODES; do
    n=$(field "$spec" 1); k="$STAND/keys/node-$n"
    if [ ! -s "$k.key" ]; then
      openssl genpkey -algorithm ed25519 -out "$k.pem" || return 1
      openssl pkey -in "$k.pem" -outform DER | tail -c 32 | base64 > "$k.key"
      openssl pkey -in "$k.pem" -pubout -outform DER | tail -c 32 | base64 > "$k.pub"
      rm -f "$k.pem"
    fi
  done
  chmod 600 "$STAND"/keys/*.key
}

overlay() { # spec
  n=$(field "$1" 1)
  trusted=""
  for peer in $NODES; do
    p=$(field "$peer" 1)
    trusted="$trusted      node-$p: \"$(cat "$STAND/keys/node-$p.pub")\"
"
  done
  seeds=""
  for peer in $NODES; do seeds="$seeds,127.0.0.1:$(field "$peer" 2)"; done
  cat > "$STAND/$n.yaml" <<EOF
version: "1.0"
# Written by tools/cluster-stand.sh; edits are lost on the next start.
# PRECONDITION: relay.node_name == cluster.name (PIDs carry the relay id,
# members() carries cluster.name; addressing a node picked from members() breaks silently otherwise).
relay:
  node_name: "node-$n"
cluster:
  enabled: true
  name: "node-$n"
  membership:
    bind_addr: "127.0.0.1"
    bind_port: $(field "$1" 2)
    join_addrs: "${seeds#,}"
    secret_file: "$STAND/keys/gossip.key"
  internode:
    bind_addr: "127.0.0.1"
    # Pinned: auto_port probes at load and binds again at start, and two
    # nodes starting together pick the same port.
    bind_port: $(field "$1" 3)
    auto_port: false
    identity_key_file: "$STAND/keys/node-$n.key"
    trusted_peer_keys:
$trusted  raft:
    bootstrap_expect: 2
    data_dir: "$STAND/$n/.wippy/cluster-store"
override:
  "app:gateway:data.addr": "127.0.0.1:$(field "$1" 4)"
  "app.env:defaults:data.values.PUBLIC_API_URL": "http://localhost:$(field "$1" 4)"
  "app.desktop:ssh:address": "127.0.0.1:$(field "$1" 5)"
EOF
}

start() {
  keys || { echo "key generation failed" >&2; return 1; }
  for spec in $NODES; do
    n=$(field "$spec" 1); port=$(field "$spec" 4)
    if [ -n "$(pid_of "$port")" ]; then echo "node $n: :$port is taken (running already?)"; continue; fi
    overlay "$spec"
    if [ ! -d "$STAND/$n/.wippy" ]; then
      mkdir -p "$STAND/$n"
      rsync -a --exclude cluster-stand "$APP/.wippy/" "$STAND/$n/.wippy/"
      for d in branding static; do [ -d "$APP/$d" ] && rsync -a "$APP/$d/" "$STAND/$n/$d/"; done
    fi
    rsync -a --delete "$APP/src/" "$STAND/$n/src/"
    # The modules follow the lock: after `wippy update` in the app the node
    # would boot the new lock against its old vendored packages and fail on
    # "unresolved dependencies". The node's data files stay its own.
    rsync -a --delete "$APP/.wippy/vendor/" "$STAND/$n/.wippy/vendor/"
    # Stand-only entries (probes, debug windows) live in $STAND/extra/src and
    # are laid over each node's src/; they never reach the repository.
    [ -d "$STAND/extra/src" ] && rsync -a "$STAND/extra/src/" "$STAND/$n/src/"
    cp "$APP/wippy.lock" "$APP/.wippy.yaml" "$STAND/$n/"
    # A lock of the stand's own ($STAND/wippy.lock) wins over the app's: it
    # pins the stand while the app's lock is being moved.
    [ -f "$STAND/wippy.lock" ] && cp "$STAND/wippy.lock" "$STAND/$n/wippy.lock"
    # exec: no shell stays behind holding this script's stdout, so
    # `cluster-stand.sh start | tail` returns once the nodes are up.
    # STAND_ARGS_<node> adds flags to one node, e.g.
    # STAND_ARGS_a="-v" (debug log; `--set logger.level=debug` alone is not enough).
    extra_var="STAND_ARGS_$n"
    # shellcheck disable=SC2086
    (cd "$STAND/$n" && exec setsid nohup "$WIPPY" run --config .wippy.yaml --config "../$n.yaml" ${!extra_var:-} \
      > "../$n.log" 2>&1 < /dev/null) &
    echo "node $n starting, log $STAND/$n.log"
  done
  for i in $(seq 1 150); do
    up=0
    for spec in $NODES; do [ -n "$(pid_of "$(field "$spec" 4)")" ] && up=$((up + 1)); done
    [ "$up" -eq 2 ] && { echo "both nodes up after ${i}s"; return 0; }
    sleep 1
  done
  echo "timeout: $up of 2 nodes up; read the logs" >&2
  return 1
}

stop() {
  pids=""
  for spec in $NODES; do
    p=$(pid_of "$(field "$spec" 4)")
    [ -n "$p" ] && { kill "$p"; pids="$pids $p"; }
  done
  for p in $pids; do while kill -0 "$p" 2>/dev/null; do sleep 1; done; done
  echo "stopped:${pids:- nothing was running}"
}

status() {
  ss -ltnH | awk '{print $4}' | grep -E ':(8097|8098|2224|2223|7946|7947|7950|7951)$' | sort
  for spec in $NODES; do
    n=$(field "$spec" 1)
    echo "--- node $n"
    grep -E "node joined|node left|now the raft leader|lost raft leadership|cluster bootstrapped|membership reconcile|start failed|bootstrap failed" \
      "$STAND/$n.log" 2>/dev/null | cut -c1-200 | tail -6
  done
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  reset) stop; rm -rf "$STAND"/a/.wippy/cluster-store "$STAND"/b/.wippy/cluster-store; echo "raft state removed" ;;
  *) echo "usage: $0 start|stop|status|reset" >&2; exit 2 ;;
esac
