#!/usr/bin/env bash
# USMS exposure report (Lab 09 Exercise 3).
#
# Classifies every network interface in usms-vpc, one line each:
#   EXPOSED   the subnet routes 0.0.0.0/0 to an internet gateway, the interface has a
#             public address, and a security group admits something from the internet
#   LIMITED   as EXPOSED, but every internet-sourced ingress rule names a narrow CIDR
#             (a /32 admin address, say) rather than 0.0.0.0/0
#   ISOLATED  no internet gateway route on its subnet, or no public address
#   UNKNOWN   a security group could not be read, so no verdict is safe
#
# The verdict uses ONLY the interface's subnet route table, its public address and its
# security groups' INGRESS rules. Never names, tags or descriptions (they appear in the
# label column only), and never egress: Exercise 1's egress changes cannot move a verdict.
#
# Unlike Step 17's matrix (security groups only), this models both axes: routing and rules.
#
# Read-only. No arguments. Runs from any directory. Writes outputs/lab-09-exposure.json.
#
# set -e is deliberately OFF. This is a report: one failed describe call (a group that
# cannot be read, an interface that vanished mid-run) must become an UNKNOWN line, not
# abort the run and hide every other interface. Each call's result is checked explicitly.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 2
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
[ -n "$VPC" ] && [ "$VPC" != "none" ] || { echo "USMS_VPC_ID is not set - source configs/lab-02.env" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {   # file, fallback JSON, command...
  local f="$1" empty="$2"; shift 2
  "$@" --output json > "$TMP/$f" 2>/dev/null || echo "$empty" > "$TMP/$f"
}
fetch vpc.json  '{"Vpcs":[]}'              aws ec2 describe-vpcs --vpc-ids "$VPC"
fetch eni.json  '{"NetworkInterfaces":[]}' aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC"
fetch sg.json   '{"SecurityGroups":[]}'    aws ec2 describe-security-groups    --filters "Name=vpc-id,Values=$VPC"
fetch rt.json   '{"RouteTables":[]}'       aws ec2 describe-route-tables       --filters "Name=vpc-id,Values=$VPC"
fetch ec2.json  '{"Reservations":[]}'      aws ec2 describe-instances          --filters "Name=vpc-id,Values=$VPC"
fetch nat.json  '{"NatGateways":[]}'       aws ec2 describe-nat-gateways       --filter  "Name=vpc-id,Values=$VPC"

python3 - "$TMP" "outputs/lab-09-exposure.json" << 'PY'
import ipaddress, json, os, subprocess, sys

tmp, out_json = sys.argv[1], sys.argv[2]
load = lambda f, k: json.load(open(os.path.join(tmp, f))).get(k, [])
vpcs   = load("vpc.json", "Vpcs")
enis   = load("eni.json", "NetworkInterfaces")
groups = {g["GroupId"]: g for g in load("sg.json", "SecurityGroups")}
rts    = load("rt.json", "RouteTables")
insts  = {i["InstanceId"]: i for r in load("ec2.json", "Reservations") for i in r.get("Instances", [])}
nats   = load("nat.json", "NatGateways")
vpc_cidrs = [ipaddress.ip_network(v["CidrBlock"]) for v in vpcs if v.get("CidrBlock")]

# ---- route table per subnet: explicit association, else the VPC's main table ----
main_rt, by_subnet = None, {}
for rt in rts:
    for a in rt.get("Associations", []):
        if a.get("Main"):
            main_rt = rt
        if a.get("SubnetId"):
            by_subnet[a["SubnetId"]] = rt

def route_for(subnet):
    rt = by_subnet.get(subnet)
    how = "explicit"
    if rt is None:
        rt, how = main_rt, "main (no explicit association)"
    if rt is None:
        return None, "no route table found", False
    igw = any(r.get("DestinationCidrBlock") == "0.0.0.0/0" and str(r.get("GatewayId", "")).startswith("igw-")
              for r in rt.get("Routes", []))
    return rt["RouteTableId"], how, igw

# ---- security groups: from the VPC cache, else fetched one by one ----
def group(gid):
    if gid in groups:
        return groups[gid]
    p = subprocess.run(["aws", "ec2", "describe-security-groups", "--group-ids", gid, "--output", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    try:
        g = json.loads(p.stdout)["SecurityGroups"][0]
    except Exception:
        return None
    groups[gid] = g
    return g

def internet_sources(g):
    """Ingress rules whose source is outside every VPC CIDR. Returns (open_to_all, [(port, cidr)])."""
    found, wide = [], False
    for p in g.get("IpPermissions", []):
        lo, hi = p.get("FromPort"), p.get("ToPort")
        port = "all" if lo is None or p.get("IpProtocol") == "-1" else (str(lo) if lo == hi else f"{lo}-{hi}")
        for r in p.get("IpRanges", []):
            net = ipaddress.ip_network(r["CidrIp"], strict=False)
            if any(net.subnet_of(v) for v in vpc_cidrs if net.version == v.version):
                continue
            found.append((port, r["CidrIp"]))
            wide = wide or net.prefixlen == 0
    return wide, found

def label(eni, inst):
    if inst:
        name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), None)
        if name:
            return name
    return eni.get("Description") or eni.get("InterfaceType") or eni["NetworkInterfaceId"]

def public_address(eni, inst):
    pub = (eni.get("Association") or {}).get("PublicIp")
    if not pub and inst:
        pub = inst.get("PublicIpAddress")
    return pub

def classify(eni_id, subnet, gids, pub):
    rt, how, igw = route_for(subnet)
    if not igw:
        return "ISOLATED", f"no igw route on subnet ({rt}, {how})"
    if not pub:
        return "ISOLATED", "igw route, but no public address"
    wide, srcs, unread = False, [], []
    for gid in gids:
        g = group(gid)
        if g is None:
            unread.append(gid)
            continue
        w, s = internet_sources(g)
        wide, srcs = wide or w, srcs + s
    if unread:
        return "UNKNOWN", f"igw route + public address; group(s) {','.join(unread)} could not be read"
    if not srcs:
        has_any = any((group(g) or {}).get("IpPermissions") for g in gids)
        if not has_any:
            # Defended verdict: still EXPOSED. Routing and addressing (two of three controls) are
            # already absent; the only thing left is a security group with no rule, and one
            # authorize call - the most common change in this whole course - makes it reachable.
            return "EXPOSED", "igw route + public address, but no ingress rule at all (one control left)"
        return "ISOLATED", "igw route + public address, but ingress admits only VPC sources"
    ports = ",".join(sorted({p for p, _ in srcs}, key=lambda x: (len(x), x)))
    cidrs = ",".join(sorted({c for _, c in srcs}))
    if wide:
        return "EXPOSED", f"igw route + sg allows {ports} from {cidrs}"
    return "LIMITED", f"igw route + sg allows {ports} only from {cidrs}"

rows = []
listed = set()
for e in sorted(enis, key=lambda x: (x.get("SubnetId", ""), x.get("PrivateIpAddress", ""))):
    listed.add(e["NetworkInterfaceId"])
    iid = (e.get("Attachment") or {}).get("InstanceId")
    inst = insts.get(iid) if iid else None
    gids = [g["GroupId"] for g in e.get("Groups", [])]
    pub = public_address(e, inst)
    verdict, why = classify(e["NetworkInterfaceId"], e.get("SubnetId"), gids, pub)
    note = ""
    if iid and (inst is None or inst.get("State", {}).get("Name") == "terminated"):
        note = " [lingering: its instance is terminated or gone]"
    rows.append({"label": label(e, inst), "interface": e["NetworkInterfaceId"], "subnet": e.get("SubnetId"),
                 "private": e.get("PrivateIpAddress"), "public": pub, "groups": gids,
                 "verdict": verdict, "reason": why + note})

# NAT gateways own an interface; on some builds describe-network-interfaces does not list it.
for n in nats:
    if n.get("State") in ("deleted", "failed"):
        continue
    for a in n.get("NatGatewayAddresses", []):
        if a.get("NetworkInterfaceId") in listed:
            continue
        rt, how, igw = route_for(n.get("SubnetId"))
        pub = a.get("PublicIp")
        if igw and pub:
            verdict, why = "EXPOSED", "igw route + public address, but no ingress rule at all (one control left; NAT interfaces carry no security group)"
        else:
            verdict, why = "ISOLATED", "no igw route or no public address"
        rows.append({"label": n["NatGatewayId"], "interface": a.get("NetworkInterfaceId"), "subnet": n.get("SubnetId"),
                     "private": a.get("PrivateIp"), "public": pub, "groups": [],
                     "verdict": verdict, "reason": why + " [interface not listed by describe-network-interfaces]"})

print(f"== USMS exposure report - {vpcs[0]['VpcId'] if vpcs else '?'} ({', '.join(map(str, vpc_cidrs))}) ==")
print()
for r in rows:
    print(f"{r['label']:<22} {r['private'] or '-':<12} {r['public'] or '-':<15} {r['verdict']:<9} {r['reason']}")
print()
counts = {v: sum(1 for r in rows if r["verdict"] == v) for v in ("EXPOSED", "LIMITED", "ISOLATED", "UNKNOWN")}
print("  ".join(f"{k}={v}" for k, v in counts.items()) + f"  interfaces={len(rows)}")

os.makedirs(os.path.dirname(out_json), exist_ok=True)
json.dump({"vpc": vpcs[0]["VpcId"] if vpcs else None, "interfaces": rows, "counts": counts},
          open(out_json, "w"), indent=2)
PY
