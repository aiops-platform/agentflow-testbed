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
# docker CLI 的后端：Docker Desktop 用 /var/run/docker.sock；podman 后端需动态解析
# （podman 的 socket 在 $TMPDIR/podman/ 下，路径随会话变。仅当本机装了 Docker Desktop
#   时 /var/run/docker.sock 才存在；否则在 /var/run 下建 socket 需要 root——非管理员账号做不到）
if [ -S /var/run/docker.sock ]; then
  export DOCKER_HOST=unix:///var/run/docker.sock
else
  export DOCKER_HOST="unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
fi

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
#    ⚠️ prometheus-config 必须同时含 order-service.yml（告警规则）：
#    prometheus.yml 里 rule_files 指向 /etc/prometheus/rules/*.yml，deployment 用
#    items 把它挂进 rules/ 子目录。漏掉的话 Prometheus 不报错，但一条规则都不加载。
kubectl -n order create configmap prometheus-config \
  --from-file=prometheus.yml=manifests/prometheus/prometheus.yml \
  --from-file=order-service.yml=manifests/prometheus/rules/order-service.yml
#    Grafana 的三个 configmap 已随 manifests/grafana/configmaps.yaml 在第 3 步 apply，
#    此处无需再 create（重复 create 会 AlreadyExists 报错）。
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
| 告警规则是否加载 | `curl localhost:19090/api/v1/rules`（`groups` 为空 = 没加载，见下） |
| 日志是否进 ES | `curl localhost:19200/app-logs/_count` |
| Pod 间网络 / 集群内 DNS | `./scripts/fix-node-net.sh`（见下） |

完整踩坑记录见 `../SCENARIOS.md` §十（minikube driver、openjdk 下架、Feign 空块、cadvisor pod 级指标、磁盘指标盲区等 13 条）。

### 6.1 节点网络：Pod 间不通 / 集群内 DNS 解析失败

**症状**（很容易误判成业务代码 bug）：

- `curl localhost:18082/quotation` → 500，gateway 日志 `DnsResolveContext ... 10.96.0.10:53 query via UDP timed out after 5000 milliseconds`
- `curl -X POST localhost:18080/checkout` → 无响应，order-service 日志 `java.net.UnknownHostException: warranty-service`
- 但 `kubectl -n order exec ... -- curl <podIP>:8080`、节点 → Pod 一切正常

**根因**（实测）：minikube 启动节点时会短暂拉起一次 `dockerd`（实测存活 1.85s，之后 `docker.service` 被 mask 成 inactive）。`dockerd` 启动时执行 `iptables -P FORWARD DROP`，dockerd 停了但 **FORWARD 策略留在节点 netns 里**。而本测试床的 CNI 是 kindnet（`ptp` 插件、`ipMasq:false`），Pod 间流量是**路由**转发、必经 FORWARD 链，kindnet 又不装 Pod 网段的放行规则 → Pod↔Pod 全被丢。节点→Pod 走 OUTPUT/INPUT，所以不受影响，现象才这么误导。

**修复（两层，建议都做）**：

```bash
# 第一层：永久修复（已验证）—— 让 dockerd 根本不碰 iptables。
# 节点 runtime 是 containerd，dockerd 只为 minikube docker-env 存在，关掉它的 iptables
# 管理无副作用。写在节点容器文件系统里，minikube stop/start 后依然有效。
minikube ssh -- 'echo "{\"iptables\": false}" | sudo tee /etc/docker/daemon.json'

# 第二层：兜底脚本 —— minikube delete 重建节点后 daemon.json 会丢，跑这个恢复。
./scripts/fix-node-net.sh
```

> 验证：`minikube ssh -- sudo iptables -S FORWARD | head -1` 不再是 `-P FORWARD DROP`；
> 或 `kubectl -n order exec deploy/grafana -- nslookup warranty-service.order.svc.cluster.local` 能解析出 ClusterIP。

### 6.2 告警规则静默未加载

`prometheus.yml` 里 `rule_files: - /etc/prometheus/rules/*.yml`，但 ConfigMap 卷会把所有 key **平铺在挂载点根目录**。若 `prometheus-config` 只放 `prometheus.yml`，那个 `rules/` 目录不存在 —— **Prometheus 不报错**，只是 `/api/v1/rules` 返回空 `groups`，规则连评估都不做。

> 注意区分：加载规则 ≠ 有人收到告警。本仓库**没有 `alerting:` 段、集群里也没有 Alertmanager**，所以规则本来就只评估、不外发（见 `prometheus.yml` 顶部说明）。修好挂载是为了 `/api/v1/rules` 可查、规则能参与评估，不是让它发通知。

修复：`prometheus-config` 必须同时含 `order-service.yml`（第 2 步 §四 的 create 命令已含），deployment 用 ConfigMap `items` 把它挂到 `/etc/prometheus/rules/`（见 `manifests/prometheus/deployment.yaml`）。

## 七、销毁

```bash
kubectl delete namespace order
minikube delete
```
