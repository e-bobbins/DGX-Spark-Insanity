#!/usr/bin/env bash
# ensure-yq.sh - make sure a mikefarah/yq binary is available.
#
# Spark-kit-3 scripts speak mikefarah/yq syntax. The Debian/Ubuntu package
# named "yq" is a different program entirely (kislyuk/yq, a jq wrapper), so
# installing via apt silently breaks every script. This helper:
#   1. accepts the system yq when it is mikefarah's;
#   2. falls back to a vendored copy at ${KIT_DIR}/bin/yq;
#   3. otherwise downloads a pinned mikefarah/yq release into ${KIT_DIR}/bin
#      (no root needed) and prepends it to PATH.
#
# Sourced (never executed) by deploy.sh, verify.sh, and rollback.sh.

ensure_yq() {
    local flavor
    if command -v yq > /dev/null 2>&1; then
        flavor="$(yq --version 2>/dev/null || true)"
        if echo "${flavor}" | grep -qi mikefarah; then
            return 0
        fi
    fi

    # Vendored copy?
    if [ -x "${KIT_DIR}/bin/yq" ]; then
        flavor="$("${KIT_DIR}/bin/yq" --version 2>/dev/null || true)"
        if echo "${flavor}" | grep -qi mikefarah; then
            export PATH="${KIT_DIR}/bin:${PATH}"
            return 0
        fi
    fi

    # Download a pinned release into the kit (no root required).
    local ver="v4.44.3"
    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *)
            echo "ERROR: unsupported architecture $(uname -m); install mikefarah/yq manually." >&2
            return 1
            ;;
    esac

    local url="https://github.com/mikefarah/yq/releases/download/${ver}/yq_linux_${arch}.tar.gz"
    mkdir -p "${KIT_DIR}/bin"
    echo "[+] Downloading mikefarah/yq ${ver} (${arch}) into ${KIT_DIR}/bin ..."
    # The release tarball stores the binary as "./yq_linux_<arch>" (leading
    # "./"), which some tar builds refuse to match by bare member name, so
    # extract the whole archive and clean up the extra files.
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "${url}" | tar -xz -C "${KIT_DIR}/bin" || return 1
    elif command -v wget > /dev/null 2>&1; then
        wget -qO- "${url}" | tar -xz -C "${KIT_DIR}/bin" || return 1
    else
        echo "ERROR: neither curl nor wget found; install mikefarah/yq manually." >&2
        return 1
    fi
    rm -f "${KIT_DIR}/bin/yq.1" "${KIT_DIR}/bin/install-man-page.sh"
    mv "${KIT_DIR}/bin/yq_linux_${arch}" "${KIT_DIR}/bin/yq"
    chmod +x "${KIT_DIR}/bin/yq"
    export PATH="${KIT_DIR}/bin:${PATH}"
}
