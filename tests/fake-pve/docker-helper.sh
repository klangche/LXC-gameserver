#!/bin/bash
# Stands in for community-scripts ct/docker.sh: records the variables it got, "creates" the CT and
# installs its own /usr/bin/update like the real helper does.
env | grep '^var_' | sort > /var/log/fake-helper.env
touch /run/fake-ct-created
printf '#!/usr/bin/env bash\n# Community-Scripts update entrypoint (generated - do not edit by hand).\necho community-scripts updater\n' > /usr/bin/update
chmod +x /usr/bin/update
