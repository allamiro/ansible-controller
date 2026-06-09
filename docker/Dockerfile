FROM ubuntu:22.04
LABEL org.opencontainers.image.title="Ansible Controller"
LABEL org.opencontainers.image.authors="Tamir Suliman <tsuliman@linuxvaults.com>"

ENV DEBIAN_FRONTEND=noninteractive

# ---- packages ----
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ansible \
      openssh-server \
      git \
      vim \
      python3 \
      python3-pip \
      sudo \
 && rm -rf /var/lib/apt/lists/*

# ---- upgrade vulnerable Python packages pulled in by apt ----
# apt pins these to old Ubuntu 22.04 versions with known HIGH CVEs.
# Upgrading via pip gets current patched releases while keeping apt's
# Ansible install intact.
RUN pip3 install --upgrade --no-cache-dir \
      pip \
      setuptools \
      wheel \
      cryptography \
      babel \
      pycryptodome \
      jinja2

# ---- user, dirs, ssh host keys ----
RUN useradd -u 1000 -m -s /bin/bash ansible \
 && mkdir -p /home/ansible/.ssh /configs /var/log/ansible /var/run/sshd \
 && chown -R ansible:ansible /home/ansible /configs /var/log/ansible

RUN printf 'Defaults:ansible !requiretty\nansible ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/99-ansible \
 && chmod 440 /etc/sudoers.d/99-ansible

# ---- entrypoint and runtime ---
RUN ssh-keygen -A
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD bash -c 'exec 6<>/dev/tcp/127.0.0.1/22'

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
