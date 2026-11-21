#!/usr/bin/env bash
# =============================================================================
# ComfyUI Auto-Installer
# Full setup: ComfyUI + Gemma (text) + Video Model + Pinggy tunnel
# =============================================================================
set -euo pipefail

# --- Colors and styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# --- Globals ---
COMFYUI_PORT=8188
COMFYUI_DIR="$(pwd)/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
CHECKPOINTS_DIR="${MODELS_DIR}/checkpoints"
VAE_DIR="${MODELS_DIR}/vae"
TEXT_ENCODERS_DIR="${MODELS_DIR}/text_encoders"
VIDEO_MODELS_DIR="${MODELS_DIR}/animatediff_models"
PINGGY_TOKEN=""

# --- Logging helpers ---
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}  $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }
log_header()  { echo -e "${MAGENTA}${BOLD}[$*]${NC}"; }

progress_bar() {
    local current=$1 total=$2 label=$3
    local pct=$(( current * 100 / total ))
    local filled=$(( current * 30 / total ))
    local empty=$(( 30 - filled ))
    local bar=""
    for (( i=0; i<filled; i++ )); do bar="${bar}#"; done
    for (( i=0; i<empty; i++ )); do bar="${bar}-"; done
    printf "\r${CYAN}%s${NC} [%-30s] %3d%%" "$label" "$bar" "$pct"
    if (( current == total )); then echo; fi
}

# --- ASCII Art Banner ---
print_banner() {
    echo -e "${MAGENTA}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    echo "  ║   ██████╗ ███████╗████████╗██████╗  ██████╗ ██████╗      ║"
    echo "  ║   ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗██╔══██╗     ║"
    echo "  ║   ██████╔╝█████╗     ██║   ██████╔╝██║   ██║██████╔╝     ║"
    echo "  ║   ██╔══██╗██╔══╝     ██║   ██╔══██╗██║   ██║██╔══██╗     ║"
    echo "  ║   ██║  ██║███████╗   ██║   ██║  ██║╚██████╔╝██║  ██║     ║"
    echo "  ║   ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝     ║"
    echo "  ║                                                          ║"
    echo "  ║   Auto-Installer v2.0                                    ║"
    echo "  ║   ComfyUI + Gemma + Video + Pinggy                      ║"
    echo "  ║                                                          ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# --- Dependency checks ---
check_root() {
    if (( EUID == 0 )); then
        log_warn "Running as root — some tools may behave unexpectedly."
    fi
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        return 1
    fi
    return 0
}

install_system_deps() {
    log_header "SYSTEM DEPENDENCIES"
    log_info "Updating package lists..."
    if check_command apt-get; then
        sudo apt-get update -qq
        local deps=(git curl wget python3 python3-pip python3-venv ffmpeg)
        local to_install=()
        for dep in "${deps[@]}"; do
            if ! check_command "$dep"; then
                to_install+=("$dep")
            fi
        done
        if (( ${#to_install[@]} > 0 )); then
            log_info "Installing: ${to_install[*]}"
            sudo apt-get install -y -qq "${to_install[@]}" 2>&1 | tail -5
            log_ok "System dependencies installed"
        else
            log_ok "All system dependencies already present"
        fi
    elif check_command dnf; then
        sudo dnf install -y git curl wget python3 python3-pip ffmpeg 2>/dev/null || true
        log_ok "System dependencies installed (dnf)"
    elif check_command pacman; then
        sudo pacman -S --noconfirm --needed git curl wget python3 pip ffmpeg 2>/dev/null || true
        log_ok "System dependencies installed (pacman)"
    else
        log_warn "Unknown package manager — skipping system deps"
    fi
}

# --- Python virtual environment ---
setup_venv() {
    log_header "PYTHON VIRTUAL ENVIRONMENT"
    if [[ -d "${COMFYUI_DIR}/venv" ]]; then
        log_info "Virtual environment already exists"
    else
        log_info "Creating virtual environment..."
        python3 -m venv "${COMFYUI_DIR}/venv"
        log_ok "Virtual environment created"
    fi
    # Activate
    # shellcheck disable=SC1091
    source "${COMFYUI_DIR}/venv/bin/activate"
    log_ok "Python venv activated"
}

# --- ComfyUI ---
install_comfyui() {
    log_header "COMFYUI"
    if [[ -d "${COMFYUI_DIR}/.git" ]]; then
        log_info "ComfyUI already cloned — updating..."
        cd "${COMFYUI_DIR}"
        git pull || true
        cd - > /dev/null
    else
        log_info "Cloning ComfyUI..."
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}"
        log_ok "ComfyUI cloned"
    fi

    log_info "Installing Python dependencies..."
    cd "${COMFYUI_DIR}"
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install --upgrade pip 2>&1 | tail -1
    pip install -r requirements.txt 2>&1 | tail -3
    cd - > /dev/null
    log_ok "ComfyUI ready"
}

# --- Create model directories ---
create_dirs() {
    log_header "MODEL DIRECTORIES"
    mkdir -p "${CHECKPOINTS_DIR}"
    mkdir -p "${VAE_DIR}"
    mkdir -p "${TEXT_ENCODERS_DIR}"
    mkdir -p "${VIDEO_MODELS_DIR}"
    mkdir -p "${COMFYUI_DIR}/models/unet"
    mkdir -p "${COMFYUI_DIR}/custom_nodes"
    log_ok "Model directories created"
}

# --- Download helper ---
download_file() {
    local url="$1"
    local dest="$2"
    local label="${3:-Downloading}"
    local filename
    filename="$(basename "$url")"

    # Create directory if needed
    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        log_info "${filename} already exists — skipping"
        return 0
    fi

    log_info "${label}: ${filename}"
    log_info "  URL: ${url}"

    # Use curl with progress bar
    if check_command curl; then
        curl -L --progress-bar -o "$dest" "$url" 2>&1 || {
            log_error "Failed to download ${filename}"
            return 1
        }
    elif check_command wget; then
        wget -q --show-progress -O "$dest" "$url" 2>&1 || {
            log_error "Failed to download ${filename}"
            return 1
        }
    else
        log_error "No download tool available (curl/wget)"
        return 1
    fi

    if [[ -f "$dest" ]]; then
        local size
        size=$(du -h "$dest" | cut -f1)
        log_ok "Downloaded (${size})"
    fi
}

# --- Gemma text model ---
install_gemma() {
    log_header "GEMMA TEXT MODEL"
    log_info "Gemma is a lightweight LLM by Google for text generation."
    log_info "We will install the Gemma 2B IT (Instruct-Tuned) variant."

    local gemma_dir="${TEXT_ENCODERS_DIR}/gemma"
    mkdir -p "${gemma_dir}"

    # Gemma 2B IT is available on HuggingFace
    # Using the GGUF format for CPU/GPU compatibility
    local gemma_url="https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-IQ2_M.gguf"
    local gemma_dest="${gemma_dir}/gemma-2-2b-it-IQ2_M.gguf"

    log_info "Model: Gemma 2 2B IT (IQ2_M quantized ~1.3GB)"
    download_file "$gemma_url" "$gemma_dest" "Gemma 2B IT"

    if [[ -f "$gemma_dest" ]]; then
        log_ok "Gemma text model installed"
        log_info "  Location: ${gemma_dest}"
    else
        log_warn "Gemma download failed — you can install it manually later"
        log_info "  HF repo: https://huggingface.co/bartowski/gemma-2-2b-it-GGUF"
    fi
}

# --- Video model (AnimateDiff / SVD) ---
install_video_model() {
    log_header "VIDEO GENERATION MODEL"
    log_info "Installing AnimateDiff-Evolved + Video model for ComfyUI."

    # AnimateDiff models directory
    local ad_models_dir="${VIDEO_MODELS_DIR}"

    # Download AnimateDiff Evo custom node
    local ad_node_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-AnimateDiff-Evolved"
    if [[ ! -d "${ad_node_dir}/.git" ]]; then
        log_info "Installing AnimateDiff-Evolved custom node..."
        git clone https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved.git "${ad_node_dir}" 2>&1 | tail -2
        log_ok "AnimateDiff-Evolved installed"
    else
        log_info "AnimateDiff-Evolved already installed"
    fi

    # Download AnimateDiff motion model (mm_sd_v15_v2.safetensors)
    local motion_model_url="https://huggingface.co/guoyww/animatediff/resolve/main/animatediff_motion_module_v1.ckpt"
    local motion_model_dest="${ad_models_dir}/mm_sd_v15_v2.ckpt"

    log_info "Model: AnimateDiff Motion Module (v15_v2)"
    download_file "$motion_model_url" "$motion_model_dest" "AnimateDiff Motion Model"

    # Also install ComfyUI-Impact-Pack for better video processing
    local impact_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-Impact-Pack"
    if [[ ! -d "${impact_dir}/.git" ]]; then
        log_info "Installing ComfyUI-Impact-Pack..."
        git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git "${impact_dir}" 2>&1 | tail -2
        log_ok "Impact-Pack installed"
    fi

    # Install ComfyUI-VideoHelperSuite for video I/O
    local vhs_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-VideoHelperSuite"
    if [[ ! -d "${vhs_dir}/.git" ]]; then
        log_info "Installing VideoHelperSuite..."
        git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "${vhs_dir}" 2>&1 | tail -2
        log_ok "VideoHelperSuite installed"
    fi

    if [[ -f "$motion_model_dest" ]]; then
        log_ok "Video generation model installed"
        log_info "  Motion model: ${motion_model_dest}"
    else
        log_warn "Motion model download failed — you can install it manually"
        log_info "  HF repo: https://huggingface.co/guoyww/animatediff"
    fi
}

# --- Pinggy tunnel ---
setup_pinggy() {
    log_header "PINGGY TUNNEL"
    log_info "Setting up Pinggy for public access to ComfyUI."

    local pinggy_bin="${COMFYUI_DIR}/pinggy"

    if check_command pinggy; then
        log_ok "Pinggy CLI already installed"
    else
        log_info "Installing Pinggy CLI..."
        # Detect architecture
        local arch
        arch=$(uname -m)
        local pinggy_url

        case "$arch" in
            x86_64)
                pinggy_url="https://github.com/pinggy/tunnel/releases/latest/download/pinggy-linux-amd64"
                ;;
            aarch64|arm64)
                pinggy_url="https://github.com/pinggy/tunnel/releases/latest/download/pinggy-linux-arm64"
                ;;
            *)
                log_warn "Unknown architecture: ${arch} — trying amd64"
                pinggy_url="https://github.com/pinggy/tunnel/releases/latest/download/pinggy-linux-amd64"
                ;;
        esac

        curl -sL --retry 3 -o "${pinggy_bin}" "${pinggy_url}" 2>&1 || {
            log_error "Failed to download Pinggy CLI"
            return 1
        }
        chmod +x "${pinggy_bin}"
        log_ok "Pinggy CLI installed"
    fi

    # Save config
    cat > "${COMFYUI_DIR}/.pinggy_config" <<EOF
# Pinggy configuration for ComfyUI
COMFYUI_PORT=${COMFYUI_PORT}
PINGGY_BIN=${pinggy_bin}
EOF
    log_ok "Pinggy configured for port ${COMFYUI_PORT}"
}

# --- Start script ---
create_start_script() {
    log_header "START SCRIPT"

    cat > "${COMFYUI_DIR}/start.sh" <<'STARTSCRIPT'
#!/usr/bin/env bash
# =============================================================================
# ComfyUI Start Script
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Starting ComfyUI..."

# Activate venv
source venv/bin/activate

# Check for Pinggy
PINGGY_BIN=""
if [[ -f ".pinggy_config" ]]; then
    # shellcheck source=/dev/null
    source .pinggy_config
fi

if [[ -n "${PINGGY_BIN:-}" && -f "$PINGGY_BIN" ]]; then
    echo "Starting with Pinggy tunnel..."
    # Start ComfyUI in background
    python main.py --port 8188 &
    COMFY_PID=$!

    # Wait for ComfyUI to be ready
    echo "Waiting for ComfyUI to start..."
    for i in $(seq 1 30); do
        if curl -s http://localhost:8188/system-stats > /dev/null 2>&1; then
            echo "ComfyUI is ready!"
            break
        fi
        sleep 1
    done

    # Start Pinggy tunnel
    echo "Starting Pinggy tunnel..."
    "$PINGGY_BIN" http --port 8188 --no-tls

    kill $COMFY_PID 2>/dev/null || true
else
    echo "Starting ComfyUI (local only)..."
    echo "Open: http://localhost:8181"
    python main.py --port 8188
fi
STARTSCRIPT

    chmod +x "${COMFYUI_DIR}/start.sh"
    log_ok "Start script created: ${COMFYUI_DIR}/start.sh"
}

# --- Quick launch helpers ---
create_helpers() {
    log_header "HELPER SCRIPTS"

    # Pinggy quick-launch
    cat > "${COMFYUI_DIR}/pinggy.sh" <<'PINGGYSCRIPT'
#!/usr/bin/env bash
# Quick Pinggy tunnel for ComfyUI
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Start ComfyUI in background
python main.py --port 8188 --listen 0.0.0.0 &
COMFY_PID=$!

# Wait for ready
echo "Waiting for ComfyUI..."
for i in $(seq 1 30); do
    if curl -s http://localhost:8188/system-stats > /dev/null 2>&1; then
        echo "ComfyUI ready!"
        break
    fi
    sleep 1
done

# Start Pinggy
if command -v pinggy &>/dev/null; then
    echo "Starting Pinggy tunnel..."
    pinggy http --port 8188 --no-tls
elif [[ -f "./pinggy" ]]; then
    echo "Starting Pinggy tunnel..."
    ./pinggy http --port 8188 --no-tls
else
    echo "Install Pinggy: https://docs.pinggy.io"
    echo "Or use: pinggy http --port 8188 --no-tls"
fi

kill $COMFY_PID 2>/dev/null || true
PINGGYSCRIPT
    chmod +x "${COMFYUI_DIR}/pinggy.sh"

    # Local start
    cat > "${COMFYUI_DIR}/local.sh" <<'LOCALSCRIPT'
#!/usr/bin/env bash
# Start ComfyUI locally
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source venv/bin/activate
echo "ComfyUI: http://localhost:8188"
python main.py --port 8188 --listen 0.0.0.0
LOCALSCRIPT
    chmod +x "${COMFYUI_DIR}/local.sh"

    log_ok "Helper scripts created"
}

# --- Final summary ---
print_summary() {
    echo ""
    echo -e "${BOLD}${MAGENTA}"
    echo "  +----------------------------------------------------------+"
    echo "  |                                                          |"
    echo "  |   INSTALLATION COMPLETE!                                 |"
    echo "  |                                                          |"
    echo -e "  |   ${GREEN}ComfyUI${NC}       : ${COMFYUI_DIR}"
    echo -e "  |   ${GREEN}Models${NC}        : ${MODELS_DIR}"
    echo -e "  |   ${GREEN}Custom Nodes${NC}  : ${COMFYUI_DIR}/custom_nodes"
    echo -e "  |   ${GREEN}Port${NC}          : ${COMFYUI_PORT}"
    echo "  |                                                          |"
    echo -e "  |   ${CYAN}Start locally:${NC}   cd ${COMFYUI_DIR} && ./local.sh"
    echo -e "  |   ${CYAN}Start with Pinggy:${NC} cd ${COMFYUI_DIR} && ./pinggy.sh"
    echo -e "  |   ${CYAN}Start full:${NC}      cd ${COMFYUI_DIR} && ./start.sh"
    echo "  |                                                          |"
    echo "  +----------------------------------------------------------+"
    echo -e "${NC}"
}

# --- Main ---
main() {
    print_banner
    check_root

    echo -e "${YELLOW}${BOLD}This script will install:${NC}"
    echo -e "  ${GREEN}ComfyUI${NC}          — Stable diffusion GUI"
    echo -e "  ${GREEN}Gemma 2B IT${NC}     — Text generation model"
    echo -e "  ${GREEN}AnimateDiff${NC}      — Video generation model"
    echo -e "  ${GREEN}Pinggy${NC}           — Public tunnel"
    echo ""

    read -r -p "${YELLOW}Continue? [Y/n]${NC} " answer
    answer="${answer:-Y}"
    if [[ "${answer,,}" == "n" || "${answer,,}" == "no" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    log_step "1/7  System dependencies"
    install_system_deps

    log_step "2/7  Python virtual environment"
    setup_venv

    log_step "3/7  ComfyUI"
    install_comfyui

    log_step "4/7  Model directories"
    create_dirs

    log_step "5/7  Gemma text model"
    install_gemma

    log_step "6/7  Video generation model"
    install_video_model

    log_step "7/7  Pinggy tunnel"
    setup_pinggy

    create_start_script
    create_helpers

    print_summary
}

main "$@"
