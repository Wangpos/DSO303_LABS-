#!/usr/bin/env bash
# Repair Lab 02: consolidate the USMS network into ONE VPC.
#
# Repeated Lab 02 attempts left three VPCs all tagged usms-vpc, and
# configs/lab-02.env had picked IDs from all three (subnets in one, security
# groups in another, IGW/NAT/route tables in a third). Floci accepted that;
# real AWS would have rejected the first run-instances in Lab 03.
#
# This script makes vpc-384d1580 - the one that already holds all four
# correctly-sized subnets and the S3 endpoint - complete, then regenerates
# configs/lab-02.env from lookups scoped to that VPC. The other two VPCs are
# left untouched.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

VPC=vpc-384d1580
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=USMS}${3:+,$3}]"; }
subnet() { aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$1" \
             --query 'Subnets[0].SubnetId' --output text; }
say() { printf '\n-- %s\n' "$1"; }

PUB_A=$(subnet usms-public-subnet-a);  PUB_B=$(subnet usms-public-subnet-b)
PRIV_A=$(subnet usms-private-subnet-a); PRIV_B=$(subnet usms-private-subnet-b)
echo "subnets: $PUB_A $PUB_B $PRIV_A $PRIV_B"

say "DNS hostnames on"
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames '{"Value":true}'
aws ec2 create-tags --resources "$VPC" --tags Key=Project,Value=USMS

say "public subnets auto-assign public IPv4"
for s in "$PUB_A" "$PUB_B"; do aws ec2 modify-subnet-attribute --subnet-id "$s" --map-public-ip-on-launch; done

say "internet gateway"
IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
        --query 'InternetGateways[0].InternetGatewayId' --output text)
if [ "$IGW" = "None" ]; then
  IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway usms-igw)" \
          --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
fi
echo "$IGW"

say "public route table"
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=usms-public-rt" \
           --query 'RouteTables[0].RouteTableId' --output text)
[ "$PUB_RT" != "None" ] || PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC" \
           --tag-specifications "$(tags route-table usms-public-rt '{Key=Tier,Value=public}')" \
           --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
# Drop any association a subnet still has to a route table in ANOTHER VPC
# (Floci permitted these during the earlier attempts; real AWS never would).
for s in "$PUB_A" "$PUB_B" "$PRIV_A" "$PRIV_B"; do
  for a in $(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$s" \
               --query "RouteTables[?VpcId!='$VPC'].Associations[?SubnetId=='$s'].RouteTableAssociationId[]" --output text); do
    aws ec2 disassociate-route-table --association-id "$a"
  done
done
for s in "$PUB_A" "$PUB_B"; do aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$s" >/dev/null; done
echo "$PUB_RT"

say "NAT gateway in usms-public-subnet-a"
NAT_EIP=$(aws ec2 allocate-address --domain vpc \
            --tag-specifications "$(tags elastic-ip usms-nat-eip)" --query 'AllocationId' --output text)
NAT=$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$NAT_EIP" \
        --tag-specifications "$(tags natgateway usms-nat)" --query 'NatGateway.NatGatewayId' --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT" || sleep 5
echo "$NAT ($NAT_EIP)"

say "private route table -> NAT, both private subnets"
PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=usms-private-rt" \
            --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT" >/dev/null
assoc=$(aws ec2 describe-route-tables --route-table-ids "$PRIV_RT" --query 'RouteTables[0].Associations[].SubnetId' --output text)
for s in "$PRIV_A" "$PRIV_B"; do
  grep -qw "$s" <<<"$assoc" || aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$s" >/dev/null
done
echo "$PRIV_RT"

say "S3 gateway endpoint onto the private route table"
S3EP=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" \
         "Name=service-name,Values=com.amazonaws.${AWS_REGION_COURSE}.s3" \
         --query 'VpcEndpoints[0].VpcEndpointId' --output text)
old_rts=$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$S3EP" --query 'VpcEndpoints[0].RouteTableIds' --output text)
aws ec2 modify-vpc-endpoint --vpc-endpoint-id "$S3EP" --add-route-table-ids "$PRIV_RT" \
  ${old_rts:+--remove-route-table-ids $old_rts} >/dev/null
aws ec2 create-tags --resources "$S3EP" --tags Key=Name,Value=usms-s3-endpoint Key=Project,Value=USMS
echo "$S3EP"

say "security groups"
APP_SG=$(aws ec2 create-security-group --vpc-id "$VPC" --group-name usms-app-sg \
           --description "USMS web tier" --tag-specifications "$(tags security-group usms-app-sg '{Key=Tier,Value=web}')" \
           --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --ip-permissions \
  'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTP from internet"}]' \
  'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTPS from internet"}]' \
  'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description="SSH - lab only; restrict to your IP on real AWS"}]' >/dev/null
DB_SG=$(aws ec2 create-security-group --vpc-id "$VPC" --group-name usms-db-sg \
          --description "USMS data tier" --tag-specifications "$(tags security-group usms-db-sg '{Key=Tier,Value=data}')" \
          --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$APP_SG,Description=\"PostgreSQL from web tier\"}]" >/dev/null
echo "$APP_SG $DB_SG"

say "private network ACL on both private subnets"
NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --tag-specifications "$(tags network-acl usms-private-nacl)" \
         --query 'NetworkAcl.NetworkAclId' --output text)
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number 100 --protocol -1 --cidr-block 0.0.0.0/0 --rule-action allow
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --egress  --rule-number 100 --protocol -1 --cidr-block 0.0.0.0/0 --rule-action allow
for s in "$PRIV_A" "$PRIV_B"; do
  cur=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$s" \
          --query "NetworkAcls[0].Associations[?SubnetId=='$s'].NetworkAclAssociationId | [0]" --output text)
  aws ec2 replace-network-acl-association --association-id "$cur" --network-acl-id "$NACL" >/dev/null
done
# Floci drops tag-specifications on create-network-acl; tag explicitly.
aws ec2 create-tags --resources "$NACL" --tags Key=Name,Value=usms-private-nacl Key=Project,Value=USMS
echo "$NACL"

say "regenerate configs/lab-02.env"
cat > configs/lab-02.env <<EOF
# Lab 02 - VPC and networking outputs
# Regenerated on $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/utilities/repair-lab-02-network.sh
# Every ID below belongs to $VPC. Contains IDs only. NO SECRETS. Safe to commit.

export USMS_VPC_ID=$VPC
export USMS_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].CidrBlock' --output text)
export USMS_IGW_ID=$IGW
export USMS_PUBLIC_SUBNET_A=$PUB_A
export USMS_PUBLIC_SUBNET_B=$PUB_B
export USMS_PRIVATE_SUBNET_A=$PRIV_A
export USMS_PRIVATE_SUBNET_B=$PRIV_B
export USMS_PUBLIC_RT=$PUB_RT
export USMS_PRIVATE_RT=$PRIV_RT
export USMS_APP_SG=$APP_SG
export USMS_DB_SG=$DB_SG
export USMS_PRIVATE_NACL=$NACL
export USMS_NAT_GW=$NAT
export USMS_NAT_EIP_ALLOC=$NAT_EIP
export USMS_S3_ENDPOINT=$S3EP
export USMS_AZ_A=us-east-1a
export USMS_AZ_B=us-east-1b
EOF
cat configs/lab-02.env
