# Workspace

The _Workspace_ provides protected user resource management that includes dedicated storage and services for resource discovery and access.

## Workspace API

The _Workspace API_ provides a REST service through which user workspaces can be created, interrogated, managed and deleted.

### Helm Chart

The _Workspace API_ is deployed via the `rm-workspace-api` helm chart from the [EOEPCA Helm Chart Repository](https://eoepca.github.io/helm-charts).

The chart is configured via values that are fully documented in the [README for the `um-workspace-api` chart](https://github.com/EOEPCA/helm-charts/tree/main/charts/rm-workspace-api#readme).

```bash
helm install --values workspace-api-values.yaml workspace-api eoepca/rm-workspace-api
```

### Values

At minimum, values for the following attributes should be specified:

* The fully-qualified public URL for the service
* (optional) Specification of Ingress for reverse-proxy access to the service<br>
  _Note that this is only required in the case that the Workspace API will **not** be protected by the `resource-guard` component - ref. [Resource Protection](../resource-protection). Otherwise the ingress will be handled by the `resource-guard` - use `ingress.enabled: false`._
* Prefix for user projects in OpenStack
* Details for underlying S3 object storage service
* Identification of secret that provides the client credentials for resource protection

Example `workspace-api-values.yaml`...
```yaml
fullnameOverride: workspace-api
ingress:
  enabled: true
  hosts:
    - host: workspace-api.192.168.49.123.nip.io
      paths: ["/"]
  tls:
    - hosts:
        - workspace-api.192.168.49.123.nip.io
      secretName: workspace-api-tls
prefixForName: "demo-user"
s3Endpoint: "https://cf2.cloudferro.com:8080"
s3Region: "RegionOne"
workspaceDomain: 192.168.49.123.nip.io
umaClientSecretName: "resman-client"
umaClientSecretNamespace: "rm"
```

### Protection

As described in [section Resource Protection](../resource-protection), the `resource-guard` component can be inserted into the request path of the Workspace API service to provide access authorization decisions

```bash
helm install --values workspace-api-guard-values.yaml workspace-api-guard eoepca/resource-guard
```

The `resource-guard` must be configured with the values applicable to the Workspace API for the _Policy Enforcement Point_ (`pep-engine`) and the _UMA User Agent_ (`uma-user-agent`)...

**Example `workspace-api-guard-values.yaml`...**

```yaml
#---------------------------------------------------------------------------
# Global values
#---------------------------------------------------------------------------
global:
  context: workspace-api
  pep: workspace-api-pep
  domain: 192.168.49.123.nip.io
  nginxIp: 192.168.49.123
  certManager:
    clusterIssuer: letsencrypt-staging
#---------------------------------------------------------------------------
# PEP values
#---------------------------------------------------------------------------
pep-engine:
  configMap:
    asHostname: auth
    pdpHostname: auth
  # customDefaultResources:
  # - name: "Eric's workspace"
  #   description: "Protected Access for eric to his user workspace"
  #   resource_uri: "/workspaces/demo-user-eric"
  #   scopes: []
  #   default_owner: "d3688daa-385d-45b0-8e04-2062e3e2cd86"
  # - name: "Bob's workspace"
  #   description: "Protected Access for bob to his user workspace"
  #   resource_uri: "/workspaces/demo-user-bob"
  #   scopes: []
  #   default_owner: "f12c2592-0332-49f4-a4fb-7063b3c2a889"
  volumeClaim:
    name: eoepca-resman-pvc
    create: false
#---------------------------------------------------------------------------
# UMA User Agent values
#---------------------------------------------------------------------------
uma-user-agent:
  fullnameOverride: workspace-api-agent
  nginxIntegration:
    enabled: true
    hosts:
      - host: workspace-api
        paths:
          - path: /(.*)
            service:
              name: workspace-api
              port: http
    annotations:
      nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
      nginx.ingress.kubernetes.io/enable-cors: "true"
      nginx.ingress.kubernetes.io/rewrite-target: /$1
  client:
    credentialsSecretName: "resman-client"
  logging:
    level: "info"
  unauthorizedResponse: 'Bearer realm="https://auth.192.168.49.123.nip.io/oxauth/auth/passport/passportlogin.htm"'
  openAccess: false
  insecureTlsSkipVerify: true
```

**NOTES:**

* TLS is enabled by the specification of `certManager.clusterIssuer`
* The `letsencrypt` Cluster Issuer relies upon the deployment being accessible from the public internet via the `global.domain` DNS name. If this is not the case, e.g. for a local minikube deployment in which this is unlikely to be so. In this case the TLS will fall-back to the self-signed certificate built-in to the nginx ingress controller
* `insecureTlsSkipVerify` may be required in the case that good TLS certificates cannot be established, e.g. if letsencrypt cannot be used for a local deployment. Otherwise the certificates offered by login-service _Authorization Server_ will fail validation in the _Resource Guard_.
* `customDefaultResources` can be specified to apply initial protection to the endpoint

### Client Secret

The Resource Guard requires confidential client credentials to be configured through the file `client.yaml`, delivered via a kubernetes secret..

**Example `client.yaml`...**

```yaml
client-id: a98ba66e-e876-46e1-8619-5e130a38d1a4
client-secret: 73914cfc-c7dd-4b54-8807-ce17c3645558
```

**Example `Secret`...**

```bash
kubectl -n rm create secret generic resman-client \
  --from-file=client.yaml \
  --dry-run=client -o yaml \
  > resman-client-secret.yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: resman-client
  namespace: rm
data:
  client.yaml: Y2xpZW50LWlkOiBhOThiYTY2ZS1lODc2LTQ2ZTEtODYxOS01ZTEzMGEzOGQxYTQKY2xpZW50LXNlY3JldDogNzM5MTRjZmMtYzdkZC00YjU0LTg4MDctY2UxN2MzNjQ1NTU4
```

The client credentials are obtained by registration of a client at the login service web interface - e.g. [https://auth.192.168.49.123.nip.io](https://auth.192.168.49.123.nip.io). In addition there is a helper script that can be used to create a basic client and obtain the credentials, as described in [section Resource Protection](../resource-protection/#client-registration)...
```bash
./local-deploy/bin/register-client auth.192.168.49.123.nip.io "Resource Guard" client.yaml
```

### Workspace API Usage

The Workspace API provides a REST interface that is accessed at the endpoint https://workspace-api.192.168.49.123.nip.io/.<br>
See the [Swagger Docs](https://workspace-api.192.168.49.123.nip.io/docs#).

### Additional Information

Additional information regarding the _Workspace API_ can be found at:

* [Helm Chart](https://github.com/EOEPCA/helm-charts/tree/main/charts/rm-workspace-api)
* [Wiki](https://github.com/EOEPCA/rm-workspace-api/wiki)
* [GitHub Repository](https://github.com/EOEPCA/rm-workspace-api)


## Bucket Operator

TBD