# Kubernetes Ingress vs. Apache APISIX API Gateway — PoC 實作指南

> **適合對象：** Kubernetes 網路與 API Gateway 的初學者
> **環境：** 本機 Kind（Kubernetes in Docker）叢集
> **目標：** 透過實際操作，比較 NGINX Ingress Controller 與 Apache APISIX 的功能差異

---

## 目錄

1. [核心概念說明](#1-核心概念說明)
2. [架構總覽](#2-架構總覽)
3. [前置準備](#3-前置準備)
4. [快速開始](#4-快速開始)
5. [Phase 1：建立 Kind 叢集與部署範例應用](#5-phase-1建立-kind-叢集與部署範例應用)
6. [Phase 2：設定 NGINX Ingress Controller](#6-phase-2設定-nginx-ingress-controller)
7. [Phase 3：設定 Apache APISIX](#7-phase-3設定-apache-apisix)
8. [Phase 4：比較測試](#8-phase-4比較測試)
9. [Phase 5：可觀測性（Observability）](#9-phase-5可觀測性observability)
10. [功能比較表](#10-功能比較表)
11. [結論與建議](#11-結論與建議)
12. [疑難排解](#12-疑難排解)
13. [名詞解釋](#13-名詞解釋)

---

## 1. 核心概念說明

### 1.1 什麼是 Kubernetes Ingress？

**Kubernetes Ingress** 是 Kubernetes 原生的 API 物件，用來管理從叢集外部進入的 HTTP/HTTPS 流量。

你可以把它想像成**大樓的接待櫃台**——它查看進來的請求（URL 路徑或主機名稱），然後引導到正確的內部服務。

```
外部流量 → Ingress Controller（例如 NGINX） → Ingress 規則 → Service → Pod
```

**重要概念：**

- **Ingress Resource**：一份 YAML 設定檔，定義路由規則（例如 `/api` 導向 `api-service`）
- **Ingress Controller**：實際執行路由的軟體。Kubernetes **預設不包含** Ingress Controller，你必須自行安裝（例如 NGINX Ingress Controller、Traefik）

**範例：**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
spec:
  rules:
    - host: myapp.local          # 當 Host 是 myapp.local 時
      http:
        paths:
          - path: /api            # 路徑 /api
            pathType: Prefix
            backend:
              service:
                name: api-service # 導向 api-service
                port:
                  number: 80
```

**優點：** 簡單、Kubernetes 原生、廣泛支援
**限制：** 僅限 L7 HTTP 路由、沒有內建限流、沒有認證插件

### 1.2 什麼是 API Gateway？

**API Gateway** 是位於客戶端與後端服務之間的一個更強大的層。除了路由之外，它還提供：

| 功能 | 說明 |
|---|---|
| **流量管理** | 限流（Rate Limiting）、熔斷（Circuit Breaking）、重試、超時 |
| **安全性** | 認證（JWT、OAuth2、mTLS）、IP 白名單、CORS |
| **可觀測性** | 指標（Metrics）、日誌、分散式追蹤（Tracing） |
| **轉換** | 請求/回應改寫、Header 操作 |
| **部署策略** | 金絲雀發布（Canary）、藍綠部署（Blue-Green） |

把它想像成同時具備**智慧保全 + 交通指揮 + 翻譯員**功能的角色。

### 1.3 什麼是 Apache APISIX？

**Apache APISIX** 是一個高效能、雲原生的 API Gateway，基於 **NGINX** 和 **Lua（OpenResty）** 建構，是 Apache 軟體基金會的頂級專案。

```
客戶端請求
     │
     ▼
┌──────────────┐
│  APISIX       │  ← 路由 + 插件（認證、限流等）
│ （資料平面）   │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   etcd        │  ← 設定儲存（即時更新設定）
└──────────────┘
       │
       ▼
┌──────────────┐
│  APISIX       │  ← Web UI 管理介面
│  Dashboard    │
└──────────────┘
```

**主要特色：**

- **80+ 內建插件**（認證、流量控制、可觀測性、Serverless）
- **熱載入（Hot Reload）** — 修改路由和插件不需要重啟
- **多協定支援** — HTTP、gRPC、WebSocket、TCP/UDP
- **Kubernetes 原生** — 可透過 APISIX Ingress Controller CRD 作為 Ingress Controller

### 1.4 什麼是 Kind？

**Kind** 全名是「**K**ubernetes **in** **D**ocker」，它在你的本機 Docker 裡面運行完整的 Kubernetes 叢集，非常適合開發和 PoC。

```
你的電腦
  └── Docker
       ├── kind-control-plane（容器，扮演 K8s 主節點 + 工作節點）
       ├── kind-worker（容器，工作節點）
       └── kind-worker2（容器，工作節點）
```

**為什麼用 Kind？**

- 不需要雲端費用
- 快速建立（不到 2 分鐘）
- 用完即棄 — 隨時刪除重建
- 支援 Port Mapping，可以從 localhost 存取服務

---

## 2. 架構總覽

本 PoC 在同一個 Kind 叢集中同時部署 NGINX Ingress Controller 和 Apache APISIX，共用相同的後端服務：

```
                        ┌─────────────────────────────────────────────┐
                        │           Kind Cluster                       │
                        │                                              │
  localhost:80/443 ────►│  ┌─────────────────────┐                    │
  (NGINX Ingress)       │  │ NGINX Ingress        │                    │
                        │  │ Controller           │──┐                │
                        │  └─────────────────────┘  │                │
                        │                            │  ┌───────────┐ │
                        │                            ├─►│ app-v1    │ │
                        │                            │  │ (2 pods)  │ │
  localhost:9080/9443 ─►│  ┌─────────────────────┐  │  └───────────┘ │
  (APISIX)              │  │ Apache APISIX        │  │                │
                        │  │ + etcd               │──┤  ┌───────────┐ │
                        │  └─────────────────────┘  └─►│ app-v2    │ │
                        │                               │ (2 pods)  │ │
                        │  ┌─────────────────────┐      └───────────┘ │
                        │  │ Prometheus + Grafana │                    │
                        │  │ (monitoring)         │                    │
                        │  └─────────────────────┘                    │
                        └─────────────────────────────────────────────┘
```

**Port 對應表：**

| Port | 用途 |
|---|---|
| `80` / `443` | NGINX Ingress Controller（HTTP / HTTPS） |
| `9080` / `9443` | Apache APISIX（HTTP / HTTPS） |
| `30300` | Grafana Web UI |

---

## 3. 前置準備

### 3.1 必要工具

| 工具 | 最低版本 | 用途 | 安裝方式 |
|---|---|---|---|
| Docker | Latest | 容器執行環境 | [docker.com](https://docs.docker.com/get-docker/) |
| Kind | v0.20+ | 本地 K8s 叢集 | `go install sigs.k8s.io/kind@latest` |
| kubectl | v1.28+ | K8s CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Helm | v3.12+ | K8s 套件管理 | [helm.sh](https://helm.sh/docs/intro/install/) |
| curl | Latest | HTTP 測試 | 系統內建 |

**選用工具（負載測試）：**

| 工具 | 用途 | 安裝方式 |
|---|---|---|
| hey | HTTP 負載測試 | `go install github.com/rakyll/hey@latest` |
| k6 | 進階負載測試 | [k6.io](https://k6.io/docs/get-started/installation/) |

### 3.2 硬體建議

- **CPU：** 4 核心以上
- **記憶體：** 最少 8 GB（建議 16 GB）
- **硬碟：** 20 GB 可用空間

### 3.3 驗證安裝

```bash
docker version
kind version
kubectl version --client
helm version
```

---

## 4. 快速開始

如果你想一次跑完所有步驟：

```bash
# 1. 建立叢集
./scripts/01-create-cluster.sh

# 2. 部署範例應用
./scripts/02-deploy-apps.sh

# 3. 設定 NGINX Ingress
./scripts/03-setup-nginx-ingress.sh

# 4. 設定 APISIX
./scripts/04-setup-apisix.sh

# 5. 設定可觀測性（選用）
./scripts/05-setup-observability.sh

# 6. 執行測試
./scripts/06-run-tests.sh

# 清除環境
./scripts/cleanup.sh
```

以下章節會**逐步詳細說明**每個步驟。

---

## 5. Phase 1：建立 Kind 叢集與部署範例應用

### Step 1：建立 Kind 叢集

Kind 叢集設定檔 `kind-cluster.yaml` 定義了：
- 1 個 Control Plane 節點（帶有 `ingress-ready=true` 標籤和 Port Mapping）
- 2 個 Worker 節點

```bash
./scripts/01-create-cluster.sh
```

**背後做了什麼：**

```bash
# 建立叢集
kind create cluster --name poc-ingress-gw --config kind-cluster.yaml

# 驗證叢集
kubectl cluster-info --context kind-poc-ingress-gw
kubectl get nodes
```

**預期輸出：**

```
NAME                            STATUS   ROLES           AGE   VERSION
poc-ingress-gw-control-plane    Ready    control-plane   30s   v1.31.0
poc-ingress-gw-worker           Ready    <none>          20s   v1.31.0
poc-ingress-gw-worker2          Ready    <none>          20s   v1.31.0
```

### Step 2：部署範例應用

我們部署兩個簡單的 HTTP 服務作為路由目標：

- **app-v1**：回應 `Hello from App V1`
- **app-v2**：回應 `Hello from App V2`

```bash
./scripts/02-deploy-apps.sh
```

**背後做了什麼：**

```bash
kubectl apply -f apps/sample-apps.yaml
kubectl wait --for=condition=ready pod --selector=app=demo --timeout=120s
```

**驗證：**

```bash
# 查看部署狀態
kubectl get pods -l app=demo

# 預期看到 4 個 Pod（app-v1 x2, app-v2 x2）
NAME                      READY   STATUS    RESTARTS   AGE
app-v1-xxxxx-yyyyy        1/1     Running   0          30s
app-v1-xxxxx-zzzzz        1/1     Running   0          30s
app-v2-xxxxx-aaaaa        1/1     Running   0          30s
app-v2-xxxxx-bbbbb        1/1     Running   0          30s
```

---

## 6. Phase 2：設定 NGINX Ingress Controller

### Step 1：安裝 NGINX Ingress Controller

```bash
./scripts/03-setup-nginx-ingress.sh
```

**背後做了什麼：**

```bash
# 安裝 NGINX Ingress Controller（Kind 專用版本）
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# 等待 Controller 就緒
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Step 2：設定路由規則

腳本會自動套用兩個 Ingress 資源：

**基本路由 (`nginx-ingress/nginx-ingress.yaml`)：**

| 請求 | 導向 |
|---|---|
| `Host: demo.local` + `/v1` | app-v1-svc |
| `Host: demo.local` + `/v2` | app-v2-svc |

**限流路由 (`nginx-ingress/nginx-ingress-ratelimit.yaml`)：**

| 請求 | 導向 | 限制 |
|---|---|---|
| `Host: demo-limited.local` + `/` | app-v1-svc | 10 req/s，burst x5 |

### Step 3：測試

```bash
# 基本路由測試
curl -H "Host: demo.local" http://localhost/v1
# 預期輸出：Hello from App V1

curl -H "Host: demo.local" http://localhost/v2
# 預期輸出：Hello from App V2

# 限流測試（快速發送 20 個請求）
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" -H "Host: demo-limited.local" http://localhost/
done
# 預期：前幾個回 200，後面開始回 503
```

> **為什麼要加 `-H "Host: demo.local"`？**
> 因為 NGINX Ingress 使用 Host-based routing，需要指定 Host header 來匹配 Ingress 規則。在本機測試時，我們用 curl 的 `-H` 參數模擬 DNS 解析。

---

## 7. Phase 3：設定 Apache APISIX

### Step 1：安裝 APISIX

```bash
./scripts/04-setup-apisix.sh
```

**背後做了什麼：**

```bash
# 新增 Helm repo
helm repo add apisix https://charts.apiseven.com
helm repo update

# 透過 Helm 安裝 APISIX（使用自訂 values）
helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  -f apisix/apisix-values.yaml
```

### Step 2：設定路由與插件

腳本會透過 APISIX Admin API 設定以下路由：

| 路由 | 路徑 | 目標 | 功能 |
|---|---|---|---|
| Route 1 | `/v1/*` | app-v1-svc | 基本路由 |
| Route 2 | `/v2/*` | app-v2-svc | 基本路由 |
| Route 3 | `/v1-limited/*` | app-v1-svc | 限流（10 req/s） |
| Route 4 | `/v1-auth/*` | app-v1-svc | API Key 認證 |
| Route 5 | `/canary/*` | 80% v1 / 20% v2 | 金絲雀發布 |

### Step 3：測試

```bash
# 基本路由
curl http://localhost:9080/v1/
# 預期：Hello from App V1

curl http://localhost:9080/v2/
# 預期：Hello from App V2

# API Key 認證 — 不帶 key（應該被拒絕）
curl -i http://localhost:9080/v1-auth/
# 預期：HTTP 401 Unauthorized

# API Key 認證 — 帶 key
curl http://localhost:9080/v1-auth/ -H "apikey: my-secret-api-key-123"
# 預期：Hello from App V1

# 金絲雀測試（100 次請求，觀察分佈）
for i in $(seq 1 100); do
  curl -s http://localhost:9080/canary/
done | sort | uniq -c
# 預期：約 80 次 "Hello from App V1"，20 次 "Hello from App V2"
```

> **APISIX vs NGINX Ingress 的設定方式差異：**
>
> | | NGINX Ingress | APISIX |
> |---|---|---|
> | 設定方式 | YAML + Annotations | Admin API（HTTP REST） |
> | 生效時間 | 需要 reload | 即時生效（透過 etcd） |
> | 彈性 | 受限於 Annotation | 80+ 插件自由組合 |

---

## 8. Phase 4：比較測試

執行自動化測試腳本，涵蓋 10 個測試案例：

```bash
./scripts/06-run-tests.sh
```

### 測試案例清單

| 編號 | 測試項目 | NGINX Ingress | APISIX | 測試工具 |
|---|---|---|---|---|
| TC-01 | 路徑路由（Path-based） | ✅ Ingress YAML | ✅ Admin API | curl |
| TC-02 | 主機路由（Host-based） | ✅ Ingress YAML | ✅ Admin API | curl |
| TC-03 | 限流（Rate Limiting） | ⚠️ Annotation（有限） | ✅ Plugin（靈活） | curl loop |
| TC-04 | API Key 認證 | ❌ 無內建 | ✅ key-auth 插件 | curl |
| TC-05 | JWT 認證 | ❌ 無內建 | ✅ jwt-auth 插件 | curl |
| TC-06 | 金絲雀發布（加權） | ⚠️ 有限支援 | ✅ 加權 Upstream | curl loop |
| TC-07 | 請求轉換 | ⚠️ Annotation | ✅ proxy-rewrite | curl |
| TC-08 | Prometheus 指標 | ✅ 內建 | ✅ prometheus 插件 | curl |
| TC-09 | 存取日誌 | ✅ NGINX logs | ✅ http-logger | kubectl logs |
| TC-10 | 熱更新設定 | ❌ 需 reload | ✅ 即時（etcd） | curl |

### 負載測試（選用）

如果安裝了 `hey` 工具，可以做更精確的負載測試：

```bash
# NGINX Ingress 限流測試
hey -n 200 -c 20 -H "Host: demo-limited.local" http://localhost:80/

# APISIX 限流測試
hey -n 200 -c 20 http://localhost:9080/v1-limited/
```

---

## 9. Phase 5：可觀測性（Observability）

### 安裝 Prometheus + Grafana

```bash
./scripts/05-setup-observability.sh
```

### 存取 Grafana

- **URL：** `http://localhost:30300`
- **帳號：** `admin`
- **密碼：** `admin`

### APISIX Prometheus 指標

APISIX 啟用 Prometheus 插件後，可以在以下端點查看指標：

```bash
# 透過 port-forward 存取 APISIX 的 Prometheus 指標
kubectl -n apisix port-forward svc/apisix-gateway 9080:9080 &
curl http://localhost:9080/apisix/prometheus/metrics
```

常見指標：

| 指標名稱 | 說明 |
|---|---|
| `apisix_http_status` | HTTP 狀態碼分佈 |
| `apisix_bandwidth` | 流量頻寬 |
| `apisix_upstream_latency` | 上游服務延遲 |
| `apisix_http_latency` | HTTP 請求延遲 |

---

## 10. 功能比較表

| 比較項目 | 權重 | NGINX Ingress | Apache APISIX | 說明 |
|---|---|---|---|---|
| **安裝容易度** | 15% | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | NGINX 一行指令；APISIX 需要 Helm + etcd |
| **路由彈性** | 15% | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | APISIX 支援更多路由條件 |
| **流量管理** | 20% | ⭐⭐ | ⭐⭐⭐⭐⭐ | APISIX 有限流、熔斷、重試等插件 |
| **安全功能** | 20% | ⭐⭐ | ⭐⭐⭐⭐⭐ | APISIX 內建 JWT、Key-Auth、OAuth2 等 |
| **可觀測性** | 15% | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | APISIX 有更豐富的 Prometheus 指標 |
| **金絲雀/藍綠** | 10% | ⭐⭐ | ⭐⭐⭐⭐⭐ | APISIX 原生支援加權流量分配 |
| **維運負擔** | 5% | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | APISIX 多了 etcd 元件需要維護 |
| **加權總分** | 100% | **2.8/5** | **4.7/5** | |

---

## 11. 結論與建議

### 選擇 NGINX Ingress 的時機

- 需求僅限**簡單的 L7 HTTP 路由**（路徑、主機名稱）
- 團隊已熟悉 NGINX 設定
- 希望**最小化維運負擔**（不需要額外的 etcd）
- 中小型部署，不需要複雜的 API 管理

### 選擇 Apache APISIX 的時機

- 需要完整的 **API Gateway 功能**（認證、限流、熔斷）
- 微服務架構，需要精細的**流量控制**
- 需要**金絲雀發布**或**藍綠部署**
- 需要豐富的**可觀測性**（指標、日誌、追蹤）
- 金融、零售、製造業等需要 API 治理的場景

### 混合方案（推薦）

在許多企業場景中，可以同時使用兩者：

```
外部流量（南北向） → Apache APISIX（API Gateway）
                         │
                         ▼
               Kubernetes 叢集內部
                         │
內部流量（東西向） → NGINX Ingress（簡單路由）
```

- **APISIX** 負責對外的 API 管理（認證、限流、監控）
- **NGINX Ingress** 負責叢集內部服務之間的簡單路由

---

## 12. 疑難排解

### Kind 叢集建立失敗

```bash
# 確認 Docker 正在執行
docker ps

# 刪除舊叢集後重建
kind delete cluster --name poc-ingress-gw
./scripts/01-create-cluster.sh
```

### NGINX Ingress Controller 無法啟動

```bash
# 查看 Pod 狀態
kubectl -n ingress-nginx get pods

# 查看日誌
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller
```

### APISIX 無法啟動

```bash
# 查看 Pod 狀態
kubectl -n apisix get pods

# 查看 APISIX 日誌
kubectl -n apisix logs -l app.kubernetes.io/name=apisix

# 查看 etcd 日誌
kubectl -n apisix logs -l app.kubernetes.io/name=etcd
```

### curl 無法連線到服務

```bash
# 確認 Port Mapping
docker port poc-ingress-gw-control-plane

# 確認服務狀態
kubectl get svc -A

# 測試叢集內部連線
kubectl run tmp --image=curlimages/curl --restart=Never --rm -it -- \
  curl http://app-v1-svc.default.svc.cluster.local
```

### APISIX Admin API 無法存取

```bash
# 設定 port-forward
kubectl -n apisix port-forward svc/apisix-admin 9180:9180

# 測試連線
curl http://127.0.0.1:9180/apisix/admin/routes \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1"
```

### 資源不足

```bash
# 查看節點資源使用狀況
kubectl top nodes

# 查看 Pod 資源使用
kubectl top pods -A

# 如果記憶體不足，可以減少 Worker 節點
# 修改 kind-cluster.yaml，移除 worker 節點後重建
```

---

## 13. 名詞解釋

| 名詞 | 說明 |
|---|---|
| **L7 路由** | 基於 HTTP 屬性（路徑、主機、Header）做路由決策，對應 OSI 模型第 7 層 |
| **Ingress Controller** | 實作 Kubernetes Ingress 規格的軟體 |
| **CRD** | Custom Resource Definition，擴展 Kubernetes API 的自訂資源類型 |
| **etcd** | 分散式鍵值儲存庫，APISIX 用它來儲存設定 |
| **南北向流量** | 進出叢集的流量（外部客戶端到內部服務） |
| **東西向流量** | 叢集內部服務之間的流量 |
| **金絲雀發布** | 逐步將流量從舊版本轉移到新版本的部署策略 |
| **熔斷器** | 當下游服務故障時，停止發送請求讓它恢復的模式 |
| **mTLS** | 雙向 TLS，客戶端和伺服器彼此用憑證驗證身份 |
| **限流** | 限制單位時間內的請求數量，防止服務過載 |
| **Hot Reload** | 不重啟服務即可更新設定的能力 |
| **Upstream** | APISIX 中代表後端服務的概念，定義了目標節點和負載均衡策略 |
| **Plugin** | APISIX 中的插件，提供各種功能（認證、限流、日誌等） |
| **Consumer** | APISIX 中代表 API 使用者的概念，可綁定認證憑證 |

---

## 專案結構

```
ingress-apigw-poc/
├── README.md                          # 本文件（zh-TW 說明指南）
├── poc-k8s-ingress-vs-apisix.md       # PoC 計畫書（原始英文版）
├── kind-cluster.yaml                  # Kind 叢集設定檔
├── apps/
│   └── sample-apps.yaml               # 範例應用（app-v1, app-v2）
├── nginx-ingress/
│   ├── nginx-ingress.yaml             # NGINX 基本路由
│   └── nginx-ingress-ratelimit.yaml   # NGINX 限流設定
├── apisix/
│   ├── apisix-values.yaml             # APISIX Helm 安裝參數
│   └── apisix-routes.sh               # APISIX 路由與插件設定腳本
├── observability/
│   └── prometheus-values.yaml         # Prometheus + Grafana 安裝參數
└── scripts/
    ├── 01-create-cluster.sh           # 建立 Kind 叢集
    ├── 02-deploy-apps.sh              # 部署範例應用
    ├── 03-setup-nginx-ingress.sh      # 設定 NGINX Ingress
    ├── 04-setup-apisix.sh             # 設定 Apache APISIX
    ├── 05-setup-observability.sh      # 設定可觀測性
    ├── 06-run-tests.sh                # 執行比較測試
    └── cleanup.sh                     # 清除環境
```

---

*本文件依據 [poc-k8s-ingress-vs-apisix.md](poc-k8s-ingress-vs-apisix.md) PoC 計畫書撰寫*
