#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODEL_DIR="$PROJECT_DIR/Models"
WHISPER_CPP_DIR="$PROJECT_DIR/.whisper.cpp"
WHISPER_OAI_DIR="$PROJECT_DIR/.whisper-openai"
HF_MODEL_DIR="$PROJECT_DIR/.hf-model"

# Use project venv if available (has working torch), otherwise system python3
if [ -f "$PROJECT_DIR/venv/bin/python3" ]; then
    PYTHON="$PROJECT_DIR/venv/bin/python3"
    PIP="$PROJECT_DIR/venv/bin/pip3"
    echo "Using venv Python: $PYTHON"
else
    PYTHON="python3"
    PIP="pip3"
fi

echo "=== Breeze-ASR-25 → GGML Model Conversion ==="
echo ""

# 1. Clone whisper.cpp (for conversion script)
if [ ! -d "$WHISPER_CPP_DIR" ]; then
    echo "Cloning whisper.cpp..."
    git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_CPP_DIR"
else
    echo "whisper.cpp already cloned."
fi

# 2. Clone OpenAI whisper repo (needed for tokenizer/vocab files)
if [ ! -d "$WHISPER_OAI_DIR" ]; then
    echo "Cloning OpenAI whisper repo..."
    git clone --depth 1 https://github.com/openai/whisper "$WHISPER_OAI_DIR"
else
    echo "OpenAI whisper repo already cloned."
fi

# 3. Install Python dependencies for conversion
echo ""
echo "Installing conversion dependencies..."
$PIP install --quiet transformers numpy huggingface_hub

# 4. Download the HuggingFace model
echo ""
echo "Downloading Breeze-ASR-25 from HuggingFace..."
$PYTHON -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='MediaTek-Research/Breeze-ASR-25',
    local_dir='$HF_MODEL_DIR',
    ignore_patterns=['*.md', '*.txt', '.gitattributes'],
)
print('Download complete.')
"

# 5. Convert to GGML format
#    Usage: convert-h5-to-ggml.py <hf-model-dir> <whisper-repo> <output-dir>
echo ""
echo "Converting to GGML format..."
mkdir -p "$MODEL_DIR"

$PYTHON "$WHISPER_CPP_DIR/models/convert-h5-to-ggml.py" \
    "$HF_MODEL_DIR" \
    "$WHISPER_OAI_DIR" \
    "$MODEL_DIR"

# 6. Check output
if [ -f "$MODEL_DIR/ggml-model.bin" ]; then
    SIZE=$(du -h "$MODEL_DIR/ggml-model.bin" | cut -f1)
    echo ""
    echo "=== Conversion complete ==="
    echo "Model: $MODEL_DIR/ggml-model.bin ($SIZE)"
    echo ""
    echo "The app will auto-detect this model file."
else
    echo ""
    echo "ERROR: Expected output file not found."
    echo "Check $MODEL_DIR for the converted model file."
    ls -la "$MODEL_DIR/"
fi
