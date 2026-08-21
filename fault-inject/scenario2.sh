#!/usr/bin/env bash
set -euo pipefail
# 场景2 故障注入：warranty-service fin 缺参 + 空 catch 吞异常 → 结账无响应
# 用法：./scenario2.sh

echo "① 开启 fin 缺参 bug（WARRANTY_MISSING_FIN=true）"
kubectl -n order set env deploy/warranty-service WARRANTY_MISSING_FIN=true
kubectl -n order rollout status deploy/warranty-service --timeout=120s

echo ""
echo "✅ 场景2 已注入：warranty-service 漏传 fin + 吞异常挂起"
echo "   验证：curl -X POST 'http://localhost:18080/checkout?orderId=ORD001' → 无响应（挂起，需 Ctrl+C）"
echo "   验证：Kibana 按 traceId 关联，能看到 warranty-service 的异常日志 + order-service 无完成日志"
echo "   恢复：./scenario2-recover.sh"
