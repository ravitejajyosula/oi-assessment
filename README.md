# DevOps Technical Challenge

## Scenario

You are tasked with implementing a platform to support a microservices architecture composed of a backend service, frontend service, and PostgreSQL database with the following requirements:
 - Automated Deployment
 - Fault Tolerant / Highly Available
 - Secure
 - Autoscaling

## Infrastructure Platforms 
### Approach-1   On-Premises Environment 
## Visual Architecture

Refer to `architectural-diagram.jpg`:

![alt text](architectural-diagram.jpg)

* Two clusters (left/right) with HA between them
* HAProxy + Keepalived for virtual IP and probe-based failover
* GitOps-based deployments through ArgoCD
* External Observability stack 
* Streaming replication for state sync (e.g., PostgreSQL)


---

## Assumptions for Approach 1

1. **Greenfield Deployment**: This setup assumes a brand-new environment with no pre-existing infrastructure, Kubernetes installations, or CI/CD pipelines. All configurations, networking, DNS, and VM templates are provisioned from scratch as part of this deployment.

2. **On-Premises Focus**: The infrastructure is built primarily on VMware vSphere, indicating an on-premise data center environment with enterprise-grade virtualization features.

3. **Network Reachability**: Regions A and B are connected via VPN, direct fiber, or routed WAN to support Active-Active synchronization and observability.

4. **Platform Team Access**: Platform engineering has full access to DNS, firewall, load balancer, and IPAM configurations to support service discovery, MetalLB, and ingress routing.

5. **Secrets Management**: Vault is already set up and accessible for secure handling of sensitive data.

6. **Git Integration**: Platform team has access to Github for setting up repositories for Terraform, Ansible, and Helm charts 
7. **Automation Service Account**: A RBAC is already in place with required access to every system. 
8. Database Failover or Active/Active Setup is already in Place per region and cross region

---

## 1. **Infrastructure Platform**

#### Chosen Platform: **VMware vSphere**

* **Reason**: Enterprise-grade virtualization that supports high availability, snapshots, backup integrations, antiaffinity rules, DRS and robust networking features.
* **Deployment Environment**:

  * Two separate clusters (e.g., Region A and Region B)
  * Each region hosts:

    * 3 Control plane nodes (masters)
    * 3 Worker nodes
    * Deployed on dedicated ESXi hosts     * 
* **High Availability**:

  * Anti-affinity rules prevent co-scheduling of critical nodes on the same host.
  * HAProxy + Keepalived provides a virtual IP for API access.

#### Database Setup 
We will discuss two environment approaches for databases below:
- Non critical or Non production environment => we will use statefulset
- Production or Critical environment => we should use a HA based DB deployment replication. 

**Why did I choose VM over stateful set in production**
- To reduce the single point of failure on the cluster. If something happens to cluster we can easily deploy stateless applications on another clusters make them available in shorter time. 
- In Active-Active Setup DB replication places a vital role and Handling it over PVC(storage) replication is quite challenging and not recommended.
- By Design DB systems are complex in design, which needs high accuracy with Storage IOPS,  So VMs offer more better IOPS I/O Performance along with custom os level tuning , Network Stability and DB certified HA Capabilities 

---
### 2. **Orchestration Technology and Components**

### Chosen: **Kubernetes (K8s)**

#### Key Components:
* **Source Code Management:** Github
* **Control Plane**: 3 vms running control plane components like kube-apiserver, controller-manager, scheduler, etcd on each region 
* **Nodes**: Minimum 3 vms running worker servives like kubelet, kube-proxy, containerd runtime
* **CNI Plugin**: Calico for network policies and IP management
* **Ingress**: NGINX Ingress Controller exposed via MetalLB (BGP mode)
* **Storage**: CSI-enabled storage like Longhorn or Ceph via Rook. 
* **Kubernetes Hardening**: Ansible for Node level hardening and Kyverno for cluster level hardening 
* **GitOps Engine**: ArgoCD
* **Security & Policy Enforcement**: Kyverno
* **Monitoring**: Internal Prometheus shipping logs to External Prometheus + Grafana
* **Logging**: External EFK (Elasticsearch, Fluent-bit, Kibana)
* **HA Management for API**: HAProxy + Keepalived
---
Let me divide the whole setup in day0, day1 and day2. 

## Day0 and Day1 Operations 

### 3. **Infrastructure Automation with Terraform**

#### Summary:

* Uses `vsphere_virtual_machine` to provision control plane and worker nodes.
* Inputs fetched dynamically from environment-specific JSON files.
* Anti-affinity rules enforced using `vsphere_compute_cluster_vm_anti_affinity_rule`.
* Remote state stored securely in AWS S3 with locking via DynamoDB.

[Key Code Snippet](on-premises/platform-engine/README.md#Terraform-sample-snippet)

Key Considerations:

* Secrets stored in Vault and fetched at runtime kept as environmental variables so that they dont get stored in state file 
* Backend state encryption enabled in S3
* PR validation includes `terraform fmt` and `terraform validate`
* Jenkins pipeline stages for validation and apply
---

### 4. **Cluster, Compliance and Observability Automation**

#### Tools: **Ansible, Argocd, Helm, Kyverno, Metallb **

##### Roles:

* `common`: Disables swap, installs base packages, sets up containerd, kubelet, kubeadm, kubectl
* `k8s-engine`: Initializes control plane on master1, joins others
* `post-cluster-provisioning`: HAProxy, Keepalived, Ingress, MetalLB, ArgoCD, Kyverno, CSI

[Detailed code Snippet](on-premises/platform-engine/README.md#Ansible)

### ArgoCD deployment for GitOps:

* ArgoCD is deployed as an Ansible-managed resource
* Applications (e.g., Kyverno) defined as ArgoCD Application CRs and policies from Centralize Kyverno policy helm chart
* Helm-based values used for templating from Centralize Kyverno policy templates
* Day1 key solutions like Observability stack and Compliance stack will be deployed as a application making the cluster always compliant. 
  
[Detailed code Snippet](on-premises/platform-engine/README.md#Ansible-tasks-for-cluster-prereqs)

---

#### 5. **Release Lifecycle Strategy**
##### Triggers: 
**Option-1**: I preferred manual pipeline execution for day0 operations because these changes are big and sometimes disruptive in nature.

**Option-2**: Github webhook whenever files are committed to jenkins github webhook. Pipeline to trigger on githubPush event and changeset  is 3 files(workers.json,master.json and haproxy.json) under terraform/environment directory 

**Detailed steps inside Jenkins Pipeline**

```
Vault auth with Jenkins Credentials 
↓
Infrastructure provisioning Terraform (Validate, plan and then apply)
↓
Ansible Inventory Generation 
↓
Cluster setup using Ansible roles(common and K8S engine)
↓
Day1 Operations-1(Cluster Hardening of Control plane files and Kyverno)
↓
Day 1 Operations-2 (ArgoCD Vault Integration, Ingress creation and Argocd Setup)
↓
Day 1 Operations-3 (Cluster Hardening with Kyverno center policy helm chart, Observability Setup and Parent app creation for Actual workload Applications )
```
Detailed code snippets for [Day0](on-premises/platform-engine/README.md#Day0) and [Day1](on-premises/platform-engine/README.md#Day1) 

---

## [Day2 Operations](#on-premises/app-deployment-engine/README.md#day2-operations)


##### Applications deployment:

* Microservices deployed via ArgoCD
* Separate Github branches for `dev`, `qa`, `prod`
* Sync policies enable auto-healing, auto-prune
* Values file per environment for Helm charts

#### New applications or services on boarding process. 
* whenever new application or service needed to be deployed on the cluster users need to add below lines app-deployment-engine repository under `argocd-apps/config/values.yaml` so that the application or service will be automatically deployed by argocd. 
* I have also chosen standard helm charts for deployments and statefulset which gives more unified and granular control over environment, in future if we need to add any custom annotation we can directly add to helm for whole environment. (recommended not mandated to developers)

```yaml
apps:
  - name: <<user application name >>
    valuesFile: <<user application values.yaml path >>
    chartFile: << user chart location >>
    namespace: <<target namespace >>
    repoURL: <<repo url>
    targetRevision: <<branch>>
    #optional 
    labels:
      <<custom labels for argocd applications >>
## Example 
  - name: app3
    valuesFile: app3/config/values.yaml
    chartFile: frontend-app3/
    namespace: app3-ns
    repoURL: git@github.oi.com:platform/oi-my-app3.git
    targetRevision: uat
    labels:
      deployed-for: uat-environment

```
### Secrets Handling:

* Vault-managed credentials fetched dynamically inside cluster using argocd vault injector plugin(AVP) configuration. 

---

## 6. **Testing Strategy**

### Infrastructure Testing:

* Terraform validation through `terraform validate` & `plan`
* Validation of every task in ansible before next task
* Using block and rescue in ansible to get detailed cases if not handled.
* Ansible dry-run mode (`--check`) on staging environment
* Health probes via HAProxy ensure API server readiness
* Liveness and Readiness probes for every object in K8S using Kyverno policy. 

### Cluster Testing:

* Cluster healthz validation once cluster is fully ready using `https://kubernetes.default.svc/healthz`
* API server responsiveness (`kubectl get nodes`)
* Node readiness checks and alerts in grafana
* Calico pod-to-pod communication tests and Service communication validation
* CSI volume provisioning tests by creating test volumes 

### Integration Tests:

* Ingress availability (e.g., ArgoCD Integration as part of Day1)
* Prometheus scraping all nodes
* Fluent-bit log collection
* ArgoCD application sync status

---

## 7. **Monitoring and Observability**

### Stack:
For the Production grade cluster its always recommended to have hybrid stack for monitoring and logging. 
Hybrid stack is recommended because of 
  - In Multi-cluster environments external observability gives more flexibility giving full environment access in one screen
  - Simplifies the full view of cluster to monitoring team and SRE team for quick and faster actions 
  - Easy to deploy because you need install only minimal components on the cluster and also they are common across clusters (fluent-bit and Metrics exporter)
* **Prometheus**: Cluster metrics (Node, Pod, Container, etc.)
* **External Grafana**: Dashboards for node, pod health, resource usage
* **Fluent-bit**: Fluent bit daemonsets on the cluster log shipping 
* **Alert manager**: Triggers alerts based on thresholds
* **Kube-state-metrics**: Detailed resource metrics
* **EFK Stack**:
  * **Elasticsearch**: Central log storage
  * **Fluent-bit**: Log forwarding
  * **Kibana**: Visualization & search

### Alerts:

* API unresponsive
* Node NotReady
* Pod CrashLoopBackOff
* PVC provisioning failures
* Node Average utilization alerts 
* Kyverno Policy violation alerts if any 

### Health Checks:

* HAProxy config includes HTTP probes to `/healthz` endpoint
* Keepalived monitors HAProxy to maintain VIP
* Liveness and Readiness probes


---

### Security and Compliance 

* Day0 ready CIS benchmarked cluster 
* Custom centralized Kyverno policy to make sure limits and request are set 
* HPA compliance validation by setting maximum number of pods to scale 
* Github signed commits. So no manual commits will be synced by argocd 
* Sonarqube for scanning the code for vulnerabilities and security leakages
* Image signing once image created you can use tools like 

### Further recommendations 
* Developers should get rid of deployments and start using argocd rollouts so that they can use release strategy like canary or blue green.

---

### Approach-2 Public Cloud Platform

If we are using public cloud platforms AWS in this case. 

The tools will slightly change keeping approach constant. 
* Deployment Environment will change multiple Availability Zones (AZs) for high availability
* Database Setup: Amazon RDS for PostgreSQL (managed service)
* Key Components:
  * **Control Plane**: EKS (managed by AWS, no manual VM provisioning)
  * **Nodes** EC2 instances managed by EKS (Managed Node Groups)
  * **CNI Plugin**: Amazon VPC CNI
  * **Ingress**: AWS Load Balancer ALB 
  * **Storage**: EBS 
  * **Kubernetes Hardening**: EKS best practices, Kyverno (same)
  * **Security & Policy Enforcement**: IAM along with Kyverno'
  * **Monitoring**: AWS Cloud Watch and Fluent-bit
  * **Secrets Management**: Secrets in AWS Secrets Manager/Parameter Store.
#### DAY0 and Day1 
We will not use ansible for kubernetes cluster building instead we will use terraform or cloudformation for building EKS cluster.   

All other Stack including monitoring parameters will look almost same.

---