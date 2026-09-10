{{/*
Genera un nome base univoco per la release.
*/}}
{{- define "bucket-cleaner.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}