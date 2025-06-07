# apps-deployment-engine/templates/_helpers.tpl
{{/*
Expand the name of the chart.
*/}}
{{- define "apps-deployment-engine.name" -}}
{{- default .Chart.Name .Values.global.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If .Values.global.app.name (per-application name) is provided, use it, otherwise fallback to chart name.
*/}}
{{- define "apps-deployment-engine.app.fullname" -}}
{{- if .app.name }}
{{- printf "%s-%s" .root.Release.Name .app.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .root.Release.Name (include "apps-deployment-engine.name" .root) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels for an application
*/}}
{{- define "apps-deployment-engine.app.labels" -}}
helm.sh/chart: {{ include "apps-deployment-engine.name" .root }}-{{ .root.Chart.Version }}
app.kubernetes.io/name: {{ .app.name | default (include "apps-deployment-engine.name" .root) }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/*
Selector labels for an application
*/}}
{{- define "apps-deployment-engine.app.selectorLabels" -}}
app.kubernetes.io/name: {{ .app.name | default (include "apps-deployment-engine.name" .root) }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}
