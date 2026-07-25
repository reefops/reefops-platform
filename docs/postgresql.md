# PostgreSQL development

## Composición

La plataforma separará cuatro raíces reconciliables:

1. `cloudnative-pg-stack`: CRD, RBAC y operador CloudNativePG;
2. `barman-cloud-stack`: plugin CNPG-I en el namespace del operador;
3. `postgresql-secret`: identidad S3 dedicada entregada por OpenBao/ESO;
4. `postgresql-cluster` y `postgresql-config`: operando, backup, red,
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

La implementación verificará firmas Sigstore, procedencia y arquitectura antes
de aceptar esos artefactos. No consumirá ramas, `latest` ni manifests remotos
en tiempo de reconciliación.

## Estado y seguridad

El operador y el plugin vivirán en `reefops-database-system`; el Cluster
`reefops-postgresql` vivirá en `reefops-data`. Development tendrá una instancia
y un PVC de 20 GiB en `reefops-hostpath-retain`. No se declarará HA.

OpenBao custodiará una identidad S3 exclusiva de Barman. ESO tendrá política y
ServiceAccount dedicadas. Las NetworkPolicy permitirán únicamente DNS, API
Kubernetes, operador↔instancia, plugin↔instancia, backup↔S3 y scrape desde
observabilidad. Los futuros clientes requerirán allowlist explícita.

## Gate de aceptación

La aceptación exigirá revisiones exactas, digests efectivos, ausencia de
exposición, PVC retenido, TLS y una única instancia. Creará una base sintética,
probará transacciones, rollback, constraints, PostGIS, pgvector y particionado,
reiniciará el pod y comprobará datos y UID del PVC.

Después forzará un backup Barman, restaurará a un Cluster aislado, comparará
marcador, extensiones, LSN/timeline y eliminará el destino. La copia externa se
cifrará con `age` en el directorio privado allowlisted del QNAP. Evidencia y
cleanup serán encadenados y fail-closed.
