# PostgreSQL development

## Composición

La plataforma separará seis raíces reconciliables:

1. `external-secrets-data`: controller ESO scoped a `reefops-data`;
2. `cloudnative-pg-stack`: CRD, RBAC y operador CloudNativePG;
3. `barman-cloud-stack`: plugin CNPG-I en el namespace del operador;
4. `postgresql-secret`: identidad S3 dedicada entregada por OpenBao/ESO;
5. `postgresql-cluster`: operando y backup;
6. `postgresql-config`: red,
   observabilidad y dashboard.

GitOps impondrá dependencias y `healthChecks`; el Cluster no podrá aparecer
antes de operador, plugin, SeaweedFS y Secret. Ninguna raíz crea entrada
norte-sur.

## Artefactos fijados

- CloudNativePG chart 0.29.0, app 1.30.0, paquete SHA-256
  `668e065ff53508d58238788fd35b355a925060843629a951df0e6a9362e6d32f`;
- Barman Cloud Plugin 0.13.0, manifest upstream SHA-256
  `d2e71e7b06822448f1a421f05781846cfdb9cc621e7ef32eef5e20c5133213b0`;
- PostgreSQL/PostGIS 18/3.6 standard-trixie, índice OCI
  `sha256:0b3f86d55fcbafad6fcde45ca58fa816d4d37bab26abc67a4cefe16d562fd05f`
  y manifiesto arm64
  `sha256:765f0fbc962916b228464330c673db5b29e88a51a8d2f2f94a754339aa18100c`.

La validación verifica las firmas Sigstore de operador y operando contra la
identidad OIDC de sus repositorios upstream. El plugin Barman no publica
firmas: su riesgo residual se limita fijando los dos digests de imagen, el
checksum del manifest de release y un mirror byte a byte del chart oficial.
No se consumen ramas, `latest` ni manifests remotos en reconciliación.

## Estado y seguridad

El operador y el plugin vivirán en `reefops-database-system`; el Cluster
`reefops-postgresql` vivirá en `reefops-data`. Development tendrá una instancia
y un PVC de 20 GiB en `reefops-hostpath-retain`. No se declarará HA.

OpenBao custodiará una identidad S3 exclusiva de Barman. ESO tendrá política y
ServiceAccount dedicadas. Las NetworkPolicy permitirán únicamente DNS, API
Kubernetes, operador↔instancia, plugin↔instancia, backup↔S3 y scrape desde
observabilidad. Los futuros clientes requerirán allowlist explícita.

El controller `external-secrets-data` pertenece a la frontera de confianza del
namespace, no a SeaweedFS ni a PostgreSQL. Cada consumidor mantiene su
ServiceAccount, TokenRequest, `SecretStore`, política OpenBao y Secret destino.
Esto permite retirar o sustituir un componente sin afectar al reconciliador de
los demás.

La ACL estática de SeaweedFS limita esa identidad al bucket
`reefops-postgresql-backup` con acciones `Read`, `Write`, `List` y `Tagging`.
No recibe `Admin` ni acceso a otros buckets. La identidad administrativa de
SeaweedFS crea el bucket una sola vez mediante una operación auditada; después
la tarea comprueba escritura, lectura y borrado con la identidad Barman sin
eliminar ni vaciar el bucket funcional.

El endpoint es interno y HTTP porque el tráfico no abandona el clúster y queda
restringido por NetworkPolicy. La protección criptográfica frente a pérdida o
compromiso del clúster se aplica a la exportación externa con `age`; habilitar
TLS también en S3 interno queda como endurecimiento antes de ejecutar en otro
host o en producción.

## Orden operativo

El primer despliegue se divide para evitar dependencias circulares:

1. reconciliar controller ESO de datos, operador CloudNativePG y plugin Barman;
2. ejecutar `task openbao-configure` desde `main`;
3. crear la credencial con
   `task postgresql-backup-credentials-bootstrap`;
4. reconciliar `reefops-seaweedfs-secret` y reiniciar únicamente el pod S3 para
   que relea la ACL estática;
5. ejecutar `task postgresql-backup-bucket-prepare`;
6. reconciliar Cluster y configuración;
7. ejecutar aceptación y recuperación.

Las tareas que usan el token raíz exigen `BAO_TOKEN` leído de forma silenciosa.
No escriben el token, la clave de acceso ni el secreto en argumentos, logs o
evidencias. Los bootstrap son create-once con CAS y las evidencias JSONL están
encadenadas mediante SHA-256.

## Operando

`reefops-postgresql` contiene una sola instancia: esto expresa capacidad real,
no una falsa alta disponibilidad dentro del mismo Mac. El PVC usa
`reefops-hostpath-retain` y la metadata heredada ordena conservarlo. El
superusuario no se publica como Secret.

La base inicial es únicamente `postgres`; las bases, propietarios, migradores
y roles runtime funcionales se crearán en raíces de cada dominio. Ningún
dominio podrá conceder permisos, crear claves foráneas, vistas o consultas
contra otro dominio.

El `ObjectStore` conserva siete días, comprime datos y WAL con gzip y fija los
ajustes de checksum necesarios para S3 compatible. El backup físico diario se
programa a las 02:15 mediante cron de seis campos y se solicita uno inmediato
al crear `ScheduledBackup`.

Prometheus recibe métricas de CloudNativePG y Barman. Las alertas cubren
indisponibilidad, retraso de réplica —aunque development tenga una instancia,
la regla ya es portable—, backup con más de 26 horas y último intento fallido.
Grafana carga el dashboard `ReefOps / PostgreSQL`.

Operador, plugin, Cluster y backup no dependen de observabilidad. Los
`PodMonitor`, reglas y dashboards se aplican después y pueden fallar o retirarse
sin impedir el servicio PostgreSQL. El sidecar Barman inyectado en la instancia
declara requests y limits propios, además de los del Deployment central.

## Gate de aceptación

La aceptación exigirá revisiones exactas, digests efectivos, ausencia de
exposición, PVC retenido, TLS y una única instancia. Creará una base sintética,
probará transacciones, rollback, constraints, PostGIS, pgvector y particionado,
reiniciará el pod y comprobará datos y UID del PVC.

Después forzará un backup Barman, restaurará a un Cluster aislado, comparará
marcador, extensiones, LSN/timeline y eliminará el destino. La copia externa se
cifrará con `age` en el destino privado allowlisted de la instalación.
Development usa actualmente el QNAP, pero el contrato admite otro NAS, disco,
cloud o medio offline sin sustituir SeaweedFS. Evidencia y cleanup serán
encadenados y fail-closed.

Un backup dentro del mismo SeaweedFS no es recuperación ante desastre. La
aceptación local solo demuestra backup/PITR. El gate de producción permanecerá
cerrado hasta que una exportación cifrada se rehidrate en almacenamiento S3
vacío y se restaure un Cluster aislado desde esa copia.

## Límites conocidos

- `10.96.0.1/32` es la dirección del API server del clúster development actual;
  un overlay futuro debe sustituirla si cambia el service CIDR.
- SeaweedFS carga su ACL estática al arrancar; tras crear o rotar una identidad
  es obligatorio un reinicio controlado del pod S3 y su verificación.
- Development usa un único disco y un único nodo. Retención de PVC y backup
  evitan borrado casual, pero no sustituyen redundancia física.
