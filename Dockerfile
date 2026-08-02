# Build dummy packages on the build machine arch only (they are
# arch-independent), so multi-arch builds don't run equivs per-platform.
FROM --platform=$BUILDPLATFORM python:3.11-slim-bookworm AS builder

# Build dummy packages to skip installing them and their dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends equivs \
    && equivs-control libgl1-mesa-dri \
    && printf 'Section: misc\nPriority: optional\nStandards-Version: 3.9.2\nPackage: libgl1-mesa-dri\nVersion: 99.0.0\nDescription: Dummy package for libgl1-mesa-dri\n' >> libgl1-mesa-dri \
    && equivs-build libgl1-mesa-dri \
    && mv libgl1-mesa-dri_*.deb /libgl1-mesa-dri.deb \
    && equivs-control adwaita-icon-theme \
    && printf 'Section: misc\nPriority: optional\nStandards-Version: 3.9.2\nPackage: adwaita-icon-theme\nVersion: 99.0.0\nDescription: Dummy package for adwaita-icon-theme\n' >> adwaita-icon-theme \
    && equivs-build adwaita-icon-theme \
    && mv adwaita-icon-theme_*.deb /adwaita-icon-theme.deb

FROM python:3.11-slim-bookworm

# Copy dummy packages
COPY --from=builder /*.deb /

# Install dependencies and create flaresolverr user
# You can test Chromium running this command inside the container:
#    xvfb-run -s "-screen 0 1600x1200x24" chromium --no-sandbox
# The error traces is like this: "*** stack smashing detected ***: terminated"
# To check the package versions available you can use this command:
#    apt-cache madison chromium
WORKDIR /app
    # Install dummy packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    dpkg -i /libgl1-mesa-dri.deb \
    && dpkg -i /adwaita-icon-theme.deb \
    # Install dependencies (apt archives cached via BuildKit mount, so
    # repeated builds reuse downloaded .debs and skip the network)
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium chromium-common chromium-driver xvfb dumb-init \
        procps curl vim xauth \
    # Remove temporary files and hardware decoding libraries
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/x86_64-linux-gnu/libmfxhw* \
    && rm -f /usr/lib/x86_64-linux-gnu/mfx/* \
    # Create flaresolverr user
    && useradd --home-dir /app --shell /bin/sh flaresolverr \
    && mv /usr/bin/chromedriver chromedriver \
    && chown -R flaresolverr:flaresolverr . \
    # Create config dir
    && mkdir /config \
    && chown flaresolverr:flaresolverr /config

VOLUME /config

# Install Python dependencies (pip download cache via BuildKit mount)
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install -r requirements.txt

# Copy source code. The JSON-POST support (contentType="json") lives in src/ itself;
# patches/ now only documents how to derive a hot-patch for an upstream-built image.
COPY src .
COPY package.json ../
# py_compile only proves the files parse. The undefined-name check below also
# catches names that compile and import fine but raise NameError on first use
# (e.g. an import dropped while resolving a fork/upstream merge conflict).
COPY scripts/check_undefined_names.py /tmp/check_undefined_names.py
RUN cd /app \
    && python3 -m py_compile *.py bottle_plugins/*.py undetected_chromedriver/*.py \
    && python3 /tmp/check_undefined_names.py *.py bottle_plugins/*.py undetected_chromedriver/*.py \
    && rm -f /tmp/check_undefined_names.py

USER flaresolverr

RUN mkdir -p "/app/.config/chromium/Crash Reports/pending"

EXPOSE 8191
EXPOSE 8192

# dumb-init avoids zombie chromium processes
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

CMD ["/usr/local/bin/python", "-u", "/app/flaresolverr.py"]

# Local build
# docker build -t ngosang/flaresolverr:3.5.2 .
# docker run -p 8191:8191 ngosang/flaresolverr:3.5.2

# Multi-arch build
# docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
# docker buildx create --use
# docker buildx build -t ngosang/flaresolverr:3.5.2 --platform linux/386,linux/amd64,linux/arm/v7,linux/arm64/v8 .
#   add --push to publish in DockerHub

# Test multi-arch build
# docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
# docker buildx create --use
# docker buildx build -t ngosang/flaresolverr:3.5.2 --platform linux/arm/v7 --load .
# docker run -p 8191:8191 --platform linux/arm/v7 ngosang/flaresolverr:3.5.2
