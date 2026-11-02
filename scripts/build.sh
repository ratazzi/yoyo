#!/bin/zsh
set -eu
cd "${0:A:h:h}"
exec mise run build-app "$@"
