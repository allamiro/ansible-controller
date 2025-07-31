FROM ubuntu:22.04

RUN apt-get  update 
RUN apt-get  upgrade -y
RUN apt-get install ansible -y
RUN apt-get install net-tools tcpdump openssh-server git vim nano openssh-* python3-pip git sudo -y

RUN useradd -u 1000 -m -s /bin/bash ansible \
 && mkdir -p /home/ansible/.ssh /configs /var/log/ansible /var/run/sshd \
 && chown -R ansible:ansible /home/ansible /configs /var/log/ansible

RUN printf 'Defaults:ansible !requiretty\nansible ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/99-ansible \
 && chmod 440 /etc/sudoers.d/99-ansible

RUN ssh-keygen -A
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]