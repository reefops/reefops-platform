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

La relación con los componentes observados es unidireccional. Las raíces de
OpenBao, Envoy Gateway, SeaweedFS, CloudNativePG, Barman y PostgreSQL no
dependen de `observability-stack` ni `observability-config`. Sus monitores,
reglas y dashboards sí dependen de ambas partes. Una avería de Prometheus o
Grafana degrada diagnóstico y alertado, pero no bloquea la reconciliación ni el
servicio del componente observado.

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

La retirada espera hasta seis minutos para cubrir el `resolve_timeout` de
Alertmanager; la desaparición temprana de la regla o de la serie en Prometheus
no basta para declarar el ciclo resuelto.

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

OpenTelemetry Collector 0.153.0 y Tempo 2.10.5 se incorporan antes del primer
servicio que emite trazas. El Collector acepta OTLP sólo desde workloads
allowlisted y autenticados por identidad mTLS de Linkerd, elimina atributos de
credenciales, identidad y rutas concretas, y
exporta a Tempo monolítico con almacenamiento local y siete días de retención.
Linkerd exige un cliente mTLS autenticado en ambos saltos y NetworkPolicy reduce
los productores a los pods de Authorizer, Envoy y Collector previstos. Las
políticas de identidad exacta se conservan declaradas, pero la versión edge del
policy controller no las aplica de forma fiable; no se elimina la barrera de
red hasta sustituirla por una versión que pase la aceptación de identidad.
Grafana consulta Tempo mediante un datasource interno. Ninguna telemetría se
envía a servicios cloud.

Los logs estructurados permanecen en stdout y son recuperables mediante la API
de Kubernetes. Loki y su recolector se añadirán sólo después de probar
redacción, límites y retención; hasta entonces no se declara búsqueda histórica
centralizada de logs.

## Métricas de recursos y escalado

`platform/metrics-server` instala Metrics Server 0.8.1 desde una imagen
multi-arquitectura fijada por digest. Esta raíz independiente publica
`metrics.k8s.io`, requisito operativo de los HPA de Authorizer y Envoy; declarar
un HPA sin que esa API esté disponible no constituye escalado verificado.

Docker Desktop presenta el kubelet con una cadena TLS que Metrics Server no
puede validar contra una CA de confianza. Sólo en este entorno local se usa
`--kubelet-insecure-tls`; no desactiva TLS ni la autenticación del API agregado,
pero omite la validación del certificado del kubelet. Un entorno compartido o
de producción deberá retirar ese argumento y distribuir una CA válida.

La aceptación exige que `v1beta1.metrics.k8s.io` informe `Available=True`, que
`kubectl top nodes` entregue muestras y que los HPA informen
`AbleToScale=True` y `ScalingActive=True`.
