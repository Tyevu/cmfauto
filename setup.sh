#!/usr/bin/env bash
# =============================================================================
# ComfyUI Auto-Installer — fully automatic, live progress, CPU/RAM monitor
# =============================================================================
set -uo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Globals ---
COMFYUI_PORT=8188
COMFYUI_DIR="$(pwd)/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
CHECKPOINTS_DIR="${MODELS_DIR}/checkpoints"
VAE_DIR="${MODELS_DIR}/vae"
TEXT_ENCODERS_DIR="${MODELS_DIR}/text_encoders"
VIDEO_MODELS_DIR="${MODELS_DIR}/animatediff_models"
PINGGY_BIN="${COMFYUI_DIR}/pinggy"
COMFY_PID=""
PINGGY_PID=""
STOP_MONITOR=0

# --- Logging ---
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}  $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }
log_header()  { echo -e "${MAGENTA}${BOLD}[$*]${NC}"; }

# --- ASCII Banner ---
print_banner() {
    echo -e "${MAGENTA}${BOLD}"
    echo "  +============================================================+"
    echo "  |                                                            |"
    echo "  |   ██████╗ ███████╗████████╗██████╗  ██████╗ ██████╗        |"
    echo "  |   ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗██╔══██╗      |"
    echo "  |   ██████╔╝█████╗     ██║   ██████╔╝██║   ██║██████╔╝      |"
    echo "  |   ██╔══██╗██╔══╝     ██║   ██╔══██╗██║   ██║██╔══██╗      |"
    echo "  |   ██║  ██║███████╗   ██║   ██║  ██║╚██████╔╝██║  ██║      |"
    echo "  |   ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝      |"
    echo "  |                                                            |"
    echo "  |   Auto-Installer v3.0 — Fully Automatic                   |"
    echo "  |   ComfyUI + Gemma + AnimateDiff + Pinggy                  |"
    echo "  |                                                            |"
    echo "  +============================================================+"
    echo -e "${NC}"
}

# --- Live CPU/RAM Monitor ---
monitor_system() {
    local interval=1
    while (( STOP_MONITOR == 0 )); do
        # CPU usage
        local cpu_line
        cpu_line=$(top -bn1 2>/dev/null | grep "Cpu(s)" | head -1)
        local cpu_idle cpu_usage
        if [[ -n "$cpu_line" ]]; then
            cpu_idle=$(echo "$cpu_line" | grep -oP '[\d.]+\s*id' | grep -oP '[\d.]+' || echo "0")
            cpu_usage=$(awk "BEGIN {printf \"%.1f\", 100 - $cpu_idle}")
        else
            # Fallback: mpstat or /proc/stat
            if command -v mpstat &>/dev/null; then
                cpu_idle=$(mpstat 1 1 2>/dev/null | tail -1 | awk '{print $NF}')
                cpu_usage=$(awk "BEGIN {printf \"%.1f\", 100 - $cpu_idle}")
            else
                cpu_usage="?"
            fi
        fi

        # RAM usage
        local mem_info mem_total mem_avail mem_used_pct
        if [[ -f /proc/meminfo ]]; then
            mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
            if (( mem_total > 0 )); then
                mem_used_pct=$(awk "BEGIN {printf \"%.0f\", (1 - $mem_avail/$mem_total) * 100}")
            else
                mem_used_pct="?"
            fi
            local mem_used_gb mem_total_gb
            mem_used_gb=$(awk "BEGIN {printf \"%.1f\", ($mem_total - $mem_avail) / 1048576}")
            mem_total_gb=$(awk "BEGIN {printf \"%.1f\", $mem_total / 1048576}")
        else
            mem_used_pct="?"
            mem_used_gb="?"
            mem_total_gb="?"
        fi

        # Render status bar
        printf "\r${DIM}  CPU: %s%%  |  RAM: %s%% (%s / %s GB)${NC}  " \
            "$cpu_usage" "$mem_used_pct" "$mem_used_gb" "$mem_total_gb"

        sleep "$interval"
    done
    echo ""
}

# --- Progress bar for downloads ---
download_with_progress() {
    local url="$1"
    local dest="$2"
    local label="${3:-Downloading}"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        log_info "$(basename "$dest") already exists — skipping"
        return 0
    fi

    local filename
    filename="$(basename "$dest")"

    # Get file size first
    local total_size=0
    if check_command curl; then
        total_size=$(curl -sIL "$url" -o /dev/null 2>/dev/null | grep -i 'Content-Length' | awk '{print $2}' | head -1)
    fi

    log_info "${label}: ${filename}"
    if (( total_size > 0 )); then
        local size_human
        size_human=$(human_size "$total_size")
        log_info "  Size: ${size_human}"
    fi

    # Download with progress
    if check_command curl; then
        curl -L --progress-bar -o "${dest}.tmp" "$url" 2>&1 || {
            log_error "Failed to download ${filename}"
            rm -f "${dest}.tmp"
            return 1
        }
    elif check_command wget; then
        wget -q --show-progress -O "${dest}.tmp" "$url" 2>&1 || {
            log_error "Failed to download ${filename}"
            rm -f "${dest}.tmp"
            return 1
        }
    else
        log_error "No download tool (curl/wget)"
        return 1
    fi

    mv "${dest}.tmp" "$dest"

    if [[ -f "$dest" ]]; then
        local size
        size=$(du -h "$dest" | cut -f1)
        log_ok "Downloaded (${size})"
    fi
}

# --- Human readable size ---
human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

# --- Check command ---
check_command() {
    command -v "$1" &>/dev/null
}

# --- Install system deps ---
install_system_deps() {
    log_header "SYSTEM DEPENDENCIES"
    sudo apt-get update -qq 2>/dev/null || true

    local deps=(git curl wget python3 python3-pip python3-venv ffmpeg)
    local to_install=()
    for dep in "${deps[@]}"; do
        if ! check_command "$dep"; then
            to_install+=("$dep")
        fi
    done

    if (( ${#to_install[@]} > 0 )); then
        log_info "Installing: ${to_install[*]}"
        sudo apt-get install -y -qq "${to_install[@]}" 2>&1 | tail -3
        log_ok "System dependencies installed"
    else
        log_ok "All system dependencies present"
    fi
}

# --- Python venv ---
setup_venv() {
    log_header "PYTHON VIRTUAL ENVIRONMENT"
    if [[ ! -d "${COMFYUI_DIR}/venv" ]]; then
        log_info "Creating virtual environment..."
        python3 -m venv "${COMFYUI_DIR}/venv"
        log_ok "Virtual environment created"
    else
        log_info "Virtual environment exists"
    fi
    # shellcheck disable=SC1091
    source "${COMFYUI_DIR}/venv/bin/activate"
    log_ok "Python venv activated"
}

# --- ComfyUI ---
install_comfyui() {
    log_header "COMFYUI"
    if [[ -d "${COMFYUI_DIR}/.git" ]]; then
        log_info "ComfyUI already cloned — updating..."
        cd "${COMFYUI_DIR}" && git pull 2>&1 | tail -2 && cd - > /dev/null
    else
        log_info "Cloning ComfyUI..."
        git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}" 2>&1 | tail -2
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

# --- Create dirs ---
create_dirs() {
    log_header "MODEL DIRECTORIES"
    mkdir -p "${CHECKPOINTS_DIR}" "${VAE_DIR}" "${TEXT_ENCODERS_DIR}"
    mkdir -p "${VIDEO_MODELS_DIR}" "${COMFYUI_DIR}/models/unet"
    mkdir -p "${COMFYUI_DIR}/custom_nodes"
    log_ok "Model directories created"
}

# --- Gemma text model ---
install_gemma() {
    log_header "GEMMA TEXT MODEL"
    local gemma_dir="${TEXT_ENCODERS_DIR}/gemma"
    mkdir -p "${gemma_dir}"
    local gemma_dest="${gemma_dir}/gemma-2-2b-it-IQ2_M.gguf"

    local gemma_url="https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-IQ2_M.gguf"
    log_info "Model: Gemma 2 2B IT (IQ2_M quantized)"
    download_with_progress "$gemma_url" "$gemma_dest" "Gemma 2B IT"

    if [[ -f "$gemma_dest" ]]; then
        log_ok "Gemma text model installed"
    else
        log_warn "Gemma download failed — install manually later"
    fi
}

# --- Video model ---
install_video_model() {
    log_header "VIDEO GENERATION MODEL"

    # AnimateDiff-Evolved custom node
    local ad_node_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-AnimateDiff-Evolved"
    if [[ ! -d "${ad_node_dir}/.git" ]]; then
        log_info "Installing AnimateDiff-Evolved..."
        git clone https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved.git "${ad_node_dir}" 2>&1 | tail -2
        log_ok "AnimateDiff-Evolved installed"
    else
        log_info "AnimateDiff-Evolved already installed"
    fi

    # Motion model
    local motion_dest="${VIDEO_MODELS_DIR}/mm_sd_v15_v2.ckpt"
    local motion_url="https://huggingface.co/guoyww/animatediff/resolve/main/animatediff_motion_module_v1.ckpt"
    log_info "Model: AnimateDiff Motion Module v15_v2"
    download_with_progress "$motion_url" "$motion_dest" "AnimateDiff Motion Model"

    # Impact Pack
    local impact_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-Impact-Pack"
    if [[ ! -d "${impact_dir}/.git" ]]; then
        git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git "${impact_dir}" 2>&1 | tail -2
        log_ok "Impact-Pack installed"
    fi

    # VideoHelperSuite
    local vhs_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-VideoHelperSuite"
    if [[ ! -d "${vhs_dir}/.git" ]]; then
        git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "${vhs_dir}" 2>&1 | tail -2
        log_ok "VideoHelperSuite installed"
    fi

    if [[ -f "$motion_dest" ]]; then
        log_ok "Video generation model installed"
    else
        log_warn "Motion model download failed"
    fi
}

# --- Pinggy ---
setup_pinggy() {
    log_header "PINGGY TUNNEL"
    if check_command pinggy; then
        log_ok "Pinggy CLI already installed"
    elif [[ -f "$PINGGY_BIN" ]]; then
        log_ok "Pinggy binary already downloaded"
    else
        log_info "Downloading Pinggy CLI..."
        local arch
        arch=$(uname -m)
        local pinggy_url
        case "$arch" in
            x86_64) pinggy_url="https://github.com/pinggy/tunnel/releases/latest/download/pinggy-linux-amd64" ;;
            aarch64|arm64) pinggy_url="https://github.com/pinggy/tunnel/releases/latest/download/pinggy-linux-arm64" ;;
            *) pinggy_url="https://github.com/pinggy/tunnel/releases/latest/download/pinggy-linux-amd64" ;;
        esac
        curl -sL --retry 3 -o "${PINGGY_BIN}" "${pinggy_url}" 2>&1
        chmod +x "${PINGGY_BIN}"
        log_ok "Pinggy CLI installed"
    fi
}

# --- Start ComfyUI + Pinggy ---
launch_comfyui_and_pinggy() {
    log_header "LAUNCHING COMFYUI + PINGGY"

    cd "${COMFYUI_DIR}"
    # shellcheck disable=SC1091
    source venv/bin/activate

    # Start ComfyUI in background
    log_info "Starting ComfyUI on port ${COMFYUI_PORT}..."
    python main.py --port "${COMFYUI_PORT}" --listen 0.0.0.0 &
    COMFY_PID=$!
    log_info "ComfyUI PID: ${COMFY_PID}"

    # Wait for ComfyUI to be ready
    log_info "Waiting for ComfyUI to be ready..."
    local ready=0
    for i in $(seq 1 60); do
        if curl -s "http://localhost:${COMFYUI_PORT}/system-stats" &>/dev/null; then
            ready=1
            break
        fi
        sleep 1
    done

    if (( ready == 0 )); then
        log_warn "ComfyUI may not be ready yet — giving up waiting"
    else
        log_ok "ComfyUI is ready!"
    fi

    # Start Pinggy tunnel
    log_info "Starting Pinggy tunnel..."
    local pinggy_cmd="${PINGGY_BIN:-pinggy}"
    if [[ ! -f "$pinggy_cmd" ]]; then
        pinggy_cmd="pinggy"
    fi

    $pinggy_cmd http --port "${COMFYUI_PORT}" --no-tls &
    PINGGY_PID=$!
    log_info "Pinggy PID: ${PINGGY_PID}"

    # Wait for Pinggy to give us the URL
    sleep 5

    # Try to get the public URL from Pinggy output
    local public_url
    public_url=$(lsof -i :${COMFYUI_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)

    echo ""
    echo -e "${BOLD}${MAGENTA}"
    echo "  +============================================================+"
    echo "  |                                                            |"
    echo "  |   COMFYUI IS RUNNING!                                      |"
    echo "  |                                                            |"
    echo -e "  |   ${GREEN}Local:${NC}     http://localhost:${COMFYUI_PORT}"
    echo -e "  |   ${GREEN}ComfyUI PID:${NC} ${COMFY_PID}"
    echo -e "  |   ${GREEN}Pinggy PID:${NC}  ${PINGGY_PID}"
    echo "  |                                                            |"
    echo "  |   Press Ctrl+C to stop everything                          |"
    echo "  |                                                            |"
    echo "  +============================================================+"
    echo -e "${NC}"

    # Cleanup on exit
    trap cleanup EXIT INT TERM

    # Keep running
    wait
}

cleanup() {
    STOP_MONITOR=1
    echo ""
    log_info "Shutting down..."
    if (( COMFY_PID > 0 )); then
        kill "$COMFY_PID" 2>/dev/null || true
        log_info "ComfyUI stopped"
    fi
    if (( PINGGY_PID > 0 )); then
        kill "$PINGGY_PID" 2>/dev/null || true
        log_info "Pinggy stopped"
    fi
    echo "Done."
    exit 0
}

# --- Main ---
main() {
    print_banner

    echo -e "${YELLOW}${BOLD}Auto-installing everything — no prompts.${NC}"
    echo ""

    # Start system monitor in background
    monitor_system &
    MONITOR_PID=$!

    # Trap to stop monitor
    trap 'STOP_MONITOR=1; kill $MONITOR_PID 2>/dev/null; wait $MONITOR_PID 2>/dev/null' EXIT INT TERM

    log_step "1/6  System dependencies"
    install_system_deps

    log_step "2/6  Python virtual environment"
    setup_venv

    log_step "3/6  ComfyUI"
    install_comfyui

    log_step "4/6  Model directories"
    create_dirs

    log_step "5/6  Gemma text model"
    install_gemma

    log_step "6/6  Video generation model"
    install_video_model

    log_step "Pinggy tunnel"
    setup_pinggy

    echo ""
    log_ok "All installations complete!"
    echo ""

    # Stop monitor before launch
    STOP_MONITOR=1
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true

    # Launch
    launch_comfyui_and_pinggy
}

main "$@"
