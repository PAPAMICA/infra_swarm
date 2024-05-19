#!/bin/bash
sudo useradd -m -s /bin/bash ansible
echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible
mkdir /home/ansible/.ssh
echo "${var.ansible_publickey}" >> /home/ansible/.ssh/authorized_keys