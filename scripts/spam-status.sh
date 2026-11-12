#!/usr/bin/env sh
# 垃圾邮件运行状态诊断：训练样本数量、分类器模型状态、规则更新、DNS 黑名单是否被拒绝。
# 只读，不修改任何配置。需要在 Stalwart 容器运行时执行。
set -eu
cd "$(dirname "$0")/.."

CONTAINER="${MAILHUB_STALWART_CONTAINER:-mailhub-stalwart}"
RECENT="${1:-30}"

docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "错误：容器 $CONTAINER 未运行" >&2; exit 1; }

jmap() {
  docker exec "$CONTAINER" sh -c '
    key="$(cat /var/lib/stalwart/.mailhub-automation-key 2>/dev/null)" || exit 3
    curl -fsS -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
      http://127.0.0.1:8080/jmap/ -d "$1"' sh "$1"
}

echo '===== 训练样本 ====='
samples="$(jmap '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:SpamTrainingSample/query",{},"q"],["x:SpamTrainingSample/get",{"#ids":{"resultOf":"q","name":"x:SpamTrainingSample/query","path":"/ids"},"properties":["isSpam"]},"g"]]}')" || {
  echo '错误：无法读取 automation API key 或调用 JMAP（Stalwart 1.4.0 首次启动后会自动生成）' >&2
  exit 1
}
spam="$(printf '%s' "$samples" | grep -o '"isSpam":true' | wc -l | tr -d ' ')"
ham="$(printf '%s' "$samples" | grep -o '"isSpam":false' | wc -l | tr -d ' ')"
echo "spam=${spam}  ham=${ham}（默认各需 ≥100，统计分类器才会启用）"
if [ "$spam" -lt 100 ] || [ "$ham" -lt 100 ]; then
  echo '提示：样本不足，可执行 docker compose run --rm trainer 从上游邮箱导入历史样本'
fi

echo
echo '===== Collector 转投标签分数（应为 0）====='
docker exec "$CONTAINER" sh -c '
  STALWART_URL=http://127.0.0.1:8080 STALWART_TOKEN="$(cat /var/lib/stalwart/.mailhub-automation-key)" HOME=/tmp \
    stalwart-cli query SpamTag --json' 2>/dev/null \
  | grep -E '"tag":"(HELO_NOT_FQDN|HELO_NORES_A_OR_MX|FORGED_RECIPIENTS|FORGED_RCVD_TRAIL|DMARC_NA|RCVD_NO_TLS_LAST)"' \
  | sed -n 's/.*"tag":"\([^"]*\)","score":\([^,}]*\).*/  \1 = \2/p' || true

echo
echo '===== 分类器与规则日志（最近）====='
docker logs "$CONTAINER" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -aE 'spam\.(model|train|rules)|spam rule' | tail -8 | cut -c1-220 || true

echo
echo "===== 最近 ${RECENT} 封邮件的 X-Spam-Result ====="
account_id="$(docker exec "$CONTAINER" sh -c '
  curl -fsS -H "Authorization: Bearer $(cat /var/lib/stalwart/.mailhub-automation-key)" http://127.0.0.1:8080/jmap/session' \
  | sed -n 's/.*"primaryAccounts":{[^}]*"urn:ietf:params:jmap:mail":"\([^"]*\)".*/\1/p')"
results="$(jmap "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Email/query\",{\"accountId\":\"${account_id}\",\"sort\":[{\"property\":\"receivedAt\",\"isAscending\":false}],\"limit\":${RECENT}},\"q\"],[\"Email/get\",{\"accountId\":\"${account_id}\",\"#ids\":{\"resultOf\":\"q\",\"name\":\"Email/query\",\"path\":\"/ids\"},\"properties\":[\"header:X-Spam-Result:asText\"]},\"g\"]]}")"
total="$(printf '%s' "$results" | grep -o '"header:X-Spam-Result:asText":"' | wc -l | tr -d ' ')"
blocked="$(printf '%s' "$results" | grep -oE '[A-Z0-9_]+_BLOCKED[A-Z_]*' | sort | uniq -c | sort -rn || true)"
echo "带 X-Spam-Result 的邮件：${total}"
if [ -n "$blocked" ]; then
  echo '警告：发现 *_BLOCKED 标签，DNS 黑名单拒绝了当前 DNS 出口（通常是公共/转发型 DNS）：'
  printf '%s\n' "$blocked"
  echo '处理：在 .env 设置 MAIL_HUB_DNS_SERVERS 指向自己做递归查询的解析器，然后重建 stalwart。'
else
  echo '未发现 *_BLOCKED 标签。'
fi
