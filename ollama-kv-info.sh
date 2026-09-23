#!/bin/bash

# ==================================================
# Ollama KV Cache and Memory Information
# ==================================================

CONTAINER="ollama_container"
OLLAMA_URL="http://localhost:11434"

# ==================================================
# Select model
# ==================================================

echo
echo "Ollama Models:"
echo "--------------------------------------------------"

# Read installed models and their sizes
mapfile -t MODEL_DATA < <(
    docker exec -i "$CONTAINER" ollama list |
    awk 'NR > 1 {
        name=$1
        size=$3
        unit=$4
        print name "|" size " " unit
    }'
)

if [ ${#MODEL_DATA[@]} -eq 0 ]; then
    echo "No models found."
    exit 1
fi

declare -a MODELS
declare -a SIZES

# Prepare model names and sizes
for i in "${!MODEL_DATA[@]}"; do
    IFS='|' read -r MODEL SIZE <<< "${MODEL_DATA[$i]}"

    MODELS[$i]="$MODEL"
    SIZES[$i]="$SIZE"

    printf "%2d) %-35s %8s\n" \
        "$((i+1))" "$MODEL" "$SIZE"
done

echo "--------------------------------------------------"

read -p "Please enter the model number of the desired model: " CHOICE

# Validate model selection
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || \
   [ "$CHOICE" -lt 1 ] || \
   [ "$CHOICE" -gt "${#MODELS[@]}" ]; then

    echo "Invalid Choice."
    exit 1
fi

SELECTED_MODEL="${MODELS[$((CHOICE-1))]}"
MODEL_SIZE="${SIZES[$((CHOICE-1))]}"

# ==================================================
# Convert model size to GiB
# ==================================================

MODEL_SIZE_VALUE=$(echo "$MODEL_SIZE" | awk '{print $1}')
MODEL_SIZE_UNIT=$(echo "$MODEL_SIZE" | awk '{print $2}')

case "$MODEL_SIZE_UNIT" in
    GB)
        MODEL_GIB=$(awk -v size="$MODEL_SIZE_VALUE" \
            'BEGIN {
                printf "%.2f", size * 1000000000 / 1073741824
            }')
        ;;
    MB)
        MODEL_GIB=$(awk -v size="$MODEL_SIZE_VALUE" \
            'BEGIN {
                printf "%.2f", size * 1000000 / 1073741824
            }')
        ;;
    TB)
        MODEL_GIB=$(awk -v size="$MODEL_SIZE_VALUE" \
            'BEGIN {
                printf "%.2f", size * 1000000000000 / 1073741824
            }')
        ;;
    *)
        MODEL_GIB="Cannot be calculated"
        ;;
esac

MODEL_GB=$(awk "BEGIN {printf \"%.2f\", $MODEL_GIB * 1.073741824}")

# ==================================================
# Determine maximum context length supported by the model
# ==================================================
#
# This must happen BEFORE the context size selection, so
# that only context sizes the model actually supports can
# be offered. The Ollama API must already be reachable at
# this point, since the model list above required the
# container to already be running.
# ==================================================

echo
echo "Read about model architecture..."

MODEL_JSON=$(
    curl -s "$OLLAMA_URL/api/show" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$SELECTED_MODEL\"}"
)

API_ERROR=$(echo "$MODEL_JSON" | jq -r '.error // empty' 2>/dev/null)

if [ -z "$MODEL_JSON" ] || [ -n "$API_ERROR" ]; then

    echo "Warning: The model architecture could not be determined."
    echo "All standard context sizes are displayed without checking"
    echo "against the maximum model context."

    LAYER=""
    KV_HEADS=""
    KEY_LENGTH=""
    VALUE_LENGTH=""
    HEAD_DIM=""
    MODEL_CONTEXT_LENGTH=""

else

LAYER=$(echo "$MODEL_JSON" | jq -r '.model_info | to_entries[] | select(.key | endswith(".block_count")) | .value')
KV_HEADS=$(echo "$MODEL_JSON" | jq -r '.model_info | to_entries[] | select(.key | endswith(".attention.head_count_kv")) | .value')
KEY_LENGTH=$(echo "$MODEL_JSON" | jq -r '.model_info | to_entries[] | select(.key | endswith(".attention.key_length")) | .value')

if [ -z "$KEY_LENGTH" ]; then
    EMBEDDING_LENGTH=$(echo "$MODEL_JSON" | jq -r '.model_info | to_entries[] | select(.key | endswith(".embedding_length")) | .value')
    HEAD_COUNT=$(echo "$MODEL_JSON" | jq -r '.model_info | to_entries[] | select(.key | endswith(".attention.head_count")) | .value')

    if [ ! -z "$EMBEDDING_LENGTH" ] && [ ! -z "$HEAD_COUNT" ]; then
        KEY_LENGTH=$(( EMBEDDING_LENGTH / HEAD_COUNT ))
    fi
fi

    VALUE_LENGTH=$(echo "$MODEL_JSON" |
        jq -r '.model_info["llama.attention.value_length"] // empty')

    # Key length represents the attention head dimension
    HEAD_DIM="$KEY_LENGTH"

    # Maximum context length supported by the model
    MODEL_CONTEXT_LENGTH=$(echo "$MODEL_JSON" | jq -r '.model_info["llama.context_length"] // .model_info["qwen2.context_length"] // .model_info["general.context_length"] // empty')

fi

# ==================================================
# Select context size
# ==================================================

echo
echo "Context sizes:"
echo "--------------------------------------------------"

# Aktualisierte Liste inklusive der exakten Google-Grenzwerte
DEFAULT_CONTEXTS=(2048 4096 8192 16384 32768 65536 98304 131072 1048576 2097152)

# Funktion zur lesbaren Formatierung (~2k, ~1M etc.)
format_label() {
    local tokens=$1
    if [ "$tokens" -ge 1048576 ]; then
        echo "~$((tokens / 1048576))M"
    elif [ "$tokens" -ge 1024 ]; then
        echo "~$((tokens / 1024))k"
    else
        echo "$tokens"
    fi
}

if [[ "$MODEL_CONTEXT_LENGTH" =~ ^[0-9]+$ ]]; then

    # Offer only context sizes that the model actually supports.
    CONTEXTS=()

    for value in "${DEFAULT_CONTEXTS[@]}"; do
        if [ "$value" -le "$MODEL_CONTEXT_LENGTH" ]; then
            CONTEXTS+=("$value")
        fi
    done

    # If the model allows for a larger context than the
    # largest predefined level covers (e.g., 256k+ models),
    # the actual model maximum is additionally appended as a separate
    # option.
    if [ "${#CONTEXTS[@]}" -eq 0 ]; then
        CONTEXTS+=("$MODEL_CONTEXT_LENGTH")
    else
        LAST_INDEX=$(( ${#CONTEXTS[@]} - 1 ))
        if [ "$MODEL_CONTEXT_LENGTH" -gt "${CONTEXTS[$LAST_INDEX]}" ]; then
            CONTEXTS+=("$MODEL_CONTEXT_LENGTH")
        fi
    fi

    echo "(Max. Model Context: $MODEL_CONTEXT_LENGTH Tokens)"
    echo "--------------------------------------------------"

else
     # Model maximum unknown -> offer all default values
    CONTEXTS=("${DEFAULT_CONTEXTS[@]}")
fi

# Display available context sizes (mit formatiertem Label)
for i in "${!CONTEXTS[@]}"; do
    LABEL=$(format_label "${CONTEXTS[$i]}")
    printf "%2d) %8d Tokens (%s)\n" \
        "$((i+1))" "${CONTEXTS[$i]}" "$LABEL"
done

# Eigene Option für die manuelle Eingabe hinzufügen
MANUAL_OPTION_NUM=$(( ${#CONTEXTS[@]} + 1 ))
printf "%2d) Custom value (Enter manually)\n" "$MANUAL_OPTION_NUM"

echo "--------------------------------------------------"

read -p "Please enter the number corresponding to the desired context size: " CONTEXT_CHOICE

# Validate context selection (erlaubt nun auch die Manual-Option-Nummer)
if ! [[ "$CONTEXT_CHOICE" =~ ^[0-9]+$ ]] || \
   [ "$CONTEXT_CHOICE" -lt 1 ] || \
   [ "$CONTEXT_CHOICE" -gt "$MANUAL_OPTION_NUM" ]; then

    echo "Invalid selection."
    exit 1
fi

# Logik für die manuelle Eingabe
if [ "$CONTEXT_CHOICE" -eq "$MANUAL_OPTION_NUM" ]; then
    echo
    read -p "Enter custom context size (Tokens): " SELECTED_CONTEXT
    
    # Validierung: Muss eine Zahl sein und größer als 0
    if ! [[ "$SELECTED_CONTEXT" =~ ^[0-9]+$ ]] || [ "$SELECTED_CONTEXT" -le 0 ]; then
        echo "Invalid token amount."
        exit 1
    fi
else
    # Reguläre Auswahl aus dem Array
    SELECTED_CONTEXT="${CONTEXTS[$((CONTEXT_CHOICE-1))]}"
fi

# Safety check: Schützt auch die manuelle Eingabe vor einer Überschreitung des Max-Werts
if [[ "$MODEL_CONTEXT_LENGTH" =~ ^[0-9]+$ ]] &&
   [ "$SELECTED_CONTEXT" -gt "$MODEL_CONTEXT_LENGTH" ]; then

    echo
    echo "Failure: The selected context size of $SELECTED_CONTEXT Tokens"
    echo "exceeds the maximum model context of $MODEL_CONTEXT_LENGTH Tokens."
    exit 1
fi

echo
echo "Selected context size: $SELECTED_CONTEXT Tokens"

echo
echo "Selected model: $SELECTED_MODEL"
echo "Model Size:          $MODEL_SIZE"
echo "Context size:        $SELECTED_CONTEXT Tokens"
echo "--------------------------------------------------"

# ==================================================
# Restart Ollama
# ==================================================

echo
echo "Restart Ollama..."

docker compose stop ollama >/dev/null 2>&1
docker compose up -d ollama >/dev/null 2>&1

echo "Wait for Ollama..."

# Wait until the Ollama API becomes available
OLLAMA_READY=false

for i in {1..30}; do

    if curl -s "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
        OLLAMA_READY=true
        break
    fi

    sleep 1
done

if [ "$OLLAMA_READY" != true ]; then
    echo "Error: The Ollama API is unavailable."
    exit 1
fi

# ==================================================
# Read Ollama Docker configuration
# ==================================================

CONTAINER_ENV=$(docker inspect -f \
    '{{range .Config.Env}}{{println .}}{{end}}' \
    "$CONTAINER")

OLLAMA_NUM_PARALLEL=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_NUM_PARALLEL=//p')

OLLAMA_MAX_LOADED_MODELS=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_MAX_LOADED_MODELS=//p')

OLLAMA_FLASH_ATTENTION=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_FLASH_ATTENTION=//p')

OLLAMA_KV_CACHE_TYPE=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_KV_CACHE_TYPE=//p')

OLLAMA_KEEP_ALIVE=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_KEEP_ALIVE=//p')

OLLAMA_VULKAN=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_VULKAN=//p')

OLLAMA_IGPU_ENABLE=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_IGPU_ENABLE=//p')

OLLAMA_NUMA=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_NUMA=//p')

OLLAMA_CONTEXT_LENGTH=$(echo "$CONTAINER_ENV" |
    sed -n 's/^OLLAMA_CONTEXT_LENGTH=//p')

# ==================================================
# Get Ollama detected memory
# ==================================================

STARTUP_LOGS=$(docker logs "$CONTAINER" 2>&1)

OLLAMA_MEMORY_LINE=$(echo "$STARTUP_LOGS" |
    grep "inference compute" |
    tail -1)

OLLAMA_MEMORY_TOTAL_GIB=$(echo "$OLLAMA_MEMORY_LINE" |
    sed -n 's/.*total="\([0-9.]*\) GiB".*/\1/p')

OLLAMA_MEMORY_AVAILABLE_GIB=$(echo "$OLLAMA_MEMORY_LINE" |
    sed -n 's/.*available="\([0-9.]*\) GiB".*/\1/p')

OLLAMA_MEMORY_TOTAL_GB=$(awk -v gib="$OLLAMA_MEMORY_TOTAL_GIB" \
    'BEGIN {printf "%.2f", gib * 1.073741824}')

OLLAMA_MEMORY_AVAILABLE_GB=$(awk -v gib="$OLLAMA_MEMORY_AVAILABLE_GIB" \
    'BEGIN {printf "%.2f", gib * 1.073741824}')

# ==================================================
# Clear Docker log
# ==================================================

# Clear the container log so that only the current
# model loading information is analyzed
LOG_PATH=$(docker inspect --format='{{.LogPath}}' "$CONTAINER")

if [ -n "$LOG_PATH" ] && [ -f "$LOG_PATH" ]; then
    sudo truncate -s 0 "$LOG_PATH"
fi

# ==================================================
# Start model with selected context size
# ==================================================
#
# Model architecture and maximum context length were
# already read from the Ollama API before context
# selection (see above), so this section only starts
# the model with the chosen context size.
# ==================================================

echo "Start model query..."
echo "Depending on the model and context size, this may take a while."
echo

# Use the Ollama API to explicitly set the context size.
# num_ctx is applied to the model request and therefore
# determines the actual context size used by the runner.

curl -s "$OLLAMA_URL/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{
        \"model\": \"$SELECTED_MODEL\",
        \"prompt\": \"Beschreibe in einem Wort, wer bist du.\",
        \"stream\": false,
        \"options\": {
            \"num_ctx\": $SELECTED_CONTEXT
        }
    }" >/dev/null

# Give Ollama some time to finish writing the logs
sleep 2

# ==================================================
# Read runtime KV-cache information
# ==================================================

LOGS=$(docker logs "$CONTAINER" 2>&1)

# Find the KV-cache information line
KV_LINE=$(echo "$LOGS" |
    grep "llama_kv_cache: size =" |
    tail -1)

# Extract KV-cache data type
KV_TYPE=$(echo "$KV_LINE" |
    sed -n 's/.*K (\([^)]*\)).*/\1/p')

# Extract actual K-cache size
K_MIB=$(echo "$KV_LINE" |
    sed -n 's/.*K ([^)]*): *\([0-9.]*\) MiB.*/\1/p')

# Extract actual V-cache size
V_MIB=$(echo "$KV_LINE" |
    sed -n 's/.*V ([^)]*): *\([0-9.]*\) MiB.*/\1/p')

# Extract total actual KV-cache size
TOTAL_MIB=$(echo "$KV_LINE" |
    sed -n 's/.*size = *\([0-9.]*\) MiB.*/\1/p')

# ==================================================
# Extract Ollama slot and sequence information
# ==================================================

# Extract number of slots
N_SLOTS=$(echo "$LOGS" |
    grep -E "n_slots[[:space:]]*=" |
    tail -1 |
    sed -n 's/.*n_slots[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p')

# Extract context size per slot
N_CTX_SLOT=$(echo "$LOGS" |
    grep -E "n_ctx_slot[[:space:]]*=" |
    tail -1 |
    sed -n 's/.*n_ctx_slot[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p')

# ==================================================
# Determine bytes per KV-cache value
# ==================================================

case "$KV_TYPE" in
    f16|bf16)
        BYTES=2
        ;;
    f32)
        BYTES=4
        ;;
    q8_0)
        BYTES="1.0625"
        ;;
    q4_0|q4_1)
        BYTES="0.5625"
        ;;
    *)
        BYTES=0
        ;;
esac

# ==================================================
# ==================================================
# Calculate theoretical KV-cache size
#
# KV-Cache PER SLOT =
# 2 ?~ Layers ?~ KV-Heads ?~ Head-Dimension
# ?~ Bytes per Value ?~ Context Size
#
# The factor 2 represents K + V.
# ==================================================

# BYTES can be a floating-point number (e.g., 1.0625 for q8_0),
# so don't use “-gt 0” here (which only works for integers), but rather an awk comparison
BYTES_VALID=$(awk -v b="$BYTES" 'BEGIN { print (b > 0) ? 1 : 0 }')

if [[ -n "$LAYER" &&
      -n "$KV_HEADS" &&
      -n "$HEAD_DIM" &&
      "$BYTES_VALID" -eq 1 &&
      -n "$N_CTX_SLOT" &&
      -n "$N_SLOTS" ]]; then

    # Calculate theoretical KV-cache size for ONE slot
    KV_BYTES=$(
        awk -v layer="$LAYER" \
            -v kvheads="$KV_HEADS" \
            -v headdim="$HEAD_DIM" \
            -v context="$N_CTX_SLOT" \
            -v bytes="$BYTES" \
            'BEGIN {
                print 2 * layer * kvheads * headdim * bytes * context
            }'
    )

    # Convert one-slot KV-cache size to GiB
    KV_GIB=$(
        awk -v bytes="$KV_BYTES" \
            'BEGIN {
                printf "%.2f", bytes / 1073741824
            }'
    )

    # Calculate KV-cache for ALL slots
    KV_GIB_TOTAL=$(
        awk -v kv="$KV_GIB" \
            -v slots="$N_SLOTS" \
            'BEGIN {
                printf "%.2f", kv * slots
            }'
    )

else

    KV_GIB="Cannot be calculated."
    KV_GIB_TOTAL="Cannot be calculated."

fi

# ==================================================
# Calculate theoretical total memory
# ==================================================

if [[ "$MODEL_GIB" != "Cannot be calculated." &&
      "$KV_GIB_TOTAL" != "Cannot be calculated." ]]; then

    TOTAL_THEORETICAL_GIB=$(
        awk -v model="$MODEL_GIB" \
            -v kv="$KV_GIB_TOTAL" \
            'BEGIN {
                printf "%.2f", model + kv
            }'
    )

else

    TOTAL_THEORETICAL_GIB="Cannot be calculated."

fi

# ==================================================
# Calculate actual total memory reserved by Ollama
# ==================================================

if [ -n "$TOTAL_MIB" ]; then

    OLLAMA_KV_GIB=$(
        awk -v mib="$TOTAL_MIB" \
            'BEGIN {
                printf "%.2f", mib / 1024
            }'
    )

    if [[ "$MODEL_GIB" != "Cannot be calculated." ]]; then

        OLLAMA_TOTAL_GIB=$(
            awk -v model="$MODEL_GIB" \
                -v kv="$OLLAMA_KV_GIB" \
                'BEGIN {
                    printf "%.2f", model + kv
                }'
        )

    else
        OLLAMA_TOTAL_GIB="Cannot be calculated."
    fi

else
    OLLAMA_KV_GIB="nicht gefunden"
    OLLAMA_TOTAL_GIB="Cannot be calculated."
fi

# ==================================================
# Calculate reservation factor
# ==================================================

if [[ "$KV_GIB" != "Cannot be calculated." &&
      "$OLLAMA_KV_GIB" != "Not found" ]]; then

    RESERVATION_FACTOR=$(
        awk -v actual="$OLLAMA_KV_GIB" \
            -v theoretical="$KV_GIB" \
            'BEGIN {
                if (theoretical > 0)
                    printf "%.2f", actual / theoretical
                else
                    print "Cannot be calculated."
            }'
    )

else
    RESERVATION_FACTOR="Cannot be calculated."
fi

# ==================================================
# Calculate system memory information
# ==================================================

RAM_BYTES=$(free -b | awk '/^Mem:/ {print $2}')

RAM_GIB=$(awk -v bytes="$RAM_BYTES" \
    'BEGIN {
        printf "%.2f", bytes / 1073741824
    }')

RAM_GB=$(awk -v bytes="$RAM_BYTES" \
    'BEGIN {
        printf "%.2f", bytes / 1000000000
    }')

RAM_FREE_BYTES=$(free -b | awk '/^Mem:/ {print $7}')

RAM_FREE_GIB=$(awk -v bytes="$RAM_FREE_BYTES" \
    'BEGIN {
        printf "%.2f", bytes / 1073741824
    }')

RAM_FREE_GB=$(awk -v bytes="$RAM_FREE_BYTES" \
    'BEGIN {
        printf "%.2f", bytes / 1000000000
    }')

# ==================================================
# Read BIOS/Kernel VRAM and GTT configuration (amdgpu)
# ==================================================
#
# VRAM and GTT sizes on iGPU systems are determined by
# the BIOS UMA buffer setting and the amdgpu kernel driver
# (e.g. amdgpu.gttsize). These values indicate the actual
# hard ceiling for GPU-accessible memory, independent of
# how much memory Ollama itself currently reports as
# available. Read from sysfs so no root/sudo is required.
# ==================================================

AMDGPU_DEVICE=""

for dev in /sys/class/drm/card*/device; do
    if [ -f "$dev/uevent" ] && grep -q "^DRIVER=amdgpu$" "$dev/uevent" 2>/dev/null; then
        AMDGPU_DEVICE="$dev"
        break
    fi
done

if [ -n "$AMDGPU_DEVICE" ] && [ -f "$AMDGPU_DEVICE/mem_info_gtt_total" ]; then

    VRAM_TOTAL_BYTES=$(cat "$AMDGPU_DEVICE/mem_info_vram_total" 2>/dev/null)
    VRAM_USED_BYTES=$(cat "$AMDGPU_DEVICE/mem_info_vram_used" 2>/dev/null)
    GTT_TOTAL_BYTES=$(cat "$AMDGPU_DEVICE/mem_info_gtt_total" 2>/dev/null)
    GTT_USED_BYTES=$(cat "$AMDGPU_DEVICE/mem_info_gtt_used" 2>/dev/null)

    VRAM_TOTAL_GIB=$(awk -v b="$VRAM_TOTAL_BYTES" 'BEGIN { if (b>0) printf "%.2f", b/1073741824; else print "nicht gefunden" }')
    VRAM_USED_GIB=$(awk -v b="$VRAM_USED_BYTES" 'BEGIN { if (b>0) printf "%.2f", b/1073741824; else print "nicht gefunden" }')
    GTT_TOTAL_GIB=$(awk -v b="$GTT_TOTAL_BYTES" 'BEGIN { if (b>0) printf "%.2f", b/1073741824; else print "nicht gefunden" }')
    GTT_USED_GIB=$(awk -v b="$GTT_USED_BYTES" 'BEGIN { if (b>0) printf "%.2f", b/1073741824; else print "nicht gefunden" }')

    if [[ "$GTT_TOTAL_GIB" =~ ^[0-9]+([.][0-9]+)?$ && "$GTT_USED_GIB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        GTT_FREE_GIB=$(awk -v t="$GTT_TOTAL_GIB" -v u="$GTT_USED_GIB" 'BEGIN { printf "%.2f", t - u }')
    else
        GTT_FREE_GIB="Cannot be calculated."
    fi

    # Anteil des GTT-Pools am gesamten System-RAM.
    # Zeigt, wie großzügig BIOS/Kernel den GPU-Speicher
    # aus dem System-RAM zugeteilt haben.
    if [[ "$GTT_TOTAL_GIB" =~ ^[0-9]+([.][0-9]+)?$ && -n "$RAM_GIB" ]]; then
        GTT_RAM_RATIO=$(awk -v gtt="$GTT_TOTAL_GIB" -v ram="$RAM_GIB" \
            'BEGIN {
                if (ram > 0)
                    printf "%.1f", (gtt / ram) * 100
                else
                    print "Cannot be calculated."
            }')
    else
        GTT_RAM_RATIO="Cannot be calculated."
    fi

else
    VRAM_TOTAL_GIB="Not found"
    VRAM_USED_GIB="Not found"
    GTT_TOTAL_GIB="Not found"
    GTT_USED_GIB="Not found"
    GTT_FREE_GIB="Cannot be calculated."
    GTT_RAM_RATIO="Cannot be calculated."
fi

# ==================================================
# Consistency check: Kernel GTT vs. memory detected by Ollama
# ==================================================
#
# If the memory detected by Ollama at runtime
# differs significantly from the GTT pool reported by the kernel, this
# indicates additional reservations (e.g., by the
# desktop environment, compositor, or other GPU processes).
# ==================================================

if [[ "$GTT_TOTAL_GIB" =~ ^[0-9]+([.][0-9]+)?$ &&
      "$OLLAMA_MEMORY_AVAILABLE_GIB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

    GTT_OLLAMA_DIFF_GIB=$(awk -v gtt="$GTT_TOTAL_GIB" \
        -v ollama="$OLLAMA_MEMORY_AVAILABLE_GIB" \
        'BEGIN { printf "%.2f", gtt - ollama }')

    GTT_OLLAMA_DIFF_ABS=$(awk -v d="$GTT_OLLAMA_DIFF_GIB" \
        'BEGIN { printf "%.2f", (d < 0) ? -d : d }')

    if awk "BEGIN {exit !($GTT_OLLAMA_DIFF_ABS > 1)}"; then
        GTT_CONSISTENCY_NOTE="Note: A discrepancy of ${GTT_OLLAMA_DIFF_GIB} GiB between kernel GTT and memory detected by Ollama (e.g., occupied by the desktop or compositor)."
    else
        GTT_CONSISTENCY_NOTE=""
    fi
else
    GTT_CONSISTENCY_NOTE=""
fi

# ==================================================
# Convert memory values from GiB to GB
# ==================================================

if [[ "$MODEL_GIB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

    MODEL_GB=$(awk -v gib="$MODEL_GIB" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

else
    MODEL_GB="Cannot be calculated."
fi


# Convert total theoretical KV-cache to GB
if [[ "$KV_GIB_TOTAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

    KV_GB=$(awk -v gib="$KV_GIB_TOTAL" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

else
    KV_GB="Cannot be calculated."
fi


# Convert theoretical total memory to GB
if [[ "$TOTAL_THEORETICAL_GIB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

    TOTAL_THEORETICAL_GB=$(awk -v gib="$TOTAL_THEORETICAL_GIB" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

    RAM_USAGE_THEORETICAL=$(awk \
        -v total="$TOTAL_THEORETICAL_GIB" \
        -v ram="$RAM_GIB" \
        'BEGIN {
            if (ram > 0)
                printf "%.1f", (total / ram) * 100
            else
                print "Cannot be calculated."
        }')

    RAM_REMAINING_THEORETICAL=$(awk \
        -v ram="$RAM_GIB" \
        -v total="$TOTAL_THEORETICAL_GIB" \
        'BEGIN {
            printf "%.2f", ram - total
        }')

    RAM_REMAINING_THEORETICAL_GB=$(awk \
        -v gib="$RAM_REMAINING_THEORETICAL" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

else

    TOTAL_THEORETICAL_GB="Cannot be calculated."
    RAM_USAGE_THEORETICAL="Cannot be calculated."
    RAM_REMAINING_THEORETICAL="Cannot be calculated."
    RAM_REMAINING_THEORETICAL_GB="Cannot be calculated."

fi
# ==================================================
# Calculate actual Ollama memory usage
# ==================================================

if [[ "$OLLAMA_TOTAL_GIB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

    OLLAMA_KV_GB=$(awk -v gib="$OLLAMA_KV_GIB" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

    OLLAMA_TOTAL_GB=$(awk -v gib="$OLLAMA_TOTAL_GIB" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

    RAM_USAGE_OLLAMA=$(awk \
        -v total="$OLLAMA_TOTAL_GIB" \
        -v ram="$RAM_GIB" \
        'BEGIN {
            if (ram > 0)
                printf "%.1f", (total / ram) * 100
            else
                print "Cannot be calculated."
        }')

    RAM_REMAINING_OLLAMA=$(awk \
        -v ram="$RAM_GIB" \
        -v total="$OLLAMA_TOTAL_GIB" \
        'BEGIN {
            printf "%.2f", ram - total
        }')

    RAM_REMAINING_OLLAMA_GB=$(awk \
        -v gib="$RAM_REMAINING_OLLAMA" \
        'BEGIN {
            printf "%.2f", gib * 1.073741824
        }')

else

    OLLAMA_KV_GB="Cannot be calculated."
    OLLAMA_TOTAL_GB="Cannot be calculated."
    RAM_USAGE_OLLAMA="Cannot be calculated."
    RAM_REMAINING_OLLAMA="Cannot be calculated."
    RAM_REMAINING_OLLAMA_GB="Cannot be calculated."

fi

# ==================================================
# Determine memory status
# ==================================================
#
# Two separate assessments are made:
#
# 1. THEORETICAL:
#    Model + theoretical KV-cache compared with the
#    memory reported as available to Ollama.
#
# 2. ACTUAL:
#    Model + KV-cache reported by the running Ollama
#    instance compared with total system RAM.
#
# This is important on iGPU systems because GTT memory
# is shared system memory and the theoretical model/KV
# calculation does not include all runtime buffers.
# ==================================================

if [[ -n "$OLLAMA_MEMORY_AVAILABLE_GIB" &&
      "$TOTAL_THEORETICAL_GIB" != "Cannot be calculated." ]]; then

    OLLAMA_USAGE_THEORETICAL=$(awk \
        -v used="$TOTAL_THEORETICAL_GIB" \
        -v available="$OLLAMA_MEMORY_AVAILABLE_GIB" \
        'BEGIN {
            if (available > 0)
                printf "%.1f", (used / available) * 100
            else
                print "Cannot be calculated."
        }')

    OLLAMA_REMAINING_THEORETICAL=$(awk \
        -v available="$OLLAMA_MEMORY_AVAILABLE_GIB" \
        -v used="$TOTAL_THEORETICAL_GIB" \
        'BEGIN {
            printf "%.2f", available - used
        }')

else
    OLLAMA_USAGE_THEORETICAL="Cannot be calculated."
    OLLAMA_REMAINING_THEORETICAL="Cannot be calculated."
fi

# ANSI Farbcodes für fette Textfarbe (Hintergrund bleibt normal)
TXT_GREEN='\e[1;32m'
TXT_YELLOW='\e[1;33m'
TXT_RED='\e[1;31m'
TXT_MAGENTA='\e[1;35m'
NC='\e[0m' # No Color (Zurücksetzen)

# Theoretical status against memory available to Ollama.
if [[ "$OLLAMA_USAGE_THEORETICAL" != "Cannot be calculated." ]]; then
    if awk "BEGIN {exit !($OLLAMA_USAGE_THEORETICAL >= 100)}"; then
        MEMORY_STATUS_THEORETICAL="${TXT_RED}CRITICAL${NC}"
    elif awk "BEGIN {exit !($OLLAMA_USAGE_THEORETICAL >= 80)}"; then
        MEMORY_STATUS_THEORETICAL="${TXT_YELLOW}WARNING${NC}"
    else
        MEMORY_STATUS_THEORETICAL="${TXT_GREEN}OK${NC}"
    fi
else
    MEMORY_STATUS_THEORETICAL="Cannot be calculated."
fi

# Actual Ollama status against total system RAM.
if [[ "$RAM_USAGE_OLLAMA" != "Cannot be calculated." ]]; then
    if awk "BEGIN {exit !($RAM_USAGE_OLLAMA >= 90)}"; then
        MEMORY_STATUS_ACTUAL="${TXT_RED}CRITICAL${NC}"
    elif awk "BEGIN {exit !($RAM_USAGE_OLLAMA >= 70)}"; then
        MEMORY_STATUS_ACTUAL="${TXT_YELLOW}WARNING${NC}"
    else
        MEMORY_STATUS_ACTUAL="${TXT_GREEN}OK${NC}"
    fi
else
    MEMORY_STATUS_ACTUAL="Cannot be calculated."
fi

# Overall status: use the more critical of theoretical and actual status.
if [[ "$MEMORY_STATUS_THEORETICAL" == *"CRITICAL"* || "$MEMORY_STATUS_ACTUAL" == *"CRITICAL"* ]]; then
    MEMORY_STATUS="${TXT_RED}CRITICAL${NC}"
elif [[ "$MEMORY_STATUS_THEORETICAL" == *"WARNING"* || "$MEMORY_STATUS_ACTUAL" == *"WARNING"* ]]; then
    MEMORY_STATUS="${TXT_YELLOW}WARNING${NC}"
elif [[ "$MEMORY_STATUS_THEORETICAL" == *"OK"* || "$MEMORY_STATUS_ACTUAL" == *"OK"* ]]; then
    MEMORY_STATUS="${TXT_GREEN}OK${NC}"
else
    MEMORY_STATUS="${TXT_MAGENTA}CALCULATION FAILURE${NC}"
fi

# ==================================================
# Override: missing values used for the calculation
# ==================================================
#
# If any of the values required for the theoretical
# KV-cache / memory calculation could not be determined
# (i.e. would be displayed as "not found" below), the
# result of the calculation is not trustworthy, even if
# one of the two partial assessments above happened to
# succeed. In that case MEMORY_STATUS is forced to
# CALCULATION FAILURE.
# ==================================================

CALCULATION_INPUTS_MISSING=false

for VALUE in "$LAYER" "$KV_HEADS" "$HEAD_DIM" "$KV_TYPE" "$N_SLOTS" "$OLLAMA_MEMORY_AVAILABLE_GIB"; do
    if [ -z "$VALUE" ]; then
        CALCULATION_INPUTS_MISSING=true
        break
    fi
done

if [ "$CALCULATION_INPUTS_MISSING" = true ]; then
    MEMORY_STATUS="${TXT_MAGENTA}CALCULATION FAILURE${NC}"
fi

# ==================================================
# Calculate total context capacity
# ==================================================

if [[ "$N_SLOTS" =~ ^[0-9]+$ &&
      "$N_CTX_SLOT" =~ ^[0-9]+$ ]]; then

    TOTAL_CONTEXT_TOKENS=$((N_SLOTS * N_CTX_SLOT))

else
    TOTAL_CONTEXT_TOKENS="Cannot be calculated."
fi

# ==================================================
# Display results
# ==================================================

echo
echo "=============================================="
echo "          Ollama storage information"
echo "=============================================="
echo "----------------------------------------------"
echo "OLLAMA CONFIGURATION:"
echo "----------------------------------------------"
echo "OLLAMA_NUM_PARALLEL:                        ${OLLAMA_NUM_PARALLEL:-not set}"
echo "OLLAMA_MAX_LOADED_MODELS:                   ${OLLAMA_MAX_LOADED_MODELS:-not set}"
echo "OLLAMA_FLASH_ATTENTION:                     ${OLLAMA_FLASH_ATTENTION:-not set}"
echo "OLLAMA_KV_CACHE_TYPE:                       ${OLLAMA_KV_CACHE_TYPE:-not set}"
echo "OLLAMA_KEEP_ALIVE:                          ${OLLAMA_KEEP_ALIVE:-not set}"
echo "OLLAMA_VULKAN:                              ${OLLAMA_VULKAN:-not set}"
echo "OLLAMA_IGPU_ENABLE:                         ${OLLAMA_IGPU_ENABLE:-not set}"
echo "OLLAMA_NUMA:                                ${OLLAMA_NUMA:-not set}"
echo "OLLAMA_CONTEXT_LENGTH:                      ${OLLAMA_CONTEXT_LENGTH:-not set}"
echo "Slots:                                      ${N_SLOTS:-not found}"
#echo "Context per Slot:                        ${N_CTX_SLOT:-not found}"
#echo "Total context capacity:                  ${TOTAL_CONTEXT_TOKENS} Tokens"
echo
echo "----------------------------------------------"
echo "ARCHITECTURE / KV-CACHE:"
echo "----------------------------------------------"
echo "Context size:                               ${SELECTED_CONTEXT} Tokens"
echo "Max. model context:                         ${MODEL_CONTEXT_LENGTH:-not found} Tokens"
echo "Layer:                                      ${LAYER:-not found}"
echo "KV Heads:                                   ${KV_HEADS:-not found}"
echo "Head Dimension:                             ${HEAD_DIM:-not found}"
echo "KV Cache Data Type:                         ${KV_TYPE:-not found}"

if [ "$BYTES" != "0" ]; then
echo "Bytes pro Wert:                             $BYTES"
else
echo "Bytes pro Wert:                             unknown"
fi
echo
echo "KV-Cache per Slot = 2 x $LAYER x $KV_HEADS x $HEAD_DIM x $BYTES x ${N_CTX_SLOT}"
echo "Total KV-Cache   = ${KV_GIB} GiB x ${N_SLOTS} Slots"
echo
echo "----------------------------------------------"
echo "THEORETICAL STORAGE REQUIREMENTS:"
echo "----------------------------------------------"
echo "Model:                                      $SELECTED_MODEL"
echo "Model size:                                 ${MODEL_GIB} GiB / ${MODEL_GB} GB"
echo "Total KV-Cache:                             ${KV_GIB_TOTAL} GiB / ${KV_GB} GB"
# echo "KV-Cache per Slot:                       ${KV_GIB} GiB"
echo "Reservation factor:                         ${RESERVATION_FACTOR} x"
echo "Model + KV-Cache:                           ${TOTAL_THEORETICAL_GIB} GiB / ${TOTAL_THEORETICAL_GB} GB"
echo

echo "----------------------------------------------"
echo "BIOS/KERNEL MEMORY CONFIGURATION (iGPU):"
echo "----------------------------------------------"
echo "Computer memory (-BIOS-VRAMs):              ${RAM_GIB} GiB / ${RAM_GB} GB"
echo "Current available RAM:                      ${RAM_FREE_GIB} GiB / ${RAM_FREE_GB} GB"
echo
echo "Total VRAM (BIOS):                          ${VRAM_TOTAL_GIB} GiB"
echo "VRAM used:                                  ${VRAM_USED_GIB} GiB"
echo
echo "Total GTT (kernel):                         ${GTT_TOTAL_GIB} GiB"
echo "Total GTT's share of system RAM:            ${GTT_RAM_RATIO} %"
echo "GTT used + Prompt-Evaluierungs-Cache:       ${GTT_USED_GIB} GiB"
echo "GTT free:                                   ${GTT_FREE_GIB} GiB"
echo
echo "Ollama recognized storage (Graphic Driver): ${OLLAMA_MEMORY_AVAILABLE_GIB:-not found} GiB / ${OLLAMA_MEMORY_AVAILABLE_GB:-nicht gefunden} GB"

echo "GTT used / Ollama recognized storage * 100: ${OLLAMA_USAGE_THEORETICAL} %"
echo
if [[ "$MEMORY_STATUS_THEORETICAL" == *"OK"* ]]; then
    LINE_COLOR_THEORETICAL="$NC"
else
    LINE_COLOR_THEORETICAL="$TXT_YELLOW"
fi
echo -e "${LINE_COLOR_THEORETICAL}Model + KV-Cache / Ollama recognized storage * 100 < 80%${NC}"

if [[ "$MEMORY_STATUS_ACTUAL" == *"OK"* ]]; then
    LINE_COLOR_ACTUAL="$NC"
else
    LINE_COLOR_ACTUAL="$TXT_YELLOW"
fi
echo -e "${LINE_COLOR_ACTUAL}Model + KV-Cache / Computer memory * 100 < 70%${NC}"
echo -e "(Worst-of Budget/RAM):                      ${MEMORY_STATUS}"

if [ -n "$GTT_CONSISTENCY_NOTE" ]; then
    echo
    echo "$GTT_CONSISTENCY_NOTE"
fi







