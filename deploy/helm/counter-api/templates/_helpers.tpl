{{- define "counter-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "counter-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- include "counter-api.name" . | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "counter-api.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "counter-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "counter-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "counter-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
