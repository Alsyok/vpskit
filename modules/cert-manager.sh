#!/bin/sh
set -eu
VPSKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$VPSKIT_ROOT/lib/common.sh"
. "$VPSKIT_ROOT/lib/node-services.sh"
. "$VPSKIT_ROOT/lib/standalone.sh"
detect
upgrade_node_publication
case "${1:-menu}" in
    menu) standalone_action cert-menu;;
    info) standalone_action cert-list;;
    renew) standalone_action renew-due;;
    *) die '支持 menu / info / renew。';;
esac
