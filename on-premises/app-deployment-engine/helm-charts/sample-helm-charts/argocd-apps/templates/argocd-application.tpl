{{- range .Values.global.apps }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name | quote }}
  namespace: {{ $.Values.global.argocd.namespace | quote }}
  labels:
    {{- if $.Values.global.globalLabels }}
    {{- toYaml $.Values.global.globalLabels | nindent 4 }}
    {{- end }}
    {{- if .labels }}
    {{- toYaml .labels | nindent 4 }}
    {{- end }}
spec:
  project: {{.project | default "default" | quote }}
  source:
    repoURL: {{ .repoURL | quote }}
    targetRevision: {{ .targetRevision | default "HEAD" | quote }}
    path: {{ .chartFile | quote }}
    helm:
      valueFiles:
        - {{ .valuesFile | quote }}
  destination:
    server: {{ $.Values.global.argocd.destinationServer | quote }}
    namespace: {{ .namespace | quote }}
  syncPolicy:
    automated:
      prune: {{ $.Values.global.syncPolicy.prune | default false }}
      selfHeal: {{ $.Values.global.syncPolicy.selfHeal | default true }}
---
{{- end }}
