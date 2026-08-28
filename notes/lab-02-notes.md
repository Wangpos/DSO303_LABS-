# Lab 02: Review Questions Answers

### 1. What Makes a Subnet "Public"
What is missing from the subnet is an **Internet Gateway (IGW) attached to the VPC** and a **route table entry that directs default outbound traffic (`0.0.0.0/0`) to that IGW target**. 

The subnet name (`public-subnet`) and tag (`Tier=public`) are merely cosmetic metadata for human organization; AWS routing logic ignores them entirely when evaluating network paths. Enabling auto-assign public IPv4 assigns a public IP address to launched instances, but a public IP alone cannot achieve internet connectivity without an egress path. Without an explicit default route pointing to an attached Internet Gateway, packets addressed to the internet have nowhere to go and are dropped locally within the VPC.

---

### 2. Stateful Security Groups vs. Stateless Network ACLs
Consider a student logging into the USMS web portal:
* **Leg 1 (Inbound Request):** The student's browser sends traffic from an ephemeral client port (e.g., port 53421) to destination port 443 (HTTPS) on the USMS web server in `usms-public-subnet-a`.
* **Leg 2 (Outbound Response):** The web server responds back from port 443 to the student's client IP on ephemeral port 53421.

Because **Security Groups are stateful**, you only write **1 rule**: an Ingress rule allowing inbound TCP traffic on port 443. The Security Group tracks the active connection state automatically and allows the outbound response back to port 53421 without requiring an explicit egress rule.

Because **Network ACLs are stateless**, you must write **4 explicit rules** across ingress and egress lists:
1. Inbound rule allowing destination port 443.
2. Outbound rule allowing return traffic to client ephemeral ports (1024–65535).
3. Inbound rule allowing response traffic on ephemeral ports (if the server acts as an outbound client).
4. Outbound rule allowing outgoing requests on port 443.

**Which to reach for first:** I would reach for **Security Groups first**. They operate at the instance level, require far fewer rules due to state tracking, and reduce human error. Network ACLs should be reserved as a secondary subnet-wide defense for broad IP blocking (e.g., stopping malicious CIDR blocks at the subnet perimeter).

---

### 3. Security Group Referencing vs. Hardcoded CIDRs
Referencing `usms-app-sg` inside `usms-db-sg` evaluates traffic based on logical identity rather than network IP placement. Two concrete changes to the USMS architecture that would break a hardcoded CIDR rule (`10.0.1.0/24`) while leaving the group-referenced version working are:

1. **Subnet Re-IPing or Secondary CIDR Expansion:** If `usms-public-subnet-a` is migrated or expanded into a new subnet range (such as `10.0.5.0/24`), database traffic from instances using the new IP range will be rejected by the hardcoded `10.0.1.0/24` rule, whereas the security group reference adapts dynamically regardless of the new IP range.
2. **Multi-AZ Auto Scaling:** If USMS application instances scale out into `usms-public-subnet-b` (`10.0.2.0/24`) during high load, instances in Subnet B will fail to connect to PostgreSQL under the single-subnet CIDR rule. The security group reference allows connection regardless of which subnet or Availability Zone the instance is running in.

---

### 4. NAT Gateway Placement and Availability Boundaries
A NAT Gateway performs Source Network Address Translation (SNAT) to allow private instances outbound internet access. It **must sit in a public subnet** because it requires a direct route to an Internet Gateway (`0.0.0.0/0 -> IGW`) and a public Elastic IP address to communicate with external endpoints.

If Availability Zone `us-east-1a` fails, the single NAT Gateway in `usms-public-subnet-a` becomes unreachable. Consequently, private instances in `usms-private-subnet-b` (`us-east-1b`) lose outbound internet access, even though their local host hardware in `us-east-1b` is healthy. 

This demonstrates that the **availability boundary of a NAT Gateway is a single Availability Zone (AZ)**, not the entire VPC. High-availability architecture requires deploying one NAT Gateway per active Availability Zone.

---

### 5. S3 Gateway Endpoint Routing, Cost, and Exposure
* **Path WITH Gateway Endpoint:** Private Instance $\rightarrow$ Private Route Table (`usms-private-rt`) $\rightarrow$ S3 Gateway Endpoint $\rightarrow$ AWS Internal Backbone Network $\rightarrow$ `usms-student-data` S3 Bucket.
* **Path WITHOUT Gateway Endpoint:** Private Instance $\rightarrow$ NAT Gateway (`usms-public-subnet-a`) $\rightarrow$ Internet Gateway (`usms-igw`) $\rightarrow$ Public Internet $\rightarrow$ AWS Public Regional S3 Endpoint $\rightarrow$ `usms-student-data` S3 Bucket.

**Impact of the Path Without Endpoint:**
* **Exposure:** Traffic leaves the isolated AWS private network and routes across public internet pathways to reach S3 public IP addresses, exposing student transcript data to transit risks.
* **Cost:** NAT Gateways charge hourly usage plus per-gigabyte data processing fees for all outbound traffic. In contrast, **S3 Gateway Endpoints are completely free of charge** and keep traffic inside the AWS internal network.

---

### 6. Persistence Verification vs. Shell Memory
Querying the VPC by tag (`Name=usms-vpc`) after restarting Floci proves that **the VPC metadata was written to host disk storage and successfully reloaded upon container restart**. 

Had we simply reused the `$VPC_ID` variable stored in local bash memory, it would only prove that our terminal retained a text string in RAM—it would obscure whether the container actually saved and reloaded the state. In Lab 1 Step 14, restarting a container without volume persistence wiped all IAM data from memory while keeping old shell variables active, causing silent failures. Querying by tag ensures physical state persistence across lifecycle events.

---

### 7. Control Plane Verification in Floci
Even though Floci (LocalStack) does not actively filter data-plane network packets using security groups, we can be confident in our rules because **the AWS API control plane records and validates rule structures**. Running `aws ec2 describe-security-groups` returns the exact JSON schema configured on AWS servers.

* **Mistake caught by verification:** Control-plane errors such as authorizing port `8080` instead of `443`, specifying protocol `udp` instead of `tcp`, or leaving out ingress permissions for `usms-app-sg`.
* **Mistake NOT caught by verification:** Data-plane issues such as an internal host OS firewall (`iptables`/`ufw`) blocking port 443, a web server listening on `127.0.0.1` instead of `0.0.0.0`, or host network adapter failures that drop physical packets before reaching the security boundary.