{{/*
Expand the name of the chart.
*/}}
{{- define "postgres-chart.name" -}}
{{- default .Chart.Name .Values.global.postgres.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "postgres-chart.fullname" -}}
{{- if .Values.global.postgres.name }}
{{- printf "%s-%s" .Release.Name (include "postgres-chart.name" .) | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postgres-chart.labels" -}}
helm.sh/chart: {{ include "postgres-chart.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "postgres-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database # Specific component label
{{- end }}