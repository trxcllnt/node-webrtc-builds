# syntax=docker/dockerfile:1.3

ARG AMD64_BASE
ARG ARM64_BASE
ARG NODE_VERSION=18.2.0

FROM node:$NODE_VERSION-bullseye-slim as node

FROM ${AMD64_BASE} as base-amd64

FROM ${ARM64_BASE} as base-arm64

ONBUILD RUN \
    if [[ -d /usr/local/cuda/lib64 ] && [ ! -f /usr/local/cuda/lib64/libcudart.so ]]; then \
        minor="$(nvcc --version | head -n4 | tail -n1 | cut -d' ' -f5 | cut -d',' -f1)"; \
        major="$(nvcc --version | head -n4 | tail -n1 | cut -d' ' -f5 | cut -d',' -f1 | cut -d'.' -f1)"; \
        ln -s /usr/local/cuda/lib64/libcudart.so.$minor /usr/local/cuda/lib64/libcudart.so.$major; \
        ln -s /usr/local/cuda/lib64/libcudart.so.$major /usr/local/cuda/lib64/libcudart.so; \
        rm /etc/ld.so.cache && ldconfig; \
    fi

FROM base-${TARGETARCH} as compilers

SHELL ["/bin/bash", "-c"]

ENV CUDA_HOME="/usr/local/cuda"
ENV PATH="$PATH:\
${CUDA_HOME}/bin:\
${CUDA_HOME}/nvvm/bin"
ENV LD_LIBRARY_PATH="\
/usr/lib/aarch64-linux-gnu:\
/usr/lib/x86_64-linux-gnu:\
/usr/lib/i386-linux-gnu:\
${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}\
${CUDA_HOME}/lib64:\
${CUDA_HOME}/nvvm/lib64:\
${CUDA_HOME}/lib64/stubs"

ARG GCC_VERSION=9
ARG CMAKE_VERSION=3.23.2
ARG SCCACHE_VERSION=0.2.15

ARG NODE_VERSION=18.2.0
ENV NODE_VERSION=$NODE_VERSION

# Install node
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/include/node /usr/local/include/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# Install yarn
COPY --from=node /opt/yarn-v*/bin/* /usr/local/bin/
COPY --from=node /opt/yarn-v*/lib/* /usr/local/lib/
# Copy entrypoint
COPY --from=node /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ADD --chown=root:root https://gitlab.com/nvidia/container-images/opengl/-/raw/5191cf205d3e4bb1150091f9464499b076104354/glvnd/runtime/10_nvidia.json /usr/share/glvnd/egl_vendor.d/10_nvidia.json

# https://github.com/moby/buildkit/blob/b8462c3b7c15b14a8c30a79fad298a1de4ca9f74/frontend/dockerfile/docs/syntax.md#example-cache-apt-packages
RUN --mount=type=cache,target=/var/lib/apt \
    --mount=type=cache,target=/var/cache/apt \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache; \
 \
 # Install compilers
    export DEBIAN_FRONTEND=noninteractive \
 && apt update \
 && apt install --no-install-recommends -y \
    gpg wget software-properties-common \
 && add-apt-repository --no-update -y ppa:git-core/ppa \
 && add-apt-repository --no-update -y ppa:ubuntu-toolchain-r/test \
 \
 && apt update \
 && apt install --no-install-recommends -y \
    git ninja-build \
    gcc-${GCC_VERSION} g++-${GCC_VERSION} gdb \
    # CMake dependencies
    curl libssl-dev libcurl4-openssl-dev xz-utils zlib1g-dev liblz4-dev \
    # From opengl/glvnd:devel
    pkg-config \
    libxau6 libxdmcp6 libxcb1 libxext6 libx11-6 \
    libglvnd-dev libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
 \
 && chmod 0644 /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
 && echo "/usr/local/nvidia/lib" >> /etc/ld.so.conf.d/nvidia.conf \
 && echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf \
 # Remove any existing gcc and g++ alternatives
 && (update-alternatives --remove-all cc >/dev/null 2>&1 || true)  \
 && (update-alternatives --remove-all c++ >/dev/null 2>&1 || true)  \
 && (update-alternatives --remove-all gcc >/dev/null 2>&1 || true)  \
 && (update-alternatives --remove-all g++ >/dev/null 2>&1 || true)  \
 && (update-alternatives --remove-all gcov >/dev/null 2>&1 || true) \
 # Install our alternatives
 && update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-${GCC_VERSION} 100 \
 && update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-${GCC_VERSION} 100 \
 && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 100 \
 && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} 100 \
 && update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-${GCC_VERSION} 100 \
 # Set the default cc/c++/gcc/g++/gcov to v${GCC_VERSION}
 && update-alternatives --set cc /usr/bin/gcc-${GCC_VERSION} \
 && update-alternatives --set c++ /usr/bin/g++-${GCC_VERSION} \
 && update-alternatives --set gcc /usr/bin/gcc-${GCC_VERSION} \
 && update-alternatives --set g++ /usr/bin/g++-${GCC_VERSION} \
 && update-alternatives --set gcov /usr/bin/gcov-${GCC_VERSION} \
 \
 # Install CMake
 && curl -fsSL --compressed -o "/tmp/cmake-$CMAKE_VERSION-linux-$(uname -m).sh" \
    "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-$(uname -m).sh" \
 && sh "/tmp/cmake-$CMAKE_VERSION-linux-$(uname -m).sh" --skip-license --exclude-subdir --prefix=/usr/local \
 \
 # Install sccache
 && curl -SsL "https://github.com/mozilla/sccache/releases/download/v$SCCACHE_VERSION/sccache-v$SCCACHE_VERSION-$(uname -m)-unknown-linux-musl.tar.gz" \
    | tar -C /usr/bin -zf - --wildcards --strip-components=1 -x */sccache \
 && chmod +x /usr/bin/sccache \
 \
 # Install npm
 && bash -c 'echo -e "\
fund=false\n\
audit=false\n\
save-prefix=\n\
--omit=optional\n\
save-exact=true\n\
package-lock=false\n\
update-notifier=false\n\
scripts-prepend-node-path=true\n\
registry=https://registry.npmjs.org/\n\
" | tee /root/.npmrc >/dev/null' \
 && ln -s /usr/local/bin/node /usr/local/bin/nodejs \
 && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && /usr/local/bin/npm install --global --unsafe-perm --no-audit --no-fund npm \
 # Smoke tests
 && node --version && npm --version && yarn --version \
 \
 # Clean up
 && add-apt-repository --remove -y ppa:git-core/ppa \
 && add-apt-repository --remove -y ppa:ubuntu-toolchain-r/test \
 && apt autoremove -y && apt clean \
 && rm -rf /tmp/* /var/tmp/*

ENTRYPOINT ["docker-entrypoint.sh"]

WORKDIR /

FROM compilers as wrtc-amd64

ONBUILD COPY --chown=root:root ci/libs/x86_64/*.so /usr/local/cuda/lib64/stubs/

FROM compilers as wrtc-arm64

ONBUILD COPY --chown=root:root ci/libs/aarch64/*.so /usr/local/cuda/lib64/stubs/

FROM wrtc-${TARGETARCH} as wrtc

ARG TARGETARCH
ARG SCCACHE_REGION
ARG SCCACHE_BUCKET
ARG SCCACHE_IDLE_TIMEOUT

ARG NODE_WEBRTC_REPO
ARG NODE_WEBRTC_BRANCH

RUN --mount=type=secret,id=AWS_ACCESS_KEY_ID \
    --mount=type=secret,id=AWS_SECRET_ACCESS_KEY \
    \
    apt update \
     && DEBIAN_FRONTEND=noninteractive \
     apt install -y --no-install-recommends python \
     && apt autoremove -y && apt clean \
     && rm -rf \
        /tmp/* \
        /var/tmp/* \
        /var/lib/apt/lists/* \
        /var/cache/apt/archives/* \
     && git clone \
        --depth 1 --branch "$NODE_WEBRTC_BRANCH" \
        "https://github.com/$NODE_WEBRTC_REPO.git" /tmp/node-webrtc \
     && cd /tmp/node-webrtc \
     && SKIP_DOWNLOAD=1 \
        TARGET_ARCH=${TARGETARCH} \
        CMAKE_MESSAGE_LOG_LEVEL=VERBOSE \
        CMAKE_C_COMPILER_LAUNCHER=/usr/bin/sccache \
        CMAKE_CXX_COMPILER_LAUNCHER=/usr/bin/sccache \
        CMAKE_CUDA_COMPILER_LAUNCHER=/usr/bin/sccache \
        AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)" \
        AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)" \
        npm install --no-audit --no-fund \
     && cd / \
     \
     && mkdir -p /opt/node-webrtc/build \
     && cp -R /tmp/node-webrtc/lib /opt/node-webrtc/ \
     && cp -R /tmp/node-webrtc/build/Release /opt/node-webrtc/build/ \
     && cp -R /tmp/node-webrtc/{README,LICENSE,THIRD_PARTY_LICENSES}.md /opt/node-webrtc/ \
     && bash -c 'echo -e "{\n\
\"name\": \"wrtc\",\n\
\"version\": \"0.4.7-linux-${TARGETARCH}\",\n\
\"author\": \"Alan K <ack@modeswitch.org> (http://blog.modeswitch.org)\",\n\
\"homepage\": \"https://github.com/node-webrtc/node-webrtc\",\n\
\"bugs\": \"https://github.com/node-webrtc/node-webrtc/issues\",\n\
\"license\": \"BSD-2-Clause\",\n\
\"main\": \"lib/index.js\",\n\
\"browser\": \"lib/browser.js\",\n\
\"repository\": {\n\
    \"type\": \"git\",\n\
    \"url\": \"http://github.com/node-webrtc/node-webrtc.git\"\n\
},\n\
\"files\": [\n\
    \"lib\",\n\
    \"build\",\n\
    \"README.md\",\n\
    \"LICENSE.md\",\n\
    \"THIRD_PARTY_LICENSES.md\"\n\
]\n\
}\n\
" | tee /opt/node-webrtc/package.json >/dev/null'; \
    \
    mkdir -p /out; \
    npm pack --pack-destination /out /opt/node-webrtc;

FROM scratch as export-stage

COPY --from=wrtc /out/ /
