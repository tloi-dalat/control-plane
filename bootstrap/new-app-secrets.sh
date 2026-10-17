#!/usr/bin/env bash
set -euo pipefail
rand() { local s; s=$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9'); printf '%s' "${s:0:$1}"; }

cat <<ENV
DJANGO__SECRET_KEY=$(rand 64)
REDIS__PASSWORD=$(rand 32)
EVENT__SUBMISSION_KEY=$(rand 64)
EVENT__CONTEST_KEY=$(rand 64)
EVENT__TICKET_KEY=$(rand 64)
MYSQL__PASSWORD=
SOCIAL__GOOGLE_SECRET=

JUDGE__KEY=$(rand 48)
ENV
