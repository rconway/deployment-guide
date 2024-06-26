#!/usr/bin/env bash

ORIG_DIR="$(pwd)"
cd "$(dirname "$0")"
BIN_DIR="$(pwd)"

onExit() {
  cd "${ORIG_DIR}"
}
trap onExit EXIT

source ../cluster/functions
configureAction "$1"
initIpDefaults

domain="${2:-${default_domain}}"
NAMESPACE="um"

main() {
  if [ "${ACTION_HELM}" = "uninstall" ]; then
    helm --namespace "${NAMESPACE}" uninstall identity-service
  else
    # helm chart
    values | helm ${ACTION_HELM} identity-service identity-service -f - \
      --repo https://eoepca.github.io/helm-charts \
      --namespace "${NAMESPACE}" --create-namespace \
      --version 1.0.98

    createIdentityApiClient
    createTestUsers
  fi
}

values() {
  cat - <<EOF
identity-keycloak:
  secrets:
    # Values for secret 'identity-keycloak'
    # Note - if ommitted, these can instead be set by creating the secret independently.
    kcDbPassword: "${IDENTITY_POSTGRES_PASSWORD}"
    keycloakAdminPassword: "${IDENTITY_SERVICE_ADMIN_PASSWORD}"
  ingress:
    enabled: true
    className: nginx
    annotations:
      ingress.kubernetes.io/ssl-redirect: "${USE_TLS}"
      nginx.ingress.kubernetes.io/ssl-redirect: "${USE_TLS}"
      cert-manager.io/cluster-issuer: ${TLS_CLUSTER_ISSUER}
    hosts:
      - host: keycloak.${domain}
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: identity-keycloak-tls
        hosts:
          - keycloak.${domain}
identity-postgres:
  secrets:
    # Values for secret 'identity-postgres'
    # Note - if ommitted, these can instead be set by creating the secret independently.
    postgresPassword: "${IDENTITY_POSTGRES_PASSWORD}"
    pgPassword: "${IDENTITY_POSTGRES_PASSWORD}"
  volumeClaim:
    name: eoepca-userman-pvc
identity-api:
  secrets:
    # Values for secret 'identity-api'
    # Note - if ommitted, these can instead be set by creating the secret independently
    # e.g. as a SealedSecret via GitOps.
    adminPassword: "${IDENTITY_SERVICE_ADMIN_PASSWORD}"
  deployment:
    # Config values that can be passed via env vars
    extraEnv:
      - name: AUTH_SERVER_URL  # see configMap.authServerUrl instead
        value: $(httpScheme)://keycloak.${domain}
      - name: ADMIN_USERNAME
        value: "${IDENTITY_SERVICE_ADMIN_USER}"
      - name: REALM
        value: "${IDENTITY_REALM}"
      # - name: VERSION
      #   value: v1.0.0
      - name: LOG_LEVEL
        value: DEBUG
identity-api-gatekeeper:
  config:
    client-id: identity-api
    discovery-url: $(httpScheme)://keycloak.${domain}/realms/master
    cookie-domain: ${domain}
  targetService:
    host: identity-api.${domain}
  secrets:
    # Values for secret 'identity-api-protection'
    # Note - if ommitted, these can instead be set by creating the secret independently.
    clientSecret: "${IDENTITY_GATEKEEPER_CLIENT_SECRET}"
    encryptionKey: "${IDENTITY_GATEKEEPER_ENCRYPTION_KEY}"
  ingress:
    annotations:
      ingress.kubernetes.io/ssl-redirect: "${USE_TLS}"
      nginx.ingress.kubernetes.io/ssl-redirect: "${USE_TLS}"
      cert-manager.io/cluster-issuer: ${TLS_CLUSTER_ISSUER}
EOF
}

createIdentityApiClient() {
  # Wait for services to be ready..
  echo "Waiting for Identity Postgres service to be ready..."
  kubectl -n "${NAMESPACE}" rollout status deploy/identity-postgres --watch
  echo "Waiting for Identity Keycloak service to be ready..."
  kubectl -n "${NAMESPACE}" rollout status deploy/identity-keycloak --watch
  echo "Waiting for Identity API service to be ready..."
  kubectl -n "${NAMESPACE}" rollout status deploy/identity-api --watch

  # Use port-forwarding to go directly to the identity-api service
  echo "Establish port-forwarding to Identity API service on port ${TEMP_FORWARDING_PORT}..."
  kubectl -n "${NAMESPACE}" port-forward svc/identity-api "${TEMP_FORWARDING_PORT}":http >/dev/null &
  portForwardPid=$!
  sleep 1

  # Create the client
  ../bin/create-client \
    -a $(httpScheme)://keycloak.${domain} \
    -i http://localhost:${TEMP_FORWARDING_PORT} \
    -r "${IDENTITY_REALM}" \
    -u "${IDENTITY_SERVICE_ADMIN_USER}" \
    -p "${IDENTITY_SERVICE_ADMIN_PASSWORD}" \
    -c "${IDENTITY_SERVICE_ADMIN_CLIENT}" \
    --id=identity-api \
    --name="Identity API Gatekeeper" \
    --secret="${IDENTITY_SERVICE_DEFAULT_SECRET}" \
    --description="Client to be used by Identity API Gatekeeper" \
    --resource="admin" \
      --uris='/*' \
      --scopes=view \
      --users="${IDENTITY_SERVICE_ADMIN_USER}"

  # Stop the port-forwarding
  echo "Stop port-forwarding to Identity API service on port ${TEMP_FORWARDING_PORT}..."
  kill -TERM $portForwardPid

  # Wait for services to be ready..
  echo "Waiting for Identity API Protection service to be ready..."
  kubectl -n "${NAMESPACE}" rollout status deploy/identity-api-protection --watch
}

createTestUsers() {
  users=("eric" "bob" "alice")
  for user in "${users[@]}"; do
    createUser "${user}"
  done
}

createUser() {
  user="$1"
  password="${IDENTITY_SERVICE_DEFAULT_SECRET}"
  ../bin/create-user \
    -a $(httpScheme)://keycloak.${domain} \
    -r "${IDENTITY_REALM}" \
    -u "${IDENTITY_SERVICE_ADMIN_USER}" \
    -p "${IDENTITY_SERVICE_ADMIN_PASSWORD}" \
    -c "${IDENTITY_SERVICE_ADMIN_CLIENT}" \
    -U "${user}" \
    -P "${password}"
}

main "$@"
