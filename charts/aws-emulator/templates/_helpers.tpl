{{- define "aws-emulator.labels" -}}
app.kubernetes.io/name: aws-emulator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}