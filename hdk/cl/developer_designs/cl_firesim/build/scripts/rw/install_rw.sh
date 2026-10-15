#!/bin/bash
# Installs a JDK 21 + RapidWright standalone jar under $RW_HOME (default /home/ubuntu/rw). Idempotent.
set -euo pipefail
RW_HOME=${RW_HOME:-/home/ubuntu/rw}
RW_VER=${RW_VER:-2025.2.2}
mkdir -p "$RW_HOME"
cd "$RW_HOME"
if [ ! -x jdk/bin/java ]; then
  curl -sSL -o jdk.tgz "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse"
  mkdir -p jdk && tar xzf jdk.tgz -C jdk --strip-components=1 && rm -f jdk.tgz
fi
if [ ! -f rapidwright.jar ]; then
  curl -sSL -o rapidwright.jar "https://github.com/Xilinx/RapidWright/releases/download/v${RW_VER}-beta/rapidwright-${RW_VER}-standalone-lin64.jar"
fi
"$RW_HOME/jdk/bin/java" -version 2>&1 | head -1
echo "RW_INSTALL rapidwright v${RW_VER}-beta jar=$(stat -c %s rapidwright.jar)"
