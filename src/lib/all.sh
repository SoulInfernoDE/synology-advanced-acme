#!/bin/bash
# Loads all Advanced ACME libraries. Expects AACME_TARGET to be set.
# shellcheck source=common.sh
. "${AACME_TARGET}/lib/common.sh"
# shellcheck source=dsm.sh
. "${AACME_TARGET}/lib/dsm.sh"
# shellcheck source=dsmtask.sh
. "${AACME_TARGET}/lib/dsmtask.sh"
# shellcheck source=certs.sh
. "${AACME_TARGET}/lib/certs.sh"
# shellcheck source=dns.sh
. "${AACME_TARGET}/lib/dns.sh"
# shellcheck source=jobs.sh
. "${AACME_TARGET}/lib/jobs.sh"
# shellcheck source=acmeupdate.sh
. "${AACME_TARGET}/lib/acmeupdate.sh"
# shellcheck source=status.sh
. "${AACME_TARGET}/lib/status.sh"
