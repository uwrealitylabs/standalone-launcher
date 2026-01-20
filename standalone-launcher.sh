#!/bin/sh
printf '\033c\033]0;%s\a' standalone-launcher
base_path="$(dirname "$(realpath "$0")")"
"$base_path/standalone-launcher.arm64" "$@"
