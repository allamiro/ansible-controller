FROM ubuntu:24.04
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
# apt pins these to Ubuntu 24.04 repo versions; pip gets current patched releases.
# --break-system-packages: required by PEP 668 (Python 3.12 marks system env as externally managed).
# --ignore-installed: apt packages have no pip RECORD file, so pip cannot uninstall them;
#   this skips the uninstall step and writes the new version to /usr/local/lib (higher sys.path priority).
RUN pip3 install --upgrade --no-cache-dir --break-system-packages --ignore-installed \
      pip \
      setuptools \
      wheel \
      cryptography \
      babel \
      pycryptodome \
      jinja2

# ---- user, dirs, ssh host keys ----
# ubuntu:24.04 base ships a pre-created 'ubuntu' user at UID 1000; remove it first.
RUN userdel -r ubuntu \
 && useradd -u 1000 -m -s /bin/bash ansible \
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
