#!/usr/bin/env bash
# Print the ResourceLabel that Application Auto Scaling's ALBRequestCountPerTarget metric needs:
#   app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>
# Usage: usms-resource-label.sh [lb-name] [tg-name]   (defaults: usms-enrolment-alb usms-enrolment-tg)
# Both ARNs are looked up from the API every time; nothing is read from configs/lab-05.env and no
# identifier is hard-coded. Read-only. Prints the label on stdout, or an error on stderr and exits 1.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
export AWS_PAGER=""

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

die() { echo "usms-resource-label: $*" >&2; exit 1; }

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
           --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) || die "load balancer $LB_NAME not found"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
           --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || die "target group $TG_NAME not found"
case "$LB_ARN" in *:loadbalancer/*) ;; *) die "unexpected load balancer ARN: '$LB_ARN'" ;; esac
case "$TG_ARN" in *:targetgroup/*)  ;; *) die "unexpected target group ARN: '$TG_ARN'" ;; esac

# The two suffixes need different treatment. The LB half must NOT contain the word "loadbalancer",
# so everything up to and including ":loadbalancer/" is stripped. The TG half MUST start with the
# word "targetgroup", so it is stripped the same way and then the word is put back.
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"          # app/usms-enrolment-alb/<id>
TG_SUFFIX="targetgroup/${TG_ARN#*:targetgroup/}"  # targetgroup/usms-enrolment-tg/<id>
LABEL="$LB_SUFFIX/$TG_SUFFIX"

# Validate before printing: both names present, exactly six segments, first segment app
# (an Application Load Balancer; a Network Load Balancer would give net).
IFS=/ read -r -a SEG <<< "$LABEL"
[ "${#SEG[@]}" -eq 6 ]           || die "expected 6 /-separated segments, got ${#SEG[@]}: $LABEL"
[ "${SEG[0]}" = "app" ]          || die "first segment is '${SEG[0]}', expected app: $LABEL"
[ "${SEG[1]}" = "$LB_NAME" ]     || die "segment 2 is not $LB_NAME: $LABEL"
[ "${SEG[3]}" = "targetgroup" ]  || die "segment 4 is not targetgroup: $LABEL"
[ "${SEG[4]}" = "$TG_NAME" ]     || die "segment 5 is not $TG_NAME: $LABEL"

echo "$LABEL"
