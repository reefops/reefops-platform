# NATS JetStream development

La plataforma separa `nats-stack`, propietario del HelmRelease y del operando,
de `nats-config`, propietario de red, monitorización y reglas. El stack no
depende de observabilidad; la configuración sí se aplica después de ambos.

Development ejecuta una sola réplica con JetStream sobre un PVC de 10 GiB
`reefops-hostpath-retain`. Los servicios son exclusivamente `ClusterIP` y el
puerto de monitorización solo es accesible desde `reefops-observability`.

La promoción GitOps espera al entorno development y aplica `nats-stack`; luego
aplica `nats-config` tras la observabilidad. La aceptación cubre persistencia,
deduplicación, redelivery, ACK, reinicio y ausencia de exposición. Productores
y consumidores funcionales se incorporarán después con credenciales OpenBao,
ACL por subject y reconciliaciones propias.
