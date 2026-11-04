#!/usr/bin/env bash
# Issue #7 on L1-B1: start a rogue copy of this hospital's Flower client, in this hospital's own
# account. Run in src/infra/aws-l1b1/participant after 'terraform workspace select <a|b|c>'.
#
# The rogue uses this account's client image, network and real execution key (from the secret),
# so it reaches the Flower server exactly like the real client. What differs is who it claims to be:
#   rogue-task.sh       a second connection as this hospital       expect duplicate_org
#   rogue-task.sh B     claims Hospital B, signs with this key      expect invalid_proof:org://HospitalB
set -euo pipefail
export AWS_PAGER=""

claim="$(tr '[:lower:]' '[:upper:]' <<<"${1:-}")"
if [[ -n "${claim}" && ! "${claim}" =~ ^[ABC]$ ]]; then
  echo "usage: $0 [A|B|C]" >&2
  exit 1
fi

# The probe task (README, step 8) is the client with its command replaced by 'sleep 3600'.
# Here the client runs normally instead, optionally with another ORG_ID.
cmd="$(terraform output -raw probe_task)"
sleep_override=',"command":["sleep","3600"]'
[[ "${cmd}" == *"${sleep_override}"* ]] || { echo "probe_task output is not as expected" >&2; exit 1; }
replacement=""
[[ -n "${claim}" ]] && replacement=",\"environment\":[{\"name\":\"ORG_ID\",\"value\":\"org://Hospital${claim}\"}]"
cmd="${cmd/"${sleep_override}"/${replacement}} --started-by issue7-rogue --query 'tasks[0].taskArn' --output text"

arn="$(eval "${cmd}")"
[[ "${arn}" == arn:* ]] || { echo "run-task returned: ${arn}" >&2; exit 1; }
task="${arn##*/}"
profile="$(sed -E 's/.*--profile ([^ ]+).*/\1/' <<<"${cmd}")"
cluster="$(sed -E 's/.*--cluster ([^ ]+).*/\1/' <<<"${cmd}")"
container="$(sed -E 's/.*"name":"(flower-client-[abc])".*/\1/' <<<"${cmd}")"

echo "Started rogue ${task} (${profile}, claims ${claim:-this hospital})"
echo "Status: aws ecs describe-tasks --profile ${profile} --cluster ${cluster} --tasks ${task} --query 'tasks[0].lastStatus' --output text"
echo "Logs:   aws logs tail /ecs/${cluster} --profile ${profile} --log-stream-name-prefix ${container}/${container}/${task} --since 30m"
echo "Stop:   aws ecs stop-task --profile ${profile} --cluster ${cluster} --task ${task} --query 'task.lastStatus' --output text"
