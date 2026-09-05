#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Authors: MickLesk (CanbiZ) | Co-Authors: remz1337
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

source /etc/os-release
if [[ "$VERSION_ID" != "12" ]]; then
  msg_error "Frigate requires Debian 12 (Bookworm) due to Python 3.11 dependencies"
  exit 238
fi

# onnxruntime ships shared objects linked requesting an executable stack. A
# kernel that refuses to grant one at dlopen time makes glibc raise "cannot
# enable executable stack as shared object requires: Invalid argument", and
# Frigate dies on "import onnxruntime" before it ever reads the config. None
# of this code needs an executable stack. Debian dropped execstack and
# Bookworm's patchelf predates --clear-execstack, so clear the PF_X bit on
# PT_GNU_STACK directly. Takes the directories to walk as arguments; defaults
# to the installed onnxruntime package.
clear_execstack() {
  python3 - "$@" <<'EXECSTACK_EOF'
import os, struct, sys, sysconfig

PT_GNU_STACK, PF_X = 0x6474E551, 0x1


def clear(path):
    with open(path, "r+b") as f:
        if f.read(4) != b"\x7fELF" or f.read(1)[0] != 2:
            return False
        f.seek(0x20)
        phoff = struct.unpack("<Q", f.read(8))[0]
        f.seek(0x36)
        entsize, num = struct.unpack("<HH", f.read(4))
        for i in range(num):
            entry = phoff + i * entsize
            f.seek(entry)
            if struct.unpack("<I", f.read(4))[0] != PT_GNU_STACK:
                continue
            f.seek(entry + 4)
            flags = struct.unpack("<I", f.read(4))[0]
            if flags & PF_X:
                f.seek(entry + 4)
                f.write(struct.pack("<I", flags & ~PF_X))
                return True
    return False


bases = sys.argv[1:] or [
    os.path.join(sysconfig.get_paths()["purelib"], "onnxruntime"),
    os.path.join("/usr/local/lib/python3.11/dist-packages", "onnxruntime"),
]
for base in bases:
    for root, _, files in os.walk(base):
        for name in files:
            if ".so" in name:
                try:
                    clear(os.path.join(root, name))
                except (OSError, struct.error):
                    pass
EXECSTACK_EOF
}

msg_info "Converting APT sources to DEB822 format"
if [ -f /etc/apt/sources.list ]; then
  cat >/etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org
Suites: bookworm-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  mv /etc/apt/sources.list /etc/apt/sources.list.bak
  $STD apt update
fi
msg_ok "Converted APT sources"

msg_info "Installing Dependencies"
$STD apt install -y \
  gnupg \
  pciutils \
  xz-utils \
  python3 \
  python3-dev \
  python3-pip \
  gcc \
  pkg-config \
  libhdf5-dev \
  build-essential \
  automake \
  libtool \
  ccache \
  libusb-1.0-0-dev \
  apt-transport-https \
  cmake \
  git \
  libgtk-3-dev \
  libavcodec-dev \
  libavformat-dev \
  libswscale-dev \
  libv4l-dev \
  libxvidcore-dev \
  libx264-dev \
  libjpeg-dev \
  libpng-dev \
  libtiff-dev \
  gfortran \
  openexr \
  libssl-dev \
  libtbbmalloc2 \
  libtbb-dev \
  libdc1394-dev \
  libopenexr-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstreamer1.0-dev \
  tclsh \
  libopenblas-dev \
  liblapack-dev \
  libgomp1 \
  make \
  moreutils
msg_ok "Installed Dependencies"

setup_hwaccel

export TARGETARCH="$(arch_resolve)"
export CCACHE_DIR=/root/.ccache
export CCACHE_MAXSIZE=2G
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn
export PIP_BREAK_SYSTEM_PACKAGES=1
export NVIDIA_VISIBLE_DEVICES=all
export NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"
export TOKENIZERS_PARALLELISM=true
export TRANSFORMERS_NO_ADVISORY_WARNINGS=1
export OPENCV_FFMPEG_LOGLEVEL=8
export PYTHONWARNINGS="ignore:::numpy.core.getlimits"
export HAILORT_LOGGER_PATH=NONE
export TF_CPP_MIN_LOG_LEVEL=3
export TF_CPP_MIN_VLOG_LEVEL=3
export TF_ENABLE_ONEDNN_OPTS=0
export AUTOGRAPH_VERBOSITY=0
export GLOG_minloglevel=3
export GLOG_logtostderr=0

FRIGATE_STABLE_TAG="v0.17.2"
FRIGATE_RC_TAG=""
frigate_releases_json="$(mktemp)"
if github_api_call "https://api.github.com/repos/blakeblackshear/frigate/releases?per_page=15" "$frigate_releases_json"; then
  # Guarded because a malformed body still arrives as HTTP 200 sometimes, and
  # jq exiting non-zero on an assignment would abort the install outright.
  _tag=$(jq -r '[.[] | select(.draft==false and .prerelease==false)][0].tag_name // empty' "$frigate_releases_json") || _tag=""
  [[ -n "$_tag" ]] && FRIGATE_STABLE_TAG="$_tag"
  FRIGATE_RC_TAG=$(jq -r '[.[] | select(.draft==false and .prerelease==true)][0].tag_name // empty' "$frigate_releases_json") || FRIGATE_RC_TAG=""
fi
rm -f "$frigate_releases_json"

FRIGATE_TAG="${FRIGATE_VERSION:-}"
if [[ -z "$FRIGATE_TAG" ]]; then
  FRIGATE_TAG="$FRIGATE_STABLE_TAG"
  if [[ -n "$FRIGATE_RC_TAG" && "$FRIGATE_RC_TAG" != "$FRIGATE_STABLE_TAG" ]]; then
    echo ""
    msg_custom "🧪" "${YW}" "Frigate RC available: ${FRIGATE_RC_TAG} (stable: ${FRIGATE_STABLE_TAG})"
    frigate_reply=""
    read -r -t 30 -p "${TAB3}Install the RC build instead of stable? [y/N] (auto-no in 30s): " frigate_reply </dev/tty || frigate_reply=""
    case "${frigate_reply,,}" in
    y | yes) FRIGATE_TAG="$FRIGATE_RC_TAG" ;;
    esac
  fi
fi
msg_ok "Selected Frigate version: ${FRIGATE_TAG}"

fetch_and_deploy_gh_release "frigate" "blakeblackshear/frigate" "tarball" "$FRIGATE_TAG" "/opt/frigate"

msg_info "Building Nginx"
$STD bash /opt/frigate/docker/main/build_nginx.sh
sed -e '/s6-notifyoncheck/ s/^#*/#/' -i /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx
msg_ok "Built Nginx"

msg_info "Building SQLite Extensions"
$STD bash /opt/frigate/docker/main/build_sqlite_vec.sh
msg_ok "Built SQLite Extensions"

fetch_and_deploy_gh_release "go2rtc" "AlexxIT/go2rtc" "singlefile" "latest" "/usr/local/go2rtc/bin" "go2rtc_linux_$(arch_resolve)"

msg_info "Installing Tempio"
sed -i 's|/rootfs/usr/local|/usr/local|g' /opt/frigate/docker/main/install_tempio.sh
$STD bash /opt/frigate/docker/main/install_tempio.sh
ln -sf /usr/local/tempio/bin/tempio /usr/local/bin/tempio
msg_ok "Installed Tempio"

msg_info "Building libUSB"
fetch_and_deploy_gh_release "libusb" "libusb/libusb" "tarball" "v1.0.26" "/opt/libusb"
cd /opt/libusb
$STD ./bootstrap.sh
$STD ./configure CC='ccache gcc' CCX='ccache g++' --disable-udev --enable-shared
$STD make -j "$(nproc)"
cd /opt/libusb/libusb
mkdir -p /usr/local/lib /usr/local/include/libusb-1.0 /usr/local/lib/pkgconfig
$STD bash ../libtool --mode=install /usr/bin/install -c libusb-1.0.la /usr/local/lib
install -c -m 644 libusb.h /usr/local/include/libusb-1.0
cd /opt/libusb/
install -c -m 644 libusb-1.0.pc /usr/local/lib/pkgconfig
ldconfig
msg_ok "Built libUSB"

msg_info "Bootstrapping pip"
curl_with_retry "https://bootstrap.pypa.io/get-pip.py" "/tmp/get-pip.py"
sed -i 's/args.append("setuptools")/args.append("setuptools==77.0.3")/' /tmp/get-pip.py
$STD python3 /tmp/get-pip.py "pip"
rm -f /tmp/get-pip.py
msg_ok "Bootstrapped pip"

msg_info "Installing Python Dependencies"
$STD pip3 install -r /opt/frigate/docker/main/requirements.txt
msg_ok "Installed Python Dependencies"

msg_info "Building Python Wheels (Patience)"
mkdir -p /wheels
$STD bash /opt/frigate/docker/main/build_pysqlite3.sh
for i in {1..3}; do
  $STD pip3 wheel --wheel-dir=/wheels -r /opt/frigate/docker/main/requirements-wheels.txt --default-timeout=300 --retries=3 && break
  [[ $i -lt 3 ]] && sleep 10
done
msg_ok "Built Python Wheels"

NODE_VERSION="20" setup_nodejs

msg_info "Downloading Inference Models"
mkdir -p /models /openvino-model
curl_download "/edgetpu_model.tflite" "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite"
curl_download "/models/cpu_model.tflite" "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite"
cp /opt/frigate/labelmap.txt /labelmap.txt
msg_ok "Downloaded Inference Models"

msg_info "Downloading Audio Model"
curl_download "/tmp/yamnet.tar.gz" "https://www.kaggle.com/api/v1/models/google/yamnet/tfLite/classification-tflite/1/download"
$STD tar xzf /tmp/yamnet.tar.gz -C /
mv /1.tflite /cpu_audio_model.tflite
cp /opt/frigate/audio-labelmap.txt /audio-labelmap.txt
rm -f /tmp/yamnet.tar.gz
msg_ok "Downloaded Audio Model"

msg_info "Installing OpenVino"
$STD pip3 install -r /opt/frigate/docker/main/requirements-ov.txt
msg_ok "Installed OpenVino"

msg_info "Building OpenVino Model"
cd /models
curl_download "ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz" "http://download.tensorflow.org/models/object_detection/ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz"
$STD tar -zxf ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz --no-same-owner
if python3 /opt/frigate/docker/main/build_ov_model.py &>/dev/null; then
  mkdir -p /openvino-model
  cp /models/ssdlite_mobilenet_v2.xml /openvino-model/
  cp /models/ssdlite_mobilenet_v2.bin /openvino-model/
  # omz_tools ships with openvino-dev, which requirements-ov.txt dropped in
  # 0.18 (it now pulls plain openvino). The import then exits 1, and under the
  # framework's ERR trap that assignment took the whole install down before
  # either of the fallbacks below could run - so keep it non-fatal.
  OV_LABELS=$(python3 -c "import omz_tools; import os; print(os.path.join(omz_tools.__path__[0], 'data/dataset_classes/coco_91cl_bkgr.txt'))" 2>/dev/null) || OV_LABELS=""
  if [[ -n "$OV_LABELS" && -f "$OV_LABELS" ]]; then
    ln -sf "$OV_LABELS" /openvino-model/coco_91cl_bkgr.txt
  else
    # Same pipefail hazard as above, and now actually reachable: find returns
    # non-zero on a missing directory and takes the pipeline down with it.
    OV_LABELS=$(find /usr/local/lib -name "coco_91cl_bkgr.txt" 2>/dev/null | head -1) || OV_LABELS=""
    if [[ -n "$OV_LABELS" ]]; then
      ln -sf "$OV_LABELS" /openvino-model/coco_91cl_bkgr.txt
    else
      curl_with_retry "https://raw.githubusercontent.com/openvinotoolkit/open_model_zoo/master/data/dataset_classes/coco_91cl_bkgr.txt" "/openvino-model/coco_91cl_bkgr.txt" ||
        msg_warn "Could not fetch the OpenVino labelmap"
    fi
  fi
  # No labelmap is not fatal either: the config below already falls back to the
  # CPU model when either OpenVino file is missing.
  if [[ -f /openvino-model/coco_91cl_bkgr.txt ]]; then
    sed -i 's/truck/car/g' /openvino-model/coco_91cl_bkgr.txt
    msg_ok "Built OpenVino Model"
  else
    msg_warn "OpenVino labelmap unavailable - Frigate will use the CPU model"
  fi
else
  msg_warn "OpenVino build failed (CPU may not support required instructions). Frigate will use CPU model."
fi

# HailoRT and MemryX are runtimes for M.2/PCIe accelerators: without the card
# they are downloaded, unpacked and never used (MemryX also pip-installs its
# own dependency set). Both vendors are detectable on the bus, so install them
# only when the card is actually there. Set FRIGATE_FORCE_NPU=1 to install them
# regardless - useful if the accelerator is going in after the container.
if [[ "${FRIGATE_FORCE_NPU:-0}" == "1" ]] || lspci -nn 2>/dev/null | grep -q '\[1e60:'; then
  msg_info "Installing HailoRT Runtime"
  $STD bash /opt/frigate/docker/main/install_hailort.sh
  msg_ok "Installed HailoRT Runtime"
else
  msg_ok "No Hailo device on the bus - skipping HailoRT"
fi

# Everything below used to sit under the "HailoRT" heading, which reads as if
# it were Hailo-specific. It is not: the rootfs overlay carries the s6 run
# scripts, nginx config and go2rtc config generator, install_deps.sh brings in
# ffmpeg and libedgetpu, and the wheels are the Python build from earlier.
# Frigate does not start without any of it.
msg_info "Installing Frigate Runtime Dependencies"
cp -a /opt/frigate/docker/main/rootfs/. /
sed -i '/^.*unset DEBIAN_FRONTEND.*$/d' /opt/frigate/docker/main/install_deps.sh
echo "libedgetpu1-max libedgetpu/accepted-eula boolean true" | debconf-set-selections
echo "libedgetpu1-max libedgetpu/install-confirm-max boolean true" | debconf-set-selections
echo 'force-overwrite' >/etc/dpkg/dpkg.cfg.d/force-overwrite
$STD bash /opt/frigate/docker/main/install_deps.sh
rm -f /etc/dpkg/dpkg.cfg.d/force-overwrite
$STD pip3 install -U /wheels/*.whl
clear_execstack
ldconfig
msg_ok "Installed Frigate Runtime Dependencies"

if [[ "${FRIGATE_FORCE_NPU:-0}" == "1" ]] || lspci -nn 2>/dev/null | grep -q '\[1fe9:'; then
  msg_info "Installing MemryX Runtime"
  $STD bash /opt/frigate/docker/main/install_memryx.sh
  msg_ok "Installed MemryX Runtime"
else
  msg_ok "No MemryX device on the bus - skipping MemryX runtime"
fi

msg_info "Building Frigate Application (Patience)"
cd /opt/frigate
$STD pip3 install -r /opt/frigate/docker/main/requirements-dev.txt
$STD bash /opt/frigate/.devcontainer/initialize.sh
$STD make version
cd /opt/frigate/web
$STD npm install
$STD npm run build
mv /opt/frigate/web/dist/BASE_PATH/monacoeditorwork/* /opt/frigate/web/dist/assets/
rm -rf /opt/frigate/web/dist/BASE_PATH
cp -r /opt/frigate/web/dist/* /opt/frigate/web/
sed -i '/^s6-svc -O \.$/s/^/#/' /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run
msg_ok "Built Frigate Application"

msg_info "Configuring Frigate"
mkdir -p /config /media/frigate
cp -r /opt/frigate/config/. /config

curl_download "/media/frigate/person-bicycle-car-detection.mp4" "https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4"

echo "tmpfs   /tmp/cache      tmpfs   defaults        0       0" >>/etc/fstab

cat <<EOF >/etc/frigate.env
DEFAULT_FFMPEG_VERSION="7.0"
INCLUDED_FFMPEG_VERSIONS="7.0:5.0"
NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"
TOKENIZERS_PARALLELISM=true
TRANSFORMERS_NO_ADVISORY_WARNINGS=1
OPENCV_FFMPEG_LOGLEVEL=8
PYTHONWARNINGS="ignore:::numpy.core.getlimits"
HAILORT_LOGGER_PATH=NONE
TF_CPP_MIN_LOG_LEVEL=3
TF_CPP_MIN_VLOG_LEVEL=3
TF_ENABLE_ONEDNN_OPTS=0
AUTOGRAPH_VERBOSITY=0
GLOG_minloglevel=3
GLOG_logtostderr=0
EOF

# ══════════════════════════════════════════════════════════════════════════════
# AMD ROCm / MIGraphX
#
# setup_hwaccel's AMD APU branch (_setup_amd_apu) installs only the Mesa VA-API
# stack - it never calls _setup_rocm, which is reached from the discrete-GPU
# branch alone. So an APU (Phoenix, Rembrandt, ...) gets video decode but no
# compute stack, and Frigate's "onnx" detector silently stays on CPU.
#
# This replicates what upstream's docker/rocm image does on top of the main
# image: the ROCm userspace compute libs, the MIGraphX/MIOpen/rocBLAS libs the
# execution provider dlopens, and the onnxruntime wheel built against MIGraphX
# (the stock CPU onnxruntime from requirements.txt has no ROCm provider).
# Runs after every pip step so nothing reinstalls the CPU wheel over it.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -e /dev/kfd ]] && lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' | grep -q '\[1002:'; then
  msg_info "Setting up AMD ROCm + MIGraphX"

  _setup_rocm "$(get_os_info id)" "$(get_os_info codename)"

  if [[ -d /opt/rocm ]]; then
    # rocm-hip-runtime pulls neither MIGraphX nor MIOpen/rocBLAS/rocFFT, which
    # are exactly what onnxruntime-migraphx calls into at inference time.
    _cs_apt_install_optional migraphx miopen-hip rocblas rocfft libnuma1 libstdc++-12-dev

    # Bookworm's Mesa 22.3 predates gfx1103 (Phoenix); VA-API on RDNA3 APUs
    # needs the backports build, same as upstream's rocm Dockerfile does.
    cat <<'BACKPORTS_EOF' >/etc/apt/sources.list.d/debian-backports.sources
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm-backports
Components: main
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
BACKPORTS_EOF
    $STD apt update
    $STD apt -y -t bookworm-backports install mesa-va-drivers mesa-vulkan-drivers 2>/dev/null ||
      msg_warn "Backports Mesa unavailable - VA-API may not work on RDNA3"

    $STD pip3 uninstall -y onnxruntime 2>/dev/null || true
    if $STD pip3 install "https://github.com/NickM-27/frigate-onnxruntime-rocm/releases/download/v7.1.0/onnxruntime_migraphx-1.23.1-cp311-cp311-linux_x86_64.whl"; then
      clear_execstack /opt/rocm/lib

      # MIGraphX compiles the model's kernels at runtime with ROCm's clang,
      # with warnings as errors. If a GCC install directory without libstdc++
      # headers is also present - a newer gcc pulled in as somebody's
      # dependency - clang refuses to run at all:
      #   error: future releases of the clang compiler will prefer GCC
      #   installations containing libstdc++ include directories
      #   [-Werror,-Wgcc-install-dir-libstdcxx]
      # and no model ever compiles. Point it at the newest GCC that does ship
      # the C++ headers. MIGRAPHX_GPU_HIP_FLAGS is appended last to the
      # compile options, so it overrides what MIGraphX set before it.
      MIGRAPHX_HIP_FLAGS="-Wno-gcc-install-dir-libstdcxx"
      for _gccver in $(ls /usr/lib/gcc/x86_64-linux-gnu/ 2>/dev/null | sort -Vr); do
        if [[ -d "/usr/include/c++/${_gccver}" ]]; then
          MIGRAPHX_HIP_FLAGS="--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/${_gccver} ${MIGRAPHX_HIP_FLAGS}"
          break
        fi
      done

      # Phoenix/Phoenix3 reports gfx1103, which ROCm has no official kernels
      # for; 11.0.0 is the RDNA3 baseline upstream maps it to. Check with
      # `unset HSA_OVERRIDE_GFX_VERSION && /opt/rocm/bin/rocminfo | grep gfx`
      # and change this line in /etc/frigate.env if yours differs.
      cat <<EOF >>/etc/frigate.env
HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-11.0.0}
MIGRAPHX_DISABLE_MIOPEN_FUSION=1
MIGRAPHX_DISABLE_SCHEDULE_PASS=1
MIGRAPHX_DISABLE_REDUCE_FUSION=1
MIGRAPHX_ENABLE_HIPRTC_WORKAROUNDS=1
MIGRAPHX_GPU_HIP_FLAGS="${MIGRAPHX_HIP_FLAGS}"
EOF
      ROCM_READY=1
      msg_ok "AMD ROCm + MIGraphX ready (HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-11.0.0})"
    else
      msg_warn "onnxruntime-migraphx wheel failed to install - ONNX detector will stay on CPU"
    fi
  else
    msg_warn "ROCm did not install (/opt/rocm missing) - skipping MIGraphX"
  fi
fi

cat <<EOF >/config/config.yml
mqtt:
  enabled: false
cameras:
  test:
    ffmpeg:
      inputs:
        - path: /media/frigate/person-bicycle-car-detection.mp4
          input_args: -re -stream_loop -1 -fflags +genpts
          roles:
            - detect
    detect:
      height: 1080
      width: 1920
      fps: 5
auth:
  enabled: false
detect:
  enabled: false
EOF

if grep -q -o -m1 -E 'avx[^ ]*|sse4_2' /proc/cpuinfo && [[ -f /openvino-model/ssdlite_mobilenet_v2.xml ]] && [[ -f /openvino-model/coco_91cl_bkgr.txt ]]; then
  cat <<EOF >/config/config.yml
ffmpeg:
  hwaccel_args: auto
detectors:
  detector01:
    type: openvino
    device: AUTO
model:
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  path: /openvino-model/ssdlite_mobilenet_v2.xml
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt
EOF
else
  cat <<EOF >/config/config.yml
ffmpeg:
  hwaccel_args: auto
model:
  path: /models/cpu_model.tflite
EOF
fi

if [[ "${ROCM_READY:-0}" == "1" ]]; then
  cat <<'ROCM_HINT_EOF' >>/config/config.yml

# ── AMD ROCm / MIGraphX ──────────────────────────────────────────────────────
# ROCm + MIGraphX are installed and /dev/kfd is passed through, so the "onnx"
# detector picks up the GPU by itself. Frigate ships no default ONNX model, so
# put one in /config/model_cache first (YOLOv9 is the best supported on AMD;
# YOLO-NAS runs poorly on integrated GPUs), then replace the detectors/model
# blocks above with:
#
# detectors:
#   onnx:
#     type: onnx
# model:
#   model_type: yolo-generic
#   width: 320
#   height: 320
#   input_tensor: nchw
#   input_dtype: float
#   path: /config/model_cache/yolov9-t.onnx
#   labelmap_path: /labelmap/coco-80.txt
#
# The first start converts the model to .mxr format and is slow, and the AMD
# kernel is known to be fragile during that step: keep detect disabled until
# the log says the conversion finished, then turn it back on.
# Check the GPU is visible with: /opt/rocm/bin/rocminfo | grep gfx
ROCM_HINT_EOF
fi
msg_ok "Configured Frigate"

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/create_directories.service
[Unit]
Description=Create necessary directories for Frigate logs
Before=frigate.service go2rtc.service nginx.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && /bin/chmod -R 777 /dev/shm/logs'

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/go2rtc.service
[Unit]
Description=go2rtc streaming service
After=network.target create_directories.service
# go2rtc's own config is regenerated from Frigate's config.yml by
# create_config.py on every start, so it goes stale as soon as Frigate is
# restarted with a changed config (new camera, changed stream). PartOf makes
# systemd propagate Frigate's stop/restart jobs here; the After= in
# frigate.service keeps go2rtc coming back up first during that restart.
PartOf=frigate.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
EnvironmentFile=/etc/frigate.env
ExecStartPre=+rm -f /dev/shm/logs/go2rtc/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/go2rtc/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/go2rtc/current
StandardError=file:/dev/shm/logs/go2rtc/current

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/frigate.service
[Unit]
Description=Frigate NVR service
After=go2rtc.service create_directories.service
# PartOf only propagates stop/restart, never start, so without this a
# "systemctl start frigate" on its own would leave go2rtc down.
Wants=go2rtc.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
EnvironmentFile=/etc/frigate.env
ExecStartPre=+rm -f /dev/shm/logs/frigate/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/frigate/current
StandardError=file:/dev/shm/logs/frigate/current

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/nginx.service
[Unit]
Description=Nginx reverse proxy for Frigate
After=frigate.service create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
ExecStartPre=+rm -f /dev/shm/logs/nginx/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/nginx/current
StandardError=file:/dev/shm/logs/nginx/current

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q --now create_directories
sleep 2
systemctl enable -q --now go2rtc
sleep 2
systemctl enable -q --now frigate
sleep 2
systemctl enable -q --now nginx
msg_ok "Created Services"

msg_info "Cleaning Up"
rm -rf /opt/libusb /wheels /models/*.tar.gz
msg_ok "Cleaned Up"

motd_ssh
customize
cleanup_lxc
