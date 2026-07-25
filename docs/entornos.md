# Entornos locales

## Topología inicial

El clúster `docker-desktop` alojará dos entornos lógicos: `development` y
`production`. Flux, cert-manager y los futuros controladores de gateway, malla
y operadores son infraestructura compartida. Las autoridades, datos y
workloads de ReefOps pertenecen exactamente a un entorno.

Los namespaces actuales sin sufijo se asignan transitoriamente a development y
reciben `reefops.io/environment=development`. No se renombran porque el
OpenBao operativo conserva PVC, PKI, identidad Raft y evidencias ligadas a
`reefops-secrets`.

Production usa namespaces `reefops-prod-*`, inicialmente vacíos y con
Pod Security `restricted` y denegación de red por defecto. Su OpenBao no forma
parte de esta primera entrega: requerirá PKI, almacenamiento, claves Shamir,
identidad `age`, ceremonia y recovery propios.

Los namespaces production pertenecen a
`environments/production-foundation`, separada de la reconciliación de
políticas y futuros workloads. Llevan `prune: disabled`; retirar una raíz Flux
no autoriza borrar namespaces ni datos. El decomission de un entorno tendrá un
procedimiento y aprobación específicos.

## Propiedad GitOps

`infrastructure/base` conserva temporalmente los namespaces de development y
los controladores compartidos. Las raíces `environments/development` y
`environments/production` materializan identidades de entorno independientes.
En esta fase la composición privada solo reconciliará
`reefops-production-foundation` con `prune: false`; development continúa bajo
la reconciliación existente y las raíces de identidad/policies quedan
preparadas pero no activadas. Antes del primer workload se habilitarán
`reefops-development` y `reefops-production` con RBAC y SOPS separados.

Mover los namespaces existentes desde `infrastructure/base` a la raíz de
development será una migración de ownership Flux separada. No se hará
eliminando y recreando recursos stateful.

## Aislamiento

No se compartirán entre entornos:

- OpenBao, CA, claves, tokens o identidades de backup;
- PostgreSQL, PVC, buckets o streams;
- subjects NATS, topics MQTT o credenciales de dispositivos;
- stores OpenFGA, proyectos ZITADEL o cuentas de servicio;
- datos de acuarios, modelos derivados, auditoría o retención.

Todo contrato, evento, job y evidencia incluirá `environment_id`. Las
NetworkPolicies parten de denegación total y cada apertura será declarativa,
mínima y específica.

Cada namespace recibe un ConfigMap local `reefops-environment` para que la
composición pueda inyectar el valor sin referencias cross-namespace. No es una
autoridad de seguridad: issuer, audience, ServiceAccount, endpoints y policies
deben fijar el entorno y rechazar discrepancias. Production permanecerá sin
workloads hasta disponer de RBAC/ServiceAccount Flux, clave SOPS, quotas,
authn/authz, datos, mensajería y políticas de admisión propios. Development
necesita una migración adicional a default-deny general antes de considerarse
equivalente al baseline production.

La separación es lógica. El host, control plane y administradores son
compartidos; por tanto un fallo del Mac Mini puede afectar a ambos entornos.

## Promoción

CI construye una vez y publica por digest. Development consume primero el
artefacto; production adopta el mismo digest mediante otro PR GitOps después de
las verificaciones. No se usan ramas permanentes ni recompilación por entorno.
