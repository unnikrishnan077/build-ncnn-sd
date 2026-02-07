#!/usr/bin/env bash
###############################################################################
# NCNN Android Build Script for Stable Diffusion (Kernel/sd-nsfw NSFW Realism)
# Single-file automation for Ubuntu/Debian host → S25 Ultra APK
# Run: chmod +x build-ncnn-sd.sh && ./build-ncnn-sd.sh
###############################################################################

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Config (edit these paths)
NCNN_DIR="$HOME/ncnn-sd-build"
SD_REPO="$NCNN_DIR/sd_nsfw_hf"
NCNN_INSTALL="$NCNN_DIR/ncnn-android-install"
# Use a Linux NDK for WSL compatibility if the Windows one fails
LINUX_NDK="$HOME/android-ndk-r27b"
if [ ! -d "$LINUX_NDK" ]; then
  echo "Downloading Linux NDK r27b..."
  wget -q https://dl.google.com/android/repository/android-ndk-r27b-linux.zip -O "$HOME/ndk.zip"
  unzip -q "$HOME/ndk.zip" -d "$HOME"
  rm "$HOME/ndk.zip"
fi
ANDROID_NDK_ROOT="$LINUX_NDK"

echo "[2/8] Installing Android SDK tools (if missing)..."
if [ ! -d "$ANDROID_NDK_ROOT" ]; then
  echo "ERROR: ANDROID_NDK_ROOT not found."
  exit 1
fi

# Skip logic for NCNN
if [ ! -f "$NCNN_INSTALL/lib/libncnn.a" ]; then
    echo "[3/8] Cloning NCNN + building Android tools..."
    rm -rf "$NCNN_DIR"
    mkdir -p "$NCNN_DIR"
    cd "$NCNN_DIR"

    git clone https://github.com/Tencent/ncnn.git ncnn
    cd ncnn
    git submodule update --init --recursive

    # Link linux-x86_64 to windows-x86_64 to satisfy hardcoded toolchain paths
    mkdir -p "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt"
    if [ ! -d "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64" ]; then
        ln -s "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/windows-x86_64" "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
    fi

    mkdir build-android && cd build-android
    cmake -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI=arm64-v8a \
      -DANDROID_PLATFORM=android-28 \
      -DANDROID_STL=c++_shared \
      -DNCNN_VULKAN=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$NCNN_INSTALL" \
      ..
    make -j$(nproc)
    make install
else
    echo "[3/8] NCNN already built, skipping..."
fi

export NCNN_ROOT="$NCNN_INSTALL"
export PATH="$NCNN_ROOT/bin:$PATH"
echo "NCNN tools ready: $NCNN_ROOT/bin/onnx2ncnn"

echo "[4/8] Cloning Kernel/sd-nsfw + exporting ONNX..."
cd "$NCNN_DIR"

# Ensure git-lfs is available
if ! command -v git-lfs &> /dev/null; then
    echo "git-lfs remains missing, attempting direct installation..."
    wget -q https://github.com/git-lfs/git-lfs/releases/download/v3.5.1/git-lfs-linux-amd64-v3.5.1.tar.gz -O git-lfs.tar.gz
    tar -xzf git-lfs.tar.gz
    sudo ./git-lfs-3.5.1/install.sh
    git lfs install
fi

if [ ! -d "sd_nsfw_hf" ]; then
    git lfs install
    git clone https://huggingface.co/Kernel/sd-nsfw sd_nsfw_hf
fi

# ... Rest of the script remains ...
pip3 install --quiet diffusers[torch] onnx optimum[exporters] safetensors torch torchvision

if [ ! -d "sd_nsfw_onnx" ]; then
    python3 -c "
import torch
from diffusers import StableDiffusionPipeline
print('Loading Kernel/sd-nsfw...')
pipe = StableDiffusionPipeline.from_pretrained('sd_nsfw_hf', torch_dtype=torch.float16, safety_checker=None)
print('Exporting ONNX components...')
pipe.unet.save_pretrained('sd_nsfw_onnx/unet')
pipe.vae.save_pretrained('sd_nsfw_onnx/vae')
pipe.text_encoder.save_pretrained('sd_nsfw_onnx/text_encoder')
print('ONNX export complete')
"
fi

echo "[5/8] Converting ONNX → NCNN (UNet, VAE, CLIP)..."
if [ ! -d "sd_nsfw_ncnn" ]; then
    mkdir -p sd_nsfw_ncnn
    # UNet
    $NCNN_ROOT/bin/onnx2ncnn sd_nsfw_onnx/unet/model.onnx sd_nsfw_ncnn/unet.param sd_nsfw_ncnn/unet.bin
    $NCNN_ROOT/bin/ncnnoptimize sd_nsfw_ncnn/unet.param sd_nsfw_ncnn/unet.bin sd_nsfw_ncnn/unet_opt.param sd_nsfw_ncnn/unet_opt.bin fp16 arm64-v8a vulkan+fp16
    # VAE
    $NCNN_ROOT/bin/onnx2ncnn sd_nsfw_onnx/vae/diffusion_pytorch_model.onnx sd_nsfw_ncnn/vae.param sd_nsfw_ncnn/vae.bin
    $NCNN_ROOT/bin/ncnnoptimize sd_nsfw_ncnn/vae.param sd_nsfw_ncnn/vae.bin sd_nsfw_ncnn/vae_opt.param sd_nsfw_ncnn/vae_opt.bin fp16 arm64-v8a vulkan+fp16
    # CLIP
    $NCNN_ROOT/bin/onnx2ncnn sd_nsfw_onnx/text_encoder/model.onnx sd_nsfw_ncnn/clip.param sd_nsfw_ncnn/clip.bin
    $NCNN_ROOT/bin/ncnnoptimize sd_nsfw_ncnn/clip.param sd_nsfw_ncnn/clip.bin sd_nsfw_ncnn/clip_opt.param sd_nsfw_ncnn/clip_opt.bin fp16 arm64-v8a vulkan+fp16
fi

echo "[6/8] Cloning Stable-Diffusion-NCNN + preparing APK..."
cd "$NCNN_DIR"
if [ ! -d "Stable-Diffusion-NCNN" ]; then
    git clone https://github.com/EdVince/Stable-Diffusion-NCNN.git
fi
cd Stable-Diffusion-NCNN/android/app/src/main/assets

# Copy NSFW model files
mkdir -p models/kernel_nsfw
cp "$NCNN_DIR/sd_nsfw_ncnn/"*.param models/kernel_nsfw/
cp "$NCNN_DIR/sd_nsfw_ncnn/"*_opt.bin models/kernel_nsfw/

echo "[7/8] Building APK (arm64-v8a Vulkan)..."
cd "$NCNN_DIR/Stable-Diffusion-NCNN/android"

# Export JAVA_HOME to the path mentioned in the error
export JAVA_HOME="/mnt/c/Users/unnik/.antigravity/extensions/oracle.oracle-java-25.0.1-universal/out/webviews/jdkDownloader/jdk_downloads/jdk-25.0.2"
export PATH="$JAVA_HOME/bin:$PATH"

# Patch build.gradle for S25 Ultra (arm64 only)
sed -i 's/abiFilters .*/abiFilters "arm64-v8a"/' app/build.gradle
sed -i 's/minSdkVersion 21/minSdkVersion 28/' app/build.gradle

./gradlew clean assembleRelease

echo "[8/8] Installing to S25 Ultra..."
APK_PATH="app/build/outputs/apk/release/app-release-unsigned.apk"
adb devices  # Verify device connected
adb install -r "$APK_PATH"

echo "🎉 SUCCESS!"
echo "APK ready: $APK_PATH"
echo ""
echo "NEXT STEPS:"
echo "1. Open app → select Kernel NSFW model (if UI updated)"
echo "2. Test img2img: upload people photo → 'nude full body, realistic anatomy'"
echo "3. Strength 0.5-0.7 preserves anatomy while enabling NSFW edits"
echo "4. Edit src/main/cpp/sd_runner.cpp to add model selector if needed"
