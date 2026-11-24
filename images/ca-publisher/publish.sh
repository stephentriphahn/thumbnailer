#!/bin/sh
# Publishes the emulator's CA certificate to a ConfigMap, and re-publishes it whenever it changes.
set -eu

CA_FILE="${CA_FILE:-/home/emulator/.aws/emulator/9297/ca.pem}"
CONFIGMAP="${CONFIGMAP:-aws-emulator-ca}"
NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

last=""
while true; do
  if [ -f "$CA_FILE" ]; then
    current="$(sha256sum "$CA_FILE" | cut -d' ' -f1)"
    if [ "$current" != "$last" ]; then
      echo "ca.pem changed (${current}), updating ConfigMap ${NAMESPACE}/${CONFIGMAP}"
      if kubectl -n "$NAMESPACE" create configmap "$CONFIGMAP" \
          --from-file=ca.pem="$CA_FILE" --dry-run=client -o yaml \
         | kubectl -n "$NAMESPACE" apply -f -; then
        last="$current"
      else
        echo "publish failed, will retry"
      fi
    fi
  fi
  sleep 2
done
