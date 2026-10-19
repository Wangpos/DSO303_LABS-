# Lab 05 - ALB - Notes

**Support path:** A or B (to be confirmed). All 10 Step 3 probes answered SUPPORTED. Final path decided after Step 5 (does create-load-balancer return an ARN?) and Step 12 (does curl connect?).

## Step 3 probe output

```
== Elastic Load Balancing v2 ==
elbv2 describe-load-balancers                    SUPPORTED
elbv2 create-load-balancer (skeleton)            SUPPORTED
elbv2 describe-target-groups                     SUPPORTED
elbv2 create-target-group (skeleton)             SUPPORTED
elbv2 describe-listeners (bad arn)               SUPPORTED
elbv2 describe-account-limits                    SUPPORTED
== ECS integration ==
ecs update-service (skeleton)                    SUPPORTED
ecs describe-services                            SUPPORTED
== Already used in Labs 1 to 4 ==
ec2 describe-security-groups                     SUPPORTED
ec2 describe-subnets                             SUPPORTED
```

Public subnets are in two different AZs: subnet-0c2aeee0 (us-east-1a, 10.0.1.0/24) and subnet-ccb62227 (us-east-1b, 10.0.2.0/24).

## Step 4 "Your turn" - HTTPS: the two missing things

## Step 6 "Your turn" - matcher (a) and (b)

## Step 10 - in-place update or fallback?

## Step 11 - ECS health vs target health table

## Step 11 "Your turn" - what you would do by hand without service registration

## Step 12 - which proof I obtained (data path or control plane)

## Step 13 - the expected verify-lab-04.sh failure

## Floci limitations hit (and what real AWS would do)

- **EC2 instances stopped after a Floci restart.** At Step 2, verify-lab-03.sh reported `FAIL usms-web-01 is running` (PASS=35 FAIL=1). Both usms-web-01 and usms-db-01 were `stopped`. I started them with `aws ec2 start-instances`, after which verify-lab-03.sh reported PASS=36 FAIL=0. Real AWS: instances keep running unless someone stops them.
- **ELBv2 does not validate ARNs.** `aws elbv2 describe-listeners --load-balancer-arn probe` returned `{"Listeners": []}` instead of a ValidationError, so the "bad arn" probe says SUPPORTED because Floci accepted a fake ARN, not because it rejected it. Real AWS returns a ValidationError for a malformed ARN.

## Section 11 - observed vs reasoned about, for MY build

## Review questions (Section 14)
### Q1
### Q2
### Q3
### Q4
### Q5
### Q6
### Q7
