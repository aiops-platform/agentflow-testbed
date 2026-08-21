# AIOps 测试环境启动指南

> 从零启动一套 AIOps Bug Fix 测试床：3 个微服务（gateway/order/warranty）+ 数据源（ES/Prometheus/Grafana/Kibana/Filebeat）。完整设计见 `../SCENARIOS.md`，踩坑记录见 §十。

## 一、前置条件

| 工具 | 版本 | 说明 |
|---|---|---|
| podman | 5.x | 本机容器运行时（macOS 走 podman machine） |
| minikube | ≥1.38 | K8s 集群（`--driver=docker` 走 podman socket） |
| docker CLI | 任意 | 仅客户端，`brew install docker`，daemon 走 podman |
| kubectl | ≥1.30 | 操作集群 |
| JDK | 21 | 构建服务 jar |
| Gradle | 8.x（wrapper 8.10） | 构建服务 |

## 二、一键启动（核心命令）

> 💡 **有脚本**：改完服务代码后，直接跑 `./build-and-deploy.sh` 一键打包 jar → 打镜像 → 发布到 minikube（用时间戳 tag，避免同 tag 不覆盖问题）。支持 `--service <name>` 只做单个、`--skip-build` 跳过打包。首次部署（含数据源）仍用下面的手动命令。

```bash
# 0. 前置
podman machine start                          # 确保 podman 可用
export DOCKER_HOST=unix:///var/run/docker.sock # docker CLI 指向 podman socket

# 1. 启动集群
minikube start --driver=docker --force --cpus=4 --memory=5120
minikube addons enable metrics-server

# 2. 构建服务 jar + 镜像 + 加载
cd services/aiops-test-order-service && ./gradlew clean build --no-daemon && docker build -t order-service:v2 . && minikube image load order-service:v2 && cd ..
cd services/aiops-test-warranty-service && ./gradlew clean build --no-daemon && docker build -t warranty-service:v1 . && minikube image load warranty-service:v1 && cd ..
cd services/aiops-test-gateway-service && ./gradlew clean build --no-daemon && docker build -t gateway-service:v1 . && minikube image load gateway-service:v1 && cd ..

# 3. 部署服务 + 数据源
cd ..
kubectl create namespace order
kubectl apply -f manifests/order-service/ -f manifests/warranty-service/ -f manifests/gateway-service/
kubectl apply -f manifests/elasticsearch/ -f manifests/prometheus/ -f manifests/grafana/ -f manifests/kibana/
kubectl apply -f manifests/filebeat/daemonset.yaml

# 4. 创建 configmaps（数据源配置）
kubectl -n order create configmap prometheus-config --from-file=prometheus.yml=manifests/prometheus/prometheus.yml
kubectl -n order create configmap grafana-datasource --from-file=prometheus.yaml=manifests/grafana/provisioning/datasources/prometheus.yaml
kubectl -n order create configmap grafana-dashboards-provider --from-file=dashboards.yaml=manifests/grafana/provisioning/dashboards/dashboards.yaml
kubectl -n order create configmap grafana-dashboard-json --from-file=service-resources.json=manifests/grafana/dashboards/service-resources.json
kubectl -n order create configmap filebeat-config --from-file=filebeat.yml=manifests/filebeat/filebeat.yml

# 5. 等待就绪
kubectl -n order wait --for=condition=available deploy/order-service deploy/warranty-service deploy/gateway-service --timeout=300s
kubectl -n order wait --for=condition=available deploy/elasticsearch deploy/prometheus deploy/grafana deploy/kibana --timeout=300s

# 6. 端口转发（访问服务 + 监控 UI）
#    用 scripts/port-forward-all.sh 一键启动，带自动重连：pod 重启/滚动发布换新 pod 也不会断。
#    等价的手动命令（单个，无自动重连）：
#      kubectl -n order port-forward svc/order-service 18080:8080 &
testbed/scripts/port-forward-all.sh
```

## 三、访问入口

### 服务端口映射

| 服务 | 本地端口 | 说明 |
|---|---|---|
| order-service | 18080 | 订单服务（报价单 / 结账；场景1 被测 + 场景2 调用方） |
| warranty-service | 18081 | 保养服务（三包期查询；场景2 bug 点） |
| gateway-service | 18082 | 统一入口（traceId 入口；路由 /quotation /checkout /test → order-service） |

### 监控 UI

| 工具 | 地址 | 登录 |
|---|---|---|
| Grafana（指标） | http://localhost:3000 | admin / admin |
| Kibana（日志） | http://localhost:5601 | 无（ES 关 security） |

Kibana 首次需建数据视图：Stack Management → Data Views → Create → 名称 `app-logs`，Index pattern `app-logs` → 保存，然后 Discover 查看。

## 四、故障注入（两个场景，已脚本化）

场景的 bug 用 **env 开关**控制（无 bug 分支，代码常驻 main）。注入/恢复都封装成脚本：

```bash
cd fault-inject
./scenario1.sh          # 场景1 注入：磁盘 100% + CPU 100%（报价单 500）
./scenario1-recover.sh  # 场景1 恢复：重启 pod（清空 tmpfs + 停 CPU 忙循环）
./scenario2.sh          # 场景2 注入：fin 缺参 + 挂起（结账无响应）
./scenario2-recover.sh  # 场景2 恢复：关闭 fin 缺参 bug
```

### 场景 1：报价单打印失败（CPU 100% + 磁盘 100%）

- **注入**：`mkdir -p /data/tmp && dd` 写满 512Mi tmpfs + `setsid` 起 2 个 CPU 忙循环（500m limit 打满）。
- **症状**：`curl localhost:18080/quotation?orderId=XXX` → 500（`IOException: No space left on device`）。
- **恢复**：`rollout restart`（tmpfs 重建清空 + 忙循环随 pod 销毁）。

### 场景 2：结账无响应（fin 缺参 + 吞异常）

- **注入**：`kubectl set env deploy/warranty-service WARRANTY_MISSING_FIN=true`（漏传 fin → 空 catch 吞异常 → `Semaphore(0).acquire()` 永久挂起）。
- **症状**：`curl -X POST localhost:18080/checkout?orderId=XXX` → 无响应（挂起，Feign 无超时）。
- **恢复**：`WARRANTY_MISSING_FIN=false`（warranty 重启，挂起线程随 pod 销毁）。

> 手写命令等价于脚本内容（详见 `fault-inject/*.sh`）。

## 五、验证

```bash
# 服务健康
kubectl -n order get pods
# 报价单（场景1，经网关统一入口）
curl "http://localhost:18082/quotation?orderId=ORD001"
# 报价单（直接打 order-service）
curl "http://localhost:18080/quotation?orderId=ORD001"
# 结账跨服务（场景2，经 order→warranty Feign）
curl -X POST "http://localhost:18080/checkout?orderId=ORD001"
# 三包期查询（直接打 warranty-service）
curl -X POST "http://localhost:18081/checkWarranty?orderId=ORD001"
# 日志进 ES
curl "http://localhost:19200/app-logs/_count"
# 指标进 Prometheus
curl "http://localhost:19090/api/v1/query?query=container_cpu_usage_seconds_total"
```

## 六、常用排障

| 问题 | 命令 |
|---|---|
| 服务崩溃 | `kubectl -n order logs <pod> --previous` |
| 数据源状态 | `kubectl -n order get pods -l app` |
| Prometheus 抓取 | `curl localhost:19090/api/v1/targets` |
| 日志是否进 ES | `curl localhost:19200/app-logs/_count` |

完整踩坑记录见 `../SCENARIOS.md` §十（minikube driver、openjdk 下架、Feign 空块、cadvisor pod 级指标、磁盘指标盲区等 13 条）。

## 七、销毁

```bash
kubectl delete namespace order
minikube delete
```
