# processmine dev container
# R 4.4.0 (rocker base, Ubuntu 22.04) + Python 3.11 (deadsnakes)
FROM rocker/r-ver:4.4.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC

# ---- System dependencies --------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common ca-certificates curl gnupg locales sudo \
    && locale-gen en_US.UTF-8 \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        # Python 3.11
        python3.11 python3.11-venv python3.11-dev python3-pip \
        # R system deps (arrow, curl, xml2, ragg, systemfonts)
        libcurl4-openssl-dev libssl-dev libxml2-dev \
        libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
        libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
        # Arrow C++ runtime
        libarrow-dev \
        # Tooling
        git make pandoc zip unzip less \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && rm -rf /var/lib/apt/lists/*

# ---- Python tooling -------------------------------------------------------
RUN python3.11 -m pip install --no-cache-dir --break-system-packages \
        pip setuptools wheel \
        radian \
        uv

# ---- R tooling ------------------------------------------------------------
# renv + devtools + pkgdown pre-installed so first session doesn't pay the cost.
RUN R -e "install.packages(c('renv','devtools','pkgdown','testthat','styler','rmarkdown','reticulate','arrow','languageserver'), repos='https://packagemanager.rstudio.com/cran/latest')"

# ---- Non-root user --------------------------------------------------------
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
WORKDIR /workspaces/processmine

# Point reticulate at the system Python 3.11.
ENV RETICULATE_PYTHON=/usr/bin/python3.11 \
    OMP_NUM_THREADS=1
