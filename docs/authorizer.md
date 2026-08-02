# ReefOps Authorizer en development

## Límite operativo

El Authorizer vive en `reefops-identity`, usa ServiceAccount exclusiva e
inyección Linkerd por workload. Sólo Envoy puede alcanzar gRPC `9002`; sólo
Prometheus puede alcanzar el puerto administrativo `9003`. El proceso accede
únicamente a DNS, OpenFGA, PostgreSQL y el Collector OTLP. Todos los demás
ingresos y egresos se deniegan por defecto.

El Deployment consume `authorizer-security` y `openfga-runtime`, nunca material
en claro. La imagen se fija por digest y corre sin root, sin capabilities, con
filesystem de sólo lectura, seccomp y sin token de Kubernetes montado. Las
probes usan `/livez` y `/readyz`; readiness exige OpenFGA y la base de auditoría.

## Escala y disponibilidad

El servicio es stateless y el Service distribuye las llamadas gRPC entre
réplicas. Development comienza con una réplica y un HPA entre una y cinco por
CPU. Cada pod solicita CPU/memoria, limita su pool PostgreSQL y se distribuye
preferentemente entre nodos. Un PDB protege una réplica disponible durante
evicciones voluntarias; en un clúster de un nodo no equivale a alta
disponibilidad. Antes de elevar `maxReplicas` se revisan conexiones disponibles
en PostgreSQL y capacidad de OpenFGA.

El HPA no habilita retries. Envoy usa timeout acotado, `failOpen: false` y no
retransmite el mismo intento; un retry explícito recibe nuevo `attempt_id`.

## Observabilidad

Prometheus descubre el puerto `metrics` mediante `ServiceMonitor`. Las alertas
cubren ausencia de réplicas, target caído, tasa de deny/error, latencia p99 y
saturación del HPA. `kube-state-metrics` aporta Deployment, Pod, restarts y HPA;
Envoy expone métricas del controlador y del data plane, incluido el cluster
ext-auth.

El Authorizer escribe logs JSON a stdout, recuperables con Kubernetes, y envía
trazas OTLP al Collector interno. Envoy envía sus trazas al mismo Collector y
mantiene access logs JSON sin cabeceras sensibles. Métricas, logs y spans no
usan sujeto, organización, recurso, correlación o decisión como labels. La
telemetría puede degradarse sin cambiar una decisión ni sustituir la auditoría
funcional.

La entrada protegida y el data plane Envoy no se activan hasta que la
composición privada aporte el backend de trazas y pruebe métricas, logs, spans,
probes, aislamiento y escalado.
