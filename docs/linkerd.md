# Linkerd development

Development usa el control plane comunitario edge 26.7.2 con una sola réplica,
CNI dedicado y sin extensiones viz ni multiclúster. El CNI es la única pieza
privilegiada y vive en `linkerd-cni`; permite mantener control plane y workloads
bajo Pod Security `restricted`. La inyección se habilita de forma
explícita por workload; instalar el control plane no incorpora automáticamente
OpenBao, PostgreSQL, SeaweedFS ni NATS a la malla.

cert-manager crea un trust anchor ECDSA de diez años y rota automáticamente el
issuer de identidad de 48 horas. El trust anchor requiere una ceremonia manual
de rotación coordinada y backup cifrado antes de producción. cainjector entrega
solo la CA pública al ConfigMap de Linkerd; la clave del anchor permanece en el
namespace `cert-manager` y el issuer en `linkerd`.

Las imágenes de controller y proxy se fijan por digest. La aceptación exige
CRD establecidas, issuer y control plane preparados, `linkerd check`, mTLS entre
dos workloads sintéticos y ausencia de retries implícitos sobre mutaciones.
