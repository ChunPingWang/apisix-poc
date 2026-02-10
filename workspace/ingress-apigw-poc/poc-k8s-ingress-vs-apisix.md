# PoC Plan: Kubernetes Ingress vs. Apache APISIX API Gateway on Kind

> **Version:** 1.0  
> **Date:** February 2026  
> **Target Audience:** Beginners to Kubernetes networking and API Gateway concepts

---

## 1. Executive Summary

This Proof of Concept (PoC) aims to compare the built-in **Kubernetes Ingress** mechanism (using NGINX Ingress Controller) with **Apache APISIX** as a full-featured API Gateway, both running on a local **Kind (Kubernetes in Docker)** cluster. The goal is to evaluate routing capabilities, traffic management, observability, security, and extensibility to help teams make informed architectural decisions.

---

## 2. Key Concepts Explained

### 2.1 What is Kubernetes Ingress?

**Kubernetes Ingress** is a native Kubernetes API object that manages external HTTP/HTTPS access to services within a cluster.

Think of it like a **receptionist at a building entrance** — it looks at the incoming request (URL path or hostname) and directs it to the right internal office (service).

**How it works:**

```
Internet → Ingress Controller (e.g., NGINX) → Ingress Rules → Service → Pod
```

- **Ingress Resource**: A YAML configuration that defines routing rules (e.g., `/api` goes to `api-service`, `/web` goes to `web-service`).
- **Ingress Controller**: The actual software that reads Ingress resources and enforces the rules. Kubernetes does **not** include one by default — you must install one (e.g., NGINX Ingress Controller, Traefik, HAProxy).

**Example Ingress Resource:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
spec:
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-service
                port:
                  number: 80
```

**Strengths:** Simple, native to Kubernetes, widely supported.  
**Limitations:** Limited to L7 HTTP routing, no built-in rate limiting, no authentication plugins, limited traffic control.

### 2.2 What is an API Gateway?

An **API Gateway** is a more powerful layer that sits between clients and backend services. Beyond simple routing, it provides:

| Capability | Description |
|---|---|
| **Traffic Management** | Rate limiting, circuit breaking, retries, timeouts |
| **Security** | Authentication (JWT, OAuth2, mTLS), IP whitelisting, CORS |
| **Observability** | Metrics, logging, distributed tracing |
| **Transformation** | Request/response rewriting, header manipulation |
| **Canary/Blue-Green** | Advanced deployment strategies with traffic splitting |

Think of it as a **smart security guard + traffic controller + translator** all in one.

### 2.3 What is Apache APISIX?

**Apache APISIX** is a high-performance, cloud-native API Gateway built on **NGINX** and **Lua (OpenResty)**. It's an Apache Software Foundation top-level project.

**Architecture:**

```
Client Request
     │
     ▼
┌──────────────┐
│  APISIX       │ ← Routes + Plugins (auth, rate-limit, etc.)
│  (Data Plane) │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   etcd        │ ← Configuration Store (real-time config updates)
└──────────────┘
       │
       ▼
┌──────────────┐
│  APISIX       │ ← Web UI for managing routes/plugins
│  Dashboard    │
└──────────────┘
```

**Key Features:**
- **80+ built-in plugins** (authentication, traffic control, observability, serverless)
- **Hot reload** — change routes and plugins without restarting
- **Multi-protocol** — HTTP, gRPC, WebSocket, TCP/UDP
- **Kubernetes native** — can act as an Ingress Controller via APISIX Ingress Controller CRDs

### 2.4 What is Kind (Kubernetes in Docker)?

**Kind** stands for "**K**ubernetes **in** **D**ocker." It runs a full Kubernetes cluster inside Docker containers on your local machine — perfect for development and PoCs.

```
Your Laptop
  └── Docker
       ├── kind-control-plane (container acting as K8s master + worker)
       └── (optional) kind-worker, kind-worker2...
```

**Why Kind for this PoC:**
- No cloud costs
- Fast setup (< 2 minutes)
- Disposable — delete and recreate anytime
- Supports port mapping to access services from localhost

### 2.5 Ingress Controller vs. API Gateway — When to Use What?

| Criteria | K8s Ingress (NGINX) | Apache APISIX |
|---|---|---|
| **Use Case** | Simple L7 routing | Full API lifecycle management |
| **Complexity** | Low | Medium |
| **Rate Limiting** | Annotation-based (limited) | Plugin-based (flexible, per-route/consumer) |
| **Authentication** | External (requires extra setup) | Built-in (JWT, Key-Auth, OAuth2, LDAP) |
| **Canary Deployments** | Limited annotation support | Native traffic splitting by weight |
| **Observability** | Basic NGINX logs | Prometheus, Grafana, Zipkin/Jaeger integration |
| **Configuration** | YAML + annotations | Admin API + Dashboard UI + CRDs |
| **Protocol Support** | HTTP/HTTPS | HTTP, gRPC, WebSocket, TCP, UDP |
| **Ecosystem** | K8s-native | Cloud-native, multi-platform |

---

## 3. PoC Objectives

1. **Set up** a local Kind cluster with both NGINX Ingress Controller and Apache APISIX
2. **Deploy** sample microservices as backend targets
3. **Compare** key capabilities side-by-side:
   - Basic routing (path-based, host-based)
   - Rate limiting
   - Authentication (API Key, JWT)
   - Canary / traffic splitting
   - Observability (metrics, logging)
4. **Document** findings with measurable results
5. **Recommend** which approach fits which use cases

---

## 4. Prerequisites

### 4.1 Tools to Install

| Tool | Version | Purpose |
|---|---|---|
| Docker Desktop | Latest | Container runtime |
| Kind | v0.20+ | Local K8s cluster |
| kubectl | v1.28+ | K8s CLI |
| Helm | v3.12+ | Package manager for K8s |
| curl / httpie | Latest | HTTP testing |
| hey / k6 | Latest | Load testing |

### 4.2 Hardware Requirements

- **CPU:** 4+ cores recommended
- **RAM:** 8 GB minimum (16 GB recommended)
- **Disk:** 20 GB free

---

## 5. PoC Implementation Plan

### Phase 1: Environment Setup (Day 1)

#### Step 1.1 — Create Kind Cluster with Port Mapping

```yaml
# kind-cluster.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 9080    # APISIX HTTP
        hostPort: 9080
        protocol: TCP
      - containerPort: 9443    # APISIX HTTPS
        hostPort: 9443
        protocol: TCP
  - role: worker
  - role: worker
```

```bash
kind create cluster --name poc-ingress-gw --config kind-cluster.yaml
kubectl cluster-info --context kind-poc-ingress-gw
```

#### Step 1.2 — Deploy Sample Microservices

Deploy two simple backend services to route traffic to:

```yaml
# sample-apps.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo
      version: v1
  template:
    metadata:
      labels:
        app: demo
        version: v1
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo
          args: ["-text=Hello from App V1"]
          ports:
            - containerPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo
      version: v2
  template:
    metadata:
      labels:
        app: demo
        version: v2
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo
          args: ["-text=Hello from App V2"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app-v1-svc
spec:
  selector:
    app: demo
    version: v1
  ports:
    - port: 80
      targetPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app-v2-svc
spec:
  selector:
    app: demo
    version: v2
  ports:
    - port: 80
      targetPort: 5678
```

### Phase 2: NGINX Ingress Controller Setup (Day 2)

#### Step 2.1 — Install NGINX Ingress Controller

```bash
# Install NGINX Ingress Controller for Kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for readiness
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

#### Step 2.2 — Configure Basic Routing

```yaml
# nginx-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: demo.local
      http:
        paths:
          - path: /v1
            pathType: Prefix
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
          - path: /v2
            pathType: Prefix
            backend:
              service:
                name: app-v2-svc
                port:
                  number: 80
```

#### Step 2.3 — Configure Rate Limiting (Annotation-based)

```yaml
# nginx-ingress-ratelimit.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress-ratelimited
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "10"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "5"
    nginx.ingress.kubernetes.io/limit-connections: "5"
spec:
  ingressClassName: nginx
  rules:
    - host: demo-limited.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
```

### Phase 3: Apache APISIX Setup (Day 3)

#### Step 3.1 — Install APISIX via Helm

```bash
# Add APISIX Helm repo
helm repo add apisix https://charts.apiseven.com
helm repo update

# Install APISIX
helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  --set gateway.type=NodePort \
  --set gateway.http.nodePort=9080 \
  --set gateway.tls.nodePort=9443 \
  --set dashboard.enabled=true \
  --set ingress-controller.enabled=true

# Wait for readiness
kubectl -n apisix wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=apisix \
  --timeout=120s
```

#### Step 3.2 — Configure Basic Routing via Admin API

```bash
# Create a route via APISIX Admin API
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "uri": "/v1/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v1-svc.default.svc.cluster.local:80": 1
      }
    }
  }'

curl http://127.0.0.1:9180/apisix/admin/routes/2 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "uri": "/v2/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v2-svc.default.svc.cluster.local:80": 1
      }
    }
  }'
```

#### Step 3.3 — Configure Rate Limiting (Plugin-based)

```bash
# Add rate limiting plugin to a route
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PATCH -d '{
    "plugins": {
      "limit-req": {
        "rate": 10,
        "burst": 5,
        "rejected_code": 429,
        "key_type": "var",
        "key": "remote_addr"
      }
    }
  }'
```

#### Step 3.4 — Configure Authentication (Key-Auth Plugin)

```bash
# Create a consumer with API key
curl http://127.0.0.1:9180/apisix/admin/consumers \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "username": "poc-user",
    "plugins": {
      "key-auth": {
        "key": "my-secret-api-key-123"
      }
    }
  }'

# Enable key-auth on a route
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PATCH -d '{
    "plugins": {
      "key-auth": {}
    }
  }'
```

#### Step 3.5 — Configure Canary / Traffic Splitting

```bash
# Route with weighted traffic splitting: 80% v1, 20% v2
curl http://127.0.0.1:9180/apisix/admin/routes/3 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "uri": "/canary/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v1-svc.default.svc.cluster.local:80": 8,
        "app-v2-svc.default.svc.cluster.local:80": 2
      }
    }
  }'
```

### Phase 4: Comparative Testing (Day 4–5)

#### Test Matrix

| Test Case | NGINX Ingress | APISIX | Tool |
|---|---|---|---|
| **TC-01:** Path-based routing | ✅ Ingress YAML | ✅ Admin API / CRD | curl |
| **TC-02:** Host-based routing | ✅ Ingress YAML | ✅ Admin API / CRD | curl |
| **TC-03:** Rate limiting | ⚠️ Annotation-only | ✅ Plugin (granular) | hey / k6 |
| **TC-04:** API Key auth | ❌ Not built-in | ✅ key-auth plugin | curl |
| **TC-05:** JWT auth | ❌ Not built-in | ✅ jwt-auth plugin | curl |
| **TC-06:** Canary release (weighted) | ⚠️ Limited (canary annotation) | ✅ Weighted upstream | k6 |
| **TC-07:** Request transformation | ⚠️ Annotation-based | ✅ proxy-rewrite plugin | curl |
| **TC-08:** Prometheus metrics | ✅ Built-in | ✅ prometheus plugin | Grafana |
| **TC-09:** Access logging | ✅ NGINX logs | ✅ http-logger / file-logger | kubectl logs |
| **TC-10:** Hot config reload | ❌ Requires reload | ✅ Real-time via etcd | curl + verify |

#### Sample Load Test Script (using `hey`)

```bash
# Test NGINX Ingress rate limiting
hey -n 200 -c 20 -H "Host: demo-limited.local" http://localhost:80/

# Test APISIX rate limiting
hey -n 200 -c 20 http://localhost:9080/v1/

# Test APISIX canary distribution
for i in $(seq 1 100); do
  curl -s http://localhost:9080/canary/ 2>&1
done | sort | uniq -c
```

### Phase 5: Observability Setup (Day 5)

#### APISIX Prometheus + Grafana Stack

```bash
# Enable Prometheus plugin globally in APISIX
curl http://127.0.0.1:9180/apisix/admin/global_rules/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "plugins": {
      "prometheus": {}
    }
  }'

# Install Prometheus + Grafana via Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

### Phase 6: Documentation & Decision (Day 6)

Document findings in the evaluation matrix below.

---

## 6. Evaluation Criteria & Scoring

| Criteria | Weight | NGINX Ingress | APISIX | Notes |
|---|---|---|---|---|
| **Ease of Setup** | 15% | _/5 | _/5 | Time to first route |
| **Routing Flexibility** | 15% | _/5 | _/5 | Path, host, header-based |
| **Traffic Management** | 20% | _/5 | _/5 | Rate limit, circuit breaker, retry |
| **Security Features** | 20% | _/5 | _/5 | Auth, mTLS, IP control |
| **Observability** | 15% | _/5 | _/5 | Metrics, logging, tracing |
| **Canary/Blue-Green** | 10% | _/5 | _/5 | Traffic splitting |
| **Operational Overhead** | 5% | _/5 | _/5 | Resource usage, maintenance |
| **Weighted Total** | 100% | _/5 | _/5 | |

---

## 7. Timeline Summary

| Phase | Activity | Duration | Deliverable |
|---|---|---|---|
| Phase 1 | Environment Setup | Day 1 | Kind cluster + sample apps running |
| Phase 2 | NGINX Ingress Controller | Day 2 | Ingress routing + rate limiting |
| Phase 3 | Apache APISIX Setup | Day 3 | APISIX routing + plugins configured |
| Phase 4 | Comparative Testing | Day 4–5 | Test results for all 10 test cases |
| Phase 5 | Observability | Day 5 | Prometheus + Grafana dashboards |
| Phase 6 | Documentation & Decision | Day 6 | Final report with recommendation |

---

## 8. Expected Outcomes

Based on typical enterprise evaluations:

- **Choose NGINX Ingress** when your needs are limited to simple L7 routing, you want minimal operational overhead, and your team is already familiar with NGINX configuration patterns. Best for small-to-medium deployments without complex API management requirements.

- **Choose Apache APISIX** when you need a full API Gateway with built-in security, traffic management, observability, and plugin extensibility. Best for microservices architectures in financial services, retail, or manufacturing where API governance and fine-grained traffic control are critical.

- **Hybrid Approach** — In many enterprise scenarios, teams use NGINX Ingress for internal east-west traffic and APISIX as the API Gateway for north-south (external) traffic. This is a common pattern in banking and financial services platforms.

---

## 9. Risk & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Kind resource constraints | Tests may not reflect production perf | Document as "functional comparison only" |
| APISIX etcd dependency | Single point of failure | Use etcd cluster (3 nodes) in production |
| Version compatibility | Helm chart / K8s version mismatch | Pin specific versions in PoC |
| Network policy conflicts | Port mapping issues on Kind | Pre-test connectivity before test cases |

---

## 10. Appendix: Glossary

| Term | Definition |
|---|---|
| **L7 Routing** | Routing decisions based on HTTP attributes (path, host, headers) — Layer 7 of the OSI model |
| **Ingress Controller** | Software that implements the Kubernetes Ingress specification |
| **CRD** | Custom Resource Definition — extends the Kubernetes API with custom object types |
| **etcd** | Distributed key-value store used by APISIX for configuration storage |
| **North-South Traffic** | Traffic entering/leaving the cluster (external clients to internal services) |
| **East-West Traffic** | Traffic between services within the cluster (service-to-service) |
| **Canary Release** | Gradually shifting traffic from an old version to a new version |
| **Circuit Breaker** | Pattern that stops sending requests to a failing service to let it recover |
| **mTLS** | Mutual TLS — both client and server authenticate each other with certificates |

---

*End of PoC Plan*
