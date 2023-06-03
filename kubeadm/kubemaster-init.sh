#!/bin/bash

## Set variables values
MASTER_IP=192.168.56.2

lsmod | grep br_netfilter
sudo modprobe br_netfilter
lsmod | grep br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system

## INSTALLING DOCKER ENGINE BASED ON OS

yum --help &>> /dev/null
if [ $? -eq 0 ]
then
  # (Install Docker CE)
  ## Set up the repository
  ### Install required packages
  yum install -y yum-utils device-mapper-persistent-data lvm2
  ## Add the Docker repository
  yum-config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo
  # Install Docker CE
  yum update -y && yum install -y \
    containerd.io-1.2.13 \
    docker-ce-19.03.11 \
    docker-ce-cli-19.03.11
  ## Create /etc/docker
  mkdir /etc/docker
  # Set up the Docker daemon
  cat > /etc/docker/daemon.json <<EOF
  {
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
      "max-size": "100m"
    },
    "storage-driver": "overlay2",
    "storage-opts": [
      "overlay2.override_kernel_check=true"
    ]
  }
EOF
  mkdir -p /etc/systemd/system/docker.service.d
  # Restart Docker
  systemctl daemon-reload
  systemctl restart docker
  sudo systemctl enable docker

else
  # (Install Docker CE)
  ## Set up the repository:
  ### Install packages to allow apt to use a repository over HTTPS
  apt-get update && apt-get install -y \
    apt-transport-https ca-certificates curl software-properties-common gnupg2
  # Add Docker's official GPG key:
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  # Add the Docker apt repository:
  add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
  # Install Docker CE
  apt-get update && apt-get install -y \
    containerd.io=1.2.13-2 \
    docker-ce=5:19.03.11~3-0~ubuntu-$(lsb_release -cs) \
    docker-ce-cli=5:19.03.11~3-0~ubuntu-$(lsb_release -cs)
  # Set up the Docker daemon
  cat > /etc/docker/daemon.json <<EOF
  {
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
      "max-size": "100m"
    },
    "storage-driver": "overlay2"
  }
EOF
  mkdir -p /etc/systemd/system/docker.service.d
  # Restart Docker
  systemctl daemon-reload
  systemctl restart docker
  sudo systemctl enable docker

fi

sleep 30

## Installing kubeadm, kubelet and kubectl
yum --help &>> /dev/null
if [ $? -eq 0 ]
then
   cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
   [kubernetes]
   name=Kubernetes
   baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
   enabled=1
   gpgcheck=1
   repo_gpgcheck=1
   gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
   exclude=kubelet kubeadm kubectl
EOF

   # Set SELinux in permissive mode (effectively disabling it)
   sudo setenforce 0
   sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

   sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

   sudo systemctl enable --now kubelet
   systemctl stop firewalld
   systemctl disable firewalld

else
   # installing cri-containerd
   git clone https://github.com/Mirantis/cri-dockerd.git
   wget https://storage.googleapis.com/golang/getgo/installer_linux
   chmod +x ./installer_linux
   ./installer_linux
   source ~/.bash_profile
   cd cri-dockerd
   mkdir bin
   go build -o bin/cri-dockerd
   mkdir -p /usr/local/bin
   install -o root -g root -m 0755 bin/cri-dockerd /usr/local/bin/cri-dockerd
   cp -a packaging/systemd/* /etc/systemd/system
   sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
   systemctl daemon-reload
   systemctl enable cri-docker.service
   systemctl start cri-docker.service
   
   # installing kubeadm

   sudo apt-get update
   sudo apt-get install -y apt-transport-https ca-certificates curl
   curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

   sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"

   
   sudo apt-get update
   sudo apt-get install -y kubelet kubeadm kubectl
   sudo apt-mark hold kubelet kubeadm kubectl
   systemctl stop ufw
   systemctl disable ufw
fi

#sleep 30

kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///var/run/cri-dockerd.sock > /tmp/kubeadm_out.log

sleep 120
/vagrant/set-kubeconfig.sh
sudo kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
sleep 60
sudo cat /tmp/kubeadm_out.log | grep -A1 'kubeadm join' > /vagrant/cltjoincommand.sh
sudo chmod +x /vagrant/cltjoincommand.sh
