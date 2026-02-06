# Apache APISIX PoC 完整實作指南

> **目標**：在 Kubernetes（EKS）上搭建 Apache APISIX，驗證藍綠部署、安全性、流量控制、可觀測性等企業級 API Gateway 功能。
>
> **前提**：已有 K8s 叢集（Minikube / Kind / EKS）、Helm 3、kubectl 已安裝。

---

## Phase 0：環境準備

### 0-1. 建立 Namespace

```bash
kubectl create namespace apisix
kubectl create namespace demo
kubectl create namespace monitoring
```

### 0-2. 建立 Demo 應用

#### Blue 版本（v1）— 模擬 Spring Boot 2 / JDK 8

**Dockerfile-v1**

```dockerfile
FROM eclipse-temurin:8-jre-alpine
COPY demo-app-v1.jar /app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
```

如果暫時不想建置 Spring Boot 專案，可以用 Nginx 快速模擬：

**demo-v1-configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-v1-config
  namespace: demo
data:
  default.conf: |
    server {
      listen 8080;
      location /api/info {
        default_type application/json;
        return 200 '{"version":"v1","color":"blue","timestamp":"$time_iso8601"}';
      }
      location /api/health {
        default_type application/json;
        return 200 '{"status":"UP"}';
      }
      location /api/orders {
        default_type application/json;
        return 200 '{"orders":[{"id":1,"item":"Widget","version":"v1"}]}';
      }
      location /api/slow {
        default_type application/json;
        # 模擬慢回應，用於測試 timeout
        return 200 '{"message":"slow response from v1"}';
      }
    }
```

**demo-v1-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-v1
  namespace: demo
  labels:
    app: demo
    version: v1
    color: blue
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
        color: blue
    spec:
      containers:
        - name: demo
          image: nginx:1.25-alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/conf.d
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
      volumes:
        - name: config
          configMap:
            name: demo-v1-config
---
apiVersion: v1
kind: Service
metadata:
  name: demo-v1
  namespace: demo
  labels:
    app: demo
    version: v1
spec:
  selector:
    app: demo
    version: v1
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
```

#### Green 版本（v2）— 模擬 Spring Boot 3 / JDK 17

**demo-v2-configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-v2-config
  namespace: demo
data:
  default.conf: |
    server {
      listen 8080;
      location /api/info {
        default_type application/json;
        return 200 '{"version":"v2","color":"green","timestamp":"$time_iso8601","features":["new-feature-a"]}';
      }
      location /api/health {
        default_type application/json;
        return 200 '{"status":"UP"}';
      }
      location /api/orders {
        default_type application/json;
        return 200 '{"orders":[{"id":1,"item":"Widget","version":"v2"},{"id":2,"item":"Gadget","version":"v2"}]}';
      }
      location /api/slow {
        default_type application/json;
        return 200 '{"message":"fast response from v2"}';
      }
    }
```

**demo-v2-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-v2
  namespace: demo
  labels:
    app: demo
    version: v2
    color: green
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
        color: green
    spec:
      containers:
        - name: demo
          image: nginx:1.25-alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/conf.d
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
      volumes:
        - name: config
          configMap:
            name: demo-v2-config
---
apiVersion: v1
kind: Service
metadata:
  name: demo-v2
  namespace: demo
  labels:
    app: demo
    version: v2
spec:
  selector:
    app: demo
    version: v2
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
```

#### 部署 Demo 應用

```bash
kubectl apply -f demo-v1-configmap.yaml
kubectl apply -f demo-v1-deployment.yaml
kubectl apply -f demo-v2-configmap.yaml
kubectl apply -f demo-v2-deployment.yaml

# 驗證
kubectl get pods -n demo
kubectl exec -it <any-pod> -n demo -- curl http://demo-v1.demo.svc:8080/api/info
kubectl exec -it <any-pod> -n demo -- curl http://demo-v2.demo.svc:8080/api/info
```

### 0-3. 部署 APISIX

#### 建立 Helm values 檔

**apisix-values.yaml**

```yaml
apisix:
  enabled: true
  image:
    repository: apache/apisix
    tag: 3.9.1-debian

  # Admin API 設定
  admin:
    enabled: true
    type: ClusterIP
    port: 9180
    adminAPIVersion: v3   # 使用 v3 Admin API
    credentials:
      admin: "poc-admin-key-2024"       # 自訂 Admin API Key
      viewer: "poc-viewer-key-2024"

  # Data Plane 設定
  gateway:
    type: LoadBalancer    # EKS 上用 LoadBalancer；本地用 NodePort
    http:
      enabled: true
      containerPort: 9080
    tls:
      enabled: true
      containerPort: 9443

  # Prometheus Plugin 全域啟用
  pluginAttrs:
    prometheus:
      export_addr:
        ip: "0.0.0.0"
        port: 9091

  # 啟用的 Plugins 清單
  plugins:
    - traffic-split
    - proxy-rewrite
    - response-rewrite
    - key-auth
    - jwt-auth
    - cors
    - ip-restriction
    - limit-req
    - limit-count
    - api-breaker
    - prometheus
    - http-logger
    - zipkin
    - opentelemetry
    - request-validation
    - client-control
    - real-ip
    - redirect
    - grpc-transcode

# etcd 設定
etcd:
  enabled: true
  replicaCount: 1         # PoC 用 1；正式環境建議 3
  persistence:
    enabled: true
    size: 5Gi

# Dashboard
dashboard:
  enabled: true
  service:
    type: ClusterIP
  config:
    authentication:
      secret: "poc-dashboard-secret"

# Ingress Controller
ingressController:
  enabled: true
  config:
    apisix:
      adminAPIVersion: v3
      serviceNamespace: apisix
```

#### 安裝 APISIX

```bash
# 加入 Helm Repo
helm repo add apisix https://charts.apiseven.com
helm repo update

# 安裝
helm install apisix apisix/apisix \
  -f apisix-values.yaml \
  -n apisix

# 驗證 Pod 狀態
kubectl get pods -n apisix

# 等待所有 Pod Ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=apisix -n apisix --timeout=120s
```

#### 驗證 Admin API

```bash
# Port-forward Admin API
kubectl port-forward svc/apisix-admin -n apisix 9180:9180 &

# 測試連線
curl -s http://127.0.0.1:9180/apisix/admin/routes \
  -H "X-API-KEY: poc-admin-key-2024" | jq .

# Port-forward Gateway
kubectl port-forward svc/apisix-gateway -n apisix 9080:80 &
```

#### 設定環境變數（後續步驟共用）

```bash
export APISIX_ADMIN="http://127.0.0.1:9180/apisix/admin"
export APISIX_API_KEY="poc-admin-key-2024"
export APISIX_GATEWAY="http://127.0.0.1:9080"
```

---

## Phase 1：核心路由與藍綠部署

### 1-1. 建立 Upstream

#### Blue Upstream（v1）

```bash
curl -i "${APISIX_ADMIN}/upstreams/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-blue-v1",
    "desc": "Blue deployment - Spring Boot 2 / JDK 8",
    "type": "roundrobin",
    "scheme": "http",
    "nodes": {
      "demo-v1.demo.svc.cluster.local:8080": 1
    },
    "timeout": {
      "connect": 5,
      "send": 10,
      "read": 10
    },
    "checks": {
      "active": {
        "type": "http",
        "http_path": "/api/health",
        "healthy": {
          "interval": 5,
          "successes": 2
        },
        "unhealthy": {
          "interval": 3,
          "http_failures": 3,
          "tcp_failures": 3
        }
      }
    }
  }'
```

#### Green Upstream（v2）

```bash
curl -i "${APISIX_ADMIN}/upstreams/2" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-green-v2",
    "desc": "Green deployment - Spring Boot 3 / JDK 17",
    "type": "roundrobin",
    "scheme": "http",
    "nodes": {
      "demo-v2.demo.svc.cluster.local:8080": 1
    },
    "timeout": {
      "connect": 5,
      "send": 10,
      "read": 10
    },
    "checks": {
      "active": {
        "type": "http",
        "http_path": "/api/health",
        "healthy": {
          "interval": 5,
          "successes": 2
        },
        "unhealthy": {
          "interval": 3,
          "http_failures": 3,
          "tcp_failures": 3
        }
      }
    }
  }'
```

### 1-2. 建立路由 — 全量 Blue

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-api-route",
    "desc": "Main API route with blue-green traffic split",
    "uri": "/api/*",
    "methods": ["GET", "POST", "PUT", "DELETE", "PATCH"],
    "upstream_id": "1",
    "plugins": {}
  }'
```

**驗證：**

```bash
# 所有請求應該回傳 v1 / blue
for i in $(seq 1 10); do
  curl -s "${APISIX_GATEWAY}/api/info" | jq -r '.version + " " + .color'
done
```

預期輸出全部為 `v1 blue`。

### 1-3. 啟用 traffic-split — 藍綠切換

#### 場景 A：金絲雀發布（90% Blue / 10% Green）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              {
                "upstream_id": "2",
                "weight": 10
              },
              {
                "weight": 90
              }
            ]
          }
        ]
      }
    }
  }'
```

> **注意**：`weighted_upstreams` 中不帶 `upstream_id` 的項目代表使用 Route 的預設 upstream（即 Blue）。

**驗證：**

```bash
# 跑 100 次，統計 v1/v2 比例
echo "=== Traffic Split Test (expect ~90:10) ==="
for i in $(seq 1 100); do
  curl -s "${APISIX_GATEWAY}/api/info" | jq -r '.version'
done | sort | uniq -c
```

#### 場景 B：50/50 切換

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 50 },
              { "weight": 50 }
            ]
          }
        ]
      }
    }
  }'
```

#### 場景 C：全量切換到 Green

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 100 },
              { "weight": 0 }
            ]
          }
        ]
      }
    }
  }'
```

#### 場景 D：回切到 Blue（Rollback）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 0 },
              { "weight": 100 }
            ]
          }
        ]
      }
    }
  }'
```

### 1-4. Header-Based 路由（測試人員直通 Green）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "match": [
              {
                "vars": [
                  ["http_X-Canary", "==", "true"]
                ]
              }
            ],
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 100 }
            ]
          },
          {
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 10 },
              { "weight": 90 }
            ]
          }
        ]
      }
    }
  }'
```

**驗證：**

```bash
# 帶 header → 一定走 Green
echo "=== With X-Canary header ==="
for i in $(seq 1 5); do
  curl -s -H "X-Canary: true" "${APISIX_GATEWAY}/api/info" | jq -r '.version + " " + .color'
done

# 不帶 header → 走 90:10
echo "=== Without header (90:10) ==="
for i in $(seq 1 20); do
  curl -s "${APISIX_GATEWAY}/api/info" | jq -r '.version'
done | sort | uniq -c
```

### 1-5. Cookie-Based 路由（Beta 用戶）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "match": [
              {
                "vars": [
                  ["cookie_beta_user", "==", "true"]
                ]
              }
            ],
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 100 }
            ]
          },
          {
            "match": [
              {
                "vars": [
                  ["http_X-Canary", "==", "true"]
                ]
              }
            ],
            "weighted_upstreams": [
              { "upstream_id": "2", "weight": 100 }
            ]
          },
          {
            "weighted_upstreams": [
              { "weight": 100 }
            ]
          }
        ]
      }
    }
  }'
```

**驗證：**

```bash
# Cookie-based routing
curl -s -b "beta_user=true" "${APISIX_GATEWAY}/api/info" | jq .
```

---

## Phase 2：安全性

### 2-1. 建立新 Route 用於安全性測試

為避免與 Phase 1 的 traffic-split 設定互相干擾，另建一條 Route：

```bash
curl -i "${APISIX_ADMIN}/routes/10" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-secure-route",
    "desc": "Route for security plugin testing",
    "uri": "/secure/api/*",
    "methods": ["GET", "POST", "PUT", "DELETE"],
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/secure/api/(.*)", "/api/$1"]
      }
    }
  }'
```

### 2-2. Key Auth

#### 建立 Consumer

```bash
curl -i "${APISIX_ADMIN}/consumers" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "username": "app-client-01",
    "desc": "PoC Test Client",
    "plugins": {
      "key-auth": {
        "key": "poc-test-api-key-001"
      }
    }
  }'
```

#### 在 Route 上啟用 key-auth

```bash
curl -i "${APISIX_ADMIN}/routes/10" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/secure/api/(.*)", "/api/$1"]
      },
      "key-auth": {}
    }
  }'
```

**驗證：**

```bash
# 無 API Key → 401
echo "=== No API Key ==="
curl -s -o /dev/null -w "%{http_code}" "${APISIX_GATEWAY}/secure/api/info"
echo ""

# 錯誤 Key → 401
echo "=== Wrong API Key ==="
curl -s -o /dev/null -w "%{http_code}" \
  -H "apikey: wrong-key" \
  "${APISIX_GATEWAY}/secure/api/info"
echo ""

# 正確 Key → 200
echo "=== Correct API Key ==="
curl -s -H "apikey: poc-test-api-key-001" \
  "${APISIX_GATEWAY}/secure/api/info" | jq .
```

### 2-3. JWT Auth

#### 建立 Consumer with JWT

```bash
curl -i "${APISIX_ADMIN}/consumers" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "username": "jwt-client-01",
    "desc": "JWT Test Client",
    "plugins": {
      "jwt-auth": {
        "key": "jwt-client-key-001",
        "secret": "my-jwt-secret-key-for-poc-2024",
        "algorithm": "HS256",
        "exp": 86400
      }
    }
  }'
```

#### 建立 JWT 專用 Route

```bash
curl -i "${APISIX_ADMIN}/routes/11" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-jwt-route",
    "desc": "Route with JWT authentication",
    "uri": "/jwt/api/*",
    "methods": ["GET", "POST", "PUT", "DELETE"],
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/jwt/api/(.*)", "/api/$1"]
      },
      "jwt-auth": {}
    }
  }'
```

#### 取得 JWT Token（APISIX 內建簽發 endpoint）

```bash
# 建立 Token 簽發 Route
curl -i "${APISIX_ADMIN}/routes/12" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "jwt-sign",
    "desc": "JWT token signing endpoint",
    "uri": "/apisix/plugin/jwt/sign",
    "plugins": {
      "public-api": {}
    }
  }'

# 簽發 Token
JWT_TOKEN=$(curl -s "${APISIX_GATEWAY}/apisix/plugin/jwt/sign?key=jwt-client-key-001" | jq -r '.')
echo "Token: ${JWT_TOKEN}"
```

**驗證：**

```bash
# 無 Token → 401
echo "=== No JWT Token ==="
curl -s -o /dev/null -w "%{http_code}" "${APISIX_GATEWAY}/jwt/api/info"
echo ""

# 偽造 Token → 401
echo "=== Fake Token ==="
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer fake.jwt.token" \
  "${APISIX_GATEWAY}/jwt/api/info"
echo ""

# 合法 Token → 200
echo "=== Valid JWT Token ==="
curl -s -H "Authorization: Bearer ${JWT_TOKEN}" \
  "${APISIX_GATEWAY}/jwt/api/info" | jq .
```

### 2-4. CORS

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "weight": 100 }
            ]
          }
        ]
      },
      "cors": {
        "allow_origins": "https://app.example.com,https://admin.example.com",
        "allow_methods": "GET,POST,PUT,DELETE,OPTIONS",
        "allow_headers": "Authorization,Content-Type,X-Canary,apikey",
        "expose_headers": "X-Request-Id",
        "max_age": 3600,
        "allow_credential": true
      }
    }
  }'
```

**驗證：**

```bash
# Preflight 請求
echo "=== CORS Preflight ==="
curl -s -I -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Authorization,Content-Type" \
  "${APISIX_GATEWAY}/api/info" 2>&1 | grep -i "access-control"

# 非允許的 Origin
echo "=== Disallowed Origin ==="
curl -s -I -H "Origin: https://evil.com" \
  "${APISIX_GATEWAY}/api/info" 2>&1 | grep -i "access-control"
```

### 2-5. IP 限制

```bash
curl -i "${APISIX_ADMIN}/routes/13" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-ip-restricted",
    "desc": "IP-restricted route (admin only)",
    "uri": "/admin/api/*",
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/admin/api/(.*)", "/api/$1"]
      },
      "ip-restriction": {
        "whitelist": [
          "127.0.0.1",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ],
        "message": "Access denied: your IP is not in the whitelist"
      }
    }
  }'
```

**驗證：**

```bash
# 從允許的 IP（本地）
curl -s "${APISIX_GATEWAY}/admin/api/info" | jq .

# 模擬被拒的 IP（透過 X-Forwarded-For，需搭配 real-ip plugin）
```

### 2-6. mTLS 設定（Client ↔ APISIX）

#### 產生自簽憑證（PoC 用）

```bash
# 建立 CA
openssl req -x509 -newkey rsa:4096 -days 365 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=APISIX-PoC-CA"

# 建立 Server 憑證
openssl req -newkey rsa:4096 -nodes \
  -keyout server.key -out server.csr \
  -subj "/CN=apisix-gateway"

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365

# 建立 Client 憑證
openssl req -newkey rsa:4096 -nodes \
  -keyout client.key -out client.csr \
  -subj "/CN=poc-client"

openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 365

# 建立 K8s Secret
kubectl create secret generic apisix-mtls \
  --from-file=ca.crt=ca.crt \
  --from-file=tls.crt=server.crt \
  --from-file=tls.key=server.key \
  -n apisix
```

#### 設定 APISIX SSL

```bash
# 讀取憑證內容
CA_CRT=$(cat ca.crt)
SERVER_CRT=$(cat server.crt)
SERVER_KEY=$(cat server.key)

curl -i "${APISIX_ADMIN}/ssls/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d "{
    \"cert\": \"${SERVER_CRT}\",
    \"key\": \"${SERVER_KEY}\",
    \"client\": {
      \"ca\": \"${CA_CRT}\"
    },
    \"snis\": [\"apisix-gateway.example.com\"]
  }"
```

**驗證 mTLS：**

```bash
# 無 Client 憑證 → 失敗
curl -s --cacert ca.crt \
  "https://apisix-gateway.example.com:9443/api/info"

# 帶 Client 憑證 → 成功
curl -s --cacert ca.crt \
  --cert client.crt --key client.key \
  "https://apisix-gateway.example.com:9443/api/info" | jq .
```

---

## Phase 3：流量控制與保護

### 3-1. Rate Limiting

#### limit-count（時間窗口計數限流）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "weight": 100 }
            ]
          }
        ]
      },
      "limit-count": {
        "count": 100,
        "time_window": 60,
        "rejected_code": 429,
        "rejected_msg": "{\"error\":\"rate_limit_exceeded\",\"message\":\"Too many requests, please retry after 60 seconds\"}",
        "key_type": "var",
        "key": "remote_addr",
        "policy": "local"
      }
    }
  }'
```

**驗證：**

```bash
# 安裝壓測工具
# macOS: brew install hey
# Linux: go install github.com/rakyll/hey@latest

# 發送 200 個請求（超過 100 上限）
hey -n 200 -c 10 "${APISIX_GATEWAY}/api/info"

# 或用 curl 驗證 header
curl -s -I "${APISIX_GATEWAY}/api/info" | grep -E "X-RateLimit|HTTP"
# 應看到: X-RateLimit-Limit, X-RateLimit-Remaining
```

#### limit-req（漏桶限流）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "weight": 100 }
            ]
          }
        ]
      },
      "limit-count": {
        "count": 100,
        "time_window": 60,
        "rejected_code": 429,
        "key_type": "var",
        "key": "remote_addr",
        "policy": "local"
      },
      "limit-req": {
        "rate": 10,
        "burst": 20,
        "rejected_code": 429,
        "key_type": "var",
        "key": "remote_addr"
      }
    }
  }'
```

### 3-2. Circuit Breaker（api-breaker）

```bash
curl -i "${APISIX_ADMIN}/routes/14" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-circuit-breaker",
    "desc": "Route with circuit breaker",
    "uri": "/cb/api/*",
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/cb/api/(.*)", "/api/$1"]
      },
      "api-breaker": {
        "break_response_code": 502,
        "break_response_body": "{\"error\":\"circuit_open\",\"message\":\"Service temporarily unavailable, circuit breaker is open\"}",
        "break_response_headers": [
          {
            "key": "Content-Type",
            "value": "application/json"
          }
        ],
        "max_breaker_sec": 60,
        "unhealthy": {
          "http_statuses": [500, 502, 503],
          "failures": 3
        },
        "healthy": {
          "http_statuses": [200],
          "successes": 3
        }
      }
    }
  }'
```

**驗證（模擬後端故障）：**

```bash
# 1. 先確認正常
curl -s "${APISIX_GATEWAY}/cb/api/info" | jq .

# 2. 把 Blue upstream 的 pod 全部 scale 到 0
kubectl scale deployment demo-v1 -n demo --replicas=0

# 3. 連續請求，觸發熔斷（3 次失敗後）
for i in $(seq 1 5); do
  echo "Request $i:"
  curl -s -o /dev/null -w "HTTP %{http_code}\n" "${APISIX_GATEWAY}/cb/api/info"
  sleep 1
done

# 4. 恢復 pod
kubectl scale deployment demo-v1 -n demo --replicas=2

# 5. 等待恢復（最多 60 秒）
sleep 30
curl -s "${APISIX_GATEWAY}/cb/api/info" | jq .
```

### 3-3. 健康檢查（已在 Upstream 設定中包含）

回顧 Phase 1 中 Upstream 的 `checks` 設定，此處做進階驗證：

```bash
# 查看 Upstream 健康狀態
curl -s "${APISIX_ADMIN}/upstreams/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" | jq '.value.checks'

# 測試步驟:
# 1. 刪除一個 v1 的 pod
kubectl delete pod -l app=demo,version=v1 -n demo --wait=false

# 2. 持續監控，流量應自動避開 unhealthy node
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "HTTP %{http_code}\n" "${APISIX_GATEWAY}/api/info"
  sleep 2
done

# 3. 驗證 pod 自動恢復後流量回到正常
kubectl get pods -n demo -w
```

### 3-4. 請求大小限制

```bash
curl -i "${APISIX_ADMIN}/global_rules/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "plugins": {
      "client-control": {
        "max_body_size": 2097152
      }
    }
  }'
```

> `max_body_size`：2MB（2 * 1024 * 1024 = 2097152 bytes）

**驗證：**

```bash
# 產生一個 3MB 的假檔案
dd if=/dev/zero of=/tmp/large-file.bin bs=1M count=3 2>/dev/null

# 上傳 → 應被拒（413）
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -X POST \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/tmp/large-file.bin \
  "${APISIX_GATEWAY}/api/orders"
```

---

## Phase 4：可觀測性

### 4-1. Prometheus 指標收集

#### 啟用全域 Prometheus Plugin

```bash
curl -i "${APISIX_ADMIN}/global_rules/2" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "plugins": {
      "prometheus": {
        "prefer_name": true
      }
    }
  }'
```

#### 驗證指標端點

```bash
# Port-forward Prometheus metrics
kubectl port-forward svc/apisix-gateway -n apisix 9091:9091 &

curl -s http://127.0.0.1:9091/apisix/prometheus/metrics | head -50
# 應看到: apisix_http_status, apisix_http_latency, apisix_bandwidth 等
```

#### 部署 Prometheus

**prometheus-values.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
      - job_name: 'apisix'
        metrics_path: '/apisix/prometheus/metrics'
        static_configs:
          - targets: ['apisix-gateway.apisix.svc.cluster.local:9091']
        scrape_interval: 10s
```

**prometheus-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.50.1
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: data
              mountPath: /prometheus
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.path=/prometheus"
            - "--storage.tsdb.retention.time=7d"
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    app: prometheus
  ports:
    - port: 9090
      targetPort: 9090
```

```bash
kubectl apply -f prometheus-values.yaml
kubectl apply -f prometheus-deployment.yaml
```

#### 部署 Grafana

**grafana-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:10.3.3
          ports:
            - containerPort: 3000
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: "admin"
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: "apisix-poc-2024"
          volumeMounts:
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
      volumes:
        - name: datasources
          configMap:
            name: grafana-datasources
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus.monitoring.svc.cluster.local:9090
        isDefault: true
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: monitoring
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
```

```bash
kubectl apply -f grafana-deployment.yaml

# Port-forward Grafana
kubectl port-forward svc/grafana -n monitoring 3000:3000 &
# 瀏覽 http://localhost:3000 (admin / apisix-poc-2024)
```

#### 匯入 APISIX Grafana Dashboard

登入 Grafana 後：

1. 左側選單 → Dashboards → Import
2. 輸入 Dashboard ID: **11719**（APISIX 官方 Dashboard）
3. 選擇 Prometheus data source
4. 點選 Import

**關鍵監控指標：**

| 指標 | PromQL |
|---|---|
| QPS by Route | `sum(rate(apisix_http_status{route!=""}[1m])) by (route)` |
| P95 Latency | `histogram_quantile(0.95, rate(apisix_http_latency_bucket[5m]))` |
| Error Rate | `sum(rate(apisix_http_status{code=~"5.."}[1m])) / sum(rate(apisix_http_status[1m]))` |
| Upstream Health | `apisix_upstream_status` |
| Bandwidth In/Out | `sum(rate(apisix_bandwidth{type="ingress"}[1m]))` |

### 4-2. HTTP Logger

```bash
# 假設你有一個 log 收集端點（如 Fluentd / Logstash HTTP input）
# 這裡用一個簡單的 echo server 模擬

curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "weight": 100 }
            ]
          }
        ]
      },
      "http-logger": {
        "uri": "http://log-collector.monitoring.svc.cluster.local:8080/logs",
        "batch_max_size": 100,
        "max_retry_count": 3,
        "retry_delay": 2,
        "buffer_duration": 10,
        "inactive_timeout": 5,
        "concat_method": "json",
        "include_resp_body": false
      }
    }
  }'
```

#### 替代方案：Kafka Logger（適合大量日誌場景）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "kafka-logger": {
        "broker_list": {
          "kafka.monitoring.svc.cluster.local": 9092
        },
        "kafka_topic": "apisix-access-log",
        "batch_max_size": 200,
        "buffer_duration": 10,
        "key": "route_id"
      }
    }
  }'
```

### 4-3. 分散式追蹤（OpenTelemetry）

#### 部署 Jaeger

**jaeger-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.54
          ports:
            - containerPort: 16686  # UI
            - containerPort: 4318   # OTLP HTTP
            - containerPort: 14268  # Jaeger HTTP
          env:
            - name: COLLECTOR_OTLP_ENABLED
              value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: monitoring
spec:
  selector:
    app: jaeger
  ports:
    - name: ui
      port: 16686
      targetPort: 16686
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: jaeger-http
      port: 14268
      targetPort: 14268
```

```bash
kubectl apply -f jaeger-deployment.yaml
```

#### 啟用 OpenTelemetry Plugin

```bash
curl -i "${APISIX_ADMIN}/global_rules/3" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "plugins": {
      "opentelemetry": {
        "sampler": {
          "name": "always_on"
        },
        "additional_attributes": [
          "http_method",
          "http_url"
        ]
      }
    }
  }'
```

> **注意**：OpenTelemetry collector endpoint 需在 `apisix-values.yaml` 的 `pluginAttrs` 中設定：

```yaml
  pluginAttrs:
    opentelemetry:
      resource:
        service.name: "APISIX-PoC"
      collector:
        address: "jaeger.monitoring.svc.cluster.local:4318"
        request_timeout: 3
```

修改後需重啟 APISIX：

```bash
helm upgrade apisix apisix/apisix -f apisix-values.yaml -n apisix
```

**驗證：**

```bash
# 發幾個請求
for i in $(seq 1 10); do
  curl -s "${APISIX_GATEWAY}/api/info" > /dev/null
done

# Port-forward Jaeger UI
kubectl port-forward svc/jaeger -n monitoring 16686:16686 &
# 瀏覽 http://localhost:16686
# 選擇 Service: APISIX-PoC → Find Traces
```

---

## Phase 5：請求/回應處理

### 5-1. 請求改寫（proxy-rewrite）

```bash
curl -i "${APISIX_ADMIN}/routes/15" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-rewrite",
    "desc": "Request rewrite demo",
    "uri": "/v1/api/*",
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/v1/api/(.*)", "/api/$1"],
        "headers": {
          "set": {
            "X-Request-Source": "apisix-gateway",
            "X-Forwarded-Prefix": "/v1",
            "X-Request-ID": "$request_id"
          },
          "remove": [
            "X-Debug-Internal"
          ]
        }
      }
    }
  }'
```

**驗證：**

```bash
# /v1/api/info → 內部改寫為 /api/info
curl -s -H "X-Debug-Internal: should-be-removed" \
  "${APISIX_GATEWAY}/v1/api/info" | jq .
```

### 5-2. 回應改寫（response-rewrite）

```bash
curl -i "${APISIX_ADMIN}/routes/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PATCH \
  -d '{
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "weighted_upstreams": [
              { "weight": 100 }
            ]
          }
        ]
      },
      "response-rewrite": {
        "headers": {
          "set": {
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
            "X-XSS-Protection": "1; mode=block",
            "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "X-Gateway": "APISIX"
          },
          "remove": [
            "Server",
            "X-Powered-By"
          ]
        }
      }
    }
  }'
```

**驗證：**

```bash
curl -s -I "${APISIX_GATEWAY}/api/info" | grep -E "X-Content-Type|X-Frame|X-XSS|Strict-Transport|X-Gateway|Server"
```

### 5-3. 請求驗證（request-validation）

```bash
curl -i "${APISIX_ADMIN}/routes/16" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-validation",
    "desc": "Route with request body validation",
    "uri": "/validated/api/orders",
    "methods": ["POST"],
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "uri": "/api/orders"
      },
      "request-validation": {
        "body_schema": {
          "type": "object",
          "required": ["customerId", "items"],
          "properties": {
            "customerId": {
              "type": "string",
              "minLength": 1,
              "maxLength": 50,
              "pattern": "^[A-Z0-9-]+$"
            },
            "items": {
              "type": "array",
              "minItems": 1,
              "maxItems": 100,
              "items": {
                "type": "object",
                "required": ["productId", "quantity"],
                "properties": {
                  "productId": {
                    "type": "string"
                  },
                  "quantity": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 9999
                  },
                  "price": {
                    "type": "number",
                    "minimum": 0
                  }
                }
              }
            },
            "notes": {
              "type": "string",
              "maxLength": 500
            }
          },
          "additionalProperties": false
        },
        "rejected_code": 400,
        "rejected_msg": "Request body validation failed"
      }
    }
  }'
```

**驗證：**

```bash
# 合法請求 → 200
echo "=== Valid Request ==="
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "CUST-001",
    "items": [
      {"productId": "PROD-A", "quantity": 2, "price": 99.99}
    ]
  }' \
  "${APISIX_GATEWAY}/validated/api/orders"

# 缺少必要欄位 → 400
echo "=== Missing required field ==="
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"customerId": "CUST-001"}' \
  "${APISIX_GATEWAY}/validated/api/orders"

# 格式錯誤 → 400
echo "=== Invalid format ==="
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "invalid id with spaces!",
    "items": [{"productId": "A", "quantity": -1}]
  }' \
  "${APISIX_GATEWAY}/validated/api/orders"

# 多餘欄位 → 400 (additionalProperties: false)
echo "=== Extra fields ==="
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "CUST-001",
    "items": [{"productId": "A", "quantity": 1}],
    "hack": "injection"
  }' \
  "${APISIX_GATEWAY}/validated/api/orders"
```

---

## Phase 6：進階功能

### 6-1. Global Rules（全域 Plugin）

已在前面各 Phase 建立了部分 Global Rules，這裡整理完整的全域配置：

```bash
# 查看所有 Global Rules
curl -s "${APISIX_ADMIN}/global_rules" \
  -H "X-API-KEY: ${APISIX_API_KEY}" | jq '.list[].value.plugins | keys'
```

### 6-2. Consumer Group（共享 Plugin 配置）

適用於多個 Consumer 共享相同的限流策略：

```bash
# 建立 Consumer Group
curl -i "${APISIX_ADMIN}/consumer_groups/standard-tier" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "desc": "Standard tier - 100 req/min",
    "plugins": {
      "limit-count": {
        "count": 100,
        "time_window": 60,
        "rejected_code": 429,
        "group": "standard-tier"
      }
    }
  }'

curl -i "${APISIX_ADMIN}/consumer_groups/premium-tier" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "desc": "Premium tier - 1000 req/min",
    "plugins": {
      "limit-count": {
        "count": 1000,
        "time_window": 60,
        "rejected_code": 429,
        "group": "premium-tier"
      }
    }
  }'

# Consumer 綁定 Group
curl -i "${APISIX_ADMIN}/consumers" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "username": "premium-client-01",
    "group_id": "premium-tier",
    "plugins": {
      "key-auth": {
        "key": "premium-api-key-001"
      }
    }
  }'
```

### 6-3. Service 抽象層

將共用的 upstream + plugin 組合封裝成 Service：

```bash
curl -i "${APISIX_ADMIN}/services/1" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-service",
    "desc": "Demo application service with common plugins",
    "upstream_id": "1",
    "plugins": {
      "cors": {
        "allow_origins": "https://app.example.com",
        "allow_methods": "GET,POST,PUT,DELETE,OPTIONS",
        "allow_headers": "Authorization,Content-Type",
        "max_age": 3600
      },
      "response-rewrite": {
        "headers": {
          "set": {
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY"
          },
          "remove": ["Server"]
        }
      }
    }
  }'

# Route 引用 Service
curl -i "${APISIX_ADMIN}/routes/17" \
  -H "X-API-KEY: ${APISIX_API_KEY}" \
  -X PUT \
  -d '{
    "name": "demo-via-service",
    "uri": "/svc/api/*",
    "service_id": "1",
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/svc/api/(.*)", "/api/$1"]
      }
    }
  }'
```

### 6-4. Declarative Configuration（YAML / GitOps）

#### 安裝 ADC（APISIX Declarative CLI）

```bash
# 方法 1：使用 Go 安裝
go install github.com/api7/adc@latest

# 方法 2：使用 Docker
docker pull api7/adc:latest
```

#### 建立 Declarative Config

**apisix-config.yaml**

```yaml
services:
  - name: demo-service
    id: "1"
    desc: "Demo application service"
    upstream:
      id: "1"
      name: demo-blue-v1
      type: roundrobin
      nodes:
        - host: demo-v1.demo.svc.cluster.local
          port: 8080
          weight: 1
      checks:
        active:
          type: http
          http_path: /api/health
          healthy:
            interval: 5
            successes: 2
          unhealthy:
            interval: 3
            http_failures: 3
    plugins:
      cors:
        allow_origins: "https://app.example.com"
        allow_methods: "GET,POST,PUT,DELETE,OPTIONS"
        allow_headers: "Authorization,Content-Type"
        max_age: 3600

upstreams:
  - name: demo-green-v2
    id: "2"
    type: roundrobin
    nodes:
      - host: demo-v2.demo.svc.cluster.local
        port: 8080
        weight: 1
    checks:
      active:
        type: http
        http_path: /api/health
        healthy:
          interval: 5
          successes: 2
        unhealthy:
          interval: 3
          http_failures: 3

routes:
  - name: demo-api-main
    id: "1"
    uri: /api/*
    methods:
      - GET
      - POST
      - PUT
      - DELETE
      - PATCH
    service_id: "1"
    plugins:
      traffic-split:
        rules:
          - weighted_upstreams:
              - upstream_id: "2"
                weight: 0
              - weight: 100
      response-rewrite:
        headers:
          set:
            X-Content-Type-Options: nosniff
            X-Frame-Options: DENY
          remove:
            - Server
      limit-count:
        count: 100
        time_window: 60
        rejected_code: 429
        key_type: var
        key: remote_addr
        policy: local

consumers:
  - username: app-client-01
    desc: "PoC Test Client"
    plugins:
      key-auth:
        key: poc-test-api-key-001

global_rules:
  - id: "1"
    plugins:
      client-control:
        max_body_size: 2097152
  - id: "2"
    plugins:
      prometheus:
        prefer_name: true
```

#### 同步配置

```bash
# Diff（預覽變更）
adc diff -f apisix-config.yaml \
  --addr http://127.0.0.1:9180 \
  --token poc-admin-key-2024

# Apply（套用變更）
adc sync -f apisix-config.yaml \
  --addr http://127.0.0.1:9180 \
  --token poc-admin-key-2024

# Dump（從 APISIX 匯出目前配置）
adc dump -o current-config.yaml \
  --addr http://127.0.0.1:9180 \
  --token poc-admin-key-2024
```

### 6-5. 藍綠部署自動化腳本

**blue-green-switch.sh**

```bash
#!/bin/bash
# =============================================================================
# APISIX Blue-Green Deployment Switch Script
# Usage: ./blue-green-switch.sh <action> [weight]
#   action: blue | green | canary | rollback | status
#   weight: 0-100 (only for canary action, represents green weight)
# =============================================================================

set -euo pipefail

APISIX_ADMIN="${APISIX_ADMIN:-http://127.0.0.1:9180/apisix/admin}"
APISIX_API_KEY="${APISIX_API_KEY:-poc-admin-key-2024}"
ROUTE_ID="${ROUTE_ID:-1}"
BLUE_UPSTREAM_ID="${BLUE_UPSTREAM_ID:-1}"
GREEN_UPSTREAM_ID="${GREEN_UPSTREAM_ID:-2}"

ACTION="${1:-status}"
GREEN_WEIGHT="${2:-10}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

get_current_weights() {
  curl -s "${APISIX_ADMIN}/routes/${ROUTE_ID}" \
    -H "X-API-KEY: ${APISIX_API_KEY}" | \
    jq -r '.value.plugins."traffic-split".rules[0].weighted_upstreams'
}

set_weights() {
  local green_w=$1
  local blue_w=$((100 - green_w))

  log "Setting weights: Blue=${blue_w}%, Green=${green_w}%"

  curl -s "${APISIX_ADMIN}/routes/${ROUTE_ID}" \
    -H "X-API-KEY: ${APISIX_API_KEY}" \
    -X PATCH \
    -d "{
      \"plugins\": {
        \"traffic-split\": {
          \"rules\": [
            {
              \"match\": [
                {
                  \"vars\": [[\"http_X-Canary\", \"==\", \"true\"]]
                }
              ],
              \"weighted_upstreams\": [
                { \"upstream_id\": \"${GREEN_UPSTREAM_ID}\", \"weight\": 100 }
              ]
            },
            {
              \"weighted_upstreams\": [
                { \"upstream_id\": \"${GREEN_UPSTREAM_ID}\", \"weight\": ${green_w} },
                { \"weight\": ${blue_w} }
              ]
            }
          ]
        }
      }
    }" > /dev/null

  log "Weights updated successfully"
}

health_check() {
  local endpoint=$1
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "${endpoint}")
  echo "${status}"
}

case "${ACTION}" in
  blue)
    log "Switching ALL traffic to Blue (v1)"
    set_weights 0
    ;;
  green)
    log "Switching ALL traffic to Green (v2)"
    set_weights 100
    ;;
  canary)
    if [[ ${GREEN_WEIGHT} -lt 0 || ${GREEN_WEIGHT} -gt 100 ]]; then
      echo "Error: weight must be between 0 and 100"
      exit 1
    fi
    log "Setting canary: ${GREEN_WEIGHT}% to Green"
    set_weights "${GREEN_WEIGHT}"
    ;;
  gradual)
    log "Starting gradual rollout: 1% → 10% → 25% → 50% → 100%"
    for w in 1 10 25 50 100; do
      set_weights ${w}
      log "Waiting 30s at ${w}% Green..."

      # 簡易健康檢查
      sleep 5
      status=$(health_check "${APISIX_GATEWAY:-http://127.0.0.1:9080}/api/health")
      if [[ "${status}" != "200" ]]; then
        log "ERROR: Health check failed (HTTP ${status}), rolling back!"
        set_weights 0
        exit 1
      fi

      if [[ ${w} -lt 100 ]]; then
        sleep 25
      fi
    done
    log "Gradual rollout complete — 100% Green"
    ;;
  rollback)
    log "ROLLBACK: Switching ALL traffic back to Blue (v1)"
    set_weights 0
    ;;
  status)
    log "Current traffic-split configuration:"
    get_current_weights | jq .
    ;;
  *)
    echo "Usage: $0 {blue|green|canary <weight>|gradual|rollback|status}"
    exit 1
    ;;
esac
```

```bash
chmod +x blue-green-switch.sh

# 使用範例
./blue-green-switch.sh status
./blue-green-switch.sh canary 10
./blue-green-switch.sh gradual
./blue-green-switch.sh rollback
./blue-green-switch.sh green
```

---

## Phase 7：驗收

### 7-1. 自動化驗收測試腳本

**run-acceptance-tests.sh**

```bash
#!/bin/bash
# =============================================================================
# APISIX PoC Acceptance Test Suite
# =============================================================================

set -uo pipefail

GATEWAY="${APISIX_GATEWAY:-http://127.0.0.1:9080}"
ADMIN="${APISIX_ADMIN:-http://127.0.0.1:9180/apisix/admin}"
API_KEY="${APISIX_API_KEY:-poc-admin-key-2024}"

PASS=0
FAIL=0
TOTAL=0

test_case() {
  TOTAL=$((TOTAL + 1))
  local name=$1
  local expected=$2
  local actual=$3

  if [[ "${actual}" == *"${expected}"* ]]; then
    PASS=$((PASS + 1))
    echo "  ✅ PASS: ${name}"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ FAIL: ${name} (expected: ${expected}, got: ${actual})"
  fi
}

echo "========================================"
echo "  APISIX PoC Acceptance Tests"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# --- Test 1: Basic Routing ---
echo "📋 Test Group 1: Basic Routing"
RESULT=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY}/api/info")
test_case "Basic route returns 200" "200" "${RESULT}"

RESULT=$(curl -s "${GATEWAY}/api/info" | jq -r '.version')
test_case "Route reaches correct backend" "v" "${RESULT}"

# --- Test 2: Blue-Green / Canary ---
echo ""
echo "📋 Test Group 2: Blue-Green Deployment"

# Set to 100% Blue first
curl -s "${ADMIN}/routes/1" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PATCH \
  -d '{"plugins":{"traffic-split":{"rules":[{"weighted_upstreams":[{"upstream_id":"2","weight":0},{"weight":100}]}]}}}' > /dev/null

sleep 2
RESULT=$(curl -s "${GATEWAY}/api/info" | jq -r '.color')
test_case "100% Blue: all traffic to v1" "blue" "${RESULT}"

# Set to 100% Green
curl -s "${ADMIN}/routes/1" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PATCH \
  -d '{"plugins":{"traffic-split":{"rules":[{"weighted_upstreams":[{"upstream_id":"2","weight":100},{"weight":0}]}]}}}' > /dev/null

sleep 2
RESULT=$(curl -s "${GATEWAY}/api/info" | jq -r '.color')
test_case "100% Green: all traffic to v2" "green" "${RESULT}"

# Header-based routing
curl -s "${ADMIN}/routes/1" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PATCH \
  -d '{"plugins":{"traffic-split":{"rules":[{"match":[{"vars":[["http_X-Canary","==","true"]]}],"weighted_upstreams":[{"upstream_id":"2","weight":100}]},{"weighted_upstreams":[{"weight":100}]}]}}}' > /dev/null

sleep 2
RESULT=$(curl -s -H "X-Canary: true" "${GATEWAY}/api/info" | jq -r '.color')
test_case "X-Canary header routes to Green" "green" "${RESULT}"

RESULT=$(curl -s "${GATEWAY}/api/info" | jq -r '.color')
test_case "Without header routes to Blue" "blue" "${RESULT}"

# --- Test 3: Authentication ---
echo ""
echo "📋 Test Group 3: Authentication"

RESULT=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY}/secure/api/info")
test_case "No API key returns 401" "401" "${RESULT}"

RESULT=$(curl -s -o /dev/null -w "%{http_code}" -H "apikey: wrong-key" "${GATEWAY}/secure/api/info")
test_case "Wrong API key returns 401" "401" "${RESULT}"

RESULT=$(curl -s -o /dev/null -w "%{http_code}" -H "apikey: poc-test-api-key-001" "${GATEWAY}/secure/api/info")
test_case "Correct API key returns 200" "200" "${RESULT}"

# --- Test 4: CORS ---
echo ""
echo "📋 Test Group 4: CORS"

RESULT=$(curl -s -I -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  "${GATEWAY}/api/info" 2>&1 | grep -i "access-control-allow-origin" | tr -d '\r')
test_case "CORS allows configured origin" "app.example.com" "${RESULT}"

# --- Test 5: Rate Limiting ---
echo ""
echo "📋 Test Group 5: Rate Limiting"

RESULT=$(curl -s -I "${GATEWAY}/api/info" 2>&1 | grep -i "X-RateLimit-Limit" | tr -d '\r')
test_case "Rate limit headers present" "X-RateLimit" "${RESULT}"

# --- Test 6: Response Headers ---
echo ""
echo "📋 Test Group 6: Security Headers"

HEADERS=$(curl -s -I "${GATEWAY}/api/info" 2>&1)
RESULT=$(echo "${HEADERS}" | grep -i "X-Content-Type-Options" | tr -d '\r')
test_case "X-Content-Type-Options header" "nosniff" "${RESULT}"

RESULT=$(echo "${HEADERS}" | grep -i "X-Frame-Options" | tr -d '\r')
test_case "X-Frame-Options header" "DENY" "${RESULT}"

# --- Test 7: Request Validation ---
echo ""
echo "📋 Test Group 7: Request Validation"

RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"customerId":"CUST-001","items":[{"productId":"A","quantity":1}]}' \
  "${GATEWAY}/validated/api/orders")
test_case "Valid request returns 200" "200" "${RESULT}"

RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"customerId":"CUST-001"}' \
  "${GATEWAY}/validated/api/orders")
test_case "Missing required field returns 400" "400" "${RESULT}"

# --- Test 8: Prometheus Metrics ---
echo ""
echo "📋 Test Group 8: Observability"

RESULT=$(curl -s "http://127.0.0.1:9091/apisix/prometheus/metrics" | grep -c "apisix_http_status" || echo "0")
test_case "Prometheus metrics available" "1" "$([ ${RESULT} -gt 0 ] && echo '1' || echo '0')"

# --- Summary ---
echo ""
echo "========================================"
echo "  Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"
echo "========================================"

if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
```

```bash
chmod +x run-acceptance-tests.sh
./run-acceptance-tests.sh
```

### 7-2. 效能測試

```bash
# 安裝 hey (HTTP load generator)
# go install github.com/rakyll/hey@latest

echo "=== Baseline Performance Test ==="

# Test 1: Throughput
echo "--- Throughput (200 concurrent, 10s) ---"
hey -z 10s -c 200 "${APISIX_GATEWAY}/api/info"

# Test 2: Latency distribution
echo "--- Latency (50 concurrent, 1000 requests) ---"
hey -n 1000 -c 50 "${APISIX_GATEWAY}/api/info"

# Test 3: With auth plugin overhead
echo "--- With Key Auth ---"
hey -n 1000 -c 50 \
  -H "apikey: poc-test-api-key-001" \
  "${APISIX_GATEWAY}/secure/api/info"
```

### 7-3. 清理資源

```bash
# 刪除所有 PoC 資源
helm uninstall apisix -n apisix
kubectl delete namespace apisix demo monitoring

# 或僅清理 APISIX 配置（保留基礎設施）
for id in 1 10 11 12 13 14 15 16 17; do
  curl -s "${APISIX_ADMIN}/routes/${id}" \
    -H "X-API-KEY: ${APISIX_API_KEY}" -X DELETE
done
```

---

## 附錄 A：完整架構圖

```
                    ┌─────────────────────────────────────────────────┐
                    │                 EKS Cluster                      │
                    │                                                  │
  Internet/Client   │  ┌──────────────────────────────────────────┐   │
        │           │  │          Namespace: apisix                │   │
        │           │  │                                           │   │
        ▼           │  │   ┌─────────┐    ┌──────────────────┐    │   │
   ┌─────────┐      │  │   │  etcd   │◄───│  APISIX Gateway  │    │   │
   │   ALB   │──────┼──┼──►│ (config │    │  (Data Plane)    │    │   │
   │  / NLB  │      │  │   │  store) │    │  :9080 HTTP      │    │   │
   └─────────┘      │  │   └─────────┘    │  :9443 HTTPS     │    │   │
                    │  │        ▲          │  :9091 Metrics   │    │   │
                    │  │        │          └──────┬───────────┘    │   │
                    │  │   ┌────┴───────┐         │               │   │
                    │  │   │  APISIX    │         │               │   │
                    │  │   │  Admin API │         │               │   │
                    │  │   │  :9180     │         │               │   │
                    │  │   └────────────┘         │               │   │
                    │  │                          │               │   │
                    │  │   ┌──────────────┐       │               │   │
                    │  │   │  Dashboard   │       │               │   │
                    │  │   │  :9000       │       │               │   │
                    │  │   └──────────────┘       │               │   │
                    │  └──────────────────────────┼───────────────┘   │
                    │                             │                    │
                    │         traffic-split        │                    │
                    │        ┌─────────────────────┤                    │
                    │        │                     │                    │
                    │        ▼                     ▼                    │
                    │  ┌───────────────┐    ┌───────────────┐          │
                    │  │  Namespace:   │    │  Namespace:   │          │
                    │  │  demo         │    │  demo         │          │
                    │  │               │    │               │          │
                    │  │  ┌─────────┐  │    │  ┌─────────┐  │          │
                    │  │  │ demo-v1 │  │    │  │ demo-v2 │  │          │
                    │  │  │ (Blue)  │  │    │  │ (Green) │  │          │
                    │  │  │ SB2/JDK8│  │    │  │ SB3/JDK │  │          │
                    │  │  │ x2 pods │  │    │  │ 17 x2   │  │          │
                    │  │  └─────────┘  │    │  └─────────┘  │          │
                    │  └───────────────┘    └───────────────┘          │
                    │                                                  │
                    │  ┌──────────────────────────────────────────┐   │
                    │  │          Namespace: monitoring            │   │
                    │  │  ┌────────────┐ ┌────────┐ ┌──────────┐ │   │
                    │  │  │ Prometheus │ │Grafana │ │  Jaeger  │ │   │
                    │  │  │ :9090      │ │:3000   │ │  :16686  │ │   │
                    │  │  └────────────┘ └────────┘ └──────────┘ │   │
                    │  └──────────────────────────────────────────┘   │
                    └─────────────────────────────────────────────────┘
```

---

## 附錄 B：Plugin 選用決策表

| Plugin | 用途 | 套用範圍 | 關鍵參數 |
|--------|------|---------|---------|
| traffic-split | 藍綠/金絲雀部署 | Route 級 | weighted_upstreams, match vars |
| key-auth | API Key 認證 | Route 級 | Consumer key |
| jwt-auth | JWT Token 認證 | Route 級 | algorithm, secret, exp |
| cors | 跨域設定 | Route/Service 級 | allow_origins, allow_methods |
| ip-restriction | IP 黑白名單 | Route 級 | whitelist/blacklist |
| limit-count | 計數限流 | Route/Global 級 | count, time_window |
| limit-req | 漏桶限流 | Route 級 | rate, burst |
| api-breaker | 熔斷器 | Route 級 | failures threshold, max_breaker_sec |
| prometheus | 指標輸出 | Global 級 | prefer_name |
| http-logger | HTTP 日誌 | Route 級 | uri, batch_max_size |
| opentelemetry | 分散式追蹤 | Global 級 | collector address, sampler |
| proxy-rewrite | 請求改寫 | Route 級 | regex_uri, headers |
| response-rewrite | 回應改寫 | Route/Service 級 | headers set/remove |
| request-validation | 請求驗證 | Route 級 | body_schema (JSON Schema) |
| client-control | 請求大小限制 | Global 級 | max_body_size |
| public-api | 暴露內部 API | Route 級 | (用於 JWT sign endpoint) |

---

## 附錄 C：正式環境 Checklist

### 安全性
- [ ] 更換所有預設 Admin API Key
- [ ] 限制 Admin API 的存取來源（僅允許 CI/CD + 維運 IP）
- [ ] 啟用 HTTPS（TLS 1.2+）
- [ ] 設定 mTLS（視安全需求）
- [ ] 移除 Dashboard 或限制存取

### 高可用
- [ ] etcd 至少 3 節點叢集
- [ ] APISIX Gateway 至少 2 replicas + PodDisruptionBudget
- [ ] 設定 resource requests/limits
- [ ] 設定 HPA（CPU/Memory based）

### 可觀測性
- [ ] Prometheus 持久化儲存
- [ ] Grafana 告警設定（Error Rate > 1%, P95 > 500ms）
- [ ] 日誌保留策略（依合規需求）

### 配置管理
- [ ] 所有配置以 YAML 管理，納入 Git 版控
- [ ] CI/CD pipeline 整合 `adc sync`
- [ ] 建立 staging 環境先行驗證配置變更

### 效能
- [ ] 壓測確認 baseline 效能（QPS, Latency）
- [ ] 設定合理的 timeout 值
- [ ] 調整 Nginx worker_processes 與 worker_connections
