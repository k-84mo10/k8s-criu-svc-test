# CRIU + Kubernetes Service Restore 実験手順

この手順では、Kubernetes 上で稼働中の Pod を checkpoint し、checkpoint archive から restore 用 image を作成して、別 Pod として復元します。最終的に、復元した Pod が Kubernetes Service 経由で疎通できることを確認します。

## 0. 前提変数

```bash
export NAMESPACE=criu-svc-test
export SOURCE_POD=server-source
export SOURCE_CONTAINER=server
export RESTORE_POD=server-restore
export SERVICE=criu-server-svc
export RESTORE_IMAGE=localhost/checkpoint-server-source:latest
export CHECKPOINT_DIR=/mnt/data/kubelet/checkpoints
```

---

## 1. 実験用リソースを作成

```bash
kubectl apply -f namespace.yaml
kubectl apply -f service.yaml
kubectl apply -f server-source.yaml
kubectl apply -f client.yaml
```

作成後、Pod と Service の状態を確認します。

```bash
kubectl get pod -n $NAMESPACE -o wide
kubectl get svc -n $NAMESPACE
kubectl get endpointslice -n $NAMESPACE \
  -l kubernetes.io/service-name=$SERVICE \
  -o wide
```

client から Service へ通信できていることを確認します。

```bash
kubectl logs -n $NAMESPACE -f client
```

---

## 2. Service から source Pod を外して drain

通信中の Pod をそのまま checkpoint すると、CRIU が in-flight connection を検出して失敗することがあります。先に source Pod を Service の backend から外します。

```bash
kubectl label pod $SOURCE_POD app- -n $NAMESPACE
sleep 5
```

EndpointSlice から source Pod が外れていることを確認します。

```bash
kubectl get endpointslice -n $NAMESPACE \
  -l kubernetes.io/service-name=$SERVICE \
  -o jsonpath='{range .items[*].endpoints[*]}ip={.addresses[*]} ready={.conditions.ready} target={.targetRef.name}{"\n"}{end}'
```

source Pod に処理中の TCP connection が残っていないことを確認します。

```bash
kubectl exec -n $NAMESPACE $SOURCE_POD -- ss -tanp
```

---

## 3. source Pod を checkpoint

kubelet checkpoint API を使って、source Pod の container を checkpoint します。

```bash
curl --insecure \
  --cert client-admin.crt \
  --key client-admin.key \
  -X POST "https://localhost:10250/checkpoint/$NAMESPACE/$SOURCE_POD/$SOURCE_CONTAINER"
```

checkpoint archive が作成されたことを確認します。

```bash
sudo ls -lh $CHECKPOINT_DIR
```

最新の checkpoint archive を変数に入れます。

```bash
export CHECKPOINT_ARCHIVE=$(sudo find $CHECKPOINT_DIR -type f \
  -name "checkpoint-${SOURCE_POD}_${NAMESPACE}-${SOURCE_CONTAINER}-*.tar" \
  | sort | tail -n 1)

echo $CHECKPOINT_ARCHIVE
```

---

## 4. checkpoint archive から restore 用 image を作成

`checkpointctl build` で checkpoint archive を restore 用 image に変換します。

```bash
sudo checkpointctl build \
  "$CHECKPOINT_ARCHIVE" \
  "$RESTORE_IMAGE"
```

作成された image を確認します。

```bash
sudo buildah images | grep checkpoint-server-source
```

---

## 5. checkpoint image を containerd の k8s.io namespace に import

Kubernetes から restore 用 image を使えるようにするため、Buildah 上の image を OCI archive として export し、containerd の `k8s.io` namespace に import します。

```bash
sudo buildah push \
  "$RESTORE_IMAGE" \
  oci-archive:/tmp/checkpoint-server-source.tar:$RESTORE_IMAGE
```

```bash
sudo ctr -n k8s.io images import /tmp/checkpoint-server-source.tar
```

containerd 側で image が見えることを確認します。

```bash
sudo ctr -n k8s.io images ls | grep checkpoint-server-source
```

CRI 経由でも image が見えることを確認します。

```bash
sudo crictl images | grep checkpoint-server-source
```

---

## 6. restore Pod を作成

checkpoint image を指定した restore Pod を作成します。

```bash
kubectl apply -f server-restore.yaml
```

restore Pod が Running / Ready になることを確認します。

```bash
kubectl get pod -n $NAMESPACE -o wide
```

必要に応じて詳細を確認します。

```bash
kubectl describe pod -n $NAMESPACE $RESTORE_POD
```

---

## 7. EndpointSlice が restore Pod を指していることを確認

Service の backend が restore Pod になっていることを確認します。

```bash
kubectl get endpointslice -n $NAMESPACE \
  -l kubernetes.io/service-name=$SERVICE \
  -o jsonpath='{range .items[*].endpoints[*]}ip={.addresses[*]} ready={.conditions.ready} target={.targetRef.name}{"\n"}{end}'
```

期待される例です。

```text
ip=192.168.xxx.xxx ready=true target=server-restore
```

---

## 8. source Pod を削除

restore Pod だけで Service 経由通信できることを確認するため、source Pod を削除します。

```bash
kubectl delete pod -n $NAMESPACE $SOURCE_POD
```

Pod の状態を確認します。

```bash
kubectl get pod -n $NAMESPACE -o wide
```

---

## 9. Service 経由で restore Pod に疎通確認

Service 経由で HTTP request を送り、応答が返ることを確認します。

```bash
kubectl run curl-test -n $NAMESPACE \
  --image=curlimages/curl:8.6.0 \
  --rm -it --restart=Never \
  -- curl -sS http://$SERVICE.$NAMESPACE.svc.cluster.local/
```

応答の `pod` や `ip` が `server-source` のままでも、EndpointSlice が `server-restore` を指していれば問題ありません。CRIU により checkpoint 時点のプロセス内部状態が復元されているためです。

---

## 10. 結果保存

必要に応じて、最終状態を保存します。

```bash
mkdir -p logs

kubectl get pod -n $NAMESPACE -o wide > logs/final-pods.txt
kubectl get endpointslice -n $NAMESPACE \
  -l kubernetes.io/service-name=$SERVICE \
  -o yaml > logs/final-endpointslice.yaml
kubectl get events -n $NAMESPACE \
  --sort-by=.metadata.creationTimestamp > logs/final-events.txt
```

---

## 11. 後片付け

```bash
kubectl delete namespace $NAMESPACE
```

---

## 自動計測: migration bottleneck 実験

研究課題として残る各区間をまとめて測る場合は、次のスクリプトを使います。

```bash
./scripts/measure-migration.sh --iterations 5
```

デフォルトでは各 iteration の前に `$NAMESPACE` を削除して作り直し、次の流れを自動で実行します。

1. 実験用リソースを作成し、source/client Pod の Ready を待つ
2. source Pod から `app` label を外して Service から drain
3. EndpointSlice から source Pod の ready endpoint が消えるまで待つ
4. checkpoint API を成功するまでリトライ
5. checkpoint archive から restore image を作成し、containerd に import
6. restore Pod を作成し、Pod Ready / EndpointSlice ready=true / Service 経由疎通を観測

結果は `logs/measurements/migration-measurements-<run_id>.csv` に保存されます。主な列は次の通りです。

| 列 | 意味 |
| --- | --- |
| `label_to_endpoint_removed_ms` | Service から外す操作を開始してから、EndpointSlice 上で source ready endpoint が消えるまで |
| `drain_to_checkpoint_ms` | Service から外す操作を開始してから、checkpoint API が初めて成功するまで |
| `checkpoint_to_restore_apply_ms` | checkpoint 成功から restore Pod apply 開始まで。restore image build/import を含む |
| `restore_image_build_import_ms` | checkpoint archive から restore image を作成し、containerd に import するまで |
| `restore_apply_to_ready_ms` | restore Pod apply 開始から Pod Ready まで |
| `restore_apply_to_endpointslice_ready_ms` | restore Pod apply 開始から EndpointSlice に restore Pod が `ready=true` で反映されるまで |
| `restore_ready_to_endpointslice_ready_ms` | restore Pod Ready から EndpointSlice `ready=true` 反映まで |
| `label_to_service_success_ms` | Service から外す操作を開始してから、Service 経由の新規 HTTP connection が初めて成功するまで |
| `endpoint_removed_to_service_success_ms` | source ready endpoint が消えてから、Service 経由の新規 HTTP connection が初めて成功するまで |
| `checkpoint_attempts` | checkpoint 成功までの API 試行回数 |

各 iteration の詳細ログは `logs/measurements/<run_id>/iteration-<N>/` に保存されます。

```text
events.jsonl         操作・観測イベントの時刻ログ
pods.txt             iteration 終了時の Pod 状態
endpointslice.yaml   iteration 終了時の EndpointSlice
k8s-events.txt       namespace 内 Kubernetes Events
checkpoint-attempt-* checkpoint API のレスポンス
```

namespace を作り直さずに現在の状態から測る場合は、次のようにします。

```bash
./scripts/measure-migration.sh --no-cleanup-before
```

実験後に namespace も削除する場合は `--cleanup-after` を付けます。

CSV から iteration ごとの stacked timeline graph を `matplotlib` で PNG として作る場合は、次のようにします。

```bash
./scripts/plot-measurements.py logs/measurements/migration-measurements-<run_id>.csv
```

出力先や形式を指定する場合は `-o` を使います。拡張子に応じて PNG / SVG / PDF などを出力できます。

```bash
./scripts/plot-measurements.py \
  logs/measurements/migration-measurements-<run_id>.csv \
  -o logs/measurements/migration-measurements-<run_id>.png
```

---

## 補足: checkpoint 失敗時の CRIU log 確認

checkpoint が失敗した場合は、CRIU の dump log を確認します。

```bash
sudo find /run/containerd/io.containerd.runtime.v2.task/k8s.io/ \
  -name criu-dump.log \
  -print
```

```bash
sudo tail -n 100 /run/containerd/io.containerd.runtime.v2.task/k8s.io/<CONTAINER_ID>/criu-dump.log
```

in-flight connection が原因の場合、次のようなエラーが出ます。

```text
Error (criu/sk-inet.c:185): inet: In-flight connection
Error (criu/sk-inet.c:186): inet: In-flight connections can be ignored with the --skip-in-flight option.
```
