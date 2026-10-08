#!/usr/bin/env bash
# Print fresh random values for a NEW environment's app secrets, as .env lines
# to import into Infisical (folder /online-judge/core, and JUDGE__KEY into
# /online-judge/judge). Writes nothing to disk.
#
#   bootstrap/new-app-secrets.sh | pbcopy     # then paste into the Infisical UI
#
# Don't run this for an environment that already exists: a new
# DJANGO__SECRET_KEY logs everyone out, and a new JUDGE__KEY must also be
# entered in the site admin (Admin → Judges).
set -euo pipefail
# No `head` here: with pipefail, an early-closing reader can turn SIGPIPE into a failure.
rand() { local s; s=$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9'); printf '%s' "${s:0:$1}"; }

cat <<ENV
# --- /online-judge/core ---
DJANGO__SECRET_KEY=$(rand 64)
REDIS__PASSWORD=$(rand 32)
EVENT__SUBMISSION_KEY=$(rand 64)
EVENT__CONTEST_KEY=$(rand 64)
EVENT__TICKET_KEY=$(rand 64)
# Fill in: the dmoj_k8s password from bootstrap/<env>/mysql-k8s-user.sql
MYSQL__PASSWORD=
# Fill in: Google OAuth client secret (leave empty to disable Google login)
SOCIAL__GOOGLE_SECRET=

# --- /online-judge/judge  (separate folder: the judge sees only this) ---
JUDGE__KEY=$(rand 48)
ENV
