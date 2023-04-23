# syntax=docker/dockerfile:1

FROM antonhub/alpine:3.17 as rootfs-stage

# environment
ARG REL
ARG ARCH

# install packages
RUN \
  apk add --no-cache \
    bash \
    curl \
    tzdata \
    xz

# grab base tarball
RUN \
  mkdir /root-out && \
  curl -o \
    /rootfs.tar.gz -L \
    https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-${ARCH}/${REL}/slim/rootfs.tar.xz && \
  tar xf \
    /rootfs.tar.gz -C \
    /root-out && \
  rm -rf \
    /root-out/var/log/*

# set version for s6 overlay
ARG S6_OVERLAY_VERSION="3.1.4.2"
ARG S6_OVERLAY_ARCH="x86_64"

# add s6 overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz

# add s6 optional symlinks
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-arch.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-symlinks-arch.tar.xz

COPY docker-mods.v3 /root-out/docker-mods
# add local files
COPY root/ /root-out/
RUN find /root-out/etc/s6-overlay -name run|xargs chmod 755 && \
    chmod 755 /root-out/docker-mods

# Runtime stage
FROM scratch
COPY --from=rootfs-stage /root-out/ /
ARG REL
ARG MIRROR_DOMAIN="deb.debian.org"
LABEL MAINTAINER="Anton Chen <contact@antonchen.com>"

# set environment variables
ARG DEBIAN_FRONTEND="noninteractive"
ENV HOME="/root" \
LC_ALL="C" \
LANGUAGE="en_US.UTF-8" \
LANG="en_US.UTF-8" \
TERM="xterm" \
RUNUSER="debian" \
S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0" \
S6_VERBOSITY=1 \
S6_STAGE2_HOOK=/docker-mods

RUN \
  echo "**** Ripped from Ubuntu Docker Logic ****" && \
  echo '#!/bin/sh' \
    > /usr/sbin/policy-rc.d && \
  echo 'exit 101' \
    >> /usr/sbin/policy-rc.d && \
  chmod +x \
    /usr/sbin/policy-rc.d && \
  dpkg-divert --local --rename --add /sbin/initctl && \
  cp -a \
    /usr/sbin/policy-rc.d \
    /sbin/initctl && \
  sed -i \
    's/^exit.*/exit 0/' \
    /sbin/initctl && \
  echo 'force-unsafe-io' \
    > /etc/dpkg/dpkg.cfg.d/docker-apt-speedup && \
  echo 'DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' \
    > /etc/apt/apt.conf.d/docker-clean && \
  echo 'APT::Update::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' \
    >> /etc/apt/apt.conf.d/docker-clean && \
  echo 'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";' \
    >> /etc/apt/apt.conf.d/docker-clean && \
  echo 'Acquire::Languages "none";' \
    > /etc/apt/apt.conf.d/docker-no-languages && \
  echo 'Acquire::GzipIndexes "true"; Acquire::CompressionTypes::Order:: "gz";' \
    > /etc/apt/apt.conf.d/docker-gzip-indexes && \
  echo 'Apt::AutoRemove::SuggestsImportant "false";' \
    > /etc/apt/apt.conf.d/docker-autoremove-suggests && \
  echo 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";' \
    > /etc/apt/apt.conf.d/90disable-suggests && \
  mkdir -p /run/systemd && \
  echo 'docker' \
    > /run/systemd/container && \
  echo "**** install apt-utils and locales ****" && \
  apt-get update && \
  apt-get install -y \
    apt-utils \
    dialog \
    libterm-readkey-perl \
    locales && \
  echo "**** generate locale ****" && \
  locale-gen en_US.UTF-8 && \
  echo "**** upgrade ****" && \
  apt-get upgrade -y && \
  echo "**** install base tools ****" && \
  apt-get install -y \
    tzdata \
    procps \
    iproute2 \
    apt-transport-https \
    ca-certificates \
    curl \
    netcat-traditional && \
  echo "**** add all sources ****" && \
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
    rm -f /etc/apt/sources.list.d/debian.sources; \
  fi && \
  if [ "${REL}" = "bullseye" ]; then \
    echo "deb https://${MIRROR_DOMAIN}/debian ${REL} main contrib non-free" > /etc/apt/sources.list; \
  else \
    echo "deb https://${MIRROR_DOMAIN}/debian ${REL} main contrib non-free non-free-firmware" > /etc/apt/sources.list; \
  fi && \
  echo "deb https://${MIRROR_DOMAIN}/debian ${REL}-updates main contrib non-free" >> /etc/apt/sources.list && \
  echo "deb https://${MIRROR_DOMAIN}/debian ${REL}-backports main contrib non-free" >> /etc/apt/sources.list && \
  echo "deb https://${MIRROR_DOMAIN}/debian-security/ ${REL}-security main contrib non-free" >> /etc/apt/sources.list && \
  echo "**** create $RUNUSER user and make our folders ****" && \
  useradd -u 5900 -U -d /config -s /bin/false $RUNUSER && \
  usermod -G users $RUNUSER && \
  mkdir -p \
    /app \
    /config \
    /defaults && \
  echo "**** cleanup ****" && \
  apt-get -y autoremove && \
  apt-get clean && \
  rm -rf \
    /tmp/* \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /var/log/* \
    /usr/share/man

ENTRYPOINT ["/init"]
