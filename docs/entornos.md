# Entornos

## Topología inicial

El clúster `docker-desktop` aloja un único entorno: `development`. Flux,
cert-manager y los futuros controladores de gateway, malla y operadores son
infraestructura del clúster. No se reservan namespaces, autoridades, datos o
workloads de `production` en el Mac Mini.

Los namespaces actuales sin sufijo se asignan transitoriamente a development y
reciben `reefops.io/environment=development`. No se renombran porque el
OpenBao operativo conserva PVC, PKI, identidad Raft y evidencias ligadas a
`reefops-secrets`.

`reefops-secret-delivery` aísla el controlador ESO y los Secrets que
materialice. Solo recibe la CA pública de OpenBao; las claves privadas
permanecen en `reefops-secrets`.

La composición privada local fija esa CA pública y el ClusterIP de la API
Kubernetes permitido por la NetworkPolicy. Su validación compara ambos contra
el clúster antes de promoverlos. Recrear la CA o cambiar el rango de Services
exige actualizar la composición mediante PR; una discrepancia falla cerrada.

La plataforma conserva componentes reutilizables y contratos con
`environment_id` para permitir más entornos. Crear uno nuevo requerirá una
composición GitOps explícita, un destino y controles verificados; no se
simulará mediante namespaces vacíos.

## Propiedad GitOps

`infrastructure/base` conserva temporalmente los namespaces de development y
los controladores compartidos. La raíz reutilizable
`environments/development` materializa su identidad, aunque la composición
actual continúa bajo la reconciliación existente hasta migrar ownership de
forma segura.

Mover los namespaces existentes desde `infrastructure/base` a la raíz de
development será una migración de ownership Flux separada. No se hará
eliminando y recreando recursos stateful.

Un entorno futuro tendrá su propia raíz y composición privada. Antes de su
primer workload deberá disponer de RBAC y ServiceAccount Flux, identidad SOPS,
quotas, políticas de admisión, authn/authz, datos, mensajería, almacenamiento,
backup y observabilidad propios.

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
deben fijar el entorno y rechazar discrepancias. Development necesita una
migración adicional a default-deny general.

Si varios entornos comparten un clúster, la separación será lógica y el host,
control plane y administradores serán riesgos transversales. La separación
física en clústeres distintos será preferible para production cuando se defina
su destino.

## Promoción

CI construye una vez y publica por digest. Development consume primero el
artefacto. Cuando exista production, adoptará el mismo digest mediante otro PR
GitOps después de las verificaciones. No se usan ramas permanentes ni
recompilación por entorno.
