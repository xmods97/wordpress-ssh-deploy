#!/usr/bin/env sh

echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
available="${FIXTURE_DF_AVAILABLE_KB:-9999999}"
printf 'fixture 10000000 1 %s 1%% /tmp\n' "$available"
