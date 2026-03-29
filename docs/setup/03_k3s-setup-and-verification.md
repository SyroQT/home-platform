# K3s Installation Validation and Access

This guide covers what to run after applying the Ansible K3s playbook, what to verify, and how to configure access.

## 1. Verify K3s Service

```bash
sudo systemctl is-active k3s
```

Expected:

```text
active
```

## 2. Verify Node Status

```bash
sudo k3s kubectl get nodes -o wide
```

Expected:

- Node is `Ready`
- Roles include `control-plane,etcd`

Example:

```text
NAME       STATUS   ROLES                AGE   VERSION
k3s-prod   Ready    control-plane,etcd   ...   v1.xx.x
```

## 3. Verify System Pods

```bash
sudo k3s kubectl get pods -A
```

Expected:

- All pods are `Running` or `Completed`
- Key components are present: `coredns`, `traefik`, `local-path-provisioner`, `metrics-server`

## 4. Verify Embedded etcd

### Check snapshot command works

```bash
sudo k3s etcd-snapshot save
sudo k3s etcd-snapshot ls
```

Expected:

- Snapshot file appears
- No errors

## 5. Verify Secrets Encryption

```bash
sudo ls -l /var/lib/rancher/k3s/server/cred/encryption-config.json
```

Expected:

- File exists
- Owned by `root`
- Permissions are `600`

## 6. Verify Persistent Storage Path

### Step 1. Create PVC

```bash
cat <<'EOF' | sudo k3s kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
```

The PVC may remain `Pending` initially.

### Step 2. Create Pod that uses PVC

```bash
cat <<'EOF' | sudo k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: storage-test-pod
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sh", "-c", "echo hello >/data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-test
EOF
```

### Step 3. Verify binding

```bash
sudo k3s kubectl get pod,pvc,pv
```

Expected:

- Pod is `Running`
- PVC is `Bound`
- PV is created

### Step 4. Verify data path

```bash
sudo find /srv/data/k3s-local-path -maxdepth 5 -type d
```

Expected:

- A new directory is created under `/srv/data/k3s-local-path/...`

### Cleanup

```bash
sudo k3s kubectl delete pod storage-test-pod
sudo k3s kubectl delete pvc storage-test
```

## 7. Verify and Standardize kubectl Access

The Ansible role already configures `/etc/rancher/k3s/k3s.yaml` to be readable by the `deployer` group, so basic non-root cluster access should work without any extra setup.

### Step 1. Verify non-root access

```bash
kubectl get nodes
```

Expected:

- The command works without `sudo`
- The node list is returned
- On hosts where `/usr/local/bin/kubectl` is the K3s-provided wrapper, warnings about `/etc/rancher/k3s/config.yaml` may still appear

Those warnings do not mean kubeconfig access is broken. They come from the K3s wrapper reading its own server config, which remains readable only by `root`.

### Step 2. Optional: copy kubeconfig to the standard location

Recommended for standard `kubectl` usage on the server.

#### On the server

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown deployer:deployer ~/.kube/config
chmod 600 ~/.kube/config
```

#### Test

```bash
kubectl get nodes
```

Why this step exists:

- The playbook keeps the server kubeconfig under `/etc/rancher/k3s/k3s.yaml`
- The file contains cluster-admin credentials
- The role grants `deployer` read access to that file
- Copying it places the config in the standard `~/.kube/config` location
- It improves compatibility with tools such as Helm and Flux

### Step 3. Optional: copy kubeconfig to a local machine

Better for day-to-day workflow from a laptop or desktop.

From your local machine:

```bash
scp deployer@<server-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-prod.yaml
```

Edit the server address inside the file:

```yaml
server: https://<server-ip>:6443
```

Use it:

```bash
kubectl --kubeconfig ~/.kube/k3s-prod.yaml get nodes
```

Important notes:

- Kubeconfig grants cluster-admin access
- Keep permissions strict with `600`
- Do not commit kubeconfig to Git
- Restrict the Kubernetes API on port `6443` unless it is needed
