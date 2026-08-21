#!/usr/bin/env bash
set -euo pipefail
# 场景2 恢复：关闭 fin 缺参 bug
# 用法：./scenario2-recover.sh

echo "关闭 fin 缺参 bug（WARRANTY_MISSING_FIN=false）"
kubectl -n order set env deploy/warranty-service WARRANTY_MISSING_FIN=false
kubectl -n order rollout status deploy/warranty-service --timeout=120s

echo ""
echo "✅ 场景2 已恢复：warranty-service 正常返回三包期结果"
echo "   验证：curl -X POST 'http://localhost:18080/checkout?orderId=ORD001' → 正常返回 checked_out + warranty 结果"
