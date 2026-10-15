#!/bin/bash
# usage: run_rw.sh <RwDcp.java subcommand> args...   (Java single-file launch, heap RW_XMX, default 48g)
# Vivado is kept OFF PATH so RapidWright never silently shells out to it (timings stay pure RW).
set -euo pipefail
RW_HOME=${RW_HOME:-/home/ubuntu/rw}
here=$(cd "$(dirname "$0")" && pwd)
export RAPIDWRIGHT_PATH=$RW_HOME
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -i xilinx | paste -sd:)
exec "$RW_HOME/jdk/bin/java" -Xmx${RW_XMX:-48g} -XX:+UseParallelGC -cp "$RW_HOME/rapidwright.jar" "$here/RwDcp.java" "$@"
