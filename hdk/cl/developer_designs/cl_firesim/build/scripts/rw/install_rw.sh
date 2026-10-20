#!/bin/bash
# RapidWright per https://www.rapidwright.io/docs/Install.html (tag matching Vivado 2025.2, Java from Vivado).
set -euo pipefail
RW_HOME=${RW_HOME:-/home/ubuntu/rw}
export PATH=$(ls -d "$XILINX_VIVADO"/tps/lnx64/jre21*/bin | tail -1):$PATH
if [ ! -f "$RW_HOME/build/libs/main.jar" ]; then
  git clone -q --depth 1 --branch v2025.2.2-beta https://github.com/Xilinx/RapidWright.git "$RW_HOME"
  (cd "$RW_HOME" && ./gradlew -q compileJava)
fi
