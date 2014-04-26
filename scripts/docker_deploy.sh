#!/bin/bash
# Copyright 2014, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Run tripleo undercloud seed in a Docker container using devtest.sh
# $1 = OS to deploy to the undercloud
# $@ = Args to pass to devtest.sh.  --trash-my-machine will be included.

[[ -d /sys/module/openvswitch ]] || {
    echo "Missing openvswitch module, this cannot possibly work."
    exit 1
}

[[ -d $HOME/.cache/openstack ]] && mkdir -p "$HOME/.cache/openstack"
[[ -d $HOME/.cache/tripleo-docker ]] && mkdir -p "$HOME/.cache/tripleo-docker/yum"


# If we are not running inside of Docker, put ourselves in a container.
if [[ ! -x /.dockerinit ]]; then
    # We want a centos container, specifically.  It is the only
    # one that service manipulation will work in without
    # Deep Hackery
    image="centos:centos6"
    if ! which docker &>/dev/null; then
        echo "Please install Docker!"
        exit 1
    fi

    if [[ $0 = /* ]]; then
        mountdir="$0"
    elif [[ $0 = .*  || $0 = */* ]]; then
        mountdir="$(readlink -f "$PWD/$0")"
    else
        echo "Cannot figure out where we are!"
        exit 1
    fi
    # This gets us to tripleo-incubator
    mountdir="${mountdir%/scripts/docker_deploy.sh}"
    # This gets us to the parent directory of tripleo-incubator,
    # where presumably the rest of our repos are checked out
    mountdir="${mountdir%/*}"
    echo "We will mount $mountdir at /opt/openstack"

    docker_args=(-t -i -w /opt/openstack/tripleo-incubator -v "$mountdir:/opt/openstack")
    docker_args+=(-v "$HOME/.cache/openstack:/home/openstack/.cache")
    docker_args+=(-v "$HOME/.cache/tripleo-docker/yum:/var/cache/yum")
    docker_args+=(-e "OUTER_UID=$(id -u)")
    docker_args+=(-e "OUTER_GID=$(id -g)")
    [[ -f $HOME/.ssh/id_rsa.pub ]] && docker_args+=(-e "SSH_PUBKEY=$(cat "$HOME/.ssh/id_rsa.pub")")
    bridge="docker0"
    bridge_re='-b=([^ ])'
    bridge_addr_re='inet ([0-9.]+)/'
    # If we told Docker to use a custom bridge, here is where it is at.
    [[ $(ps -C docker -o 'command=') =~ $bridge_re ]] && \
        bridge="${BASH_REMATCH[1]}"
    # Capture the IP of the bridge for later when we are hacking up
    # proxies.
    [[ $(ip -o -4 addr show dev $bridge) =~ $bridge_addr_re ]] && \
        bridge_ip="${BASH_REMATCH[1]}"
    # Make sure the container knows about our proxies, if applicable.
    . "$mountdir/tripleo-incubator/scripts/proxy_lib.sh"
    mangle_proxies "$bridge_ip"
    for proxy in "${!mangled_proxies[@]}"; do
        docker_args+=(-e "$proxy=${mangled_proxies[$proxy]}")
    done

    # since 0.8.1 we need to run in privileged mode so we can change the networking
    docker_args+=("--privileged")
    # Run whatever we specified to run inside a container.
    docker run "${docker_args[@]}" "$image" /opt/openstack/tripleo-incubator/scripts/docker_deploy.sh "$@"
    exit $?
fi
export TRIPLEO_ROOT=/opt/openstack
case $1 in
    fedora|opensuse|ubuntu) export TRIPLEO_OS_DISTRO="$1";;
    *) echo "Don't know how to create an undercloud on $1"
        exit 1;;
esac
shift
export LANG=en_US.UTF-8
if grep -q openstack /etc/passwd; then
    find /var /home -xdev -user openstack -exec chown "$OUTER_UID" '{}' ';'
    usermod -o -u "$OUTER_UID" openstack
else
    useradd -o -U -u "$OUTER_UID" \
        -d /home/openstack -m \
        -s /bin/bash \
        openstack
fi
if grep -q openstack /etc/group; then
    find /var /home -xdev -group openstack -exec chown "$OUTER_UID:$OUTER_GID" '{}' ';'
    groupmod -o -g "$OUTER_GID" openstack
    usermod -g "$OUTER_GID" openstack
    usermod -a -G wheel openstack
    usermod -a -G wheel root
fi
chown -R openstack:openstack /home/openstack
mkdir -p /root/.ssh
printf "%s\n" "$SSH_PUBKEY" >> /root/.ssh/authorized_keys

if [[ ! -f /etc/yum.repos.d/epel.repo ]]; then
    # This will need to be updated as the EPEL release changes.
    yum -y localinstall \
        http://mirrors.servercentral.net/fedora/epel/6/i386/epel-release-6-8.noarch.rpm || {
        echo Cannot automatically install the EPEL repository.
        echo See http://fedoraproject.org/wiki/EPEL for manual installation instructions.
        exit 1
    }
fi

# Disable using mirrors
( cd /etc/yum.repos.d; sed -i -e '/^#baseurl/ s/\#//' -e '/^mirrorlist/ s/^mirror/#mirror/' *.repo)

yum -y install sudo tmux openssh openssh-server
sed -i -e '/^Defaults.*(requiretty|visiblepw)/ s/^.*$//' /etc/sudoers
echo 'Defaults   env_keep += "TRIPLEO_OS_DISTRO TRIPLEO_ROOT http_proxy https_proxy no_proxy"' >/etc/sudoers.d/wheel
echo '%wheel	ALL=(ALL)	NOPASSWD: ALL' >>/etc/sudoers.d/wheel
/etc/init.d/sshd start

cat >/root/devstack.sh <<EOL
sudo -E -H -u openstack /bin/bash <<'EOF'
. /etc/profile
"$TRIPLEO_ROOT/tripleo-incubator/scripts/devtest.sh" --trash-my-machine "$@"
/bin/bash -i
EOF
EOL

chmod 755 /root/devstack.sh

tmux new-session /root/devstack.sh
