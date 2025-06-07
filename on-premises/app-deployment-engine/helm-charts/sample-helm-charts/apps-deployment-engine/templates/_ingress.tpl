# apps-deployment-engine/templates/_ingress.tpl
{{- define "apps-deployment-engine.ingress" -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ default (include "apps-deployment-engine.app.fullname" (dict "root" $.root "app" .app)) .app.name }}-ingress
  namespace: {{ .root.Release.Namespace }} 
  labels:
    {{- include "apps-deployment-engine.app.labels" (dict "root" $.root "app" .app) | nindent 4 }}
  {{- with .app.ingress.ingressAnnotations }} 
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .app.ingress.className }} 
  ingressClassName: {{ .app.ingress.className }}
  {{- end }}
  {{- if .app.ingress.tls }} 
  tls:
    {{- toYaml .app.ingress.tls | nindent 4 }} 
  {{- end }}
  rules:
    {{- range .app.ingress.rules }} 
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path | quote }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ default (include "apps-deployment-engine.app.fullname" (dict "root" $.root "app" $.app)) $.app.service.name }}
                port:
                  {{- if .backendServicePortName }}
                  name: {{ .backendServicePortName }}
                  {{- else if .backendServicePort }}
                  number: {{ .backendServicePort }}
                  {{- else }}
                  {{- fail "Either backendServicePort or backendServicePortName must be specified for ingress backend." }}
                  {{- end }}
          {{- end }}
    {{- end }}
  {{- if .app.ingress.defaultBackend.enabled }} 
  defaultBackend:
    service:
      name: {{ .app.ingress.defaultBackend.serviceName }}
      port:
        number: {{ .app.ingress.defaultBackend.servicePort }}
  {{- end }}
{{- end }}
