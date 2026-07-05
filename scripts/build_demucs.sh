#!/bin/bash
# Fetches demucs.cpp (MIT) + Eigen (MPL2, header-only) so the app target can
# compile real AI stem separation. Run BEFORE `xcodegen generate`. Without this
# script the app still builds — DemucsBridge compiles as a stub and the app
# reports separation as unavailable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/ThirdParty"
DL="$TP/downloads"
mkdir -p "$DL"

# demucs.cpp sources
if [ ! -d "$DL/demucs.cpp" ]; then
  git clone --depth 1 https://github.com/sevagh/demucs.cpp "$DL/demucs.cpp"
fi
rm -rf "$TP/demucscpp"
mkdir -p "$TP/demucscpp"
cp -R "$DL/demucs.cpp/src" "$TP/demucscpp/src"

# Eigen (header-only)
if [ ! -d "$TP/eigen" ]; then
  curl -L --retry 3 --fail -o "$DL/eigen.tar.gz" \
    "https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz"
  tar xzf "$DL/eigen.tar.gz" -C "$DL"
  mv "$DL/eigen-3.4.0" "$TP/eigen"
fi

# Minimal OpenMP stub: demucs.cpp uses omp pragmas (ignored without -fopenmp)
# but may include omp.h for thread queries.
mkdir -p "$TP/omp-stub"
cat > "$TP/omp-stub/omp.h" <<'EOF'
#pragma once
static inline int omp_get_max_threads(void) { return 1; }
static inline int omp_get_num_threads(void) { return 1; }
static inline int omp_get_thread_num(void) { return 0; }
static inline void omp_set_num_threads(int n) { (void)n; }
static inline double omp_get_wtime(void) { return 0.0; }
EOF

XCCONFIG="$ROOT/Configs/ThirdParty.xcconfig"
if ! grep -q "demucscpp" "$XCCONFIG"; then
cat >> "$XCCONFIG" <<'EOF'
HEADER_SEARCH_PATHS = $(inherited) $(SRCROOT)/ThirdParty/demucscpp/src $(SRCROOT)/ThirdParty/eigen $(SRCROOT)/ThirdParty/omp-stub
GCC_PREPROCESSOR_DEFINITIONS = $(inherited) EIGEN_DONT_PARALLELIZE=1
EOF
fi

echo "demucs.cpp ready at $TP/demucscpp/src"
