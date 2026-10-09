#!/usr/bin/env bash
set -euo pipefail

# 修复 minikube 节点的 FORWARD 丢包（表现为 Pod 间网络不通、集群内 DNS 解析失败）
#
# 背景（实测根因）：
#   1. minikube 启动节点时会短暂拉起一次 dockerd（实测存活 1.85s，之后 docker.service
#      被 mask 掉）。dockerd 启动时执行 `iptables -P FORWARD DROP` 并建 Docker 链；
#      dockerd 停了，**FORWARD 策略却留在节点 netns 里**。
#   2. 本测试床的 CNI 是 kindnet（`ptp` 插件、ipMasq:false），Pod 间流量是**路由**转发，
#      必须经过 FORWARD 链；kindnet 不装任何 Pod 网段的放行规则。
#   3. 节点 → Pod 走 OUTPUT/INPUT，不受影响；Pod → Pod 走 FORWARD，被 DROP。
#
#   症状（很容易误判成代码 bug）：
#     - `curl localhost:18082/quotation` → 500，gateway 日志
#       `DnsResolveContext ... 10.96.0.10:53 query via UDP timed out`
#     - `curl -X POST localhost:18080/checkout` → 无响应，order-service 日志
#       `java.net.UnknownHostException: warranty-service`
#
# 本脚本幂等（-C 命中即跳过），minikube start 之后跑一次即可。
# 只放行「源或目的落在 Pod 网段」的转发，FORWARD 默认策略仍保持 DROP。
#
# 用法:
#   ./fix-node-net.sh                # 用默认 Pod 网段 10.244.0.0/16
#   ./fix-node-net.sh 10.244.0.0/16  # 显式指定（与节点 CNI conflist 的 ranges 一致）
#
# 注意：规则写在节点容器的 netns 里，`minikube delete` 重建节点后会丢失，重跑本脚本即可。
#       若想连 `minikube stop/start` 也免于重跑，见 README「节点网络」一节的一劳永逸做法。

CIDR="${1:-10.244.0.0/16}"

if ! minikube status >/dev/null 2>&1; then
  echo "❌ minikube 未运行，先启动集群再跑本脚本" >&2
  exit 1
fi

# 幂等加规则：已存在则跳过，否则插到 FORWARD 链首
add_rule() {
  local spec="$1"
  minikube ssh -- "if sudo iptables -C FORWARD ${spec} 2>/dev/null; then
      echo '  已存在，跳过: ${spec}'
    else
      sudo iptables -I FORWARD 1 ${spec} && echo '  ✅ 已添加: ${spec}'
    fi"
}

echo "修复节点 FORWARD 丢包（Pod 网段 ${CIDR}）:"
add_rule "-s ${CIDR} -d ${CIDR} -j ACCEPT"
add_rule "-s ${CIDR} -j ACCEPT"
add_rule "-d ${CIDR} -j ACCEPT"

echo ""
echo "当前 FORWARD 链首:"
minikube ssh -- 'sudo iptables -S FORWARD | head -6'

echo ""
# 验证：借已有的 Grafana pod 查一次集群内 DNS（grafana 镜像基于 alpine，自带 busybox nslookup）
if kubectl -n order get deploy/grafana >/dev/null 2>&1; then
  echo "验证（在 Grafana pod 内解析 warranty-service）:"
  kubectl -n order exec deploy/grafana -- \
    nslookup warranty-service.order.svc.cluster.local 2>&1 | tail -4
else
  echo "（order 命名空间下没有 grafana，跳过验证；可自行执行:"
  echo "   kubectl -n order exec deploy/<任意 pod> -- nslookup <service>）"
fi
