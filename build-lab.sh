#!/bin/zsh
set -eu
exec zsh "${0:A:h}/scripts/build.sh" "$@"
