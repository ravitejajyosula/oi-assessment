# apps-deployment-engine/templates/_deployment.tpl
{{- define "apps-deployment-engine.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "apps-deployment-engine.app.fullname" (dict "root" $.root "app" .app) }}
  namespace: {{ $.root.Release.Namespace }} 
  labels:
    {{- include "apps-deployment-engine.app.labels" (dict "root" $.root "app" .app) | nindent 4 }}
    {{- with .app.labels }} 
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  replicas: {{ .app.replicaCount }} 
  selector:
    matchLabels:
      {{- include "apps-deployment-engine.app.selectorLabels" (dict "root" $.root "app" .app) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "apps-deployment-engine.app.selectorLabels" (dict "root" $.root "app" .app) | nindent 8 }}
      {{- with .app.podAnnotations }} 
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- if .app.serviceAccountName }} 
      serviceAccountName: {{ .app.serviceAccountName }}
      {{- end }}
      {{- if .app.imagePullSecrets }} 
      imagePullSecrets:
        {{- toYaml .app.imagePullSecrets | nindent 8 }}
      {{- end }}
      {{- with .app.podSecurityContext }} 
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if .app.nodeSelector }} 
      nodeSelector:
        {{- toYaml .app.nodeSelector | nindent 8 }}
      {{- end }}
      {{- with .app.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if .app.tolerations }} 
      tolerations:
        {{- toYaml .app.tolerations | nindent 8 }}
      {{- end }}
      {{- if .app.initContainers }} 
      initContainers:
        {{- toYaml .app.initContainers | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .app.name }} 
          image: "{{ .app.image.repository }}:{{ .app.image.tag }}" 
          imagePullPolicy: {{ .app.image.pullPolicy }} 
          {{- if .app.workingDir }} 
          workingDir: {{ .app.workingDir | quote }}
          {{- end }}
          {{- if .app.command }} 
          command:
            {{- toYaml .app.command | nindent 12 }}
          {{- end }}
          {{- if .app.args }} 
          args:
            {{- toYaml .app.args | nindent 12 }}
          {{- end }}
          {{- if .app.env }} 
          env:
            {{- toYaml .app.env | nindent 12 }}
          {{- end }}
          ports:
            {{- range .app.containerPorts }} 
            - containerPort: {{ .containerPort }}
              {{- if .name }}
              name: {{ .name }}
              {{- end }}
              {{- if .protocol }}
              protocol: {{ .protocol }}
              {{- end }}
            {{- end }}
          {{- if .app.volumeMounts }} 
          volumeMounts:
            {{- toYaml .app.volumeMounts | nindent 12 }}
          {{- end }}
          {{- with .app.resources }} 
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .app.containerSecurityContext }} 
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}

          {{- if .app.livenessProbe }} 
          livenessProbe:
            {{- if .app.livenessProbe.httpGet }}
            httpGet:
              {{- toYaml .app.livenessProbe.httpGet | nindent 14 }}
            {{- else if .app.livenessProbe.tcpSocket }}
            tcpSocket:
              {{- toYaml .app.livenessProbe.tcpSocket | nindent 14 }}
            {{- else if .app.livenessProbe.exec }}
            exec:
              {{- toYaml .app.livenessProbe.exec | nindent 14 }}
            {{- end }}
            {{- if .app.livenessProbe.initialDelaySeconds }}
            initialDelaySeconds: {{ .app.livenessProbe.initialDelaySeconds }}
            {{- end }}
            {{- if .app.livenessProbe.periodSeconds }}
            periodSeconds: {{ .app.livenessProbe.periodSeconds }}
            {{- end }}
            {{- if .app.livenessProbe.timeoutSeconds }}
            timeoutSeconds: {{ .app.livenessProbe.timeoutSeconds }}
            {{- end }}
            {{- if .app.livenessProbe.successThreshold }}
            successThreshold: {{ .app.livenessProbe.successThreshold }}
            {{- end }}
            {{- if .app.livenessProbe.failureThreshold }}
            failureThreshold: {{ .app.livenessProbe.failureThreshold }}
            {{- end }}
          {{- end }}

          {{- if .app.readinessProbe }} 
          readinessProbe:
            {{- if .app.readinessProbe.httpGet }}
            httpGet:
              {{- toYaml .app.readinessProbe.httpGet | nindent 14 }}
            {{- else if .app.readinessProbe.tcpSocket }}
            tcpSocket:
              {{- toYaml .app.readinessProbe.tcpSocket | nindent 14 }}
            {{- else if .app.readinessProbe.exec }}
            exec:
              {{- toYaml .app.readinessProbe.exec | nindent 14 }}
            {{- end }}
            {{- if .app.readinessProbe.initialDelaySeconds }}
            initialDelaySeconds: {{ .app.readinessProbe.initialDelaySeconds }}
            {{- end }}
            {{- if .app.readinessProbe.periodSeconds }}
            periodSeconds: {{ .app.readinessProbe.periodSeconds }}
            {{- end }}
            {{- if .app.readinessProbe.timeoutSeconds }}
            timeoutSeconds: {{ .app.readinessProbe.timeoutSeconds }}
            {{- end }}
            {{- if .app.readinessProbe.successThreshold }}
            successThreshold: {{ .app.readinessProbe.successThreshold }}
            {{- end }}
            {{- if .app.readinessProbe.failureThreshold }}
            failureThreshold: {{ .app.readinessProbe.failureThreshold }}
            {{- end }}
          {{- end }}

      {{- if .app.volumes }} 
      volumes:
        {{- toYaml .app.volumes | nindent 8 }}
      {{- end }}
{{- end }}
{{- if .app.hpa.enabled }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "apps-deployment-engine.app.fullname" (dict "root" $.root "app" .app) }}
  namespace: {{ $.root.Release.Namespace }}
  labels:
    {{- include "apps-deployment-engine.app.labels" (dict "root" $.root "app" .app) | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "apps-deployment-engine.app.fullname" (dict "root" $.root "app" .app) }}
  minReplicas: {{ .app.hpa.minReplicas }}
  maxReplicas: {{ .app.hpa.maxReplicas }}
  {{- if .app.hpa.metrics }}
  metrics:
    {{- toYaml .app.hpa.metrics | nindent 4 }}
  {{- end }}
{{- end }}