# Lab 01: Review Questions Answers

### 1. Trust vs. Permissions
What is almost certainly missing is a **Trust Policy** (AssumeRole Policy Document). 

IAM separates these into two distinct documents to adhere to the principle of least privilege and separate **who can assume the role** (authentication/trust) from **what the role can do once assumed** (authorization/permissions). The Trust Policy dictates which principals (such as an EC2 service, a specific AWS account, or a federated user) are allowed to perform the `sts:AssumeRole` action. The Permissions Policy defines the API actions allowed on target resources after assuming the role. Without a valid Trust Policy, no entity can assume the role to utilize its attached permissions.

---

### 2. Explicit vs. Implicit Deny
Internally, the two `AccessDenied` failures differ based on how AWS IAM evaluates permissions:
* **Implicit Deny (`dynamodb:PutItem`):** The policy simply does not grant permission for `dynamodb:PutItem`. By default, all IAM actions are implicitly denied unless explicitly allowed by an `Allow` statement.
* **Explicit Deny (`iam:CreateUser`):** The policy contains an explicit `"Effect": "Deny"` statement targeting `iam:CreateUser` (or all IAM user management actions).

**How to tell them apart:** You can tell them apart by auditing the attached policy JSON documents or testing with the IAM Policy Simulator. An implicit deny returns `AccessDenied` because no matching `Allow` rule exists, whereas an explicit deny returns `AccessDenied` because an explicit `Deny` rule overrides any present or future `Allow` statements.

**Why the fix differs:**
* To fix the **implicit deny** for `dynamodb:PutItem`, you add an `Allow` statement granting the action.
* To fix the **explicit deny** for `iam:CreateUser`, adding an `Allow` statement will not work because an explicit `Deny` always takes precedence over an `Allow`. You must locate and remove or modify the explicit `Deny` statement itself.

---

### 3. Roles Over Keys
Attaching `usms-ec2-app-role` directly to the EC2 instance (via an Instance Profile) is significantly more secure than embedding `usms-dev-01`'s long-lived access key in application configuration files for two distinct reasons:

1. **Automatic Credential Rotation & Temporary Duration:** IAM Roles issue temporary, short-lived credentials via AWS Security Token Service (STS) that automatically rotate periodically. If an attacker breaches the instance file system, stolen credentials expire rapidly. In contrast, hardcoded access keys remain valid indefinitely until manually revoked.
2. **Elimination of Credential Exposure Risks:** Hardcoded keys inside codebases or configuration files run a high risk of being accidentally committed to public version control (e.g., GitHub), leaked through log outputs, or read by unauthorized local developers. Instance profile role credentials are retrieved securely directly from host metadata endpoints at runtime without ever appearing in source code.

---

### 4. The S3 ARN Trap
The downloads fail because S3 operations distinguish between **bucket-level actions** and **object-level actions**, but the student applied a single bucket resource ARN (`arn:aws:s3:::usms-student-data`) to both.

* `s3:ListBucket` operates on the **bucket itself** (`arn:aws:s3:::usms-student-data`) to list the contents inside.
* `s3:GetObject` operates on **objects inside the bucket** (`arn:aws:s3:::usms-student-data/*`) to download files.

Applying `s3:GetObject` to `arn:aws:s3:::usms-student-data` evaluates as attempting to download the bucket container itself as a file, which fails.

**Corrected Resource Values:**
* For `s3:ListBucket`: `"Resource": "arn:aws:s3:::usms-student-data"`
* For `s3:GetObject`: `"Resource": "arn:aws:s3:::usms-student-data/*"`

---

### 5. The Floci Illusion
Command execution success in a simulated local environment proves that CLI syntax was accepted, but it is **not evidence that IAM policies are correctly scoped or follow least-privilege principles**. Local emulation tools like Floci may bypass strict IAM evaluation engines or accept overly permissive wildcard rules (`*`) that an enterprise AWS environment would block or expose to security risks.

**Two concrete techniques to gain confidence before deploying to real AWS:**
1. **AWS IAM Policy Simulator / Access Analyzer:** Run policies through the IAM Policy Simulator or AWS IAM Access Analyzer to statically analyze policy syntax, detect overly broad permissions, and verify exact action-to-resource authorization boundaries without affecting live infrastructure.
2. **Least-Privilege Integration Testing in a Sandbox Account:** Deploy the policies to an isolated, real AWS sandbox account with automated integration test suites. Verify that required actions succeed while intentionally executing unauthorized calls to confirm that unauthorized actions are correctly blocked.

---

### 6. The Persistence Trap
Three independent reasons why IAM users vanished despite using `--persist ~/floci-data`:

1. **Volume Mount Misconfiguration:** The local path `~/floci-data` was specified on host startup, but it was not correctly mapped to the internal container directory where LocalStack actually writes its state database.
2. **Container Force Kill / Unclean Shutdown:** The container process was abruptly terminated (e.g., `kill -9` or system crash) before Floci flushed in-memory state changes to the disk directory.
3. **Directory Permissions Issue:** The user account running Docker lacked write permissions on `~/floci-data`, causing state persistence writes to fail silently in the background while the container ran in RAM.

**Single Test Catching it in Under a Minute:**  
Run a rapid restart smoke-test: Create a test resource (e.g., `aws iam create-user --user-name test-user`), restart the container (`docker restart floci`), and immediately attempt to read it back (`aws iam get-user --user-name test-user`). If it returns `NoSuchEntity`, persistence is broken.

---

### 7. Configuration as Evidence
Having `docker-compose.yml` committed into version control serves as a critical **security and reproducibility property** because it transforms infrastructure setup into an audited, deterministic, and repeatable blueprint. Rather than relying on ephemeral environment state or undocumented manual steps, the configuration file guarantees that every developer and CI/CD runner provisions identical network mounts, environment flags, and volume bindings. 

An instructor or colleague can inspect the committed file to verify exact container flags, persistent storage mappings, port bindings, and environment variables—details that cannot be verified or audited from a ephemeral terminal command typed interactively by an engineer.