#!/bin/bash
# vim: syntax=sh ts=4 sts=4 sw=4 expandtab

PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export PATH

dockervarlib_check() {
    if [ -d /var/lib/docker/ ]; then
        if ! [[ "$(stat -c%D /var/lib/)" == "$(stat -c%D /var/lib/docker/)" ]]; then
            echo "/var/lib/docker is on a separate device"
        else
            echo "/var/lib/docker is on the same device"
            move_docker
        fi
    else
        move_docker
    fi
}

move_docker() {
    # Does /var/lib/docker already exist and is it a symbolic link?
    # if not, move it, if it is, remove it
    if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
        mv -f /var/lib/docker /local/mnt/workspace/
    elif [ -d /var/lib/docker ] && [ -L /var/lib/docker ]; then
        rm -f /var/lib/docker
    fi

    # If /local/mnt/workspace/docker doesn't exist, create it, otherwise
    # symlink /var/lib/docker to it
    if [ ! -e /local/mnt/workspace/docker ]; then
        # Creating workspace location if it doesn't exist
        mkdir -p /local/mnt/workspace/docker
        ln -s -f /local/mnt/workspace/docker/ /var/lib/docker
    else
        # Creating a link for it in /var/lib so no move will be needed
        ln -s -f /local/mnt/workspace/docker/ /var/lib/docker
    fi
}

# Change the default network to a 169.254.0.1/17
# We do this because the defaults are an RFC1918 network
# that we actually route within Qualcomm, meaning any
# containers that come up with those IPs are unable
# to route packets to clients in that RFC1918 space.
# The /17 is because we use the upper half of the
# 169.254 space for Rancher's internal network (if Rancher is used)

# 169.254.0.0-169.254.127.255 = Docker net (169.254.0.0/17)
# 169.254.128.0-169.254.255.255 = Rancher net (169.254.128.0/17)
docker_net() {
    DOCKER_NET="169.254.0.1/17"
    RANCHER_NET="169.254.128.0/17"
    local os_dist
    local init
    os_dist=$(gvquery -p os_dist)
    init=$(ucmsvc -i)
    # Should maybe implement in the future:
    # https://docs.docker.com/engine/admin/systemd/#runtime-directory-and-storage-driver
    case "${init}-${os_dist}" in
        upstart-ubuntu*)
            if ucmps -o delimited -f args | grep '[d]ockerd' | grep -q -- "--bip=$DOCKER_NET"; then
                echo "dockerd already running with correct network"
            else
                service docker stop
                # Ensure docker uses the ITNET-approved subnet
                if [ -f /etc/default/docker ]; then
                    sed -i -e '/^DOCKER_OPTS=/d' /etc/default/docker
                    echo "DOCKER_OPTS=\"--bip=$DOCKER_NET\"" >> /etc/default/docker
                fi
                # Ensure UFW allows forwarding: https://docs.docker.com/engine/installation/linux/linux-postinstall/#allow-access-to-the-remote-api-through-a-firewall
                sed -i -e 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
                service ufw restart
                killall dockerd
                [ -d /var/run/docker.sock ] && rm -rf /var/run/docker.sock
                service docker start
            fi
            ;;
        systemd-*)
            if [ -f /lib/systemd/system/docker.service ]; then
                dist_exec_start=$(grep "^ExecStart=" /lib/systemd/system/docker.service | cut -d= -f2-)
            elif [ -f /usr/lib/systemd/system/docker.service ]; then
                dist_exec_start=$(grep "^ExecStart=" /usr/lib/systemd/system/docker.service | cut -d= -f2-)
            else
                echo "ERROR: Unable to find docker.service"
                exit 1
            fi
            # Create drop-in that modifies ExecStart to include --bip
            mkdir -p /etc/systemd/system/docker.service.d
            override_unit=/etc/systemd/system/docker.service.d/99-docker-duty.conf
            echo "[Service]" > $override_unit
            echo "# Required to override ExecStart; see https://bugzilla.redhat.com/show_bug.cgi?id=756787" >> $override_unit
            echo "ExecStart=" >> $override_unit
            echo "# Use appropriate CIDR net" >> $override_unit
            echo "ExecStart=${dist_exec_start} --bip=$DOCKER_NET" >> $override_unit
            # Reload systemd configuration
            sleep 1
            systemctl daemon-reload
            sleep 1
            systemctl reload docker.service
            sleep 1
            # CM-2030: Fix systems that ended up with --containerd --bip=169... in commandline
            if ucmps -o delimited -f args | grep -q '[d]ockerd .*--containerd --bip'; then
                systemctl restart docker.service
            else
                systemctl start docker.service
            fi
            ;;
        *)
            echo "Unsupported init-os_dist ${init}-${os_dist}"
            exit 1
            ;;
    esac
}

#Install Docker Package
install_pkg() {
    local os_dist
    os_dist=$(gvquery -p os_dist)
    # add_check limits distros before this runs.

    # Run the pinning cronjob before we start, to ensure
    # we install the pinned version (if applicable)
    run_setups cron
    run_setups repo
    /var/adm/gv/cron/1_per_hour.d/D50-docker_version_pin
    /var/adm/gv/cron/1_per_day.d/D98-docker-compose

    dockervarlib_check
    run_setups duty-inherit
    echo "Installing Docker"

    case "${os_dist}" in
        rhel*|centos*|rocky*)
            if gvquery -p docker-version-pin 2>/dev/null | grep -q 17.05; then
                # Older version of Docker CE requires that the container-selinux
                # package be removed before installing (it pulls in its own
                # selinux policy package)
                rpm -e --nodeps container-selinux
            fi
            yum -y install docker-ce
            ;;
        ubuntu14*|ubuntu16*|ubuntu18*|ubuntu20*|ubuntu22*)
            apt-get -y install docker-ce
            ;;
        sles12*)
            zypper --no-gpg-checks --non-interactive install --download-as-needed --auto-agree-with-licenses docker
            ;;
        *)
            echo "Unknown os_dist ${os_dist}"
            exit 1
            ;;
    esac

    # CM-1987: Run the on-boot cron that configures
    # overlayfs.  The cron is smart enough to verify
    # if the aufs filesystem is empty, and will only
    # enable overlayfs if so.
    /var/adm/gv/cron/boot.d/D01-docker_overlayfs

    docker_net
    sleep 5
    echo "Starting docker service"
    ucmsvc -t docker enable
    ucmsvc -t docker restart
}

#Remove Docker Package
remove_pkg() {
    local os_dist=$(gvquery -lp os_dist)
    echo "Removing docker-compose"
    rm -f /usr/local/bin/docker-compose

    echo "Stopping docker service"
    ucmsvc -t docker stop

    case "${os_dist}" in
    rhel*|centos*|rocky*)
        echo "Removing docker"
        yum -y remove docker-engine
        yum -y remove docker-ce
        yum -y remove docker-ce-selinux
        yum -y remove docker-ce-cli
        ;;
    ubuntu*)
        echo "Removing docker"
        DEBIAN_FRONTEND=noninteractive apt-get -y remove docker-engine
        DEBIAN_FRONTEND=noninteractive apt-get -y remove docker-ce
        DEBIAN_FRONTEND=noninteractive apt-get -y remove docker-ce-cli
        ;;
    sles12*)
        zypper --no-gpg-checks --non-interactive remove docker
        ;;
    *)
        echo "Unknown os_dist ${os_dist}"
        exit 1
        ;;
    esac
}

# Check if Docker package installed
pkg_install_failed() {
    local os_dist=$(gvquery -lp os_dist)

    echo "Checking docker installation"
    pushd /

    case "${os_dist}" in
    rhel*|centos*|rocky*)
        rpm --verify docker-ce || return 0
        popd
        return 1
        ;;
    ubuntu*)
        dpkg --verify docker-ce || return 0
        popd
        return 1
        ;;
    sles12*)
        # we use --nofiles because SUSE's rpm verification
        # seems to consider edits to daemon.json and mode changes
        # for /var/lib/docker to be "failures"
        rpm --verify --nofiles docker || return 0
        popd
        return 1
        ;;
    *)
        echo "Unknown os_dist ${os_dist}"
        popd
        exit 1
        ;;
    esac

}

# CM-2901: if duty is being added/removed under a sudo environment, $HOME
# will refer to the non-root user's home.  Docker commands don't work properly
# if executed as root, with $HOME set to a non-root homedir.  So we force
# $HOME to /root if $SUDO_USER is set
if [[ -n "${SUDO_USER}" ]]; then
    export HOME=/root
fi

case ${1} in
    start)
    # CM-2724: Check to see if the docker group is local
    if [[ "$(getent group docker)" =~ VAS ]]; then
        echo "CM-2724: VAS docker group still in cache, flushing group cache"
        /opt/quest/bin/vastool flush groups
    fi
    if [[ "$(getent group docker)" =~ VAS ]]; then
        echo "ERROR: CM-2724: VAS docker group still in cache after flush"
        exit 1
    fi

    #Install docker package
    install_pkg

    # If the package didn't install, abort
    if pkg_install_failed; then
        echo "ERROR: docker package did not install correctly, removing duty"
        remove_pkg
        # remove the duty so they can try again
        gvquery -D docker
        exit 1
    fi

    #Add user to docker group if GV2.6
    if [[ "$(gvquery -p gv_version)" =~ 2\.6 ]]; then
        for user in $(gvquery -p user | tr ',' ' '); do
            echo "Adding ${user} to the system's local docker group"
            usermod -aG docker "${user}"
        done
    else
        echo "This is not a GV2.6 host; you will need to manage"
        echo "the permissions of /var/run/docker.sock manually."
    fi

    # Run the docker subsystem before we run our final validation
    run_setups docker

    # Check that Docker is working
    echo "Checking if Docker is running..."
    if docker info; then
        echo "Docker started OK"
    else
        echo "ERROR: Docker did not start up properly"
        remove_pkg
        # remove the duty so they can try again
        gvquery -D docker
        exit 1
    fi

    ;;
    modifyip)
        docker_net
    ;;
    stop)
        ucmsvc -t docker stop
        killall docker
        killall dockerd

        # Remove the docker software
        remove_pkg

        # Remove any systemd drop-ins
        rm -rf /etc/systemd/system/docker.service.d

        # Get rid of /var/lib/docker bits
        echo "Removing local docker files"
        if [ -e /local/mnt/workspace/docker ]; then
            rm -rf /local/mnt/workspace/docker
        fi
        rm -rf /var/lib/docker
    ;;
esac
