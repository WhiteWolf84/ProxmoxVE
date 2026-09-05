#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Authors: MickLesk (CanbiZ) | Co-Author: remz1337
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate

APP="Frigate"
var_tags="${var_tags:-nvr}"
var_cpu="${var_cpu:-8}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-0}"
# var_gpu=yes makes core/backend.func auto-detect the host's GPU(s) via lspci
# and pass the device nodes into the LXC with the right video/render GIDs -
# for AMD that includes /dev/kfd, which ROCm needs. frigate-install.sh then
# installs the matching userspace: Mesa VA-API for AMD, plus the ROCm and
# MIGraphX stack that the stock script leaves out on APUs.
var_gpu="${var_gpu:-yes}"
# Optional: pin a specific Frigate tag (stable or RC, e.g. "v0.17.2" or
# "v0.18.0-rc1") instead of being asked interactively during install. Only
# takes effect if it reaches the container's environment (e.g. you export it
# in a wrapper you control) - see frigate-install.sh for the actual selection
# logic and its interactive prompt.
FRIGATE_VERSION="${FRIGATE_VERSION:-}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /etc/systemd/system/frigate.service ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi
    msg_error "To update Frigate, create a new container and transfer your configuration."
    exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:5000${CL}"
