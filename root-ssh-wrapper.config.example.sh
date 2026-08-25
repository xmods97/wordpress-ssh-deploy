#!/bin/sh

# Private server-local wrapper configuration.
# Install outside the Git checkout; do not commit real paths or secrets here.
# Required ownership/mode: root:root, 0600.

REMOTE_RUNNER_PATH='/root/.../server-deploy.sh'
REMOTE_TMP_PATH='/root/.../tmp'
ALLOW_PRODUCTION_FULL_OPT_IN='0'
SCP_BIN='/usr/bin/scp'
