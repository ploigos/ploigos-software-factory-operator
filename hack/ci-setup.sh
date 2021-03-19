#!/bin/bash -ex
# Installs dependencies needed to run the tests in CI environment


mkdir -p $HOME/.local/bin
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=$HOME/.kube/config

# Basic pip prereqs
pip3 install --user --upgrade setuptools wheel pip

# Dependencies for test environment
# NOTE: explicitly downgrading openshift due to https://github.com/kubernetes-client/python/issues/1333
pip3 install --user docker==4.2.2 ansible molecule ansible-lint yamllint flake8 openshift==0.11.2 jmespath

# Ansible dependencies
ansible-galaxy collection install -r requirements.yml

# OC CLI
curl -Lo $HOME/oc.tar.gz http://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xvzf $HOME/oc.tar.gz -C $HOME/.local/bin oc

# Helm CLI
curl -Lo $HOME/helm.tgz https://get.helm.sh/helm-v3.5.2-linux-amd64.tar.gz
tar xvzf $HOME/helm.tgz -C $HOME/.local/bin --strip-components 1 linux-amd64/helm

# Kustomize CLI
curl -Lo $HOME/kustomize.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v3.10.0/kustomize_v3.10.0_linux_amd64.tar.gz
tar zxvf $HOME/kustomize.tar.gz -C $HOME/.local/bin kustomize
