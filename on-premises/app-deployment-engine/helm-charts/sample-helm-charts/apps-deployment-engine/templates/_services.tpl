# apps-deployment-engine/templates/_service.tpl
{{- define "apps-deployment-engine.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ default (include "apps-deployment-engine.app.fullname" (dict "root" $.root "app" .app)) .app.service.name }}
  namespace: {{ .root.Release.Namespace }} 
  labels:
    {{- include "apps-deployment-engine.app.labels" (dict "root" $.root "app" .app) | nindent 4 }}
  {{- with .app.service.serviceAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  selector:
    {{- include "apps-deployment-engine.app.selectorLabels" (dict "root" $.root "app" .app) | nindent 4 }}
  ports:
    {{- range .app.service.ports }}
    - port: {{ .port }}
      targetPort: {{ .targetPort }}
      {{- if .protocol }}
      protocol: {{ .protocol }}
      {{- end }}
      {{- if .name }}
      name: {{ .name }}
      {{- end }}
    {{- end }}
  type: {{ default "ClusterIP" .app.service.type }}
  {{- if and (or (eq .app.service.type "NodePort") (eq .app.service.type "LoadBalancer")) .app.service.externalTrafficPolicy }}
  externalTrafficPolicy: {{ .app.service.externalTrafficPolicy }}
  {{- end }}
  {{- if .app.service.sessionAffinity }}
  sessionAffinity: {{ .app.service.sessionAffinity }}
  {{- end }}
  {{- if .app.service.clusterIP }}
  clusterIP: {{ .app.service.clusterIP }}
  {{- end }}
  {{- if .app.service.externalIPs }}
  externalIPs:
    {{- toYaml .app.service.externalIPs | nindent 4 }}
  {{- end }}
{{- end }}
