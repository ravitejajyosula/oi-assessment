### VMware:

We will use Terraform to provision VMs on vmware. I have created sample code snippet for creating VM.

Anti affinity rules we must consider while creating VM. We must make sure all nodes are not scheduled on the same physical node. 

We can use `vsphere_compute_cluster_vm_anti_affinity_rule` module for creating anti affinity rule in vmware
### Day0
#### Terraform sample snippet 

``` hcl
provider "vsphere" {
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = false
}



# for getting data from vault 
# We will concatenate two lists workers and masters into one list so that we can create all the vms in one terraform 
locals {
  master_vms_raw = file("${path.module}/environment/masters.json")
  master_vms     = jsondecode(local.master_vms_raw)
  worker_vms_raw = file("${path.module}/environment/workers.json")
  worker_vms     = jsondecode(local.worker_vms_raw)
  all_vms_list = concat(local.master_vms, local.worker_vms)
  vm_configs = {
    for vm in local.all_vms_list : vm.name => vm
  }
}

resource "vsphere_virtual_machine" "vms" {
  for_each = local.vm_configs
  name             = each.key
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      linux_options {
        host_name = each.value.hostname
      }
    

      network_interface {
        network_id = data.vsphere_network.network.id
        ipv4_address    = each.value.ipv4_address
        ipv4_netmask    = var.ipv4_netmask
        dns_domain_list = [var.domain_name]
        dns_server_list = var.dns_server_list
        ipv4_gateway    = var.ipv4_gateway
      }
    }
  }

  num_cpus = each.value.cpu # Number of CPUs for the VM
  memory   = each.value.memory # Memory in MB for the VM
  guest_id = data.vsphere_virtual_machine.template.guest_id
  wait_for_guest_ip_timeout = 5 
  wait_for_guest_net_timeout = 5 
 # Primary disk
  disk {
    label            = "${each.key}-disk0"
    size             = 50
    unit_number      = 0
    thin_provisioned = true
  }
 # Secondary Disk
  disk {
    label            = "disk1"
    size             = 100
    unit_number      = 1
    thin_provisioned = true
  }
}


resource "vsphere_compute_cluster_vm_anti_affinity_rule" "anti_affinity_vms" {
  name        = "terraform-vms-anti-affinity-rule"
  cluster_id  = data.vsphere_compute_cluster.cluster.id
  virtual_machine_ids = [for vm in vsphere_virtual_machine.vms : vm.id]
  enabled     = true 
}

``` 
Other files are which are needed are `variables.tf` with all variables and `backend.tf` with state file backend configuration 

**Note**: We have to configure backend for storing the state file.  
Options 
1. We can use AWS S3 with dynamo DB for version management. (Most Preferred if Environment has connectivity to AWS )
   - We need to create a user in IAM and assign a custom policy which has access to S3 bucket and Dynamo DB
   - Create a access key and secret for the user 
   - store the access key and secret either in Vault or Jenkins credential manager or Github secrets 
   - We will fetch these credentials run time and set them in environmental variables for updating state
```
terraform {
    backend "s3" {
    bucket         = "oi-terraform-state-${var.cluster_name}" 
    key            = "k8s/${var.cluster_name}/terraform.tfstate"
    region         = "me-central-1"
    encrypt        = true
    dynamodb_table = "${var.cluster_name}" # For state locking
  }
}
```

2. We can deploy open source version Hashicorp consul in house and use the same for statement 
   - We should have to maintain the consul and if we are not using it for anything like service discovery 

##### Security and compliance 
-  We will fetch credentials like Vcenter username, Password run time from vault and keep them as environment variables preventing them to store in state file

```bash
export VSPHERE_USER="your-username"
export VSPHERE_PASSWORD="your-password"
export VSPHERE_SERVER="your-vcenter-server" # if not set via variable
``` 

-  We should also enable state file encryption at S3 level in bucket properties 
-  We have to add  terraform validate and terraform fmt commands to our stages in jenkins or github for proper validation 
- PR process should be followed for every merge with proper approvals 
----
#### Ansible 
Lets create a ansible playbook for configuring the cluster. 
We will create a multiple roles for whole set up of the cluster 
`rolename: common` 
`rolename: k8s-engine` 
`rolename: post-cluster-provisioning`

**common** role will have prereqs 
- swap off 
- stopping the firewalld 
- disabling Selinux 
- subscribing to repo if its internal 
- Deploy containerd module 
- install kubelet, kubeadm, kubectl 
- enable kubelet 

**k8s-engine**  role will have below deployments
- Setup the first master initialize the cluster. 
- Join the other two masters by storing the kubeadm join command from master1
- Join the workers to the clusters. 

**post-cluster-provisioning** role will have below deployments 

- Server side hardening of the cluster 
- HA proxy setup for API management 
- Ingress Deployment
- MetalLB Deployment
- ArgoCD Deployment
- Kyverno for Cluster hardening 
- Observability onboarding 

#####  Ansible tasks for cluster prereqs 

`roles/commom/tasks/main.yaml`

``` yaml 
    - name: Install dependencies
      yum:
        name:
          - curl
          - yum-utils
          - device-mapper-persistent-data
          - lvm2
        state: present

    - name: Add Kubernetes YUM repository
      yum_repository:
        name: kubernetes
        description: Kubernetes
        baseurl: https://packages.cloud.google.com/yum/repos/kubernetes-el7-$basearch
        enabled: yes
        gpgcheck: 1
        repo_gpgcheck: 1
        gpgkey:
          - https://packages.cloud.google.com/yum/doc/yum-key.gpg
          - https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
        exclude: kubelet kubeadm kubectl

## Exluding  kubelet kubeadm kubectl everytime as part of yum update 

    - name: Install Kubernetes packages
      yum:
        name:
          - kubelet
          - kubeadm
          - kubectl
        state: present
        disable_excludes: kubernetes

    - name: Enable and start kubelet
      systemd:
        name: kubelet
        enabled: yes
        state: started

    - name: Disable swap
      shell: |
        swapoff -a
        sed -i '/ swap / s/^/#/' /etc/fstab
      args:
        warn: false

```

  

#####  Ansible tasks for cluster setup using kubeadm 
`roles/k8s-engine/tasks/main.yaml`

``` yaml
---
# roles/k8s_engine/tasks/main.yml

- name: Initialize Kubernetes control plane on master1
  command: >
    kubeadm init
    --control-plane-endpoint "{{ control_plane_endpoint }}"
    --upload-certs
    --pod-network-cidr {{ pod_network_cidr }}
    --service-cidr {{ service_cidr }}
  register: kubeadm_init_output
  when: inventory_hostname == groups['masters'][0]
  tags: 
    - master1-steps 

- name: Wait for kubeadm init to complete
  wait_for:
    port: 6443
    delay: 10
    timeout: 300
    state: started
  when: inventory_hostname == groups['masters'][0]
  tags: 
    - master1-steps

- name: Extract join command for control plane (master1)
  shell: |
    kubeadm token create --print-join-command --certificate-key $(awk '/--certificate-key/ {print $3}' <<< "{{ kubeadm_init_output.stdout }}")
  register: master_join_cmd
  when: inventory_hostname == groups['masters'][0]
  tags: 
    - master1-steps 

- name: Extract join command for workers (master1)
  shell: |
    kubeadm token create --print-join-command
  register: worker_join_cmd
  when: inventory_hostname == groups['masters'][0]
  tags: 
    - master1-steps 

- name: Save join commands for other hosts (master1)
  copy:
    content: |
      MASTER_JOIN_COMMAND={{ master_join_cmd.stdout }}
      WORKER_JOIN_COMMAND={{ worker_join_cmd.stdout }}
    dest: /tmp/k8s_join_commands.txt
    mode: 0644
  when: inventory_hostname == groups['masters'][0]
  tags: 
    - master1-steps 

- name: Set kubeconfig for root (master1)
  shell: |
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
  when: inventory_hostname == groups['masters'][0]
  tags: 
    - master1-steps 

- name: Install Calico network plugin (master1)
  shell: |
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
  when: inventory_hostname == groups['masters'][0]
  tags:
    - master1-steps

- name: Fetch join commands from master1
  fetch:
    src: /tmp/k8s_join_commands.txt
    dest: /tmp/k8s_join_commands.txt
    flat: yes
  delegate_to: "{{ groups['masters'][0] }}"
  tags: 
    - control-plane-setup
    - master1-steps

- name: Wait for master1 API server
  wait_for:
    port: 6443
    host: "{{ hostvars['master1']['ansible_host'] }}"
    timeout: 60
  when: inventory_hostname in groups['masters'] and inventory_hostname != groups['masters'][0]
  tags: 
    - control-plane-setup
    
- name: Read master join command into fact
  shell: |
    grep MASTER_JOIN_COMMAND /tmp/k8s_join_commands.txt | cut -d= -f2-
  register: master_join_command
  changed_when: false
  when: inventory_hostname in groups['masters'] and inventory_hostname != groups['masters'][0]
  tags: 
    - control-plane-setup

- name: Read worker join command into fact
  shell: |
    grep WORKER_JOIN_COMMAND /tmp/k8s_join_commands.txt | cut -d= -f2-
  register: worker_join_command
  changed_when: false
  when: inventory_hostname in groups['workers']
  tags:
    - workers-setup

- name: Join as control plane node
  shell: "{{ master_join_command.stdout }} --v=5"
  args:
    creates: /etc/kubernetes/kubelet.conf
  when: inventory_hostname in groups['masters'] and inventory_hostname != groups['masters'][0]
  tags: 
    - control-plane-setup

- name: Join as worker node
  shell: "{{ worker_join_command.stdout }} --v=5"
  args:
    creates: /etc/kubernetes/kubelet.conf
  when: inventory_hostname in groups['workers']
  tags: 
    - workers-setup

- name: Ensure kubelet is running
  service:
    name: kubelet
    state: started
    enabled: true
  when: inventory_hostname in groups['masters'] or inventory_hostname in groups['workers']
  tags:
    - always

- name: Wait for kubelet to be ready
  wait_for:
    port: 10250 # Kubelet API port
    delay: 10
    timeout: 300
    state: started
  when: inventory_hostname in groups['masters'] or inventory_hostname in groups['workers']
  tags:
    - always



```
##### Ansible playbook for Master1 setup 
``` yaml 
---
- name: Kubernetes Cluster Setup using k8s_engine role
  hosts: master1
  become: yes
  vars:
    pod_network_cidr: "10.10.0.0/16"
    service_cidr: "172.16.0.0/16"
    control_plane_endpoint: "{{ hostvars[groups['masters'][0]]['ansible_host'] }}:6443"

  roles:
    - role: k8s_engine
      tags:
        - master1-steps
```
##### Ansible Playbook for control plane setup 

``` yaml
--- 
- name: Kubernetes Cluster Setup using k8s_engine role
  hosts: masters:!master1
  become: yes
  vars:
    pod_network_cidr: "10.10.0.0/16"
    service_cidr: "172.16.0.0/16"
    control_plane_endpoint: "{{ hostvars[groups['masters'][0]]['ansible_host'] }}:6443"

  roles:
    - role: k8s_engine
      tags:
        - control-plane-setup
```
##### Ansible Playbook for workers plane setup 

``` yaml  
--- 
- name: Kubernetes Cluster Setup using k8s_engine role
  hosts: workers
  become: yes
  vars:
    pod_network_cidr: "10.10.0.0/16"
    service_cidr: "172.16.0.0/16"
    control_plane_endpoint: "{{ hostvars[groups['masters'][0]]['ansible_host'] }}:6443"

  roles:
    - role: k8s_engine
      tags:
        - workers-setup
```
-----

#### Kubernetes 

With the above tasks in Ansible we have built the kubernetes cluster. So, We must run cluster CIS hardening playbook. 

**Note:** 
1. To decrease the number of lines of the code I am placing some of the critical CIS tasks here Hardening here. 
2. We used ansible for server side hardening because most of the tools like OPA or Kyverno  are not capable of server side hardening like modifying api manifest file or etcd file. 

`roles/post-cluster-provisioning/tasks/k8s-hardening.yaml`

##### Server Side Hardening of the cluster 
``` yaml

- name: Ensure --authorization-mode includes Node,RBAC
  tags:
      - post-cluster-configuration
  lineinfile:
    path: "{{ kube_apiserver_manifest }}"
    regexp: '^- --authorization-mode='
    line: "    - --authorization-mode=Node,RBAC"


- name: Ensure --anonymous-auth is set to false
  tags:
      - post-cluster-configuration
  lineinfile:
    path: "{{ kube_apiserver_manifest }}"
    regexp: '^- --anonymous-auth='
    line: "    - --anonymous-auth=false"


- name: Ensure --insecure-port is set to 0
  tags:
      - post-cluster-configuration
  lineinfile:
    path: "{{ kube_apiserver_manifest }}"
    regexp: '^- --insecure-port='
    line: "    - --insecure-port=0"
- name: Ensure --audit-log-path is set
  tags:
      - post-cluster-configuration
  lineinfile:
    path: "{{ kube_apiserver_manifest }}"
    regexp: '^- --audit-log-path='
    line: "    - --audit-log-path={{ audit_log_path }}"


- name: Ensure encryption config file exists
  tags:
      - post-cluster-configuration
  copy:
    dest: /etc/kubernetes/encryption-config.yaml
    content: |
      apiVersion: apiserver.config.k8s.io/v1
      kind: EncryptionConfiguration
      resources:
        - resources:
            - secrets
          providers:
            - aescbc:
                keys:
                - name: key1
                  secret: {{ lookup('password', '/dev/null length=32 chars=ascii_letters,digits') | b64encode }}
            - identity: {}


  - name: Ensure --encryption-provider-config is set
    tags:
      - post-cluster-configuration
    lineinfile:
      path: "{{ kube_apiserver_manifest }}"
      regexp: '^- --encryption-provider-config='
      line: "    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml"

  - name: Ensure etcd manifest file permissions are 644
    tags:
      - post-cluster-configuration
    file:
      path: "{{ etcd_manifest }}"
      owner: root
      group: root
      mode: '0644'
# Restart kubelet after all 
  - name: Restart kubelet
    service:
      name: kubelet
      state: restarted
    tags:
      - post-cluster-configuration
```
---- 
### Day1

#### ArgoCD Setup 
Now we almost set up the full cluster including HA proxy setup. Lets proceed with last two steps of platform engine readiness 
1. Ingress Deployment
2. MetalLB Deployment 
3. ArgoCD Deployment 

We will use ansible for deploying argocd and ingress controller.

Create another role that will deploy the Ingress controller and argocd. 

We are using k8s modules of ansible to deploy above services 
##### Ingress Setup

`roles/post-cluster-provisioning/tasks/argocd-setup.yaml`

``` yaml 

- name: Deploy NGINX Ingress Controller
  tags: 
    - argocd-setup
    - post-cluster-configuration
  k8s:
    state: present
    definition:
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ingress-nginx-controller
        namespace: ingress-nginx
      spec:
        replicas: 3
        selector:
          matchLabels:
            app.kubernetes.io/name: ingress-nginx
        template:
          metadata:
            labels:
              app.kubernetes.io/name: ingress-nginx
          spec:
            containers:
              - name: controller
                image: k8s.gcr.io/ingress-nginx/controller:v1.9.4
                args:
                  - /nginx-ingress-controller
                  - --publish-service=$(POD_NAMESPACE)/ingress-nginx-controller
                  - --election-id=ingress-controller-leader
                  - --ingress-class=nginx
                ports:
                  - containerPort: 80
                  - containerPort: 443

# /roles/post-cluster-provisioning/tasks/argocd-setup.yaml
# Create a ns for argocd
# create TLS secret and deploy argocd with TLS
# Ansible tasks for Metallb Deployment 
- name: Add Argo Helm repository
  shell: |
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
  args:
    executable: /bin/bash
  tags: 
    - argocd-setup
    - post-cluster-configuration
    - day1


- name: Read secret from Vault
  hashi_vault:
    url: "{{ lookup('env', 'VAULT_URL') }}"
    token: "{{ lookup('env', 'VAULT_TOKEN') }}"
    secret: secret/data/cluster/tls
  register: vault_secret
  tags: 
    - argocd-setup
    - post-cluster-configuration
    - day1


- name: Create TLS secret in Kubernetes
  k8s:
    state: present
    definition:
      apiVersion: v1
      kind: Secret
      metadata:
        name: "{{ argocd_tls_secret_name }}"
        namespace: "{{ argocd_namespace }}"
      type: kubernetes.io/tls
      data:
        tls.crt: "{{ vault_secret.data.data['tls.crt'] | b64encode }}"
        tls.key: "{{ vault_secret.data.data['tls.key'] | b64encode }}"
  no_log: true
  tags: 
    - argocd-setup
    - post-cluster-configuration
    - day1


- template:
    src: "{{ role_path }}/templates/argocd-install.yaml.j2"
    dest: "{{ role_path }}/files/argocd-values.yaml"
  register: argocd_install
  tags: 
    - argocd-setup
    - post-cluster-configuration
    - day1

- name: Install ArgoCD via Helm with Ingress & TLS
  tags: 
    - argocd-setup
    - post-cluster-configuration
    - day1
  helm:
    name: argocd
    chart_ref: argo/argo-cd
    release_namespace: argocd
    create_namespace: true
    values_file: "{{ role_path }}/files/argocd-values.yaml"

## Metallb IPAddressPool creation 

## BGP Peer for Metallb 

## SVC for Ingress 
- name: LoadBalancer Service for Ingress Controller
  tags: 
    - loadbalancer 
    - post-cluster-configuration
  k8s:
    state: present
    definition: |
      apiVersion: v1
      kind: Service
      metadata:
        name: ingress-nginx-loadbalancer
        namespace: ingress-nginx 
          spec:
            type: LoadBalancer
            selector:
              app.kubernetes.io/name: ingress-nginx     
              app.kubernetes.io/part-of: ingress-nginx   
            ports:
              - name: http
                protocol: TCP
                port: 80
                targetPort: http
              - name: https
                protocol: TCP
                port: 443
                targetPort: https
            externalTrafficPolicy: Local
```

Now We will also deploy the first app which is responsible for cluster hardening. I have selected Kyverno because its more focused on kubernetes and policy language is yaml.  


##### Ansible tasks Kyverno set up for Cluster Hardening 

`roles/post-cluster-provisioning/templates/kyverno-argo-deploy.yaml.j2`

``` yaml

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  annotations:
    argocd.argoproj.io/compare-options: ServerSideDiff=true,IncludeMutationWebhook=true
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ kyverno_namespace }} 
  source:
    repoURL: <<>
    chart: k8s-compliance
    targetRevision: "{{ kyverno_chart_version }}" 
    helm:
      valueFiles:
        - "{{}}"
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true 
```

``` yaml
- name: Apply Kyverno ArgoCD Application for cluster hardening 
  k8s:
    state: present
    src: "{{ role_path }}/templates/kyverno_argo_app.yml.j2"
  register: kyverno_app_status
  tags:
    - kyverno
    - post-cluster-configuration
```
Here are some of the sample Kyverno policies which we must deploy on the cluster

``` yaml 
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: enforce
  rules:
    - name: check-resources
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "CPU and memory requests/limits must be set for all containers."
        foreach:
          - list: "spec.containers[]"
            pattern:
              resources:
                requests:
                  memory: "?*"
                  cpu: "?*"
                limits:
                  memory: "?*"
                  cpu: "?*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-hpa-replicas
spec:
  validationFailureAction: enforce
  rules:
    - name: validate-hpa-replicas
      match:
        resources:
          kinds:
            - HorizontalPodAutoscaler
      validate:
        message: "HPA replicas must be within allowed ranges (min: 1-5, max: 5-10)."
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.minReplicas }}"
                operator: NotIn
                value: [1,2,3,4,5]
              - key: "{{ request.object.spec.maxReplicas }}"
                operator: NotIn
                value: [5,6,7,8,9,10]
--- 
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-anonymous-bindings
spec:
  validationFailureAction: enforce
  rules:
    - name: deny-anonymous-subjects
      match:
        resources:
          kinds:
            - RoleBinding
            - ClusterRoleBinding
      validate:
        message: "Binding to system:anonymous or system:unauthenticated is not allowed."
        foreach:
          - list: "subjects"
            deny:
              conditions:
                any:
                  - key: "{{ element.kind }}"
                    operator: In
                    value: ["User", "Group"]
                  - key: "{{ element.name }}"
                    operator: In
                    value: ["system:anonymous", "system:unauthenticated"]
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-prefix
spec:
  validationFailureAction: enforce
  rules:
    - name: check-image-prefix
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Container images must start with allowed prefixes: 'oi-registry/', 'gcr.io/project-id/'."
        foreach:
          - list: "spec.containers[]"
            pattern:
              image: "oi-registry/* | gcr.io/project-id/*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-https-ingress
spec:
  validationFailureAction: enforce
  rules:
    - name: enforce-https
      match:
        resources:
          kinds:
            - Ingress
      validate:
        message: "Ingress must use HTTPS and disable HTTP."
        pattern:
          metadata:
            annotations:
              kubernetes.io/ingress.allow-http: "false"
          spec:
            tls: "?*"
--- 
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-storageclass
spec:
  validationFailureAction: enforce
  rules:
    - name: check-storageclass
      match:
        resources:
          kinds:
            - PersistentVolumeClaim
      validate:
        message: "StorageClass must be specified."
        pattern:
          spec:
            storageClassName: "?*"
```
### Observability Setup 

We will deploy Below tools for observability 
  * Prometheus inside the cluster and use remote_write with authentication for shipping the metrics to external prometheus
    * Before deploying prometheus we need to configure `Node Exporter` and `kube-state-metrics` <br> <br>
  
Reason for this style of deployment is 
    - Having cluster level tool for Metrics collection will be added advantage when we are troubleshooting
    - Even when we loose connectivity cluster still we can last known metrics from external Prometheus
    - If we configure external Prometheus Scrapes the Cluster directly, that will be complex design when we have multiple clusters  and also Creates external dependency 
    - No need to expose Kubernetes API and all metrics endpoints (node-exporter, kube-state-metrics, etc.)

**Steps**

`roles/post-cluster-provisioning/templates/prometheus-secret.yaml.j2`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: external-prometheus-auth
  namespace: monitoring
type: Opaque
data:
  username: {{prometheus_username}}
  password: {{prometheus_password}}
```
Mount the secret inside Prometheus deployment 

`roles/post-cluster-provisioning/templates/prometheus-deployment.yaml.j2`

```yaml
      volumes:
        - name: external-prometheus-auth
          secret:
            secretName: external-prometheus-auth
      containers:
        - name: prometheus
          # ...
          volumeMounts:
            - name: external-prometheus-auth
              mountPath: /etc/prometheus/external-prometheus-auth
              readOnly: true

### Remote Write configuration in configmap 
    remote_write:
      - url: "https://{{external_prometheus_server_url}}/api/v1/write"
        basic_auth:
          username_file: /etc/prometheus/external-prometheus-auth/username
          password_file: /etc/prometheus/external-prometheus-auth/password
```

#### Logging 
We will deploy `fluent-bit` a light weight daemonset for collecting from the cluster. <br><br>
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
  labels:
    app: fluent-bit
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:2.1.8
        resources:
          limits:
            memory: 100Mi
          requests:
            cpu: 100m
            memory: 100Mi
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: fluent-bit-config
          mountPath: /fluent-bit/etc/
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
      - name: fluent-bit-config
        configMap:
          name: fluent-bit-config
```
So far we have completed almost all necessary steps for cluster. We will do the last step as part of cluster provisioning which CSI deployment. we can either use longhorn or ceph with rook. I have attached 100gb Disk for each worker VM we will use for configuring the csi. 

Once CSI is configured we will create a storage class for provisioning volumes.  <br>

##### HA proxy set up 

Lets install HA proxy and set up HA proxy servers for api management. 

``` bash
server k8s-master-01 192.168.1.11:6443 check inter 10s fall 2 rise 1
server k8s-master-02 192.168.1.12:6443 check inter 10s fall 2 rise 1
server k8s-master-03 192.168.1.13:6443 check inter 10s fall 2 rise 1

```
##### VRRP or Keepalived Set up
``` bash
vrrp_instance VI_1 {
    state MASTER               
    interface eth0
    virtual_router_id 51       
    priority 101               
    advert_int 1                
    authentication {
        auth_type PASS
        auth_pass password@vrrp1234$ 
    }
    virtual_ipaddress {
        192.168.1.201/24    
    }
    track_script {
        chk_haproxy           
    }
    notify_master "/usr/bin/printf '%s %s\n' $(date '+%F %T') 'Become MASTER on haproxy-01 (192.168.1.202)' >> /var/log/keepalived-state.log"
    notify_backup "/usr/bin/printf '%s %s\n' $(date '+%F %T') 'Become BACKUP on haproxy-01 (192.168.1.202)' >> /var/log/keepalived-state.log"
    notify_fault "/usr/bin/printf '%s %s\n' $(date '+%F %T') 'Enter FAULT state on haproxy-01 (192.168.1.202)' >> /var/log/keepalived-state.log"
}
```
---
#### Jenkins Setup 
I am using Jenkins as my CI engine to deploy the platform (Kubernetes cluster). Its not mandatory to use jenkins but I preferred Jenkins as this is on premises set up. 

Here we will discuss the multiple stages for the platform deployment 
- Stage-1(Infrastructure Provisioning) with below steps:
  - Terraform validation
  - Terraform plan 
  - Terraform apply 
- Stage-2(Inventory creation for ansible):
  - We will use the haproxy.json, masters.json and workers.json from folder platform-engine/terraform/environment/ to create Ansible inventory 
- Stage-3 (Ansible playbook execution for K8S deployment with below steps)
  - We will deploy the cluster using ansible on master1
  - We will join other control plane nodes 
  - we will add workers 
- Stage-4 (Ansible playbook execution for post-cluster-provisioning)
  - We will control-plane/worker OS level hardening CIS level 
  - Ingress Controller deployment 
  - ArgoCD deployment 
  - Metallb Deployment 
  - Ingress Service Deployment for argocd 
  - Metallb service for ingress controller 
  - Kyverno set up for cluster level hardening 
  - Storage class configuration 


``` groovy

pipeline {
  agent any

  environment {
    VAULT_ADDR = 'https://vault.opi.com'
    terraform_dir = 'platform-engine/terraform'
    ansible_dir = 'platform-engine/ansible'
    ENV_DIR = "${terraform_dir}/environments/"
    ANSIBLE_CONFIG = "${ansible_dir}/ansible.cfg"
    ANSIBLE_INVENTORY = 'inventory.ini'
  }

  stages {
    stage('Vault Authentication') {
      steps {
        script {
          try {
            withCredentials([string(credentialsId: 'vault-token', variable: 'VAULT_TOKEN')]) {
              echo 'Fetching secrets from Vault...'
              sh """
                set +x
                curl -s --header "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/secret/data/platform/vsphere | jq -r '.data.data' > vault_secrets.json
                set -x
              """
                def secrets = readJSON file: 'vault_secrets.json'
                env.VSPHERE_USER  = secrets['vsphere_user']
                env.VSPHERE_PASSWORD = secrets['vsphere_password']
                env.VSPHERE_SERVER = secrets['vsphere_server']
              echo 'Vault authentication successful.'
            }
          } catch (err) {
            error("failed to get Vsphere credentials: ${err}")
          }
        }
      }
    }

    stage('Terraform Init') {
      steps {
        dir("${terraform_dir}") {
          script {
            try {
              sh 'terraform init'
            } catch (err) {
              error("Terraform Init failed: ${err}")
            }
          }
        }
      }
    }

    stage('Terraform Validate') {
      steps {
        dir("${terraform_dir}") {
          script {
            try {
              sh 'terraform validate'
            } catch (err) {
              error("Terraform Validate failed: ${err}")
            }
          }
        }
      }
    }

    stage('Terraform Plan') {
      steps {
        dir("${terraform_dir}") {
          script {
            try {
              sh 'terraform plan -out=tfplan'
            } catch (err) {
              error("Terraform Plan failed: ${err}")
            }
          }
        }
      }
    }

    stage('Terraform Apply') {
      steps {
        dir("${terraform_dir}") {
          script {
            try {
              sh 'terraform apply -auto-approve tfplan'
            } catch (err) {
              error("Terraform Apply failed: ${err}")
            }
          }
        }
      }
    }

    stage('Ansible Inventory Creation') {
      steps {
        script {
          try {
            def groups = ['haproxy', 'masters', 'workers']
            def inventory = [:].withDefault { [] }

            groups.each { group ->
              def jsonFile = "${ENV_DIR}/${group}.json"
              if (fileExists(jsonFile)) {
                def data = readJSON file: jsonFile
                data.eachWithIndex { node, index ->
                  def hostname = node.hostname ?: node.name
                  def ip = node.ipv4_address
                  def alias = "${group[0..-2]}${index + 1}"
                  def line = "${alias} ${hostname} ansible_host=${ip}"
                  inventory[group] << line
                }
              }
            }

            def inventoryText = groups.collect { group ->
              inventory[group] ? "[${group}]\n" + inventory[group].join("\n") : ""
            }.findAll { it }.join("\n\n")

            writeFile file: 'inventory.ini', text: inventoryText
            echo "Generated Ansible Inventory:\n${inventoryText}"
          } catch (err) {
            error("Inventory creation failed: ${err}")
          }
        }
      }
    }

    stage('Kubernetes master1 setup via Ansible') {
      steps {
        script {
          try {
            echo 'Running Ansible playbook to deploy Kubernetes cluster...'
             ansiblePlaybook(
              playbook: 'master1-steps.yaml',
              inventory: 'inventory.ini',
              tags: 'master1-steps'
            )
          } catch (err) {
            error("Ansible K8s deployment failed: ${err}")
          }
        }
      }
    }
    stage('Kubernetes control plane setup via Ansible') {
      steps {
        script {
            try {
            echo 'Running Ansible playbook to deploy Kubernetes control plane...'
            ansiblePlaybook(
              playbook: 'control-plane-setup.yaml',
              inventory: 'inventory.ini',
              tags: 'control-plane-setup'
            )
          } catch (err) {
            error("Ansible K8s deployment failed: ${err}")
          }
        }
      }
    }
    stage('Kubernetes worker nodes setup via Ansible') {
      steps {
        script {
          try {
            echo 'Running Ansible playbook to join worker nodes to the cluster...'
            ansiblePlaybook(
              playbook: 'workers-setup.yaml',
              inventory: 'inventory.ini',
              tags: 'workers-setup'
            )
          } catch (err) {
            error("Ansible K8s worker setup failed: ${err}")
          }
        }
      }
    }
    stage('Day1 Operations') {
      steps {
        script {
          try {
            echo 'Running post-cluster provisioning playbook...'
             ansiblePlaybook(
              playbook: 'post-cluster-setup.yaml',
              inventory: 'inventory.ini',
              tags: 'post-cluster-configuration'
            )
          } catch (err) {
            error("Post-cluster provisioning failed: ${err}")
          }
        }
      }
    }
  }
  post {
    always {
      echo ' Pipeline completed.'
      cleanWs()
    }
    failure {
      echo 'Pipeline failed. Please check the logs for details.'
    }
  }
}

```