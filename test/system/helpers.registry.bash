# -*- bash -*-
#
# helpers for starting/stopping a local registry.
#
# Used primarily in 150-login.bats
#

###############################################################################
# BEGIN one-time envariable setup

# Override any user-set path to an auth file
unset REGISTRY_AUTH_FILE

# END   one-time envariable setup
###############################################################################

# Start a local registry. Only needed on demand (e.g. by 150-login.bats)
# and then only once: if we start, leave it running until final teardown.
function start_registry() {
    if [[ -d "$PODMAN_LOGIN_WORKDIR/auth" ]]; then
        # Already started

        # Fixes very obscure corner case in root system tests:
        #  1) we run 150-login tests, starting a registry; then
        #  2) run 500-network, which runs iptables -F; then
        #  3) run 700-play, the "private" test, which needs the
        #     already-started registry, but its port is now DROPped,
        #     so the test times out trying to talk to registry
        run_podman --storage-driver vfs $(podman_isolation_opts ${PODMAN_LOGIN_WORKDIR}) network reload --all
        return
    fi

    AUTHDIR=${PODMAN_LOGIN_WORKDIR}/auth
    mkdir -p $AUTHDIR

    # Registry image; copy of docker.io, but on our own registry
    local REGISTRY_IMAGE="$PODMAN_TEST_IMAGE_REGISTRY/$PODMAN_TEST_IMAGE_USER/registry:2.8.2"

    # Pull registry image, but into a separate container storage and DB and everything
    PODMAN_LOGIN_ARGS="--storage-driver vfs $(podman_isolation_opts ${PODMAN_LOGIN_WORKDIR})"
    # Registry image needs a cert. Self-signed is good enough.
    CERT=$AUTHDIR/domain.crt
    if [ ! -e $CERT ]; then
        openssl req -newkey rsa:4096 -nodes -sha256 \
                -keyout $AUTHDIR/domain.key -x509 -days 2 \
                -out $AUTHDIR/domain.crt \
                -subj "/C=US/ST=Foo/L=Bar/O=Red Hat, Inc./CN=localhost" \
                -addext "subjectAltName=DNS:localhost"
    fi

    # Copy a cert to another directory for --cert-dir option tests
    mkdir -p ${PODMAN_LOGIN_WORKDIR}/trusted-registry-cert-dir
    cp $CERT ${PODMAN_LOGIN_WORKDIR}/trusted-registry-cert-dir

    # Store credentials where container will see them
    htpasswd -Bbn ${PODMAN_LOGIN_USER} ${PODMAN_LOGIN_PASS} > $AUTHDIR/htpasswd

    # In case $PODMAN_TEST_KEEP_LOGIN_REGISTRY is set, for testing later
    echo "${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS}" > $AUTHDIR/htpasswd-plaintext

    # Run the registry container.
    run_podman ${PODMAN_LOGIN_ARGS} run -d \
               -p 127.0.0.1:${PODMAN_LOGIN_REGISTRY_PORT}:5000 \
               --name registry \
               -v $AUTHDIR:/auth:Z \
               -e "REGISTRY_AUTH=htpasswd" \
               -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
               -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
               -e REGISTRY_HTTP_TLS_CERTIFICATE=/auth/domain.crt \
               -e REGISTRY_HTTP_TLS_KEY=/auth/domain.key \
               $REGISTRY_IMAGE
    cid="$output"

    # wait_for_port isn't enough: that just checks that podman has mapped the port...
    wait_for_port 127.0.0.1 ${PODMAN_LOGIN_REGISTRY_PORT}
    # ...so we look in container logs for confirmation that registry is running.
    _PODMAN_TEST_OPTS="${PODMAN_LOGIN_ARGS}" wait_for_output "listening on .::.:5000" $cid
}

function stop_registry() {
    if [[ ! -d "$PODMAN_LOGIN_WORKDIR/auth" ]]; then
        # No registry running
        return
    fi

    opts="--storage-driver vfs $(podman_isolation_opts ${PODMAN_LOGIN_WORKDIR})"
    run_podman $opts rm -f -t0 registry
    run_podman $opts rmi -a -f

    # By default, clean up
    if [ -z "${PODMAN_TEST_KEEP_LOGIN_WORKDIR}" ]; then
        # FIXME: why is this necessary??? If we don't do this, we can't
        # rm -rf the workdir, because ..../overlay is mounted
        mount | grep ${PODMAN_LOGIN_WORKDIR} | awk '{print $3}' | xargs --no-run-if-empty umount

        if [[ $(id -u) -eq 0 ]]; then
            rm -rf ${PODMAN_LOGIN_WORKDIR}
        else
            # rootless image data is owned by a subuid
            run_podman unshare rm -rf ${PODMAN_LOGIN_WORKDIR}
        fi
    fi

    # Make sure socket is closed
    if tcp_port_probe $PODMAN_LOGIN_REGISTRY_PORT; then
        # for debugging flakes
        echo ""
        echo "ps auxww --forest"
        ps auxww --forest
        echo ""
        echo "lsof -i -P"
        lsof -i -P
        die "Socket still seems open"
    fi
}

function pause_registry() {
    if [[ ! -d "$PODMAN_LOGIN_WORKDIR/auth" ]]; then
        # No registry running
        return
    fi

    opts="--storage-driver vfs $(podman_isolation_opts ${PODMAN_LOGIN_WORKDIR})"
    run_podman $opts stop registry
}

function unpause_registry() {
    if [[ ! -d "$PODMAN_LOGIN_WORKDIR/auth" ]]; then
        # No registry running
        return
    fi

    opts="--storage-driver vfs $(podman_isolation_opts ${PODMAN_LOGIN_WORKDIR})"
    run_podman $opts start registry
}
