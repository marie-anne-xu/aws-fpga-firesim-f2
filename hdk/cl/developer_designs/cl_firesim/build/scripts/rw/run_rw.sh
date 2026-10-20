#!/bin/bash
# usage: run_rw.sh <RwDcp.java args>  (heap RW_XMX, default 48g; Vivado kept off PATH)
set -euo pipefail
RW_HOME=${RW_HOME:-/home/ubuntu/rw}
here=$(cd "$(dirname "$0")" && pwd)
java=$(ls -d "$XILINX_VIVADO"/tps/lnx64/jre21*/bin/java | tail -1)
export CLASSPATH="$RW_HOME/bin:$RW_HOME/jars/*"
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -i xilinx | paste -sd:)
exec "$java" -Xmx${RW_XMX:-48g} -XX:+UseParallelGC "$here/RwDcp.java" "$@"
