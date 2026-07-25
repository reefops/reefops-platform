# Observabilidad mínima

## Alcance

La primera puerta de observabilidad de `development` reside en
`platform/observability-stack` y `platform/observability-config`.

`observability-stack` instala `kube-prometheus-stack` 86.0.0 desde el OCI
oficial fijado por digest. Incluye Prometheus Operator, Prometheus,
Alertmanager, `kube-state-metrics` y node-exporter. Grafana se declara
separadamente en `observability-config` para no aceptar el Secret administrador,
los sidecars ni la RBAC cluster-wide del subchart. Las imágenes efectivas,
incluidas las que el operador inyecta, están fijadas por digest.

El ownership ReefOps se expresa con labels propias de dominio. No se
sobrescriben mediante `commonLabels` las labels estándar que el chart ya
declara, porque una clave duplicada invalida el post-render estricto de Flux.

`observability-config` se aplica únicamente después de que el stack esté
preparado. Añade servicios y monitores para Flux, cert-manager y ESO, así como
las reglas propias y las políticas de red.

Ambos directorios son raíces Kustomize deliberadamente independientes y no
forman parte del agregado `platform`. GitOps reconcilia primero el stack
—incluidas sus CRD y el operador— y solo después la configuración que consume
esas API. Aplicar directamente `platform` no instala observabilidad ni elimina
esa barrera.

La Kustomization de Flux reside en `flux-system`, mientras que el HelmRelease y
sus workloads residen en `reefops-observability`; las comprobaciones operativas
deben respetar esa separación de namespaces.

Los Services adaptadores creados dentro de `flux-system`, `cert-manager` y
`reefops-secret-delivery` pertenecen a la integración de observabilidad, llevan
la etiqueta `reefops.io/metrics` y no sustituyen recursos propiedad de los
charts observados.

## Aislamiento y acceso

Prometheus, Alertmanager y Grafana solo exponen servicios `ClusterIP`. Hasta
disponer de Envoy Gateway y de identidad/autorización, el operador accede
mediante `kubectl port-forward`.

Grafana no crea un administrador inicial, Secret, sidecar ni RBAC y no admite
login básico. El acceso temporal es anónimo y de solo lectura, pero su namespace
deniega ingreso por defecto; el port-forward autenticado por Kubernetes es la
única vía operativa prevista. Kubernetes atribuye la apertura del túnel, no
cada lectura HTTP dentro de la sesión. Dashboards y datasources se aprovisionan
como ConfigMaps.

`kube-state-metrics` excluye Secrets de sus collectors. El Prometheus Operator
solo observa CR de su namespace; su RBAC cluster se limita a nodos, namespaces
y StorageClasses, y los permisos sobre Secrets residen en un Role exclusivo de
`reefops-observability`. La gestión de Services y Endpoints de kubelet está
desactivada para no conceder escritura en `kube-system`; kubelet/cAdvisor se
evaluará en una fase posterior con una integración que permita acotar el
recurso exactamente.

El node-exporter necesita mounts del host que no cumplen Pod Security
`restricted`. Se aísla en `reefops-node-observability`, el único namespace con
enforcement `privileged`, marcado con el propósito explícito
`reefops.io/privileged-purpose=node-metrics`. Una política de red solo permite
entrada desde `reefops-observability` al puerto 9100. El DaemonSet desactiva
`hostNetwork` y `hostPID`, y conserva únicamente los mounts de host requeridos,
sin propagación de mounts —Docker Desktop no expone `/` como mount compartido—,
con seccomp, root filesystem de solo lectura, sin escalado de privilegios y sin
capabilities.

El webhook de admisión del Prometheus Operator no forma parte de esta fase. Se
desactivan tanto el webhook como el TLS interno asociado para que el Deployment
no dependa de un certificado que no se genera; el servicio sigue siendo
interno y aislado por red.

## Capacidad inicial

| Componente | Persistencia | Retención/límite |
|---|---:|---:|
| Prometheus | 10 GiB | 7 días y 8 GB |
| Alertmanager | 1 GiB | 120 horas |
| Grafana | 1 GiB | configuración y estado local |

Se ejecuta una sola réplica por componente porque el clúster tiene un único
nodo. Esto no constituye alta disponibilidad. La telemetría técnica tampoco
sustituye los backups ni la auditoría funcional.

## Aceptación y evidencia

`task observability-verify` falla antes de mutar si `main` local, la fuente
Flux y las dos reconciliaciones de observabilidad no coinciden exactamente.
Después activa y retira una `PrometheusRule` sintética, comprueba su recepción
en Alertmanager mediante una anotación única, comprueba su resolución en ambos
sistemas, crea un silencio temporal y captura muestras históricas. Tras
reiniciar los tres componentes con estado, verifica que los UID de los PVC, las
muestras, el silencio, el dashboard y el datasource se conservan, y elimina
todo el estado sintético.

Cada ejecución escribe una evidencia JSONL sin secretos con identidad de
entorno, operación, correlación, causación, actor, autorización, revisiones,
digests, hash de manifiestos, UIDs, fases, tiempos, restauración y resultado.
Los registros se encadenan por SHA-256 bajo exclusión mutua, usan permisos
`0600` y un fallo al persistirlos invalida la prueba. Se conservan un año como
mínimo y `task observability-evidence-backup` los incorpora a un backup cifrado
fuera del clúster. `task observability-evidence-backup-verify` descifra una
copia temporal, contrasta manifiesto, hashes, cadena y retención, y la elimina
al terminar.

## Evolución

Loki y el recolector de logs se añadirán después de SeaweedFS y de probar
redacción y retención. OpenTelemetry Collector y Tempo se incorporarán antes
del primer servicio que emita trazas. Ninguna de estas fases enviará datos a
servicios cloud.
