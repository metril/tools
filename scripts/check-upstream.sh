#!/usr/bin/env bash
#
# check-upstream.sh — decide whether pinned upstreams (Vault, Alpine base image)
# have a newer version that has been public long enough to adopt.
#
# The "1-week vetting delay" gate: a newer upstream is only adopted once it has
# been released for at least DELAY_DAYS days, giving the community time to vet it.
#
# On a qualifying change this rewrites versions.json in place and emits a
# conventional-commit subject. Designed for GNU date (GitHub Linux runners).
#
# Env:
#   VERSIONS_FILE   path to versions.json            (default: versions.json)
#   DELAY_DAYS      vetting delay in days            (default: 7)
#   NOW_EPOCH       override "now" for tests         (default: date +%s)
#   DRY_RUN         if non-empty, never write a file
#   GITHUB_OUTPUT   if set, key=value outputs are appended for Actions
#
# Outputs (stdout is a single JSON object; also mirrored to GITHUB_OUTPUT):
#   changed, commit_type (feat|fix), commit_subject, body
#
set -euo pipefail

VERSIONS_FILE="${VERSIONS_FILE:-versions.json}"
DELAY_DAYS="${DELAY_DAYS:-7}"
NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"
DELAY_SECONDS=$(( DELAY_DAYS * 86400 ))

log() { echo "$@" >&2; }

# ISO-8601 (e.g. 2026-06-04T20:58:41.244Z) -> epoch seconds.
iso_to_epoch() { date -d "$1" +%s; }

age_days() { echo $(( ( NOW_EPOCH - $1 ) / 86400 )); }

current_vault="$(jq -r '.vault_version' "$VERSIONS_FILE")"
current_base_image="$(jq -r '.base_image' "$VERSIONS_FILE")"
current_base_digest="$(jq -r '.base_digest' "$VERSIONS_FILE")"

new_vault="$current_vault"
new_base_digest="$current_base_digest"
vault_changed=false
base_changed=false
body=""

# --- Vault -----------------------------------------------------------------
log "Checking Vault (pinned: ${current_vault})…"
vault_json="$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/vault/latest)"
latest_vault="$(jq -r '.version' <<<"$vault_json")"
vault_prerelease="$(jq -r '.is_prerelease' <<<"$vault_json")"
vault_created="$(jq -r '.timestamp_created' <<<"$vault_json")"

if [[ "$vault_prerelease" == "true" ]]; then
  log "  latest ${latest_vault} is a prerelease — skipping."
elif [[ "$latest_vault" == "$current_vault" ]]; then
  log "  already on latest stable (${current_vault})."
else
  vault_age="$(age_days "$(iso_to_epoch "$vault_created")")"
  if (( NOW_EPOCH - $(iso_to_epoch "$vault_created") >= DELAY_SECONDS )); then
    log "  ${current_vault} -> ${latest_vault} (released ${vault_age}d ago, gate passed)."
    new_vault="$latest_vault"
    vault_changed=true
    body+="- Vault ${current_vault} → ${latest_vault} (released ${vault_age}d ago)"$'\n'
  else
    log "  ${latest_vault} only ${vault_age}d old (< ${DELAY_DAYS}d) — holding back."
  fi
fi

# --- Alpine base image (Docker Hub) ----------------------------------------
log "Checking base image (pinned: ${current_base_image}@${current_base_digest:0:19}…)"
repo="${current_base_image%%:*}"
tag="${current_base_image##*:}"
[[ "$repo" == */* ]] || repo="library/${repo}"   # Docker Hub official-image namespace

dh_token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r '.token')"
accept_hdr=(
  -H "Accept: application/vnd.oci.image.index.v1+json"
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json"
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
)
reg="https://registry-1.docker.io/v2/${repo}"

latest_base_digest="$(curl -fsSL -D - -o /dev/null \
  -H "Authorization: Bearer ${dh_token}" "${accept_hdr[@]}" \
  "${reg}/manifests/${tag}" | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | tr -d '\r')"

if [[ -z "$latest_base_digest" ]]; then
  log "  could not resolve base digest — skipping base check."
elif [[ "$latest_base_digest" == "$current_base_digest" ]]; then
  log "  already on latest digest."
else
  # Created date: index -> first platform manifest -> config blob -> .created
  index_json="$(curl -fsSL -H "Authorization: Bearer ${dh_token}" "${accept_hdr[@]}" "${reg}/manifests/${tag}")"
  plat_digest="$(jq -r '.manifests[0].digest // empty' <<<"$index_json")"
  if [[ -z "$plat_digest" ]]; then
    plat_digest="$latest_base_digest"   # single-arch manifest, not an index
  fi
  plat_manifest="$(curl -fsSL -H "Authorization: Bearer ${dh_token}" "${accept_hdr[@]}" "${reg}/manifests/${plat_digest}")"
  config_digest="$(jq -r '.config.digest' <<<"$plat_manifest")"
  base_created="$(curl -fsSL -H "Authorization: Bearer ${dh_token}" "${reg}/blobs/${config_digest}" | jq -r '.created')"
  base_age="$(age_days "$(iso_to_epoch "$base_created")")"

  if (( NOW_EPOCH - $(iso_to_epoch "$base_created") >= DELAY_SECONDS )); then
    log "  digest update available (image built ${base_age}d ago, gate passed)."
    new_base_digest="$latest_base_digest"
    base_changed=true
    body+="- ${current_base_image} base image digest refreshed (built ${base_age}d ago)"$'\n'
  else
    log "  new digest only ${base_age}d old (< ${DELAY_DAYS}d) — holding back."
  fi
fi

# --- Result ----------------------------------------------------------------
changed=false
commit_type=""
commit_subject=""
if [[ "$vault_changed" == true ]]; then
  changed=true; commit_type="feat"; commit_subject="feat: update vault to ${new_vault}"
elif [[ "$base_changed" == true ]]; then
  changed=true; commit_type="fix"; commit_subject="fix: refresh ${current_base_image} base image digest"
fi

if [[ "$changed" == true && -z "${DRY_RUN:-}" ]]; then
  tmp="$(mktemp)"
  jq --arg v "$new_vault" --arg d "$new_base_digest" \
    '.vault_version = $v | .base_digest = $d' "$VERSIONS_FILE" >"$tmp"
  mv "$tmp" "$VERSIONS_FILE"
  log "Wrote ${VERSIONS_FILE}."
fi

result="$(jq -nc \
  --argjson changed "$changed" \
  --arg type "$commit_type" \
  --arg subject "$commit_subject" \
  --arg body "$body" \
  '{changed:$changed, commit_type:$type, commit_subject:$subject, body:$body}')"

echo "$result"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "changed=${changed}"
    echo "commit_type=${commit_type}"
    echo "commit_subject=${commit_subject}"
    echo "body<<__EOF__"
    printf '%s' "$body"
    echo "__EOF__"
  } >>"$GITHUB_OUTPUT"
fi
